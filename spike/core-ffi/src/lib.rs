//! jena-file core FFI spike: can Swift drive russh through UniFFI?
//!
//! Shape mirrors what the app needs (기획서 §11):
//! - async calls (Swift async/await) on a tokio runtime
//! - typed errors (Swift `throws`), split by hop so the UI can say which side failed
//! - events pushed from Rust to Swift (status log, host key confirmation)
//! - one `Connection` object holding SSH session + SFTP, optionally via a bastion

use std::sync::Arc;

use russh::client::{self, Handle};
use russh::keys::{HashAlg, PublicKeyOrCertificate};
use russh::ChannelMsg;
use russh_sftp::client::SftpSession;

uniffi::setup_scaffolding!();

#[derive(uniffi::Record, Clone)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
}

#[derive(uniffi::Record)]
pub struct FileEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{hop}: cannot connect: {message}")]
    Connect { hop: String, message: String },
    #[error("{hop}: authentication failed")]
    Auth { hop: String },
    #[error("{hop}: host key rejected")]
    HostKeyRejected { hop: String },
    #[error("{message}")]
    Server { message: String },
}

/// Implemented in Swift. Rust calls it from tokio threads.
#[uniffi::export(foreign)]
pub trait EventListener: Send + Sync {
    fn on_log(&self, hop: String, message: String);
    /// Return true to trust the key. Real app: compare with known_hosts, ask the user.
    fn on_host_key(&self, hop: String, algorithm: String, fingerprint: String) -> bool;
}

struct Handler {
    hop: String,
    listener: Arc<dyn EventListener>,
}

impl client::Handler for Handler {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        Ok(match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => self.listener.on_host_key(
                self.hop.clone(),
                key.algorithm().to_string(),
                key.fingerprint(HashAlg::Sha256).to_string(),
            ),
            PublicKeyOrCertificate::Certificate(_) => false,
        })
    }
}

fn config() -> Arc<client::Config> {
    // Defaults measured in the throughput spike (docs/spike/2026-11-01-russh.md).
    Arc::new(client::Config { window_size: 32 * 1024 * 1024, ..Default::default() })
}

fn sftp_config() -> russh_sftp::client::Config {
    russh_sftp::client::Config {
        max_concurrent_reads: 64,
        max_concurrent_writes: 64,
        max_write_packet_len: 128 * 1024,
        ..Default::default()
    }
}

async fn auth(h: &mut Handle<Handler>, hop: &str, ep: &Endpoint) -> Result<(), CoreError> {
    let ok = h
        .authenticate_password(&ep.user, &ep.password)
        .await
        .map_err(|e| CoreError::Connect { hop: hop.into(), message: e.to_string() })?
        .success();
    if ok { Ok(()) } else { Err(CoreError::Auth { hop: hop.into() }) }
}

fn connect_err(hop: &str, e: russh::Error) -> CoreError {
    match e {
        russh::Error::UnknownKey => CoreError::HostKeyRejected { hop: hop.into() },
        other => CoreError::Connect { hop: hop.into(), message: other.to_string() },
    }
}

#[derive(uniffi::Object)]
pub struct Connection {
    // Kept alive so the tunnel stays open; dropping it closes the hop.
    _bastion: Option<Handle<Handler>>,
    session: Handle<Handler>,
    sftp: SftpSession,
    listener: Arc<dyn EventListener>,
}

/// Connect to `target`, optionally through `via` (bastion). No local port is opened.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect(
    target: Endpoint,
    via: Option<Endpoint>,
    listener: Arc<dyn EventListener>,
) -> Result<Arc<Connection>, CoreError> {
    let (bastion, mut session) = match via {
        None => {
            listener.on_log("target".into(), format!("connecting {}:{}", target.host, target.port));
            let h = client::connect(
                config(),
                (target.host.as_str(), target.port),
                Handler { hop: "target".into(), listener: listener.clone() },
            )
            .await
            .map_err(|e| connect_err("target", e))?;
            (None, h)
        }
        Some(b) => {
            listener.on_log("bastion".into(), format!("connecting {}:{}", b.host, b.port));
            let mut bh = client::connect(
                config(),
                (b.host.as_str(), b.port),
                Handler { hop: "bastion".into(), listener: listener.clone() },
            )
            .await
            .map_err(|e| connect_err("bastion", e))?;
            auth(&mut bh, "bastion", &b).await?;
            listener.on_log("bastion".into(), "authenticated".into());
            let tunnel = bh
                .channel_open_direct_tcpip(target.host.as_str(), target.port as u32, "127.0.0.1", 0)
                .await
                .map_err(|e| CoreError::Connect { hop: "bastion→target".into(), message: e.to_string() })?;
            listener.on_log("target".into(), format!("tunnel to {}:{} open", target.host, target.port));
            let h = client::connect_stream(
                config(),
                tunnel.into_stream(),
                Handler { hop: "target".into(), listener: listener.clone() },
            )
            .await
            .map_err(|e| connect_err("target", e))?;
            (Some(bh), h)
        }
    };
    auth(&mut session, "target", &target).await?;
    listener.on_log("target".into(), "authenticated".into());

    let sftp = open_sftp(&session).await?;
    listener.on_log("target".into(), "sftp ready".into());
    Ok(Arc::new(Connection { _bastion: bastion, session, sftp, listener }))
}

/// Waits for the subsystem reply and surfaces stderr — the lesson from the
/// real-server spike (expired password showed up only on stderr).
async fn open_sftp(h: &Handle<Handler>) -> Result<SftpSession, CoreError> {
    let server = |m: String| CoreError::Server { message: m };
    let mut ch = h.channel_open_session().await.map_err(|e| server(e.to_string()))?;
    ch.request_subsystem(true, "sftp").await.map_err(|e| server(e.to_string()))?;
    loop {
        match ch.wait().await {
            Some(ChannelMsg::Success) => break,
            Some(ChannelMsg::Failure) => return Err(server("server refused sftp".into())),
            Some(ChannelMsg::WindowAdjusted { .. }) => {}
            _ => return Err(server("sftp channel closed before reply".into())),
        }
    }
    SftpSession::new_with_config(ch.into_stream(), sftp_config())
        .await
        .map_err(|e| server(format!("sftp start failed: {e}")))
}

#[uniffi::export(async_runtime = "tokio")]
impl Connection {
    pub async fn home(&self) -> Result<String, CoreError> {
        self.sftp.canonicalize(".").await.map_err(|e| CoreError::Server { message: e.to_string() })
    }

    pub async fn list(&self, path: String) -> Result<Vec<FileEntry>, CoreError> {
        let dir = self.sftp.read_dir(&path).await.map_err(|e| CoreError::Server { message: e.to_string() })?;
        let mut out: Vec<FileEntry> = dir
            .map(|e| {
                let m = e.metadata();
                FileEntry { name: e.file_name(), size: m.size.unwrap_or(0), is_dir: m.is_dir() }
            })
            .collect();
        out.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
        Ok(out)
    }

    /// Runs a command on the same SSH session as SFTP (FR-30).
    pub async fn run(&self, command: String) -> Result<String, CoreError> {
        let server = |m: String| CoreError::Server { message: m };
        let mut ch = self.session.channel_open_session().await.map_err(|e| server(e.to_string()))?;
        ch.exec(true, command.as_str()).await.map_err(|e| server(e.to_string()))?;
        let mut out = Vec::new();
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => out.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => {
                    self.listener.on_log("target".into(), format!("`{command}` exited {exit_status}"))
                }
                ChannelMsg::Close => break,
                _ => {}
            }
        }
        Ok(String::from_utf8_lossy(&out).into_owned())
    }
}
