//! Connection manager and one actor (tokio task) per connection (ADR-003).
//! The actor alone owns the SSH session; everyone else sends it commands.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use crate::error::CoreError;
use crate::events::{ConnectionId, ConnectionState, Event, EventSink, Hop, LogLevel, PromptAnswer, PromptId};
use crate::prompt::PromptBroker;
use crate::transport::{self, HopContext, KnownHosts, RemoteEntry, Session};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
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

enum Command {
    Home(oneshot::Sender<Result<String, CoreError>>),
    List(String, oneshot::Sender<Result<Vec<RemoteEntry>, CoreError>>),
    Close(oneshot::Sender<()>),
}

/// `None` while connecting (reserves a slot), `Some` once the actor runs.
type Slots = Mutex<HashMap<ConnectionId, Option<mpsc::Sender<Command>>>>;

struct Inner {
    sink: Arc<dyn EventSink>,
    prompts: Arc<PromptBroker>,
    known_hosts: Arc<KnownHosts>,
    slots: Slots,
    next_id: AtomicU64,
    max_connections: u32,
}

impl Inner {
    fn emit_state(&self, connection: ConnectionId, state: ConnectionState) {
        self.sink.emit(Event::StateChanged { connection, state });
    }

    fn log(&self, connection: ConnectionId, level: LogLevel, message: String) {
        self.sink.emit(Event::Log { connection, hop: Hop::Target, level, message });
    }

    fn sender(&self, id: ConnectionId) -> Result<mpsc::Sender<Command>, CoreError> {
        self.slots.lock().unwrap().get(&id).cloned().flatten().ok_or(CoreError::NotConnected(id))
    }
}

#[derive(Clone)]
pub struct ConnectionManager {
    inner: Arc<Inner>,
}

impl ConnectionManager {
    pub fn new(config: CoreConfig, sink: Arc<dyn EventSink>) -> Self {
        let known_hosts = KnownHosts::new(config.data_dir.join("known_hosts"), config.user_known_hosts);
        Self {
            inner: Arc::new(Inner {
                prompts: Arc::new(PromptBroker::new(sink.clone())),
                sink,
                known_hosts: Arc::new(known_hosts),
                slots: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
                max_connections: config.max_connections,
            }),
        }
    }

    /// Connects and returns once SFTP is ready. Host key and password are
    /// asked through `Event::PromptRequested`; answer with [`Self::respond`].
    pub async fn connect(&self, endpoint: Endpoint) -> Result<ConnectionId, CoreError> {
        let inner = &self.inner;
        let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
        {
            let mut slots = inner.slots.lock().unwrap();
            if slots.len() as u32 >= inner.max_connections {
                return Err(CoreError::LimitReached { max: inner.max_connections });
            }
            slots.insert(id, None);
        }
        inner.log(id, LogLevel::Info, format!("connecting to {}@{}:{}", endpoint.user, endpoint.host, endpoint.port));
        let ctx = HopContext {
            connection: id,
            hop: Hop::Target,
            host: endpoint.host.clone(),
            port: endpoint.port,
            user: endpoint.user.clone(),
            prompts: inner.prompts.clone(),
            known_hosts: inner.known_hosts.clone(),
        };
        let result = transport::connect_direct(ctx, |step| {
            inner.emit_state(id, ConnectionState::Connecting { step });
        })
        .await;
        match result {
            Ok(session) => {
                let (tx, rx) = mpsc::channel(32);
                inner.slots.lock().unwrap().insert(id, Some(tx));
                tokio::spawn(run_actor(id, session, rx, inner.clone()));
                inner.log(id, LogLevel::Info, "connected, SFTP ready".into());
                inner.emit_state(id, ConnectionState::Ready);
                Ok(id)
            }
            Err(error) => {
                inner.slots.lock().unwrap().remove(&id);
                inner.log(id, LogLevel::Error, error.to_string());
                inner.emit_state(id, ConnectionState::Failed { error: error.clone() });
                Err(error)
            }
        }
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

    pub async fn disconnect(&self, id: ConnectionId) {
        let (tx, rx) = oneshot::channel();
        if self.send(id, Command::Close(tx)).await.is_ok() {
            let _ = rx.await;
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

async fn run_actor(id: ConnectionId, session: Session, mut rx: mpsc::Receiver<Command>, inner: Arc<Inner>) {
    // Reconnect comes in M6; for now a dead session is reported and the slot freed.
    let mut liveness = tokio::time::interval(Duration::from_secs(2));
    let end = loop {
        tokio::select! {
            cmd = rx.recv() => match cmd {
                Some(Command::Home(reply)) => { let _ = reply.send(session.home(Hop::Target).await); }
                Some(Command::List(path, reply)) => { let _ = reply.send(session.list(Hop::Target, &path).await); }
                Some(Command::Close(reply)) => {
                    session.close().await;
                    let _ = reply.send(());
                    break ConnectionState::Closed;
                }
                None => { session.close().await; break ConnectionState::Closed; }
            },
            _ = liveness.tick() => if session.is_closed() {
                let error = CoreError::Connect { hop: Hop::Target, message: "connection lost".into() };
                inner.log(id, LogLevel::Error, error.to_string());
                break ConnectionState::Failed { error };
            }
        }
    };
    inner.slots.lock().unwrap().remove(&id);
    if end == ConnectionState::Closed {
        inner.log(id, LogLevel::Info, "disconnected".into());
    }
    inner.emit_state(id, end);
}
