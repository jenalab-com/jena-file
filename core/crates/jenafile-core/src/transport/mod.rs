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
    /// None for terminal-only sessions (bastions, password change).
    /// Shared with transfer workers so copies do not queue behind the actor.
    sftp: Option<Arc<SftpSession>>,
}

/// A direct-tcpip channel through a bastion, ready to carry the next SSH session.
pub(crate) struct Tunnel(russh::ChannelStream<client::Msg>);

fn client_config() -> Arc<client::Config> {
    Arc::new(client::Config {
        window_size: CHANNEL_WINDOW,
        // Notice a silently dead link (no RST, e.g. Wi-Fi gone) within ~30 s so
        // reconnect can start (AC-5).
        keepalive_interval: Some(std::time::Duration::from_secs(10)),
        keepalive_max: 3,
        ..Default::default()
    })
}

fn sftp_config() -> russh_sftp::client::Config {
    russh_sftp::client::Config {
        max_concurrent_reads: SFTP_IN_FLIGHT,
        max_concurrent_writes: SFTP_IN_FLIGHT,
        max_write_packet_len: SFTP_WRITE_LEN,
        ..Default::default()
    }
}

/// Dial, verify host key, authenticate, optionally open SFTP.
pub(crate) async fn connect_direct(
    ctx: HopContext,
    with_sftp: bool,
    mut on_step: impl FnMut(crate::events::ConnectStep),
) -> Result<Session, CoreError> {
    on_step(crate::events::ConnectStep::Dialing);
    let refusal = Arc::new(Mutex::new(None));
    let handler = Handler { ctx: ctx.clone(), refusal: refusal.clone() };
    let handle = client::connect(client_config(), (ctx.host.as_str(), ctx.port), handler)
        .await
        .map_err(|e| refusal.lock().unwrap().take().unwrap_or(CoreError::Connect { hop: ctx.hop, message: e.to_string() }))?;
    finish(handle, &ctx, with_sftp, on_step).await
}

/// Same as [`connect_direct`] but over a bastion tunnel (`ssh -J`). End-to-end
/// encrypted: the bastion only relays bytes and never sees these credentials.
pub(crate) async fn connect_via(
    ctx: HopContext,
    tunnel: Tunnel,
    with_sftp: bool,
    mut on_step: impl FnMut(crate::events::ConnectStep),
) -> Result<Session, CoreError> {
    on_step(crate::events::ConnectStep::Dialing);
    let refusal = Arc::new(Mutex::new(None));
    let handler = Handler { ctx: ctx.clone(), refusal: refusal.clone() };
    let handle = client::connect_stream(client_config(), tunnel.0, handler)
        .await
        .map_err(|e| refusal.lock().unwrap().take().unwrap_or(CoreError::Connect { hop: ctx.hop, message: e.to_string() }))?;
    finish(handle, &ctx, with_sftp, on_step).await
}

async fn finish(
    mut handle: Handle<Handler>,
    ctx: &HopContext,
    with_sftp: bool,
    mut on_step: impl FnMut(crate::events::ConnectStep),
) -> Result<Session, CoreError> {
    on_step(crate::events::ConnectStep::Auth);
    authenticate(&mut handle, ctx).await?;
    let sftp = if with_sftp {
        on_step(crate::events::ConnectStep::Sftp);
        Some(Arc::new(open_sftp(&handle, ctx.hop).await?))
    } else {
        None
    };
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
    fn sftp(&self, hop: Hop) -> Result<&SftpSession, CoreError> {
        self.sftp.as_deref().ok_or(CoreError::Server { hop, message: "this connection has no SFTP".into(), detail: None })
    }

    /// A handle transfer workers can use concurrently with the actor.
    pub(crate) fn files(&self, hop: Hop) -> Result<Files, CoreError> {
        self.sftp(hop)?;
        Ok(Files { sftp: self.sftp.clone().unwrap(), hop })
    }

    /// Ask the bastion to open a channel to host:port (what `ssh -L` / `-J` do).
    pub(crate) async fn open_tunnel(&self, host: &str, port: u16) -> Result<Tunnel, CoreError> {
        let ch = self
            .handle
            .channel_open_direct_tcpip(host, port as u32, "127.0.0.1", 0)
            .await
            .map_err(|e| CoreError::TunnelFailed { host: host.into(), port, message: e.to_string() })?;
        Ok(Tunnel(ch.into_stream()))
    }

    pub(crate) async fn home(&self, hop: Hop) -> Result<String, CoreError> {
        self.sftp(hop)?.canonicalize(".").await.map_err(|e| sftp_err(hop, e))
    }

    pub(crate) async fn list(&self, hop: Hop, path: &str) -> Result<Vec<RemoteEntry>, CoreError> {
        let dir = self.sftp(hop)?.read_dir(path).await.map_err(|e| sftp_err(hop, e))?;
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
        if let Some(sftp) = &self.sftp {
            let _ = sftp.close().await;
        }
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
        lang: Option<String>,
        sink: std::sync::Arc<dyn TerminalSink>,
    ) -> Result<tokio::sync::mpsc::UnboundedSender<TerminalInput>, CoreError> {
        let server = |e: russh::Error| CoreError::Server { hop, message: e.to_string(), detail: None };
        let ch = self.handle.channel_open_session().await.map_err(server)?;
        let (mut read, write) = ch.split();
        if let Some(lang) = lang {
            // Like OpenSSH's `SendEnv LANG`: without it the shell runs in the POSIX
            // locale and swallows multibyte input (Korean never echoed back).
            // Servers accept it only with `AcceptEnv LANG` (Debian/Ubuntu default).
            write.set_env(false, "LANG", lang).await.map_err(server)?;
        }
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

/// Copy buffer for transfers; SFTP pipelining (SFTP_IN_FLIGHT) does the rest.
const COPY_CHUNK: usize = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RemoteStat {
    pub size: u64,
    pub modified: Option<u64>,
    pub is_dir: bool,
}

/// SFTP file operations for transfers. Cheap to clone.
#[derive(Clone)]
pub(crate) struct Files {
    sftp: Arc<SftpSession>,
    hop: Hop,
}

fn local_err(e: std::io::Error) -> CoreError {
    CoreError::Local { message: e.to_string() }
}

impl Files {
    /// `None` when the path does not exist.
    pub(crate) async fn stat(&self, path: &str) -> Result<Option<RemoteStat>, CoreError> {
        match self.sftp.metadata(path).await {
            Ok(m) => Ok(Some(RemoteStat { size: m.size.unwrap_or(0), modified: m.mtime.map(u64::from), is_dir: m.is_dir() })),
            Err(russh_sftp::client::error::Error::Status(s)) if s.status_code == russh_sftp::protocol::StatusCode::NoSuchFile => Ok(None),
            Err(e) => Err(sftp_err(self.hop, e)),
        }
    }

    /// `mkdir -p`
    pub(crate) async fn mkdir_all(&self, path: &str) -> Result<(), CoreError> {
        let mut cur = String::new();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            cur.push('/');
            cur.push_str(part);
            if self.stat(&cur).await?.is_none() {
                self.sftp.create_dir(cur.as_str()).await.map_err(|e| sftp_err(self.hop, e))?;
            }
        }
        Ok(())
    }

    /// Every entry under `root` as (path relative to root, stat), folders included.
    pub(crate) async fn walk(&self, root: &str) -> Result<Vec<(String, RemoteStat)>, CoreError> {
        let mut out = Vec::new();
        let mut stack = vec![String::new()];
        while let Some(rel) = stack.pop() {
            let dir = if rel.is_empty() { root.to_string() } else { format!("{}/{}", root.trim_end_matches('/'), rel) };
            for e in self.sftp.read_dir(&dir).await.map_err(|e| sftp_err(self.hop, e))? {
                let name = e.file_name();
                if name == "." || name == ".." {
                    continue;
                }
                let m = e.metadata();
                let child = if rel.is_empty() { name } else { format!("{rel}/{name}") };
                let st = RemoteStat { size: m.size.unwrap_or(0), modified: m.mtime.map(u64::from), is_dir: m.is_dir() };
                if st.is_dir {
                    stack.push(child.clone());
                }
                out.push((child, st));
            }
        }
        Ok(out)
    }

    /// Uploads `local` to `remote` starting at `offset` (0 = replace the file).
    pub(crate) async fn upload(&self, local: &std::path::Path, remote: &str, offset: u64, progress: &std::sync::atomic::AtomicU64) -> Result<(), CoreError> {
        use russh_sftp::protocol::OpenFlags;
        use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
        let mut src = tokio::fs::File::open(local).await.map_err(local_err)?;
        src.seek(std::io::SeekFrom::Start(offset)).await.map_err(local_err)?;
        let flags = if offset == 0 { OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE } else { OpenFlags::WRITE };
        let mut dst = self.sftp.open_with_flags(remote, flags).await.map_err(|e| sftp_err(self.hop, e))?;
        let io = |e: std::io::Error| CoreError::Server { hop: self.hop, message: e.to_string(), detail: None };
        if offset > 0 {
            dst.seek(std::io::SeekFrom::Start(offset)).await.map_err(io)?;
        }
        let mut buf = vec![0u8; COPY_CHUNK];
        loop {
            let n = src.read(&mut buf).await.map_err(local_err)?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await.map_err(io)?;
            progress.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
        }
        dst.shutdown().await.map_err(io)
    }

    /// Downloads `remote` into `local` starting at `offset` (0 = replace the file).
    pub(crate) async fn download(&self, remote: &str, local: &std::path::Path, offset: u64, progress: &std::sync::atomic::AtomicU64) -> Result<(), CoreError> {
        use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
        let io = |e: std::io::Error| CoreError::Server { hop: self.hop, message: e.to_string(), detail: None };
        let mut src = self.sftp.open(remote).await.map_err(|e| sftp_err(self.hop, e))?;
        if offset > 0 {
            src.seek(std::io::SeekFrom::Start(offset)).await.map_err(io)?;
        }
        let mut dst = tokio::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(offset == 0)
            .open(local)
            .await
            .map_err(local_err)?;
        dst.seek(std::io::SeekFrom::Start(offset)).await.map_err(local_err)?;
        let mut buf = vec![0u8; COPY_CHUNK];
        loop {
            let n = src.read(&mut buf).await.map_err(io)?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await.map_err(local_err)?;
            progress.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
        }
        dst.flush().await.map_err(local_err)
    }
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
