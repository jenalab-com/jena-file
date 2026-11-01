//! Against tests/docker (bastion on 127.0.0.1:2201, jena / jena-test).
//!   docker compose -f tests/docker/compose.yml up -d
//!   cargo test -p jenafile-core --features docker-tests
#![cfg(feature = "docker-tests")]

use std::sync::{Arc, Mutex, OnceLock};

use jenafile_core::*;

const HOST: &str = "127.0.0.1";
const PORT: u16 = 2201;

/// Answers prompts like a scripted user and records what was asked.
struct Script {
    manager: OnceLock<ConnectionManager>,
    host_key: PromptAnswer,
    passwords: Mutex<Vec<String>>,
    asked: Mutex<Vec<PromptKind>>,
}

impl EventSink for Script {
    fn emit(&self, event: Event) {
        if let Event::PromptRequested { prompt, kind, .. } = event {
            self.asked.lock().unwrap().push(kind.clone());
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

fn setup(dir: &std::path::Path, host_key: PromptAnswer, passwords: &[&str], max: u32) -> (ConnectionManager, Arc<Script>) {
    let script = Arc::new(Script {
        manager: OnceLock::new(),
        host_key,
        passwords: Mutex::new(passwords.iter().map(|s| s.to_string()).collect()),
        asked: Mutex::new(vec![]),
    });
    let config = CoreConfig { data_dir: dir.to_path_buf(), user_known_hosts: None, max_connections: max };
    let manager = ConnectionManager::new(config, script.clone());
    let _ = script.manager.set(manager.clone());
    (manager, script)
}

fn endpoint() -> Endpoint {
    Endpoint { host: HOST.into(), port: PORT, user: "jena".into() }
}

#[tokio::test]
async fn connect_list_and_remember_host_key() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    let id = m.connect(endpoint()).await.unwrap();
    let home = m.home(id).await.unwrap();
    assert_eq!(home, "/home/jena");
    let names: Vec<String> = m.list(id, home).await.unwrap().into_iter().map(|e| e.name).collect();
    assert!(names.contains(&".bashrc".to_string()), "{names:?}");
    let root = m.list(id, "/".into()).await.unwrap();
    let first_file = root.iter().position(|e| !e.is_dir).unwrap_or(root.len());
    assert!(first_file > 0 && root[first_file..].iter().all(|e| !e.is_dir), "folders first");
    assert!(root.iter().any(|e| e.name == "etc" && e.is_dir));
    m.disconnect(id).await;
    assert!(matches!(m.home(id).await, Err(CoreError::NotConnected(_))));

    // Second time: key is remembered, only the password is asked.
    script.asked.lock().unwrap().clear();
    script.passwords.lock().unwrap().push("jena-test".into());
    let id = m.connect(endpoint()).await.unwrap();
    let asked = script.asked.lock().unwrap().clone();
    assert!(matches!(asked.as_slice(), [PromptKind::Password { .. }]), "{asked:?}");
    m.disconnect(id).await;
}

#[tokio::test]
async fn wrong_password_three_times_is_auth_error() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["a", "b", "c"], 3);
    assert_eq!(m.connect(endpoint()).await, Err(CoreError::Auth { hop: Hop::Target }));
    let attempts: Vec<u32> = script.asked.lock().unwrap().iter()
        .filter_map(|k| if let PromptKind::Password { attempt, .. } = k { Some(*attempt) } else { None })
        .collect();
    assert_eq!(attempts, [1, 2, 3]);
}

#[tokio::test]
async fn rejected_host_key_stops_before_auth() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Reject, &["jena-test"], 3);
    assert_eq!(m.connect(endpoint()).await, Err(CoreError::HostKeyRejected { hop: Hop::Target }));
    assert!(!script.asked.lock().unwrap().iter().any(|k| matches!(k, PromptKind::Password { .. })), "no password sent");
    assert!(!dir.path().join("known_hosts").exists(), "nothing remembered");
}

#[tokio::test]
async fn changed_host_key_is_flagged_and_can_be_refused_or_accepted() {
    let dir = tempfile::tempdir().unwrap();
    // A stale, different key recorded for this host:port.
    std::fs::write(
        dir.path().join("known_hosts"),
        format!("[{HOST}]:{PORT} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGmodU4tgcSnTLXNQ9tkHzisY8gnVH2Us7IE+mfLIimK\n"),
    )
    .unwrap();

    let (m, script) = setup(dir.path(), PromptAnswer::Reject, &["jena-test"], 3);
    assert_eq!(m.connect(endpoint()).await, Err(CoreError::HostKeyChanged { hop: Hop::Target }));
    assert!(matches!(script.asked.lock().unwrap()[0], PromptKind::HostKeyChanged { .. }));

    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    let id = m.connect(endpoint()).await.unwrap();
    m.disconnect(id).await;
    let recorded = std::fs::read_to_string(dir.path().join("known_hosts")).unwrap();
    assert_eq!(recorded.lines().count(), 1, "old entry replaced: {recorded}");
    assert!(!recorded.contains("IGmodU4t"));
}

#[tokio::test]
async fn connection_limit_and_unreachable_host() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test", "jena-test"], 1);
    let id = m.connect(endpoint()).await.unwrap();
    assert_eq!(m.connect(endpoint()).await, Err(CoreError::LimitReached { max: 1 }));
    m.disconnect(id).await;

    let bad = Endpoint { port: 2299, ..endpoint() };
    assert!(matches!(m.connect(bad).await, Err(CoreError::Connect { hop: Hop::Target, .. })));
}
