//! jena-file core. Everything stateful lives here; the native UIs stay thin.
//! See docs/ARCHITECTURE.md for the module plan.

mod connection;
mod error;
mod events;
mod prompt;
mod ssh_command;
mod transport;

pub use connection::{Connected, ConnectionManager, CoreConfig, Endpoint, TerminalId, Via};
pub use error::CoreError;
pub use events::{
    ConnectStep, ConnectionId, ConnectionState, Event, EventSink, HostKeyInfo, Hop, InteractivePrompt,
    LogLevel, PromptAnswer, PromptId, PromptKind,
};
pub use ssh_command::{HostSpec, ParsedSsh, parse_ssh_command};
pub use transport::{RemoteEntry, TerminalSink};

/// Core library version, shown in the app so a stale xcframework is easy to spot.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_matches_manifest() {
        assert_eq!(super::version(), env!("CARGO_PKG_VERSION"));
    }
}
