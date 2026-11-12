//! Transfers against tests/docker (direct to 127.0.0.1:2201).
#![cfg(feature = "docker-tests")]

use std::fs;
use std::path::Path;

use jenafile_core::*;

mod common;
use common::*;

/// A name no previous run used, so the server never has leftovers for it.
fn unique(tag: &str) -> String {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    format!("{tag}-{nanos}")
}

/// Creates an empty remote folder `/tmp/<name>` by uploading an empty local one.
async fn remote_folder(m: &ConnectionManager, id: ConnectionId, tmp: &Path, name: &str) -> String {
    let local = tmp.join("mk").join(name);
    fs::create_dir_all(&local).unwrap();
    assert!(m.upload(id, vec![local], "/tmp".into(), None).await.unwrap().is_empty());
    format!("/tmp/{name}")
}

async fn connected(dir: &Path, max: u32) -> (ConnectionManager, std::sync::Arc<Script>, ConnectionId) {
    let (m, script) = setup(dir, PromptAnswer::Accept, &["jena-test"], max);
    let id = m.connect(endpoint(), None, true).await.unwrap().id;
    (m, script, id)
}

/// Upload a file and a nested folder, download the folder back: same bytes.
#[tokio::test]
async fn round_trip_files_and_folders() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, script, id) = connected(tmp.path(), 3).await;
    let pack = unique("pack");
    let src = tmp.path().join("src");
    fs::create_dir_all(src.join(&pack).join("inner")).unwrap();
    fs::write(src.join(&pack).join("big.bin"), noise(3 << 20, 1)).unwrap();
    fs::write(src.join(&pack).join("inner/한글 이름.txt"), "안녕하세요\n").unwrap();
    fs::write(src.join(&pack).join("inner/empty"), b"").unwrap();

    let ids = m.upload(id, vec![src.join(&pack)], "/tmp".into(), None).await.unwrap();
    assert_eq!(ids.len(), 3);
    for t in settle(&script, &ids).await {
        assert_eq!(t.state, TransferState::Done, "{t:?}");
        assert_eq!(t.transferred, t.size);
    }

    let back = tmp.path().join("back");
    fs::create_dir_all(&back).unwrap();
    let ids = m.download(id, vec![format!("/tmp/{pack}")], back.clone(), None).await.unwrap();
    settle(&script, &ids).await;
    for rel in ["big.bin", "inner/한글 이름.txt", "inner/empty"] {
        assert_eq!(fs::read(back.join(&pack).join(rel)).unwrap(), fs::read(src.join(&pack).join(rel)).unwrap(), "{rel}");
    }
    m.disconnect(id).await;
}

/// At most three files of one connection run at once (FR-12).
#[tokio::test]
async fn three_at_a_time() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, script, id) = connected(tmp.path(), 3).await;
    let files: Vec<_> = (0..7).map(|i| {
        let p = tmp.path().join(format!("f{i}.bin"));
        fs::write(&p, noise(2 << 20, i)).unwrap();
        p
    }).collect();
    let dir = remote_folder(&m, id, tmp.path(), &unique("three")).await;
    let ids = m.upload(id, files, dir, None).await.unwrap();
    settle(&script, &ids).await;

    let (mut running, mut peak) = (std::collections::BTreeSet::new(), 0);
    for e in script.events.lock().unwrap().iter() {
        if let Event::Transfer(t) = e {
            if t.state == TransferState::Running { running.insert(t.id); } else { running.remove(&t.id); }
            peak = peak.max(running.len());
        }
    }
    assert_eq!(peak, 3);
    m.disconnect(id).await;
}

/// Destination exists: skip, rename (keep both), overwrite, resume a partial file.
#[tokio::test]
async fn conflicts_and_resume() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, script, id) = connected(tmp.path(), 3).await;
    let data = noise(5 << 20, 7);
    let file = tmp.path().join("same.bin");
    let remote_dir = remote_folder(&m, id, tmp.path(), &unique("conflict")).await;
    let remote = format!("{remote_dir}/same.bin");

    // A partial copy already on the server (first 2 MiB).
    fs::write(&file, &data[..2 << 20]).unwrap();
    let first = m.upload(id, vec![file.clone()], remote_dir.clone(), None).await.unwrap();
    assert_eq!(settle(&script, &first).await[0].state, TransferState::Done);
    fs::write(&file, &data).unwrap();

    // Resume: only the rest is sent, result is the whole file.
    script.asked.lock().unwrap().clear();
    script.conflicts.lock().unwrap().push(PromptAnswer::Conflict { action: ConflictAction::Resume, apply_to_all: false });
    let ids = m.upload(id, vec![file.clone()], remote_dir.clone(), None).await.unwrap();
    assert_eq!(settle(&script, &ids).await[0].state, TransferState::Done);
    assert!(matches!(script.asked.lock().unwrap().last(), Some(PromptKind::Conflict { can_resume: true, destination_size, .. }) if *destination_size == 2 << 20));
    let check = tmp.path().join("check");
    fs::create_dir_all(&check).unwrap();
    let d = m.download(id, vec![remote.clone()], check.clone(), None).await.unwrap();
    settle(&script, &d).await;
    assert_eq!(fs::read(check.join("same.bin")).unwrap(), data, "resumed upload is byte-identical");

    // Skip, then Rename.
    script.conflicts.lock().unwrap().push(PromptAnswer::Conflict { action: ConflictAction::Skip, apply_to_all: false });
    let ids = m.upload(id, vec![file.clone()], remote_dir.clone(), None).await.unwrap();
    assert_eq!(settle(&script, &ids).await[0].state, TransferState::Skipped);
    script.conflicts.lock().unwrap().push(PromptAnswer::Conflict { action: ConflictAction::Rename, apply_to_all: false });
    let ids = m.upload(id, vec![file.clone()], remote_dir.clone(), None).await.unwrap();
    let t = settle(&script, &ids).await.remove(0);
    assert_eq!(t.state, TransferState::Done);
    assert_eq!(t.remote_path, format!("{remote_dir}/same (1).bin"));

    // Download resume: a partial local file continues.
    let local = check.join("same.bin");
    fs::write(&local, &data[..1 << 20]).unwrap();
    script.conflicts.lock().unwrap().push(PromptAnswer::Conflict { action: ConflictAction::Resume, apply_to_all: false });
    let d = m.download(id, vec![remote], check.clone(), None).await.unwrap();
    settle(&script, &d).await;
    assert_eq!(fs::read(&local).unwrap(), data, "resumed download is byte-identical");
    m.disconnect(id).await;
}

/// Pause in the middle, resume later: continues from what the server really has.
#[tokio::test]
async fn pause_and_resume_mid_file() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, script, id) = connected(tmp.path(), 3).await;
    let data = noise(96 << 20, 9);
    let file = tmp.path().join("pause.bin");
    fs::write(&file, &data).unwrap();
    let remote_dir = remote_folder(&m, id, tmp.path(), &unique("pause")).await;
    let t = m.upload(id, vec![file.clone()], remote_dir.clone(), None).await.unwrap()[0];

    for _ in 0..400 {
        if transfers(&script).get(&t).is_some_and(|i| i.transferred > 0) { break; }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    m.pause_transfer(t);
    let paused = transfers(&script)[&t].clone();
    assert_eq!(paused.state, TransferState::Paused);
    assert!(paused.transferred < paused.size, "paused before the end: {paused:?}");

    m.resume_transfer(t);
    assert_eq!(settle(&script, &[t]).await[0].state, TransferState::Done);
    let check = tmp.path().join("check");
    fs::create_dir_all(&check).unwrap();
    let d = m.download(id, vec![format!("{remote_dir}/pause.bin")], check.clone(), None).await.unwrap();
    settle(&script, &d).await;
    assert!(fs::read(check.join("pause.bin")).unwrap() == data, "byte-identical after pause/resume");
    m.disconnect(id).await;
}

/// 설정: transfer limit and a default answer for existing files (no prompt).
#[tokio::test]
async fn settings_limit_and_default_conflict_action() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, script, id) = connected(tmp.path(), 3).await;
    m.set_transfer_limit(1);
    let dir = remote_folder(&m, id, tmp.path(), &unique("limit")).await;
    let files: Vec<_> = (0..4).map(|i| {
        let p = tmp.path().join(format!("l{i}.bin"));
        fs::write(&p, noise(1 << 20, 20 + i)).unwrap();
        p
    }).collect();
    let ids = m.upload(id, files.clone(), dir.clone(), None).await.unwrap();
    settle(&script, &ids).await;
    let (mut running, mut peak) = (std::collections::BTreeSet::new(), 0);
    for e in script.events.lock().unwrap().iter() {
        if let Event::Transfer(t) = e {
            if t.state == TransferState::Running { running.insert(t.id); } else { running.remove(&t.id); }
            peak = peak.max(running.len());
        }
    }
    assert_eq!(peak, 1);

    script.asked.lock().unwrap().clear();
    let ids = m.upload(id, files, dir, Some(ConflictAction::Skip)).await.unwrap();
    assert!(settle(&script, &ids).await.iter().all(|t| t.state == TransferState::Skipped));
    assert!(script.asked.lock().unwrap().is_empty(), "no prompt with a default action");
    m.disconnect(id).await;
}

/// Rename a folder; renaming onto an existing name is refused, nothing is replaced.
#[tokio::test]
async fn rename_folder_and_refuse_existing_target() {
    let tmp = tempfile::tempdir().unwrap();
    let (m, _script, id) = connected(tmp.path(), 3).await;
    let a = remote_folder(&m, id, tmp.path(), &unique("ren-a")).await;
    let b = remote_folder(&m, id, tmp.path(), &unique("ren-b")).await;
    let moved = format!("{a}-새 이름");
    m.rename(id, a.clone(), moved.clone()).await.unwrap();
    let names: Vec<String> = m.list(id, "/tmp".into()).await.unwrap().into_iter().map(|e| e.name).collect();
    assert!(names.contains(&moved["/tmp/".len()..].to_string()) && !names.contains(&a["/tmp/".len()..].to_string()), "{names:?}");
    assert!(m.rename(id, moved.clone(), b.clone()).await.is_err(), "existing target is not replaced");
    assert!(m.list(id, moved).await.is_ok() && m.list(id, b).await.is_ok());
    m.disconnect(id).await;
}
