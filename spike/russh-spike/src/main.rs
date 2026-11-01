//! russh spike for jena-file (docs/기획서.md §13 step 0).
//!
//! Checks, against real sshd:
//!   1. direct SFTP: connect, host key fingerprint, list, throughput
//!   2. keyboard-interactive auth (same mechanism as OTP)
//!   3. bastion hop (ProxyJump): SSH session over a direct-tcpip channel
//!   4. SFTP + shell channel on the same session at the same time

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use russh::client::{self, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::HashAlg;
use russh::ChannelMsg;
use russh::keys::PublicKeyOrCertificate;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
    #[arg(long, default_value = "jena")]
    user: String,
    /// Jump target user (defaults to --user)
    #[arg(long)]
    target_user: Option<String>,
    /// known_hosts name for the jump target, e.g. "localhost:2222" if it was
    /// only ever reached through `ssh -L 2222:...`
    #[arg(long)]
    target_known_as: Option<String>,
    /// Read from SPIKE_PASSWORD if omitted
    #[arg(long)]
    password: Option<String>,
    /// Use keyboard-interactive instead of password auth
    #[arg(long)]
    kbd: bool,
    /// Local file to upload then download back (throughput test)
    #[arg(long)]
    file: Option<String>,
    /// SFTP chunk size in KiB
    #[arg(long, default_value_t = 256)]
    chunk_kib: usize,
    /// SFTP requests in flight (russh-sftp default 16)
    #[arg(long, default_value_t = 16)]
    inflight: usize,
    /// SFTP write request size in KiB (russh-sftp default 32)
    #[arg(long, default_value_t = 32)]
    write_kib: u32,
    /// SSH channel window in MiB (russh default 2)
    #[arg(long, default_value_t = 2)]
    window_mib: u32,
    /// Skip the second target connection (jump mode)
    #[arg(long)]
    single: bool,
    /// Skip the shell (exec) channel next to SFTP
    #[arg(long)]
    no_shell: bool,
    /// Send SSH_FXP_INIT by hand and hex-dump the raw reply, then stop
    #[arg(long)]
    probe: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// Connect straight to host:port
    Direct { addr: String },
    /// Connect to target through bastion (like `ssh -J bastion target`)
    Jump { bastion: String, target: String },
}

struct Client {
    label: &'static str,
    host: String,
    port: u16,
}

impl client::Handler for Client {
    type Error = anyhow::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool> {
        // The real app compares against known_hosts and asks the user (AC-6).
        // The spike only proves we can see the key to make that decision.
        match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => {
                println!("[{}] host key {} {}", self.label, key.algorithm(), key.fingerprint(HashAlg::Sha256));
                // Read-only: report, never write known_hosts from the spike.
                let verdict = match russh::keys::check_known_hosts(&self.host, self.port, key) {
                    Ok(true) => "matches ~/.ssh/known_hosts".to_string(),
                    Ok(false) => "not in ~/.ssh/known_hosts (app would ask the user)".to_string(),
                    Err(e) => format!("MISMATCH/ERROR vs known_hosts: {e} (app would block)"),
                };
                println!("[{}] known_hosts [{}]:{} -> {verdict}", self.label, self.host, self.port);
            }
            PublicKeyOrCertificate::Certificate(_) => println!("[{}] host certificate", self.label),
        }
        Ok(true)
    }
}

fn split_addr(addr: &str) -> Result<(String, u16)> {
    match addr.rsplit_once(':') {
        Some((h, p)) => Ok((h.to_string(), p.parse().context("bad port")?)),
        None => Ok((addr.to_string(), 22)),
    }
}

async fn authenticate(h: &mut Handle<Client>, label: &str, user: &str, password: &str, kbd: bool) -> Result<()> {
    let started = Instant::now();
    if kbd {
        let mut reply = h.authenticate_keyboard_interactive_start(user, None).await?;
        loop {
            match reply {
                KeyboardInteractiveAuthResponse::Success => break,
                KeyboardInteractiveAuthResponse::Failure { .. } => bail!("[{label}] keyboard-interactive rejected"),
                KeyboardInteractiveAuthResponse::InfoRequest { prompts, .. } => {
                    for p in &prompts {
                        println!("[{label}] server prompt: {:?} (echo={})", p.prompt, p.echo);
                    }
                    // A real OTP prompt would be shown to the user here.
                    let answers = prompts.iter().map(|_| password.to_string()).collect();
                    reply = h.authenticate_keyboard_interactive_respond(answers).await?;
                }
            }
        }
    } else if !h.authenticate_password(user, password).await?.success() {
        bail!("[{label}] password rejected");
    }
    println!("[{label}] authenticated ({}) in {:?}", if kbd { "keyboard-interactive" } else { "password" }, started.elapsed());
    Ok(())
}

fn config(cli: &Cli) -> Arc<client::Config> {
    Arc::new(client::Config {
        keepalive_interval: Some(Duration::from_secs(30)),
        window_size: cli.window_mib * 1024 * 1024,
        ..Default::default()
    })
}

fn sftp_config(cli: &Cli) -> russh_sftp::client::Config {
    russh_sftp::client::Config {
        max_concurrent_reads: cli.inflight,
        max_concurrent_writes: cli.inflight,
        max_write_packet_len: cli.write_kib * 1024,
        ..Default::default()
    }
}

/// SFTP and a shell command running on one session concurrently (FR-30).
/// Opens the sftp subsystem and waits for the server's answer.
/// `request_subsystem` itself only sends the request, so a refusal would
/// otherwise surface later as an opaque "sender dropped".
async fn open_sftp(h: &Handle<Client>, label: &str, cli: &Cli) -> Result<SftpSession> {
    println!("[{label}] step: open session channel for sftp");
    let mut ch = h.channel_open_session().await.context("open sftp channel")?;
    println!("[{label}] step: request sftp subsystem");
    ch.request_subsystem(true, "sftp").await?;
    loop {
        match ch.wait().await {
            Some(ChannelMsg::Success) => break,
            Some(ChannelMsg::Failure) => bail!("[{label}] server refused the sftp subsystem"),
            Some(ChannelMsg::ExtendedData { data, .. }) => {
                println!("[{label}] sftp stderr: {}", String::from_utf8_lossy(&data).trim())
            }
            Some(ChannelMsg::ExitStatus { exit_status }) => println!("[{label}] sftp channel exit status {exit_status}"),
            Some(ChannelMsg::WindowAdjusted { .. }) => {}
            Some(other) => println!("[{label}] sftp channel message before reply: {other:?}"),
            None => bail!("[{label}] sftp channel closed before the server answered"),
        }
    }
    println!("[{label}] step: sftp subsystem accepted, init");
    if cli.probe {
        probe_init(h, ch, label).await?;
        std::process::exit(0);
    }
    let sftp = SftpSession::new_with_config(ch.into_stream(), sftp_config(cli))
        .await
        .context("sftp init")?;
    println!("[{label}] step: sftp ready");
    Ok(sftp)
}

/// What does the server really send back to SSH_FXP_INIT, and if it hangs
/// up, what does it say on stderr / exit status? Then read (read-only) the
/// server's sftp setup through a plain exec channel.
async fn probe_init(h: &Handle<Client>, mut ch: russh::Channel<client::Msg>, label: &str) -> Result<()> {
    ch.data(&[0u8, 0, 0, 5, 1, 0, 0, 0, 3][..]).await?;
    let mut got = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(2000), ch.wait()).await {
            Ok(Some(ChannelMsg::Data { data })) => got.extend_from_slice(&data),
            Ok(Some(ChannelMsg::ExtendedData { data, ext })) => {
                println!("[{label}] probe: stderr(ext {ext}): {:?}", String::from_utf8_lossy(&data))
            }
            Ok(Some(ChannelMsg::ExitStatus { exit_status })) => println!("[{label}] probe: exit status {exit_status}"),
            Ok(Some(ChannelMsg::ExitSignal { signal_name, error_message, .. })) => {
                println!("[{label}] probe: exit signal {signal_name:?} {error_message:?}")
            }
            Ok(Some(ChannelMsg::Eof)) => println!("[{label}] probe: eof"),
            Ok(Some(ChannelMsg::Close)) => { println!("[{label}] probe: channel closed"); break; }
            Ok(Some(other)) => println!("[{label}] probe: {other:?}"),
            Ok(None) => { println!("[{label}] probe: channel gone"); break; }
            Err(_) => break,
        }
    }
    println!("[{label}] probe: {} data bytes", got.len());
    for (i, row) in got.chunks(16).take(8).enumerate() {
        let hex: Vec<String> = row.iter().map(|b| format!("{b:02x}")).collect();
        let txt: String = row.iter().map(|&b| if (0x20..0x7f).contains(&b) { b as char } else { '.' }).collect();
        println!("  {:04x}  {:<47}  {txt}", i * 16, hex.join(" "));
    }

    let diag = "echo \"user: $(id)\"; echo \"shell: $SHELL\"; \
        grep -iE '^[[:space:]]*(subsystem|forcecommand|match|chrootdirectory)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>&1; \
        ls -l /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/libexec/sftp-server /usr/lib/sftp-server 2>&1; \
        cat /etc/os-release 2>/dev/null | head -2";
    println!("[{label}] probe: running read-only diagnostics over exec");
    let mut ex = h.channel_open_session().await.context("open diag channel")?;
    ex.exec(true, diag).await?;
    let mut out = Vec::new();
    loop {
        match tokio::time::timeout(Duration::from_secs(5), ex.wait()).await {
            Ok(Some(ChannelMsg::Data { data })) | Ok(Some(ChannelMsg::ExtendedData { data, .. })) => out.extend_from_slice(&data),
            Ok(Some(ChannelMsg::ExitStatus { exit_status })) => { println!("[{label}] diag exit {exit_status}"); }
            Ok(Some(ChannelMsg::Close)) | Ok(None) | Err(_) => break,
            _ => {}
        }
    }
    for line in String::from_utf8_lossy(&out).lines() {
        println!("  | {line}");
    }
    Ok(())
}

async fn exercise(h: &Handle<Client>, label: &str, cli: &Cli) -> Result<()> {
    let sftp = open_sftp(h, label, cli).await?;

    let home = sftp.canonicalize(".").await.context("sftp canonicalize")?;
    let names: Vec<String> = sftp.read_dir(&home).await.context("sftp read_dir")?.map(|e| e.file_name()).collect();
    println!("[{label}] sftp home {home} entries {names:?}");

    if cli.no_shell {
        if let Some(path) = &cli.file {
            throughput(&sftp, label, path, cli.chunk_kib * 1024).await?;
        }
        return Ok(());
    }
    println!("[{label}] step: open shell channel next to sftp");
    let mut exec_ch = h.channel_open_session().await.context("open shell channel")?;
    exec_ch.exec(true, "hostname && uname -sr").await?;
    // SFTP must keep working while the shell channel is open.
    let again = sftp.read_dir(&home).await.context("sftp read_dir with shell open")?.count();
    println!("[{label}] sftp still works with shell open ({again} entries)");

    let mut out = Vec::new();
    while let Some(msg) = exec_ch.wait().await {
        match msg {
            ChannelMsg::Data { data } => out.extend_from_slice(&data),
            ChannelMsg::ExitStatus { .. } | ChannelMsg::Eof => break,
            _ => {}
        }
    }
    println!("[{label}] shell channel on same session: {}", String::from_utf8_lossy(&out).trim().replace('\n', " | "));

    if let Some(path) = &cli.file {
        throughput(&sftp, label, path, cli.chunk_kib * 1024).await?;
    }
    Ok(())
}

async fn throughput(sftp: &SftpSession, label: &str, path: &str, chunk: usize) -> Result<()> {
    let size = tokio::fs::metadata(path).await?.len();
    let remote = "spike_upload.bin";
    let mb = size as f64 / 1_048_576.0;
    let mut buf = vec![0u8; chunk];

    let mut local = tokio::fs::File::open(path).await?;
    let mut rf = sftp
        .open_with_flags(remote, OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE)
        .await?;
    let t = Instant::now();
    loop {
        let n = local.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        rf.write_all(&buf[..n]).await?;
    }
    rf.shutdown().await?;
    let up = t.elapsed();
    println!("[{label}] upload   {mb:.0} MiB in {up:.2?} = {:.1} MiB/s", mb / up.as_secs_f64());

    let mut rf = sftp.open(remote).await?;
    let t = Instant::now();
    let mut got = 0u64;
    loop {
        let n = rf.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        got += n as u64;
    }
    let down = t.elapsed();
    println!("[{label}] download {mb:.0} MiB in {down:.2?} = {:.1} MiB/s", mb / down.as_secs_f64());
    if got != size {
        bail!("size mismatch: sent {size}, got {got}");
    }
    sftp.remove_file(remote).await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init(); // RUST_LOG=russh=debug for protocol-level detail
    let cli = Cli::parse();
    let password = match &cli.password {
        Some(p) => p.clone(),
        None => std::env::var("SPIKE_PASSWORD").context("set --password or SPIKE_PASSWORD")?,
    };

    match &cli.cmd {
        Cmd::Direct { addr } => {
            let (host, port) = split_addr(addr)?;
            let t = Instant::now();
            let mut h = client::connect(config(&cli), (host.as_str(), port), Client { label: "direct", host: host.clone(), port }).await?;
            authenticate(&mut h, "direct", &cli.user, &password, cli.kbd).await?;
            println!("[direct] ready in {:?}", t.elapsed());
            exercise(&h, "direct", &cli).await?;
        }
        Cmd::Jump { bastion, target } => {
            let (bh, bp) = split_addr(bastion)?;
            let (th, tp) = split_addr(target)?;
            let (kh, kp) = match &cli.target_known_as {
                Some(a) => split_addr(a)?,
                None => (th.clone(), tp),
            };
            let target_user = cli.target_user.clone().unwrap_or_else(|| cli.user.clone());
            let target_password = std::env::var("SPIKE_TARGET_PASSWORD").unwrap_or_else(|_| password.clone());
            let t = Instant::now();
            let mut b = client::connect(config(&cli), (bh.as_str(), bp), Client { label: "bastion", host: bh.clone(), port: bp }).await?;
            authenticate(&mut b, "bastion", &cli.user, &password, cli.kbd).await?;

            // Same request `ssh -L` / `ssh -J` make; no local port is opened.
            let tunnel = b.channel_open_direct_tcpip(th.as_str(), tp as u32, "127.0.0.1", 0).await?;
            let mut h = client::connect_stream(config(&cli), tunnel.into_stream(), Client { label: "target", host: kh.clone(), port: kp }).await?;
            authenticate(&mut h, "target", &target_user, &target_password, cli.kbd).await?;
            println!("[jump] ready in {:?} (bastion + target)", t.elapsed());

            // A second internal server over the same bastion session: no re-auth on bastion (AC-3).
            if !cli.single {
            let tunnel2 = b.channel_open_direct_tcpip(th.as_str(), tp as u32, "127.0.0.1", 0).await?;
            let mut h2 = client::connect_stream(config(&cli), tunnel2.into_stream(), Client { label: "target#2", host: kh.clone(), port: kp }).await?;
            authenticate(&mut h2, "target#2", &target_user, &target_password, cli.kbd).await?;
            }

            exercise(&h, "target", &cli).await?;
            // bastion shell stays usable while the target session is busy
            let mut bsh = b.channel_open_session().await?;
            bsh.exec(true, "hostname").await?;
            while let Some(msg) = bsh.wait().await {
                if let ChannelMsg::Data { data } = msg {
                    println!("[bastion] shell still alive: {}", String::from_utf8_lossy(&data).trim());
                    break;
                }
            }
        }
    }
    Ok(())
}
