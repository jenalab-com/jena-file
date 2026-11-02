//! Thin UniFFI surface over jenafile-core: mirror types + conversions only.
//! Swift sees these names; keep them stable and UI-friendly.

use std::path::PathBuf;
use std::sync::Arc;

use jenafile_core as jc;

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn core_version() -> String {
    jc::version().to_string()
}

#[derive(uniffi::Record)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
}

/// How to reach a target.
#[derive(uniffi::Enum)]
pub enum Via {
    /// Use an open connection as the bastion (no re-authentication).
    Connection { id: u64 },
    /// Open a bastion just for this target; it closes with the target.
    Endpoint { endpoint: Endpoint },
}

#[derive(uniffi::Record)]
pub struct Connected {
    pub id: u64,
    /// Set when a bastion was opened for this target.
    pub bastion: Option<u64>,
}

#[derive(uniffi::Record)]
pub struct HostSpec {
    pub user: Option<String>,
    pub host: String,
    pub port: u16,
}

/// A pasted `ssh ...` command (기획서 FR-09).
#[derive(uniffi::Record)]
pub struct ParsedSsh {
    pub target: Option<HostSpec>,
    pub bastion: Option<HostSpec>,
    pub dropped_local_port: Option<u16>,
    pub ignored: Vec<String>,
}

#[uniffi::export]
pub fn parse_ssh_command(text: String) -> Option<ParsedSsh> {
    let h = |h: jc::HostSpec| HostSpec { user: h.user, host: h.host, port: h.port };
    jc::parse_ssh_command(&text).map(|p| ParsedSsh {
        target: p.target.map(h),
        bastion: p.bastion.map(h),
        dropped_local_port: p.dropped_local_port,
        ignored: p.ignored,
    })
}

/// A saved server (S-02). No secrets: passwords live in the Keychain by `id`.
#[derive(uniffi::Record, Clone)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub group: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub via: Option<ProfileVia>,
    pub remote_dir: Option<String>,
    pub local_dir: Option<String>,
    pub save_password: bool,
}

#[derive(uniffi::Enum, Clone)]
pub enum ProfileVia {
    Server { id: String },
    Endpoint { host: String, port: u16, user: String },
}

/// Profiles made from a pasted `ssh` command (FR-09). Not saved yet.
#[derive(uniffi::Record)]
pub struct SshProfiles {
    pub bastion: Option<Profile>,
    pub target: Profile,
}

#[uniffi::export]
pub fn profiles_from_ssh_command(text: String) -> Option<SshProfiles> {
    let parsed = jc::parse_ssh_command(&text)?;
    let (bastion, target) = jc::profiles_from_ssh(&parsed)?;
    Some(SshProfiles { bastion: bastion.map(Into::into), target: target.into() })
}

#[derive(uniffi::Record)]
pub struct RemoteEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub modified: Option<u64>,
    pub permissions: Option<u32>,
}

#[derive(uniffi::Record)]
pub struct HostKeyInfo {
    pub algorithm: String,
    pub fingerprint: String,
}

#[derive(uniffi::Record)]
pub struct InteractivePrompt {
    pub text: String,
    pub echo: bool,
}

#[derive(uniffi::Enum)]
pub enum Hop {
    Bastion,
    Target,
}

#[derive(uniffi::Enum)]
pub enum ConnectStep {
    Dialing,
    Auth,
    Sftp,
}

#[derive(uniffi::Enum)]
pub enum ConnectionState {
    Connecting { step: ConnectStep },
    Ready,
    Reconnecting { attempt: u32, max: u32 },
    Failed { error: CoreError },
    Closed,
}

#[derive(uniffi::Enum)]
pub enum LogLevel {
    Info,
    Warn,
    Error,
}

#[derive(uniffi::Enum)]
pub enum Direction {
    Upload,
    Download,
}

#[derive(uniffi::Enum)]
pub enum TransferState {
    Queued,
    Running,
    Paused,
    Waiting,
    Done,
    Skipped,
    Cancelled,
    Failed { message: String },
}

#[derive(uniffi::Record)]
pub struct TransferInfo {
    pub id: u64,
    pub connection: u64,
    pub direction: Direction,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub transferred: u64,
    pub bytes_per_sec: u64,
    pub state: TransferState,
}

#[derive(uniffi::Enum)]
pub enum ConflictAction {
    Overwrite,
    Resume,
    Rename,
    Skip,
}

#[derive(uniffi::Enum)]
pub enum PromptKind {
    HostKeyUnknown { host: String, port: u16, key: HostKeyInfo },
    HostKeyChanged { host: String, port: u16, key: HostKeyInfo },
    Password { user: String, host: String, attempt: u32 },
    KeyboardInteractive { name: String, instructions: String, prompts: Vec<InteractivePrompt> },
    Conflict {
        direction: Direction,
        destination: String,
        source_size: u64,
        source_modified: Option<u64>,
        destination_size: u64,
        destination_modified: Option<u64>,
        can_resume: bool,
    },
}

#[derive(uniffi::Enum)]
pub enum PromptAnswer {
    Accept,
    Reject,
    Secret { value: String },
    Responses { values: Vec<String> },
    Conflict { action: ConflictAction, apply_to_all: bool },
    Cancel,
}

#[derive(uniffi::Enum)]
pub enum CoreEvent {
    StateChanged { connection: u64, state: ConnectionState },
    Log { connection: u64, hop: Hop, level: LogLevel, message: String },
    PromptRequested { prompt: u64, connection: u64, hop: Hop, kind: PromptKind },
    Transfer { info: TransferInfo },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{message}")]
    Connect { hop: Hop, message: String },
    #[error("authentication failed")]
    Auth { hop: Hop },
    #[error("host key was not trusted")]
    HostKeyRejected { hop: Hop },
    #[error("host key changed")]
    HostKeyChanged { hop: Hop },
    #[error("password has expired")]
    PasswordExpired { hop: Hop },
    #[error("{message}")]
    Server { hop: Hop, message: String, detail: Option<String> },
    #[error("bastion could not reach {host}:{port}")]
    TunnelFailed { host: String, port: u16, message: String },
    #[error("{message}")]
    Local { message: String },
    #[error("cancelled")]
    Cancelled,
    #[error("not connected")]
    NotConnected { connection: u64 },
    #[error("connection limit reached")]
    LimitReached { max: u32 },
}

impl std::fmt::Debug for Hop {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self { Hop::Bastion => "bastion", Hop::Target => "target" })
    }
}

/// Implemented in Swift. Called on tokio threads — hop to the main thread there.
#[uniffi::export(foreign)]
pub trait CoreListener: Send + Sync {
    fn on_event(&self, event: CoreEvent);
}

/// One per terminal tab, implemented in Swift. Called on tokio threads.
#[uniffi::export(foreign)]
pub trait TerminalSink: Send + Sync {
    fn on_output(&self, data: Vec<u8>);
    fn on_closed(&self, exit_status: Option<u32>);
}

struct TerminalBridge(Arc<dyn TerminalSink>);

impl jc::TerminalSink for TerminalBridge {
    fn on_output(&self, data: Vec<u8>) {
        self.0.on_output(data)
    }
    fn on_closed(&self, exit_status: Option<u32>) {
        self.0.on_closed(exit_status)
    }
}

#[derive(uniffi::Object)]
pub struct Core {
    manager: jc::ConnectionManager,
    profiles: jc::ProfileStore,
}

#[uniffi::export(async_runtime = "tokio")]
impl Core {
    /// `data_dir`: app data folder (known_hosts lives there).
    /// `user_known_hosts`: read-only, usually ~/.ssh/known_hosts.
    #[uniffi::constructor]
    pub fn new(data_dir: String, user_known_hosts: Option<String>, listener: Arc<dyn CoreListener>) -> Arc<Self> {
        let config = jc::CoreConfig {
            data_dir: PathBuf::from(data_dir),
            user_known_hosts: user_known_hosts.map(PathBuf::from),
            max_connections: 3,
        };
        let profiles = jc::ProfileStore::new(&config.data_dir);
        Arc::new(Self { manager: jc::ConnectionManager::new(config, Arc::new(Sink(listener))), profiles })
    }

    /// `with_sftp = false`: terminal only (e.g. to change an expired password).
    pub async fn connect(&self, endpoint: Endpoint, via: Option<Via>, with_sftp: bool) -> Result<Connected, CoreError> {
        let via = via.map(|v| match v {
            Via::Connection { id } => jc::Via::Connection(id),
            Via::Endpoint { endpoint } => jc::Via::Endpoint(endpoint.into()),
        });
        let c = self.manager.connect(endpoint.into(), via, with_sftp).await?;
        Ok(Connected { id: c.id, bastion: c.bastion })
    }

    pub async fn home(&self, connection: u64) -> Result<String, CoreError> {
        Ok(self.manager.home(connection).await?)
    }

    pub async fn list(&self, connection: u64, path: String) -> Result<Vec<RemoteEntry>, CoreError> {
        Ok(self.manager.list(connection, path).await?.into_iter().map(Into::into).collect())
    }

    pub async fn disconnect(&self, connection: u64) {
        self.manager.disconnect(connection).await
    }

    /// Opens a shell on the connection's SSH session. `start_dir`: cd there first.
    /// `lang`: sent as LANG (like `ssh` SendEnv), e.g. "ko_KR.UTF-8".
    pub async fn open_terminal(
        &self,
        connection: u64,
        cols: u32,
        rows: u32,
        start_dir: Option<String>,
        lang: Option<String>,
        sink: Arc<dyn TerminalSink>,
    ) -> Result<u64, CoreError> {
        Ok(self.manager.open_terminal(connection, cols, rows, start_dir, lang, Arc::new(TerminalBridge(sink))).await?)
    }

    /// Queue uploads of local files / folders into `remote_dir`.
    /// `on_conflict`: answer for existing files without asking (설정); None = ask.
    pub async fn upload(
        &self,
        connection: u64,
        local_paths: Vec<String>,
        remote_dir: String,
        on_conflict: Option<ConflictAction>,
    ) -> Result<Vec<u64>, CoreError> {
        let locals = local_paths.into_iter().map(PathBuf::from).collect();
        Ok(self.manager.upload(connection, locals, remote_dir, on_conflict.map(Into::into)).await?)
    }

    /// Queue downloads of remote files / folders into `local_dir`.
    pub async fn download(
        &self,
        connection: u64,
        remote_paths: Vec<String>,
        local_dir: String,
        on_conflict: Option<ConflictAction>,
    ) -> Result<Vec<u64>, CoreError> {
        Ok(self.manager.download(connection, remote_paths, PathBuf::from(local_dir), on_conflict.map(Into::into)).await?)
    }

    /// Files transferred at once per connection (1…10).
    pub fn set_transfer_limit(&self, limit: u32) {
        self.manager.set_transfer_limit(limit)
    }

    // ---- saved servers ----

    pub fn list_profiles(&self) -> Result<Vec<Profile>, CoreError> {
        Ok(self.profiles.list()?.into_iter().map(Into::into).collect())
    }

    /// Insert or update. A new profile (empty id) gets an id.
    pub fn save_profile(&self, profile: Profile) -> Result<Profile, CoreError> {
        Ok(self.profiles.save(profile.into())?.into())
    }

    /// Fails while another server uses it as bastion.
    pub fn delete_profile(&self, id: String) -> Result<(), CoreError> {
        Ok(self.profiles.delete(&id)?)
    }

    pub fn pause_transfer(&self, transfer: u64) {
        self.manager.pause_transfer(transfer)
    }

    /// Resume / retry from the destination's current size.
    pub fn resume_transfer(&self, transfer: u64) {
        self.manager.resume_transfer(transfer)
    }

    pub fn cancel_transfer(&self, transfer: u64) {
        self.manager.cancel_transfer(transfer)
    }

    pub fn clear_finished_transfers(&self) {
        self.manager.clear_finished_transfers()
    }

    pub fn transfers_active(&self) -> bool {
        self.manager.transfers_active()
    }

    /// Synchronous on purpose: keystrokes must keep the caller's order.
    pub fn terminal_write(&self, terminal: u64, data: Vec<u8>) {
        self.manager.terminal_write(terminal, data)
    }

    pub fn terminal_resize(&self, terminal: u64, cols: u32, rows: u32) {
        self.manager.terminal_resize(terminal, cols, rows)
    }

    pub fn close_terminal(&self, terminal: u64) {
        self.manager.close_terminal(terminal)
    }

    /// Returns false if the prompt was already answered or abandoned.
    pub fn respond(&self, prompt: u64, answer: PromptAnswer) -> bool {
        self.manager.respond(prompt, answer.into())
    }
}

struct Sink(Arc<dyn CoreListener>);

impl jc::EventSink for Sink {
    fn emit(&self, event: jc::Event) {
        self.0.on_event(event.into());
    }
}

// ---- conversions -------------------------------------------------------------

impl From<Endpoint> for jc::Endpoint {
    fn from(e: Endpoint) -> Self {
        jc::Endpoint { host: e.host, port: e.port, user: e.user }
    }
}

impl From<jc::Hop> for Hop {
    fn from(h: jc::Hop) -> Self {
        match h { jc::Hop::Bastion => Hop::Bastion, jc::Hop::Target => Hop::Target }
    }
}

impl From<jc::ConnectStep> for ConnectStep {
    fn from(s: jc::ConnectStep) -> Self {
        match s {
            jc::ConnectStep::Dialing => ConnectStep::Dialing,
            jc::ConnectStep::Auth => ConnectStep::Auth,
            jc::ConnectStep::Sftp => ConnectStep::Sftp,
        }
    }
}

impl From<jc::CoreError> for CoreError {
    fn from(e: jc::CoreError) -> Self {
        use jc::CoreError as E;
        match e {
            E::Connect { hop, message } => CoreError::Connect { hop: hop.into(), message },
            E::Auth { hop } => CoreError::Auth { hop: hop.into() },
            E::HostKeyRejected { hop } => CoreError::HostKeyRejected { hop: hop.into() },
            E::HostKeyChanged { hop } => CoreError::HostKeyChanged { hop: hop.into() },
            E::PasswordExpired { hop } => CoreError::PasswordExpired { hop: hop.into() },
            E::Server { hop, message, detail } => CoreError::Server { hop: hop.into(), message, detail },
            E::TunnelFailed { host, port, message } => CoreError::TunnelFailed { host, port, message },
            E::Local { message } => CoreError::Local { message },
            E::Cancelled => CoreError::Cancelled,
            E::NotConnected(connection) => CoreError::NotConnected { connection },
            E::LimitReached { max } => CoreError::LimitReached { max },
        }
    }
}

impl From<jc::ConnectionState> for ConnectionState {
    fn from(s: jc::ConnectionState) -> Self {
        match s {
            jc::ConnectionState::Connecting { step } => ConnectionState::Connecting { step: step.into() },
            jc::ConnectionState::Ready => ConnectionState::Ready,
            jc::ConnectionState::Reconnecting { attempt, max } => ConnectionState::Reconnecting { attempt, max },
            jc::ConnectionState::Failed { error } => ConnectionState::Failed { error: error.into() },
            jc::ConnectionState::Closed => ConnectionState::Closed,
        }
    }
}

impl From<jc::LogLevel> for LogLevel {
    fn from(l: jc::LogLevel) -> Self {
        match l { jc::LogLevel::Info => LogLevel::Info, jc::LogLevel::Warn => LogLevel::Warn, jc::LogLevel::Error => LogLevel::Error }
    }
}

impl From<jc::HostKeyInfo> for HostKeyInfo {
    fn from(k: jc::HostKeyInfo) -> Self {
        HostKeyInfo { algorithm: k.algorithm, fingerprint: k.fingerprint }
    }
}

impl From<jc::PromptKind> for PromptKind {
    fn from(k: jc::PromptKind) -> Self {
        use jc::PromptKind as K;
        match k {
            K::HostKeyUnknown { host, port, key } => PromptKind::HostKeyUnknown { host, port, key: key.into() },
            K::HostKeyChanged { host, port, key } => PromptKind::HostKeyChanged { host, port, key: key.into() },
            K::Password { user, host, attempt } => PromptKind::Password { user, host, attempt },
            K::Conflict { direction, destination, source_size, source_modified, destination_size, destination_modified, can_resume } => {
                PromptKind::Conflict {
                    direction: direction.into(),
                    destination,
                    source_size,
                    source_modified,
                    destination_size,
                    destination_modified,
                    can_resume,
                }
            }
            K::KeyboardInteractive { name, instructions, prompts } => PromptKind::KeyboardInteractive {
                name,
                instructions,
                prompts: prompts.into_iter().map(|p| InteractivePrompt { text: p.text, echo: p.echo }).collect(),
            },
        }
    }
}

impl From<PromptAnswer> for jc::PromptAnswer {
    fn from(a: PromptAnswer) -> Self {
        match a {
            PromptAnswer::Accept => jc::PromptAnswer::Accept,
            PromptAnswer::Reject => jc::PromptAnswer::Reject,
            PromptAnswer::Secret { value } => jc::PromptAnswer::Secret(value),
            PromptAnswer::Responses { values } => jc::PromptAnswer::Responses(values),
            PromptAnswer::Conflict { action, apply_to_all } => jc::PromptAnswer::Conflict { action: action.into(), apply_to_all },
            PromptAnswer::Cancel => jc::PromptAnswer::Cancel,
        }
    }
}

impl From<jc::Event> for CoreEvent {
    fn from(e: jc::Event) -> Self {
        match e {
            jc::Event::StateChanged { connection, state } => CoreEvent::StateChanged { connection, state: state.into() },
            jc::Event::Log { connection, hop, level, message } => {
                CoreEvent::Log { connection, hop: hop.into(), level: level.into(), message }
            }
            jc::Event::PromptRequested { prompt, connection, hop, kind } => {
                CoreEvent::PromptRequested { prompt, connection, hop: hop.into(), kind: kind.into() }
            }
            jc::Event::Transfer(t) => CoreEvent::Transfer { info: t.into() },
        }
    }
}

impl From<jc::RemoteEntry> for RemoteEntry {
    fn from(e: jc::RemoteEntry) -> Self {
        RemoteEntry {
            name: e.name,
            size: e.size,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            modified: e.modified,
            permissions: e.permissions,
        }
    }
}

impl From<jc::Direction> for Direction {
    fn from(d: jc::Direction) -> Self {
        match d { jc::Direction::Upload => Direction::Upload, jc::Direction::Download => Direction::Download }
    }
}

impl From<jc::TransferInfo> for TransferInfo {
    fn from(t: jc::TransferInfo) -> Self {
        TransferInfo {
            id: t.id,
            connection: t.connection,
            direction: t.direction.into(),
            local_path: t.local_path,
            remote_path: t.remote_path,
            size: t.size,
            transferred: t.transferred,
            bytes_per_sec: t.bytes_per_sec,
            state: match t.state {
                jc::TransferState::Queued => TransferState::Queued,
                jc::TransferState::Running => TransferState::Running,
                jc::TransferState::Paused => TransferState::Paused,
                jc::TransferState::Waiting => TransferState::Waiting,
                jc::TransferState::Done => TransferState::Done,
                jc::TransferState::Skipped => TransferState::Skipped,
                jc::TransferState::Cancelled => TransferState::Cancelled,
                jc::TransferState::Failed { message } => TransferState::Failed { message },
            },
        }
    }
}

impl From<ConflictAction> for jc::ConflictAction {
    fn from(a: ConflictAction) -> Self {
        match a {
            ConflictAction::Overwrite => jc::ConflictAction::Overwrite,
            ConflictAction::Resume => jc::ConflictAction::Resume,
            ConflictAction::Rename => jc::ConflictAction::Rename,
            ConflictAction::Skip => jc::ConflictAction::Skip,
        }
    }
}

impl From<jc::Profile> for Profile {
    fn from(p: jc::Profile) -> Self {
        Profile {
            id: p.id,
            name: p.name,
            group: p.group,
            host: p.host,
            port: p.port,
            user: p.user,
            via: p.via.map(|v| match v {
                jc::ProfileVia::Server { id } => ProfileVia::Server { id },
                jc::ProfileVia::Endpoint { host, port, user } => ProfileVia::Endpoint { host, port, user },
            }),
            remote_dir: p.remote_dir,
            local_dir: p.local_dir,
            save_password: p.save_password,
        }
    }
}

impl From<Profile> for jc::Profile {
    fn from(p: Profile) -> Self {
        jc::Profile {
            id: p.id,
            name: p.name,
            group: p.group,
            host: p.host,
            port: p.port,
            user: p.user,
            via: p.via.map(|v| match v {
                ProfileVia::Server { id } => jc::ProfileVia::Server { id },
                ProfileVia::Endpoint { host, port, user } => jc::ProfileVia::Endpoint { host, port, user },
            }),
            remote_dir: p.remote_dir,
            local_dir: p.local_dir,
            save_password: p.save_password,
        }
    }
}
