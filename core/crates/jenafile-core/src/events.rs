//! What the core tells the UI. The UI never polls; it reacts to these.

use std::fmt;

pub type ConnectionId = u64;
pub type PromptId = u64;

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
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    StateChanged { connection: ConnectionId, state: ConnectionState },
    Log { connection: ConnectionId, hop: Hop, level: LogLevel, message: String },
    PromptRequested { prompt: PromptId, connection: ConnectionId, hop: Hop, kind: PromptKind },
}

/// Implemented by the UI layer. Called from tokio threads.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: Event);
}
