//! Bastion (ProxyJump) paths against tests/docker: bastion 127.0.0.1:2201, internal app01:22.
#![cfg(feature = "docker-tests")]

use jenafile_core::*;

mod common;
use common::*;

fn bastion() -> Endpoint {
    ep(HOST, PORT, "jena")
}

fn app01() -> Endpoint {
    ep("app01", 22, "jena")
}

async fn run(m: &ConnectionManager, id: ConnectionId, cmd: &str, expect: &str) -> String {
    let sink = TermCapture::new();
    let t = m.open_terminal(id, 80, 24, None, Some("C.UTF-8".into()), sink.clone()).await.unwrap();
    m.terminal_write(t, format!("{cmd}\n").into_bytes());
    let out = sink.wait_for(expect).await;
    m.close_terminal(t);
    out
}

/// Quick connect with a bastion: one call, both hops asked in order, no local port.
#[tokio::test]
async fn target_through_a_bastion_endpoint() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["jena-test", "jena-test"], 1);
    let c = m.connect(app01(), Some(Via::Endpoint(bastion())), true).await.unwrap();
    let b = c.bastion.expect("bastion opened for the target");

    assert_eq!(m.home(c.id).await.unwrap(), "/home/jena");
    run(&m, c.id, "echo host=$(hostname)", "host=app01").await;

    let hops = script.hops.lock().unwrap().clone();
    assert_eq!(hops, [Hop::Bastion, Hop::Bastion, Hop::Target, Hop::Target], "{:?}", script.asked.lock().unwrap());
    assert!(matches!(&script.asked.lock().unwrap()[2], PromptKind::HostKeyUnknown { host, .. } if host == "app01"));

    // The bastion does not count against the limit (max = 1 above), and closes with its target.
    m.disconnect(c.id).await;
    assert!(!is_open(&m, b).await, "bastion opened for the target closes with it");
}

/// AC-3: an open connection used as bastion is reused; only the new target is asked.
#[tokio::test]
async fn reuse_an_open_connection_as_bastion() {
    let dir = tempfile::tempdir().unwrap();
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["jena-test", "jena-test", "jena-test"], 3);
    let b = m.connect(bastion(), None, true).await.unwrap().id;
    let t1 = m.connect(app01(), Some(Via::Connection(b)), true).await.unwrap();
    assert_eq!(t1.bastion, None, "nothing new was opened for it");

    script.asked.lock().unwrap().clear();
    script.hops.lock().unwrap().clear();
    let t2 = m.connect(app01(), Some(Via::Connection(b)), true).await.unwrap().id;
    let asked = script.asked.lock().unwrap().clone();
    assert!(matches!(asked.as_slice(), [PromptKind::Password { .. }]), "no bastion re-auth, key remembered: {asked:?}");
    assert_eq!(*script.hops.lock().unwrap(), [Hop::Target]);

    // Closing a target keeps the user's own bastion connection.
    m.disconnect(t2).await;
    assert!(is_open(&m, b).await);
    // Closing the bastion closes what rides on it.
    m.disconnect(b).await;
    assert!(!is_open(&m, t1.id).await);
}

/// AC-4: the bastion is fine but cannot reach the next host — say so, keep the bastion.
#[tokio::test]
async fn unreachable_internal_host_is_a_tunnel_failure() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["jena-test", "jena-test"], 3);
    let b = m.connect(bastion(), None, true).await.unwrap().id;
    let err = m.connect(ep("app99", 22, "jena"), Some(Via::Connection(b)), true).await.unwrap_err();
    assert!(matches!(&err, CoreError::TunnelFailed { host, port: 22, .. } if host == "app99"), "{err:?}");
    assert!(is_open(&m, b).await, "bastion untouched");
    run(&m, b, "echo still-here", "still-here").await;

    // With a bastion opened just for it, the failure also closes that bastion.
    let (m, script) = setup(dir.path(), PromptAnswer::Accept, &["jena-test"], 3);
    assert!(matches!(m.connect(ep("app99", 22, "jena"), Some(Via::Endpoint(bastion())), true).await, Err(CoreError::TunnelFailed { .. })));
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let closed = script.events.lock().unwrap().iter().any(|e| matches!(e, Event::StateChanged { state: ConnectionState::Closed, .. }));
    assert!(closed, "no orphan bastion left open");
}

/// FR-03b: expired password → SFTP refused with a clear error; a terminal-only
/// connection opens a PTY where the server asks for the new password.
#[tokio::test]
async fn expired_password_is_reported_and_can_be_changed_in_a_terminal() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = setup(dir.path(), PromptAnswer::Accept, &["old-pass-1", "old-pass-1"], 3);
    let expired = ep(HOST, PORT, "expired");
    assert_eq!(m.connect(expired.clone(), None, true).await, Err(CoreError::PasswordExpired { hop: Hop::Target }));

    let id = m.connect(expired, None, false).await.unwrap().id;
    let sink = TermCapture::new();
    m.open_terminal(id, 80, 24, None, None, sink.clone()).await.unwrap();
    let text = sink.wait_for("password").await.to_lowercase();
    assert!(text.contains("change your password") || text.contains("current password"), "{text}");
    m.disconnect(id).await;
}
