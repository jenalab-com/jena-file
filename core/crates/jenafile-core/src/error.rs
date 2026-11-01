use crate::events::Hop;

/// Every failure says which hop failed so the UI can tell the user where to look
/// (docs/ARCHITECTURE.md §1-5).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CoreError {
    #[error("{hop}: cannot connect: {message}")]
    Connect { hop: Hop, message: String },
    #[error("{hop}: authentication failed")]
    Auth { hop: Hop },
    #[error("{hop}: host key was not trusted")]
    HostKeyRejected { hop: Hop },
    #[error("{hop}: host key changed and was not accepted")]
    HostKeyChanged { hop: Hop },
    #[error("{hop}: password has expired; change it in a terminal")]
    PasswordExpired { hop: Hop },
    /// Server-side failure. `detail` carries what the server said (stderr / exit status).
    #[error("{hop}: {message}")]
    Server { hop: Hop, message: String, detail: Option<String> },
    /// The bastion is fine but could not reach the next host (AC-4).
    #[error("bastion could not reach {host}:{port}: {message}")]
    TunnelFailed { host: String, port: u16, message: String },
    /// A problem on this Mac's side (local file not readable, disk full…).
    #[error("local: {message}")]
    Local { message: String },
    #[error("cancelled")]
    Cancelled,
    #[error("connection {0} is not open")]
    NotConnected(u64),
    #[error("at most {max} connections can be open")]
    LimitReached { max: u32 },
}
