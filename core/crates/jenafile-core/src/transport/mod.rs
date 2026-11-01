//! The only module that uses russh (ARCHITECTURE §1-2). Nothing russh-typed leaves it.

mod known_hosts;

use std::sync::{Arc, Mutex};

use russh::client::{self, AuthResult, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::{HashAlg, PublicKeyOrCertificate};
use russh::{ChannelMsg, MethodKind};
use russh_sftp::client::SftpSession;

pub(crate) use known_hosts::KnownHosts;
use known_hosts::Trust;

use crate::error::CoreError;
use crate::events::{ConnectionId, HostKeyInfo, Hop, InteractivePrompt, PromptAnswer, PromptKind};
use crate::prompt::PromptBroker;

/// Measured in the throughput spike (docs/spike/2026-11-01-russh.md).
const CHANNEL_WINDOW: u32 = 32 * 1024 * 1024;
const SFTP_IN_FLIGHT: usize = 64;
const SFTP_WRITE_LEN: u32 = 128 * 1024;
const PASSWORD_ATTEMPTS: u32 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    pub is_symlink: bool,
    /// Unix seconds
    pub modified: Option<u64>,
    /// Unix mode bits (lower 12 bits are permissions)
    pub permissions: Option<u32>,
}

/// What a hop needs to ask the user and check keys.
#[derive(Clone)]
pub(crate) struct HopContext {
    pub connection: ConnectionId,
    pub hop: Hop,
    pub host: String,
    pub port: u16,
    pub user: String,
    pub prompts: Arc<PromptBroker>,
    pub known_hosts: Arc<KnownHosts>,
}

struct Handler {
    ctx: HopContext,
    /// Why the key check said no, so the caller can report it precisely.
    refusal: Arc<Mutex<Option<CoreError>>>,
}

impl client::Handler for Handler {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let ctx = &self.ctx;
        let PublicKeyOrCertificate::PublicKey { key, .. } = key else {
            *self.refusal.lock().unwrap() = Some(CoreError::HostKeyRejected { hop: ctx.hop });
            return Ok(false);
        };
        let info = HostKeyInfo {
            algorithm: key.algorithm().to_string(),
            fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
        };
        let (kind, refusal) = match ctx.known_hosts.check(&ctx.host, ctx.port, key) {
            Trust::Known => return Ok(true),
            Trust::Unknown => (
                PromptKind::HostKeyUnknown { host: ctx.host.clone(), port: ctx.port, key: info },
                CoreError::HostKeyRejected { hop: ctx.hop },
            ),
            Trust::Changed => (
                PromptKind::HostKeyChanged { host: ctx.host.clone(), port: ctx.port, key: info },
                CoreError::HostKeyChanged { hop: ctx.hop },
            ),
        };
        if ctx.prompts.ask(ctx.connection, ctx.hop, kind).await == PromptAnswer::Accept {
            if let Err(e) = ctx.known_hosts.remember(&ctx.host, ctx.port, key) {
                log::warn!("could not record host key: {e}");
            }
            return Ok(true);
        }
        *self.refusal.lock().unwrap() = Some(refusal);
        Ok(false)
    }
}

pub(crate) struct Session {
    handle: Handle<Handler>,
    sftp: SftpSession,
}

fn client_config() -> Arc<client::Config> {
    Arc::new(client::Config { window_size: CHANNEL_WINDOW, ..Default::default() })
}

fn sftp_config() -> russh_sftp::client::Config {
    russh_sftp::client::Config {
        max_concurrent_reads: SFTP_IN_FLIGHT,
        max_concurrent_writes: SFTP_IN_FLIGHT,
        max_write_packet_len: SFTP_WRITE_LEN,
        ..Default::default()
    }
}

/// Dial, verify host key, authenticate, open SFTP. `on_step` reports progress.
pub(crate) async fn connect_direct(
    ctx: HopContext,
    mut on_step: impl FnMut(crate::events::ConnectStep),
) -> Result<Session, CoreError> {
    use crate::events::ConnectStep;
    on_step(ConnectStep::Dialing);
    let refusal = Arc::new(Mutex::new(None));
    let handler = Handler { ctx: ctx.clone(), refusal: refusal.clone() };
    let mut handle = client::connect(client_config(), (ctx.host.as_str(), ctx.port), handler)
        .await
        .map_err(|e| refusal.lock().unwrap().take().unwrap_or(CoreError::Connect { hop: ctx.hop, message: e.to_string() }))?;
    on_step(ConnectStep::Auth);
    authenticate(&mut handle, &ctx).await?;
    on_step(ConnectStep::Sftp);
    let sftp = open_sftp(&handle, ctx.hop).await?;
    Ok(Session { handle, sftp })
}

async fn authenticate(handle: &mut Handle<Handler>, ctx: &HopContext) -> Result<(), CoreError> {
    let connect_err = |e: russh::Error| CoreError::Connect { hop: ctx.hop, message: e.to_string() };
    for attempt in 1..=PASSWORD_ATTEMPTS {
        let kind = PromptKind::Password { user: ctx.user.clone(), host: ctx.host.clone(), attempt };
        let password = match ctx.prompts.ask(ctx.connection, ctx.hop, kind).await {
            PromptAnswer::Secret(p) => p,
            _ => return Err(CoreError::Cancelled),
        };
        match handle.authenticate_password(&ctx.user, password).await.map_err(connect_err)? {
            AuthResult::Success => return Ok(()),
            AuthResult::Failure { remaining_methods, .. } => {
                // Servers with PAM often refuse "password" but accept keyboard-interactive.
                if !remaining_methods.contains(&MethodKind::Password)
                    && remaining_methods.contains(&MethodKind::KeyboardInteractive)
                {
                    return keyboard_interactive(handle, ctx).await;
                }
            }
        }
    }
    Err(CoreError::Auth { hop: ctx.hop })
}

async fn keyboard_interactive(handle: &mut Handle<Handler>, ctx: &HopContext) -> Result<(), CoreError> {
    let connect_err = |e: russh::Error| CoreError::Connect { hop: ctx.hop, message: e.to_string() };
    let mut reply = handle.authenticate_keyboard_interactive_start(&ctx.user, None).await.map_err(connect_err)?;
    loop {
        match reply {
            KeyboardInteractiveAuthResponse::Success => return Ok(()),
            KeyboardInteractiveAuthResponse::Failure { .. } => return Err(CoreError::Auth { hop: ctx.hop }),
            KeyboardInteractiveAuthResponse::InfoRequest { name, instructions, prompts } => {
                let answers = if prompts.is_empty() {
                    Vec::new()
                } else {
                    let kind = PromptKind::KeyboardInteractive {
                        name,
                        instructions,
                        prompts: prompts.into_iter().map(|p| InteractivePrompt { text: p.prompt, echo: p.echo }).collect(),
                    };
                    match ctx.prompts.ask(ctx.connection, ctx.hop, kind).await {
                        PromptAnswer::Responses(r) => r,
                        PromptAnswer::Secret(s) => vec![s],
                        _ => return Err(CoreError::Cancelled),
                    }
                };
                reply = handle.authenticate_keyboard_interactive_respond(answers).await.map_err(connect_err)?;
            }
        }
    }
}

/// `request_subsystem` does not wait for the server's answer, so wait here.
/// The SFTP stream drops stderr; if SFTP dies early, ask the server why on a
/// second channel. An expired password only ever shows up there (real-server spike).
async fn open_sftp(handle: &Handle<Handler>, hop: Hop) -> Result<SftpSession, CoreError> {
    let server = |message: String| CoreError::Server { hop, message, detail: None };
    let mut ch = handle.channel_open_session().await.map_err(|e| server(e.to_string()))?;
    ch.request_subsystem(true, "sftp").await.map_err(|e| server(e.to_string()))?;
    loop {
        match ch.wait().await {
            Some(ChannelMsg::Success) => break,
            Some(ChannelMsg::Failure) => return Err(server("server refused SFTP".into())),
            // Window adjustments can arrive before the reply.
            Some(ChannelMsg::WindowAdjusted { .. }) => continue,
            Some(other) => log::debug!("before sftp reply: {other:?}"),
            None => return Err(server("SFTP channel closed".into())),
        }
    }
    match SftpSession::new_with_config(ch.into_stream(), sftp_config()).await {
        Ok(s) => Ok(s),
        Err(e) => Err(classify_sftp_failure(hop, &e.to_string(), diagnose(handle).await)),
    }
}

/// Runs a no-op command and returns whatever the server printed (both streams).
async fn diagnose(handle: &Handle<Handler>) -> Option<String> {
    let mut ch = handle.channel_open_session().await.ok()?;
    ch.exec(true, "true").await.ok()?;
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
    while let Ok(Some(msg)) = tokio::time::timeout_at(deadline, ch.wait()).await {
        match msg {
            ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => out.extend_from_slice(&data),
            ChannelMsg::Close => break,
            _ => {}
        }
    }
    let text = String::from_utf8_lossy(&out).trim().to_string();
    (!text.is_empty()).then_some(text)
}

pub(crate) fn classify_sftp_failure(hop: Hop, error: &str, server_said: Option<String>) -> CoreError {
    if let Some(said) = &server_said {
        if said.to_ascii_lowercase().contains("password has expired") {
            return CoreError::PasswordExpired { hop };
        }
    }
    CoreError::Server { hop, message: format!("SFTP could not start ({error})"), detail: server_said }
}

impl Session {
    pub(crate) async fn home(&self, hop: Hop) -> Result<String, CoreError> {
        self.sftp.canonicalize(".").await.map_err(|e| sftp_err(hop, e))
    }

    pub(crate) async fn list(&self, hop: Hop, path: &str) -> Result<Vec<RemoteEntry>, CoreError> {
        let dir = self.sftp.read_dir(path).await.map_err(|e| sftp_err(hop, e))?;
        let mut entries: Vec<RemoteEntry> = dir
            .filter(|e| e.file_name() != "." && e.file_name() != "..")
            .map(|e| {
                let m = e.metadata();
                RemoteEntry {
                    name: e.file_name(),
                    size: m.size.unwrap_or(0),
                    is_dir: m.is_dir(),
                    is_symlink: m.is_symlink(),
                    modified: m.mtime.map(u64::from),
                    permissions: m.permissions,
                }
            })
            .collect();
        sort_entries(&mut entries);
        Ok(entries)
    }

    pub(crate) async fn close(&self) {
        let _ = self.sftp.close().await;
        let _ = self.handle.disconnect(russh::Disconnect::ByApplication, "", "en").await;
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.handle.is_closed()
    }
}

/// Output side of a remote terminal. Implemented by the UI (one per terminal tab).
pub trait TerminalSink: Send + Sync {
    fn on_output(&self, data: Vec<u8>);
    fn on_closed(&self, exit_status: Option<u32>);
}

pub(crate) enum TerminalInput {
    Data(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
}

/// Coalesce output for up to this long so a flood of small packets becomes a
/// few UI updates (ARCHITECTURE §8). Small enough not to be felt while typing.
const OUTPUT_COALESCE: std::time::Duration = std::time::Duration::from_millis(4);
const OUTPUT_MAX_BATCH: usize = 64 * 1024;

impl Session {
    /// Opens a PTY shell on this same SSH session (FR-30) and wires it to `sink`.
    /// Returns the input sender; dropping it or sending `Close` ends the shell.
    pub(crate) async fn open_terminal(
        &self,
        hop: Hop,
        cols: u32,
        rows: u32,
        start_dir: Option<String>,
        sink: std::sync::Arc<dyn TerminalSink>,
    ) -> Result<tokio::sync::mpsc::UnboundedSender<TerminalInput>, CoreError> {
        let server = |e: russh::Error| CoreError::Server { hop, message: e.to_string(), detail: None };
        let ch = self.handle.channel_open_session().await.map_err(server)?;
        let (mut read, write) = ch.split();
        write.request_pty(true, "xterm-256color", cols, rows, 0, 0, &[]).await.map_err(server)?;
        write.request_shell(true).await.map_err(server)?;
        if let Some(dir) = start_dir {
            // SSH has no "start in this directory"; type it for the user.
            write.data_bytes(format!("cd {} && clear\n", shell_quote(&dir)).into_bytes()).await.map_err(server)?;
        }

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TerminalInput>();
        // Input: keystrokes in order (unbounded + sync send keeps caller order).
        tokio::spawn(async move {
            while let Some(input) = rx.recv().await {
                let ok = match input {
                    TerminalInput::Data(d) => write.data_bytes(d).await.is_ok(),
                    TerminalInput::Resize { cols, rows } => write.window_change(cols, rows, 0, 0).await.is_ok(),
                    TerminalInput::Close => break,
                };
                if !ok {
                    break;
                }
            }
            let _ = write.eof().await;
            let _ = write.close().await;
        });
        // Output: coalesce, forward, report exit.
        tokio::spawn(async move {
            let mut exit = None;
            let mut buf: Vec<u8> = Vec::new();
            loop {
                let next = if buf.is_empty() {
                    read.wait().await
                } else {
                    match tokio::time::timeout(OUTPUT_COALESCE, read.wait()).await {
                        Ok(m) => m,
                        Err(_) => {
                            sink.on_output(std::mem::take(&mut buf));
                            continue;
                        }
                    }
                };
                match next {
                    Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                        buf.extend_from_slice(&data);
                        if buf.len() >= OUTPUT_MAX_BATCH {
                            sink.on_output(std::mem::take(&mut buf));
                        }
                    }
                    Some(ChannelMsg::ExitStatus { exit_status }) => exit = Some(exit_status),
                    Some(_) => {}
                    None => break,
                }
            }
            if !buf.is_empty() {
                sink.on_output(buf);
            }
            sink.on_closed(exit);
        });
        Ok(tx)
    }
}

/// Single-quote for POSIX shells: 'it'\''s' style.
pub(crate) fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn sftp_err(hop: Hop, e: russh_sftp::client::error::Error) -> CoreError {
    CoreError::Server { hop, message: e.to_string(), detail: None }
}

/// Folders first, then case-insensitive by name.
pub(crate) fn sort_entries(entries: &mut [RemoteEntry]) {
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, is_dir: bool) -> RemoteEntry {
        RemoteEntry { name: name.into(), size: 0, is_dir, is_symlink: false, modified: None, permissions: None }
    }

    #[test]
    fn folders_first_then_name_ignoring_case() {
        let mut v = vec![entry("b.txt", false), entry("Zeta", true), entry("A.txt", false), entry("alpha", true)];
        sort_entries(&mut v);
        let names: Vec<_> = v.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["alpha", "Zeta", "A.txt", "b.txt"]);
    }

    #[test]
    fn shell_quote_survives_spaces_and_quotes() {
        assert_eq!(shell_quote("/var/www"), "'/var/www'");
        assert_eq!(shell_quote("/tmp/it's here"), "'/tmp/it'\\''s here'");
    }

    #[test]
    fn expired_password_is_recognised_from_server_output() {
        let said = "WARNING: Your password has expired.\nPassword change required but no TTY available.";
        assert_eq!(
            classify_sftp_failure(Hop::Target, "sender dropped", Some(said.into())),
            CoreError::PasswordExpired { hop: Hop::Target }
        );
        assert!(matches!(
            classify_sftp_failure(Hop::Target, "sender dropped", Some("subsystem request failed".into())),
            CoreError::Server { detail: Some(_), .. }
        ));
    }
}
