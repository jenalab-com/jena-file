//! Connection manager and one actor (tokio task) per connection (ADR-003).
//! The actor alone owns the SSH session; everyone else sends it commands.
//!
//! Connections form a small tree (ARCHITECTURE §4.1): a target reached through a
//! bastion is a child of the bastion's connection and rides a direct-tcpip
//! channel the bastion's actor opens for it.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use crate::error::CoreError;
use crate::events::{ConflictAction, ConnectionId, ConnectionState, Event, EventSink, Hop, LogLevel, PromptAnswer, PromptId, TransferId};
use crate::prompt::PromptBroker;
use crate::transfer::{self, Transfers};
use crate::transport::{self, Files, HopContext, KnownHosts, RemoteEntry, Session, TerminalInput, TerminalSink, Tunnel};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
}

/// How to reach a target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    /// Through an already open connection, used as the bastion. No re-authentication (AC-3).
    Connection(ConnectionId),
    /// Through a bastion opened just for this target; it closes with the target.
    Endpoint(Endpoint),
}

/// What `connect` opened. `bastion` is set when a bastion was opened for this target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Connected {
    pub id: ConnectionId,
    pub bastion: Option<ConnectionId>,
}

#[derive(Debug, Clone)]
pub struct CoreConfig {
    /// `~/Library/Application Support/jena-file` on macOS. Holds the app's known_hosts.
    pub data_dir: PathBuf,
    /// Read-only. Usually `~/.ssh/known_hosts`.
    pub user_known_hosts: Option<PathBuf>,
    /// Open connections allowed at once, bastions excluded (기획서 FR-06).
    pub max_connections: u32,
}

pub type TerminalId = u64;

enum Command {
    Home(oneshot::Sender<Result<String, CoreError>>),
    List(String, oneshot::Sender<Result<Vec<RemoteEntry>, CoreError>>),
    OpenTerminal {
        cols: u32,
        rows: u32,
        start_dir: Option<String>,
        lang: Option<String>,
        sink: Arc<dyn TerminalSink>,
        reply: oneshot::Sender<Result<mpsc::UnboundedSender<TerminalInput>, CoreError>>,
    },
    OpenTunnel { host: String, port: u16, reply: oneshot::Sender<Result<Tunnel, CoreError>> },
    Files(oneshot::Sender<Result<Files, CoreError>>),
    Close(oneshot::Sender<()>),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Target,
    /// Opened only to carry a target; not counted against the limit, closed with it.
    Bastion,
}

struct Slot {
    role: Role,
    parent: Option<ConnectionId>,
    /// `None` while connecting (reserves the slot), `Some` once the actor runs.
    commands: Option<mpsc::Sender<Command>>,
}

struct Inner {
    sink: Arc<dyn EventSink>,
    prompts: Arc<PromptBroker>,
    known_hosts: Arc<KnownHosts>,
    slots: Mutex<HashMap<ConnectionId, Slot>>,
    /// Terminal input goes straight to its channel task, not through the actor:
    /// keystrokes must not wait behind a slow SFTP listing.
    terminals: Mutex<HashMap<TerminalId, (ConnectionId, mpsc::UnboundedSender<TerminalInput>)>>,
    next_id: AtomicU64,
    max_connections: u32,
    transfers: Arc<Transfers>,
}

impl Inner {
    fn emit_state(&self, connection: ConnectionId, state: ConnectionState) {
        self.sink.emit(Event::StateChanged { connection, state });
    }

    fn log(&self, connection: ConnectionId, hop: Hop, level: LogLevel, message: String) {
        self.sink.emit(Event::Log { connection, hop, level, message });
    }

    fn sender(&self, id: ConnectionId) -> Result<mpsc::Sender<Command>, CoreError> {
        self.slots.lock().unwrap().get(&id).and_then(|s| s.commands.clone()).ok_or(CoreError::NotConnected(id))
    }

    fn children(&self, id: ConnectionId) -> Vec<ConnectionId> {
        self.slots.lock().unwrap().iter().filter(|(_, s)| s.parent == Some(id)).map(|(k, _)| *k).collect()
    }
}

#[derive(Clone)]
pub struct ConnectionManager {
    inner: Arc<Inner>,
}

impl ConnectionManager {
    pub fn new(config: CoreConfig, sink: Arc<dyn EventSink>) -> Self {
        let known_hosts = KnownHosts::new(config.data_dir.join("known_hosts"), config.user_known_hosts);
        let prompts = Arc::new(PromptBroker::new(sink.clone()));
        Self {
            inner: Arc::new(Inner {
                transfers: Transfers::new(sink.clone(), prompts.clone()),
                prompts,
                sink,
                known_hosts: Arc::new(known_hosts),
                slots: Mutex::new(HashMap::new()),
                terminals: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
                max_connections: config.max_connections,
            }),
        }
    }

    /// Connects and returns once ready. Host keys and passwords are asked through
    /// `Event::PromptRequested`; answer with [`Self::respond`].
    /// `with_sftp = false` opens a terminal-only session (e.g. to change an expired password).
    pub async fn connect(&self, endpoint: Endpoint, via: Option<Via>, with_sftp: bool) -> Result<Connected, CoreError> {
        let (parent, own_bastion) = match via {
            None => (None, None),
            Some(Via::Connection(b)) => {
                self.inner.sender(b)?;
                (Some(b), None)
            }
            Some(Via::Endpoint(b)) => {
                let id = self.open(b, Role::Bastion, Hop::Bastion, None, false).await?;
                (Some(id), Some(id))
            }
        };
        match self.open(endpoint, Role::Target, Hop::Target, parent, with_sftp).await {
            Ok(id) => Ok(Connected { id, bastion: own_bastion }),
            Err(e) => {
                if let Some(b) = own_bastion {
                    self.disconnect(b).await;
                }
                Err(e)
            }
        }
    }

    async fn open(
        &self,
        endpoint: Endpoint,
        role: Role,
        hop: Hop,
        parent: Option<ConnectionId>,
        with_sftp: bool,
    ) -> Result<ConnectionId, CoreError> {
        let inner = &self.inner;
        let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
        {
            let mut slots = inner.slots.lock().unwrap();
            let targets = slots.values().filter(|s| s.role == Role::Target).count() as u32;
            if role == Role::Target && targets >= inner.max_connections {
                return Err(CoreError::LimitReached { max: inner.max_connections });
            }
            slots.insert(id, Slot { role, parent, commands: None });
        }
        let route = parent.map(|_| " via bastion").unwrap_or("");
        inner.log(id, hop, LogLevel::Info, format!("connecting to {}@{}:{}{route}", endpoint.user, endpoint.host, endpoint.port));
        let ctx = HopContext {
            connection: id,
            hop,
            host: endpoint.host.clone(),
            port: endpoint.port,
            user: endpoint.user.clone(),
            prompts: inner.prompts.clone(),
            known_hosts: inner.known_hosts.clone(),
        };
        let on_step = |step| inner.emit_state(id, ConnectionState::Connecting { step });
        let result = match parent {
            None => transport::connect_direct(ctx, with_sftp, on_step).await,
            Some(p) => match self.tunnel(p, &endpoint).await {
                Ok(tunnel) => transport::connect_via(ctx, tunnel, with_sftp, on_step).await,
                Err(e) => Err(e),
            },
        };
        match result {
            Ok(session) => {
                let (tx, rx) = mpsc::channel(32);
                if let Some(slot) = inner.slots.lock().unwrap().get_mut(&id) {
                    slot.commands = Some(tx);
                }
                tokio::spawn(run_actor(id, hop, session, rx, inner.clone()));
                inner.log(id, hop, LogLevel::Info, if with_sftp { "connected, SFTP ready" } else { "connected" }.into());
                inner.emit_state(id, ConnectionState::Ready);
                Ok(id)
            }
            Err(error) => {
                inner.slots.lock().unwrap().remove(&id);
                inner.log(id, hop, LogLevel::Error, error.to_string());
                inner.emit_state(id, ConnectionState::Failed { error: error.clone() });
                Err(error)
            }
        }
    }

    async fn tunnel(&self, bastion: ConnectionId, to: &Endpoint) -> Result<Tunnel, CoreError> {
        let (reply, rx) = oneshot::channel();
        self.send(bastion, Command::OpenTunnel { host: to.host.clone(), port: to.port, reply }).await?;
        rx.await.map_err(|_| CoreError::NotConnected(bastion))?
    }

    pub async fn home(&self, id: ConnectionId) -> Result<String, CoreError> {
        let (tx, rx) = oneshot::channel();
        self.send(id, Command::Home(tx)).await?;
        rx.await.map_err(|_| CoreError::NotConnected(id))?
    }

    pub async fn list(&self, id: ConnectionId, path: String) -> Result<Vec<RemoteEntry>, CoreError> {
        let (tx, rx) = oneshot::channel();
        self.send(id, Command::List(path, tx)).await?;
        rx.await.map_err(|_| CoreError::NotConnected(id))?
    }

    /// Closes the connection, its children first. A bastion opened for this
    /// target (`Via::Endpoint`) closes with it.
    pub async fn disconnect(&self, id: ConnectionId) {
        for child in self.inner.children(id) {
            Box::pin(self.disconnect(child)).await;
        }
        let parent = self.inner.slots.lock().unwrap().get(&id).and_then(|s| s.parent);
        let (tx, rx) = oneshot::channel();
        if self.send(id, Command::Close(tx)).await.is_ok() {
            let _ = rx.await;
        }
        if let Some(p) = parent {
            let own_bastion = self.inner.slots.lock().unwrap().get(&p).is_some_and(|s| s.role == Role::Bastion);
            // `id` may still be listed for a moment after its actor answered Close.
            if own_bastion && self.inner.children(p).iter().all(|c| *c == id) {
                Box::pin(self.disconnect(p)).await;
            }
        }
    }

    /// Queues uploads of local files / folders into `remote_dir` (folders are recreated).
    /// `on_conflict`: what to do with existing files without asking; None = ask.
    pub async fn upload(
        &self,
        id: ConnectionId,
        locals: Vec<PathBuf>,
        remote_dir: String,
        on_conflict: Option<ConflictAction>,
    ) -> Result<Vec<TransferId>, CoreError> {
        let files = self.files(id).await?;
        let jobs = transfer::plan_upload(&files, &locals, &remote_dir).await?;
        Ok(self.inner.transfers.enqueue(id, files, jobs, on_conflict))
    }

    /// Queues downloads of remote files / folders into `local_dir`.
    pub async fn download(
        &self,
        id: ConnectionId,
        remotes: Vec<String>,
        local_dir: PathBuf,
        on_conflict: Option<ConflictAction>,
    ) -> Result<Vec<TransferId>, CoreError> {
        let files = self.files(id).await?;
        let jobs = transfer::plan_download(&files, &remotes, &local_dir).await?;
        Ok(self.inner.transfers.enqueue(id, files, jobs, on_conflict))
    }

    /// Files transferred at once per connection (1…10).
    pub fn set_transfer_limit(&self, n: u32) {
        self.inner.transfers.set_limit(n as usize)
    }

    pub fn pause_transfer(&self, id: TransferId) {
        self.inner.transfers.pause(id)
    }

    /// Resume / retry from the destination's current size.
    pub fn resume_transfer(&self, id: TransferId) {
        self.inner.transfers.resume(id)
    }

    pub fn cancel_transfer(&self, id: TransferId) {
        self.inner.transfers.cancel(id)
    }

    pub fn clear_finished_transfers(&self) {
        self.inner.transfers.clear_finished()
    }

    /// True while anything is queued or running (the UI keeps the Mac awake).
    pub fn transfers_active(&self) -> bool {
        self.inner.transfers.has_active()
    }

    async fn files(&self, id: ConnectionId) -> Result<Files, CoreError> {
        let (reply, rx) = oneshot::channel();
        self.send(id, Command::Files(reply)).await?;
        rx.await.map_err(|_| CoreError::NotConnected(id))?
    }

    /// Opens a shell tab on the connection's SSH session (same login as SFTP).
    pub async fn open_terminal(
        &self,
        id: ConnectionId,
        cols: u32,
        rows: u32,
        start_dir: Option<String>,
        lang: Option<String>,
        sink: Arc<dyn TerminalSink>,
    ) -> Result<TerminalId, CoreError> {
        let (reply, rx) = oneshot::channel();
        self.send(id, Command::OpenTerminal { cols, rows, start_dir, lang, sink, reply }).await?;
        let input = rx.await.map_err(|_| CoreError::NotConnected(id))??;
        let terminal = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        self.inner.terminals.lock().unwrap().insert(terminal, (id, input));
        Ok(terminal)
    }

    /// Keystrokes / paste. Synchronous so callers keep their order.
    pub fn terminal_write(&self, terminal: TerminalId, data: Vec<u8>) {
        self.terminal_send(terminal, TerminalInput::Data(data));
    }

    pub fn terminal_resize(&self, terminal: TerminalId, cols: u32, rows: u32) {
        self.terminal_send(terminal, TerminalInput::Resize { cols, rows });
    }

    pub fn close_terminal(&self, terminal: TerminalId) {
        self.terminal_send(terminal, TerminalInput::Close);
        self.inner.terminals.lock().unwrap().remove(&terminal);
    }

    fn terminal_send(&self, terminal: TerminalId, input: TerminalInput) {
        if let Some((_, tx)) = self.inner.terminals.lock().unwrap().get(&terminal) {
            let _ = tx.send(input);
        }
    }

    /// Answer a prompt. Returns false if it was already answered or abandoned.
    pub fn respond(&self, prompt: PromptId, answer: PromptAnswer) -> bool {
        self.inner.prompts.respond(prompt, answer)
    }

    async fn send(&self, id: ConnectionId, cmd: Command) -> Result<(), CoreError> {
        self.inner.sender(id)?.send(cmd).await.map_err(|_| CoreError::NotConnected(id))
    }
}

async fn run_actor(id: ConnectionId, hop: Hop, session: Session, mut rx: mpsc::Receiver<Command>, inner: Arc<Inner>) {
    // Reconnect comes in M6; for now a dead session is reported and the slot freed.
    // A child behind a dead bastion notices here too: its tunnel closes with it.
    let mut liveness = tokio::time::interval(Duration::from_secs(2));
    let end = loop {
        tokio::select! {
            cmd = rx.recv() => match cmd {
                Some(Command::Home(reply)) => { let _ = reply.send(session.home(hop).await); }
                Some(Command::List(path, reply)) => { let _ = reply.send(session.list(hop, &path).await); }
                Some(Command::OpenTerminal { cols, rows, start_dir, lang, sink, reply }) => {
                    let _ = reply.send(session.open_terminal(hop, cols, rows, start_dir, lang, sink).await);
                }
                Some(Command::OpenTunnel { host, port, reply }) => {
                    let _ = reply.send(session.open_tunnel(&host, port).await);
                }
                Some(Command::Files(reply)) => { let _ = reply.send(session.files(hop)); }
                Some(Command::Close(reply)) => {
                    session.close().await;
                    let _ = reply.send(());
                    break ConnectionState::Closed;
                }
                None => { session.close().await; break ConnectionState::Closed; }
            },
            _ = liveness.tick() => if session.is_closed() {
                let error = CoreError::Connect { hop, message: "connection lost".into() };
                inner.log(id, hop, LogLevel::Error, error.to_string());
                break ConnectionState::Failed { error };
            }
        }
    };
    let parent = inner.slots.lock().unwrap().remove(&id).and_then(|s| s.parent);
    inner.terminals.lock().unwrap().retain(|_, (conn, _)| *conn != id);
    inner.transfers.connection_closed(id);
    // A bastion opened only for this target has nothing left to carry.
    if let Some(p) = parent {
        let slots = inner.slots.lock().unwrap();
        let orphan = slots.get(&p).is_some_and(|s| s.role == Role::Bastion)
            && !slots.values().any(|s| s.parent == Some(p));
        if let Some(tx) = slots.get(&p).and_then(|s| s.commands.clone()).filter(|_| orphan) {
            let (reply, _) = oneshot::channel();
            let _ = tx.try_send(Command::Close(reply));
        }
    }
    if end == ConnectionState::Closed {
        inner.log(id, hop, LogLevel::Info, "disconnected".into());
    }
    inner.emit_state(id, end);
}
