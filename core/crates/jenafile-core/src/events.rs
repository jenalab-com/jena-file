//! What the core tells the UI. The UI never polls; it reacts to these.

use std::fmt;

pub type ConnectionId = u64;
pub type PromptId = u64;
pub type TransferId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Upload,
    Download,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransferState {
    Queued,
    Running,
    Paused,
    Done,
    Skipped,
    Cancelled,
    Failed { message: String },
}

/// One file in the transfer queue, as the UI shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferInfo {
    pub id: TransferId,
    pub connection: ConnectionId,
    pub direction: Direction,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub transferred: u64,
    /// Smoothed, 0 when not running.
    pub bytes_per_sec: u64,
    pub state: TransferState,
}

/// What to do when the destination already exists (기획서 FR-14).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictAction {
    Overwrite,
    /// Continue a partial file from its current size.
    Resume,
    /// Keep both: `name (1).ext`.
    Rename,
    Skip,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hop {
    Bastion,
    Target,
}

impl fmt::Display for Hop {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Hop::Bastion => "bastion",
            Hop::Target => "target",
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectStep {
    Dialing,
    Auth,
    Sftp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    Connecting { step: ConnectStep },
    Ready,
    Failed { error: crate::CoreError },
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyInfo {
    pub algorithm: String,
    /// `SHA256:...`, same format as `ssh-keygen -l`
    pub fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InteractivePrompt {
    pub text: String,
    pub echo: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptKind {
    HostKeyUnknown { host: String, port: u16, key: HostKeyInfo },
    /// The key differs from the recorded one. Possible attack; the UI must warn loudly.
    HostKeyChanged { host: String, port: u16, key: HostKeyInfo },
    Password { user: String, host: String, attempt: u32 },
    /// The destination exists. `can_resume` when it is smaller than the source.
    Conflict {
        direction: Direction,
        destination: String,
        source_size: u64,
        source_modified: Option<u64>,
        destination_size: u64,
        destination_modified: Option<u64>,
        can_resume: bool,
    },
    /// Server-driven questions (OTP etc.).
    KeyboardInteractive { name: String, instructions: String, prompts: Vec<InteractivePrompt> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptAnswer {
    /// Host key: trust and remember.
    Accept,
    Reject,
    Secret(String),
    Responses(Vec<String>),
    /// For `Conflict`; `apply_to_all` covers the rest of the same batch.
    Conflict { action: ConflictAction, apply_to_all: bool },
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    StateChanged { connection: ConnectionId, state: ConnectionState },
    Log { connection: ConnectionId, hop: Hop, level: LogLevel, message: String },
    PromptRequested { prompt: PromptId, connection: ConnectionId, hop: Hop, kind: PromptKind },
    /// Queue changes and progress (progress at most ~10 times a second per item).
    Transfer(TransferInfo),
}

/// Implemented by the UI layer. Called from tokio threads.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: Event);
}
