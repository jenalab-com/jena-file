//! Against tests/docker (bastion on 127.0.0.1:2201, jena / jena-test).
//!   docker compose -f tests/docker/compose.yml up -d
//!   cargo test -p jenafile-core --features docker-tests
#![cfg(feature = "docker-tests")]


use jenafile_core::*;

mod common;
use common::*;

#[tokio::test]
async fn connect_list_and_remember_host_key() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
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
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    let asked = script.asked.lock().unwrap().clone();
    assert!(matches!(asked.as_slice(), [PromptKind::Password { .. }]), "{asked:?}");
    m.disconnect(id).await;
}

#[tokio::test]
async fn wrong_password_three_times_is_auth_error() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["a", "b", "c"], 3);
    assert_eq!(m.connect(endpoint(), None, true).await, Err(CoreError::Auth { hop: Hop::Target }));
    let attempts: Vec<u32> = script.asked.lock().unwrap().iter()
        .filter_map(|k| if let PromptKind::Password { attempt, .. } = k { Some(*attempt) } else { None })
        .collect();
    assert_eq!(attempts, [1, 2, 3]);
}

#[tokio::test]
async fn rejected_host_key_stops_before_auth() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Reject, &["jena-test"], 3);
    assert_eq!(m.connect(endpoint(), None, true).await, Err(CoreError::HostKeyRejected { hop: Hop::Target }));
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
    assert_eq!(m.connect(endpoint(), None, true).await, Err(CoreError::HostKeyChanged { hop: Hop::Target }));
    assert!(matches!(script.asked.lock().unwrap()[0], PromptKind::HostKeyChanged { .. }));

    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    m.disconnect(id).await;
    let recorded = std::fs::read_to_string(dir.path().join("known_hosts")).unwrap();
    assert_eq!(recorded.lines().count(), 1, "old entry replaced: {recorded}");
    assert!(!recorded.contains("IGmodU4t"));
}

#[tokio::test]
async fn connection_limit_and_unreachable_host() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test", "jena-test"], 1);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    assert_eq!(m.connect(endpoint(), None, true).await, Err(CoreError::LimitReached { max: 1 }));
    m.disconnect(id).await;

    let bad = Endpoint { port: 2299, ..endpoint() };
    assert!(matches!(m.connect(bad, None, true).await, Err(CoreError::Connect { hop: Hop::Target, .. })));
}

#[tokio::test]
async fn terminal_on_same_session_as_sftp() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    let sink = TermCapture::new();
    let term = m.open_terminal(id, 100, 30, Some("/etc".into()), Some("ko_KR.UTF-8".into()), sink.clone()).await.unwrap();

    // Started in the requested folder, PTY has the requested size.
    m.terminal_write(term, b"pwd; stty size; echo marker-$((40+2))\n".to_vec());
    let text = sink.wait_for("marker-42").await;
    assert!(text.contains("/etc"), "{text}");
    assert!(text.contains("30 100"), "{text}");

    // SFTP keeps working while the shell is open.
    assert!(m.list(id, "/etc".into()).await.unwrap().iter().any(|e| e.name == "passwd"));

    // Resize reaches the server.
    m.terminal_resize(term, 120, 40);
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    m.terminal_write(term, b"stty size; echo resized-ok\n".to_vec());
    assert!(sink.wait_for("resized-ok").await.contains("40 120"));

    // LANG reached the shell, and typed Korean is echoed back by the line editor
    // (in the POSIX locale bash only beeps and drops it — the bug this guards).
    m.terminal_write(term, b"echo lang=$LANG\n".to_vec());
    sink.wait_for("lang=ko_KR.UTF-8").await;
    sink.out.lock().unwrap().clear();
    m.terminal_write(term, "echo 안녕하세요-입력".as_bytes().to_vec());
    sink.wait_for("안녕하세요-입력").await; // echoed while typing (before Enter)
    m.terminal_write(term, b"\n".to_vec());
    sink.wait_for("안녕하세요-입력\r\n").await; // and printed by echo

    // Exit status is reported.
    m.terminal_write(term, b"exit 3\n".to_vec());
    for _ in 0..100 {
        if sink.closed.lock().unwrap().is_some() { break; }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(*sink.closed.lock().unwrap(), Some(Some(3)), "{:?}", String::from_utf8_lossy(&sink.out.lock().unwrap()));
    m.disconnect(id).await;
}
