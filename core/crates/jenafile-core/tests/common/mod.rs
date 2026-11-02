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
    /// Answers for transfer conflicts, in order.
    pub conflicts: Mutex<Vec<PromptAnswer>>,
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
                PromptKind::Conflict { .. } => {
                    let mut c = self.conflicts.lock().unwrap();
                    if c.is_empty() { PromptAnswer::Cancel } else { c.remove(0) }
                }
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
        conflicts: Mutex::new(vec![]),
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

/// Latest info per transfer, from the event log.
pub fn transfers(script: &Script) -> std::collections::BTreeMap<TransferId, TransferInfo> {
    let mut out = std::collections::BTreeMap::new();
    for e in script.events.lock().unwrap().iter() {
        if let Event::Transfer(t) = e {
            out.insert(t.id, t.clone());
        }
    }
    out
}

/// Waits until every id reached a final state; returns their infos.
pub async fn settle(script: &Script, ids: &[TransferId]) -> Vec<TransferInfo> {
    for _ in 0..600 {
        let all = transfers(script);
        let done: Vec<_> = ids.iter().filter_map(|id| all.get(id)).filter(|t| !matches!(t.state, TransferState::Queued | TransferState::Running | TransferState::Waiting)).cloned().collect();
        if done.len() == ids.len() {
            return done;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("transfers did not settle: {:?}", transfers(script));
}

/// Deterministic pseudo-random bytes (no rand dependency).
pub fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    (0..len).map(|_| { x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); (x >> 33) as u8 }).collect()
}
