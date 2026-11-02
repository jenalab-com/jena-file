//! Reconnect and resume (AC-5) against tests/docker. Restarts / stops the bastion
//! container, so every scenario lives in ONE test (tests in a binary run in parallel).
#![cfg(feature = "docker-tests")]

use std::fs;
use std::process::Command;
use std::time::{Duration, Instant};

use jenafile_core::*;

mod common;
use common::*;

const BASTION: &str = "jenafile-test-bastion-1";

fn docker(args: &[&str]) {
    let ok = Command::new("docker").args(args).status().map(|s| s.success()).unwrap_or(false);
    assert!(ok, "docker {args:?} failed");
}

/// Wait for sshd to accept TCP again after a restart.
async fn sshd_up() {
    for _ in 0..100 {
        if tokio::net::TcpStream::connect((HOST, PORT)).await.is_ok() {
            tokio::time::sleep(Duration::from_millis(300)).await;
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("sshd did not come back");
}

fn states(script: &Script, id: ConnectionId) -> Vec<ConnectionState> {
    script.events.lock().unwrap().iter().filter_map(|e| match e {
        Event::StateChanged { connection, state } if *connection == id => Some(state.clone()),
        _ => None,
    }).collect()
}

async fn wait_state(script: &Script, id: ConnectionId, want: impl Fn(&ConnectionState) -> bool, secs: u64) {
    let end = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < end {
        if states(script, id).iter().any(&want) { return; }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("connection {id}: never reached the state; saw {:?}", states(script, id));
}

fn unique(tag: &str) -> String {
    format!("{tag}-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos())
}

#[tokio::test]
async fn reconnect_resume_and_give_up() {
    let tmp = tempfile::tempdir().unwrap();
    sshd_up().await;

    // ---- 1. Direct: the server restarts mid-upload; the upload finishes by itself.
    let (m, script) = setup(tmp.path(), PromptAnswer::Accept, &["jena-test"; 12], 3);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    let term = TermCapture::new();
    m.open_terminal(id, 80, 24, None, None, term.clone()).await.unwrap();
    docker(&["exec", BASTION, "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "rate", "80mbit"]);

    let data = noise(48 << 20, 42);
    let file = tmp.path().join("big.bin");
    fs::write(&file, &data).unwrap();
    let dir = format!("/tmp/{}", unique("rc"));
    let mk = tmp.path().join("mk").join(dir.trim_start_matches("/tmp/"));
    fs::create_dir_all(&mk).unwrap();
    m.upload(id, vec![mk], "/tmp".into(), None).await.unwrap();
    let t = m.upload(id, vec![file.clone()], dir.clone(), None).await.unwrap()[0];
    for _ in 0..400 {
        if transfers(&script).get(&t).is_some_and(|i| i.transferred > 8 << 20) { break; }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    docker(&["restart", "-t", "0", BASTION]);

    wait_state(&script, id, |s| matches!(s, ConnectionState::Reconnecting { .. }), 20).await;
    wait_state(&script, id, |s| *s == ConnectionState::Ready, 30).await;
    assert!(transfers(&script).values().any(|i| i.id == t) );
    let seen: Vec<_> = script.events.lock().unwrap().iter().filter_map(|e| match e {
        Event::Transfer(i) if i.id == t => Some(i.state.clone()), _ => None }).collect();
    assert!(seen.contains(&TransferState::Waiting), "waited for the connection: {seen:?}");
    let done = settle(&script, &[t]).await.remove(0);
    assert_eq!(done.state, TransferState::Done, "{done:?}");
    assert!(term.closed.lock().unwrap().is_some(), "the old shell was reported closed");

    let check = tmp.path().join("check");
    fs::create_dir_all(&check).unwrap();
    let d = m.download(id, vec![format!("{dir}/big.bin")], check.clone(), None).await.unwrap();
    settle(&script, &d).await;
    assert!(fs::read(check.join("big.bin")).unwrap() == data, "byte-identical after reconnect");
    m.disconnect(id).await;

    // ---- 2. Through a bastion: both hops come back, bastion first.
    let (m, script) = setup(tmp.path(), PromptAnswer::Accept, &["jena-test"; 12], 3);
    let c = m.connect(ep("app01", 22, "jena"), Some(Via::Endpoint(endpoint())), true).await.unwrap();
    let b = c.bastion.unwrap();
    docker(&["restart", "-t", "0", BASTION]);
    wait_state(&script, b, |s| *s == ConnectionState::Ready && false || matches!(s, ConnectionState::Reconnecting { .. }), 20).await;
    let ready_after = |id| {
        let s = states(&script, id);
        let lost = s.iter().position(|x| matches!(x, ConnectionState::Reconnecting { .. }));
        lost.is_some_and(|i| s[i..].contains(&ConnectionState::Ready))
    };
    let end = Instant::now() + Duration::from_secs(40);
    while !(ready_after(b) && ready_after(c.id)) && Instant::now() < end {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    assert!(ready_after(b) && ready_after(c.id), "bastion {:?} / target {:?}", states(&script, b), states(&script, c.id));
    assert_eq!(m.home(c.id).await.unwrap(), "/home/jena", "SFTP works again through the new tunnel");
    m.disconnect(c.id).await;

    // ---- 3. Server stays down: give up after three tries, queued work fails.
    let (m, script) = setup(tmp.path(), PromptAnswer::Accept, &["jena-test"; 4], 3);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    docker(&["stop", "-t", "0", BASTION]);
    wait_state(&script, id, |s| matches!(s, ConnectionState::Failed { .. }), 40).await;
    let tries = states(&script, id).iter().filter(|s| matches!(s, ConnectionState::Reconnecting { .. })).count();
    assert_eq!(tries, 3);
    assert!(matches!(m.home(id).await, Err(CoreError::NotConnected(_))), "slot freed");
    docker(&["start", BASTION]);
    sshd_up().await;
}
