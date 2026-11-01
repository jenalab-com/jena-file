//! Shared helpers for the Docker integration tests (tests/docker).
#![allow(dead_code)]

use std::sync::{Arc, Mutex, OnceLock};

use jenafile_core::*;

pub const HOST: &str = "127.0.0.1";
pub const PORT: u16 = 2201;

/// Answers prompts like a scripted user and records what was asked.
pub struct Script {
    pub manager: OnceLock<ConnectionManager>,
    pub host_key: PromptAnswer,
    pub passwords: Mutex<Vec<String>>,
    pub asked: Mutex<Vec<PromptKind>>,
    /// Hop of each prompt in `asked`, same order.
    pub hops: Mutex<Vec<Hop>>,
    pub events: Mutex<Vec<Event>>,
}

impl EventSink for Script {
    fn emit(&self, event: Event) {
        self.events.lock().unwrap().push(event.clone());
        if let Event::PromptRequested { prompt, kind, hop, .. } = event {
            self.asked.lock().unwrap().push(kind.clone());
            self.hops.lock().unwrap().push(hop);
            let answer = match kind {
                PromptKind::HostKeyUnknown { .. } | PromptKind::HostKeyChanged { .. } => self.host_key.clone(),
                PromptKind::Password { .. } => {
                    let mut pw = self.passwords.lock().unwrap();
                    if pw.is_empty() { PromptAnswer::Cancel } else { PromptAnswer::Secret(pw.remove(0)) }
                }
                PromptKind::KeyboardInteractive { .. } => PromptAnswer::Cancel,
            };
            assert!(self.manager.get().unwrap().respond(prompt, answer));
        }
    }
}

pub fn setup(dir: &std::path::Path, host_key: PromptAnswer, passwords: &[&str], max: u32) -> (ConnectionManager, Arc<Script>) {
    let script = Arc::new(Script {
        manager: OnceLock::new(),
        host_key,
        passwords: Mutex::new(passwords.iter().map(|s| s.to_string()).collect()),
        asked: Mutex::new(vec![]),
        hops: Mutex::new(vec![]),
        events: Mutex::new(vec![]),
    });
    let config = CoreConfig { data_dir: dir.to_path_buf(), user_known_hosts: None, max_connections: max };
    let manager = ConnectionManager::new(config, script.clone());
    let _ = script.manager.set(manager.clone());
    (manager, script)
}

pub fn ep(host: &str, port: u16, user: &str) -> Endpoint {
    Endpoint { host: host.into(), port, user: user.into() }
}

pub fn endpoint() -> Endpoint {
    ep(HOST, PORT, "jena")
}

/// True while the connection exists. Terminal-only connections answer `home`
/// with "no SFTP", which still means alive.
pub async fn is_open(m: &ConnectionManager, id: ConnectionId) -> bool {
    !matches!(m.home(id).await, Err(CoreError::NotConnected(_)))
}

/// Collects terminal output for assertions.
pub struct TermCapture {
    pub out: Mutex<Vec<u8>>,
    pub closed: Mutex<Option<Option<u32>>>,
}

impl TerminalSink for TermCapture {
    fn on_output(&self, data: Vec<u8>) {
        self.out.lock().unwrap().extend(data);
    }
    fn on_closed(&self, exit_status: Option<u32>) {
        *self.closed.lock().unwrap() = Some(exit_status);
    }
}

impl TermCapture {
    pub fn new() -> Arc<Self> {
        Arc::new(TermCapture { out: Mutex::new(vec![]), closed: Mutex::new(None) })
    }

    pub async fn wait_for(&self, needle: &str) -> String {
        for _ in 0..100 {
            let text = String::from_utf8_lossy(&self.out.lock().unwrap()).to_string();
            if text.contains(needle) {
                return text;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("never saw {needle:?} in {:?}", String::from_utf8_lossy(&self.out.lock().unwrap()));
    }
}
