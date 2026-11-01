//! Transfer queue (ARCHITECTURE §7): per-file items, up to N running per
//! connection, progress events throttled, pause / resume / cancel / retry.
//!
//! Resume never trusts our own byte counter: it stats the destination and
//! continues from its real size, so in-flight writes lost to an abort are redone.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::error::CoreError;
use crate::events::{
    ConflictAction, ConnectionId, Direction, Event, EventSink, Hop, PromptAnswer, PromptKind, TransferId, TransferInfo,
    TransferState,
};
use crate::prompt::PromptBroker;
use crate::transport::{Files, RemoteStat};

/// Files running at once per connection by default (기획서 FR-12); see `set_limit`.
pub(crate) const PER_CONNECTION: usize = 3;
pub(crate) const MAX_PER_CONNECTION: usize = 10;
const TICK: Duration = Duration::from_millis(100);

/// Files enqueued together share the "apply to all" answer.
#[derive(Default)]
struct Batch {
    policy: Mutex<Option<ConflictAction>>,
}

struct Item {
    info: TransferInfo,
    files: Files,
    batch: Arc<Batch>,
    progress: Arc<AtomicU64>,
    /// Continue from the destination's size without asking (resume / retry).
    resume: bool,
    task: Option<tokio::task::AbortHandle>,
    last_sample: (Instant, u64),
}

pub(crate) struct Transfers {
    sink: Arc<dyn EventSink>,
    prompts: Arc<PromptBroker>,
    items: Mutex<BTreeMap<TransferId, Item>>,
    next_id: AtomicU64,
    ticking: AtomicBool,
    per_connection: std::sync::atomic::AtomicUsize,
}

/// A file to copy, already expanded from folders.
pub(crate) struct Job {
    pub direction: Direction,
    pub local: PathBuf,
    pub remote: String,
    pub size: u64,
}

impl Transfers {
    pub(crate) fn new(sink: Arc<dyn EventSink>, prompts: Arc<PromptBroker>) -> Arc<Self> {
        Arc::new(Self {
            sink,
            prompts,
            items: Mutex::new(BTreeMap::new()),
            next_id: AtomicU64::new(1),
            ticking: AtomicBool::new(false),
            per_connection: std::sync::atomic::AtomicUsize::new(PER_CONNECTION),
        })
    }

    /// Files running at once per connection, 1…10 (설정 > 전송).
    pub(crate) fn set_limit(self: &Arc<Self>, n: usize) {
        self.per_connection.store(n.clamp(1, MAX_PER_CONNECTION), Ordering::Relaxed);
        self.pump();
    }

    /// `on_conflict`: answer for existing destinations without asking (설정); None = ask.
    pub(crate) fn enqueue(
        self: &Arc<Self>,
        connection: ConnectionId,
        files: Files,
        jobs: Vec<Job>,
        on_conflict: Option<ConflictAction>,
    ) -> Vec<TransferId> {
        let batch = Arc::new(Batch { policy: Mutex::new(on_conflict) });
        let mut ids = Vec::new();
        {
            let mut items = self.items.lock().unwrap();
            for job in jobs {
                let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                let info = TransferInfo {
                    id,
                    connection,
                    direction: job.direction,
                    local_path: job.local.to_string_lossy().into_owned(),
                    remote_path: job.remote,
                    size: job.size,
                    transferred: 0,
                    bytes_per_sec: 0,
                    state: TransferState::Queued,
                };
                self.sink.emit(Event::Transfer(info.clone()));
                items.insert(id, Item {
                    info,
                    files: files.clone(),
                    batch: batch.clone(),
                    progress: Arc::new(AtomicU64::new(0)),
                    resume: false,
                    task: None,
                    last_sample: (Instant::now(), 0),
                });
                ids.push(id);
            }
        }
        self.start_ticker();
        self.pump();
        ids
    }

    pub(crate) fn pause(self: &Arc<Self>, id: TransferId) {
        self.stop(id, TransferState::Paused);
    }

    pub(crate) fn cancel(self: &Arc<Self>, id: TransferId) {
        self.stop(id, TransferState::Cancelled);
    }

    /// Resume a paused / failed / cancelled item from where the destination stands.
    pub(crate) fn resume(self: &Arc<Self>, id: TransferId) {
        {
            let mut items = self.items.lock().unwrap();
            let Some(item) = items.get_mut(&id) else { return };
            if !matches!(item.info.state, TransferState::Paused | TransferState::Failed { .. } | TransferState::Cancelled) {
                return;
            }
            item.resume = true;
            item.info.state = TransferState::Queued;
            self.sink.emit(Event::Transfer(item.info.clone()));
        }
        self.pump();
    }

    /// Drops finished items (done / skipped / cancelled) from the list.
    pub(crate) fn clear_finished(&self) {
        self.items.lock().unwrap().retain(|_, i| {
            !matches!(i.info.state, TransferState::Done | TransferState::Skipped | TransferState::Cancelled)
        });
    }

    /// The connection is gone: running and queued items fail (retry later).
    pub(crate) fn connection_closed(self: &Arc<Self>, connection: ConnectionId) {
        let ids: Vec<_> = self.items.lock().unwrap().iter()
            .filter(|(_, i)| i.info.connection == connection && matches!(i.info.state, TransferState::Queued | TransferState::Running))
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            self.stop(id, TransferState::Failed { message: "connection closed".into() });
        }
    }

    pub(crate) fn has_active(&self) -> bool {
        self.items.lock().unwrap().values().any(|i| matches!(i.info.state, TransferState::Queued | TransferState::Running))
    }

    fn stop(self: &Arc<Self>, id: TransferId, state: TransferState) {
        {
            let mut items = self.items.lock().unwrap();
            let Some(item) = items.get_mut(&id) else { return };
            if !matches!(item.info.state, TransferState::Queued | TransferState::Running) {
                return;
            }
            if let Some(task) = item.task.take() {
                task.abort();
            }
            item.info.transferred = item.progress.load(Ordering::Relaxed);
            item.info.bytes_per_sec = 0;
            item.info.state = state;
            self.sink.emit(Event::Transfer(item.info.clone()));
        }
        self.pump();
    }

    /// Start queued items while their connection has free slots.
    fn pump(self: &Arc<Self>) {
        let limit = self.per_connection.load(Ordering::Relaxed);
        let mut items = self.items.lock().unwrap();
        let mut running: BTreeMap<ConnectionId, usize> = BTreeMap::new();
        for i in items.values().filter(|i| i.info.state == TransferState::Running) {
            *running.entry(i.info.connection).or_default() += 1;
        }
        let ready: Vec<TransferId> = items.iter().filter(|(_, i)| i.info.state == TransferState::Queued).map(|(id, _)| *id).collect();
        for id in ready {
            let item = items.get_mut(&id).unwrap();
            let slot = running.entry(item.info.connection).or_default();
            if *slot >= limit {
                continue;
            }
            *slot += 1;
            item.info.state = TransferState::Running;
            item.last_sample = (Instant::now(), item.progress.load(Ordering::Relaxed));
            self.sink.emit(Event::Transfer(item.info.clone()));
            let me = self.clone();
            let work = Work {
                connection: item.info.connection,
                direction: item.info.direction,
                local: PathBuf::from(&item.info.local_path),
                remote: item.info.remote_path.clone(),
                size: item.info.size,
                files: item.files.clone(),
                batch: item.batch.clone(),
                progress: item.progress.clone(),
                resume: std::mem::take(&mut item.resume),
            };
            let handle = tokio::spawn(async move {
                let outcome = me.clone().run(work).await;
                me.finish(id, outcome);
            });
            item.task = Some(handle.abort_handle());
        }
    }

    fn finish(self: &Arc<Self>, id: TransferId, outcome: Result<Finished, CoreError>) {
        {
            let mut items = self.items.lock().unwrap();
            let Some(item) = items.get_mut(&id) else { return };
            if item.info.state != TransferState::Running {
                return; // paused / cancelled meanwhile
            }
            item.task = None;
            item.info.bytes_per_sec = 0;
            match outcome {
                Ok(Finished::Done { remote, local }) => {
                    item.info.remote_path = remote;
                    item.info.local_path = local;
                    item.info.transferred = item.info.size;
                    item.info.state = TransferState::Done;
                }
                Ok(Finished::Skipped) => item.info.state = TransferState::Skipped,
                Err(CoreError::Cancelled) => item.info.state = TransferState::Cancelled,
                Err(e) => {
                    item.info.transferred = item.progress.load(Ordering::Relaxed);
                    item.info.state = TransferState::Failed { message: e.to_string() };
                }
            }
            self.sink.emit(Event::Transfer(item.info.clone()));
        }
        self.pump();
    }

    async fn run(self: Arc<Self>, w: Work) -> Result<Finished, CoreError> {
        let (mut local, mut remote) = (w.local.clone(), w.remote.clone());
        let existing = match w.direction {
            Direction::Upload => w.files.stat(&remote).await?.map(|s| (s.size, s.modified)),
            Direction::Download => local_stat(&local).await,
        };
        let source_modified = match w.direction {
            Direction::Upload => local_stat(&local).await.and_then(|s| s.1),
            Direction::Download => w.files.stat(&remote).await?.and_then(|s| s.modified),
        };
        let action = match existing {
            None => ConflictAction::Overwrite,
            Some((size, _)) if w.resume => if size <= w.size { ConflictAction::Resume } else { ConflictAction::Overwrite },
            Some((size, modified)) => {
                let policy = *w.batch.policy.lock().unwrap();
                match policy {
                    Some(p) => p,
                    None => {
                        let kind = PromptKind::Conflict {
                            direction: w.direction,
                            destination: match w.direction { Direction::Upload => remote.clone(), Direction::Download => local.to_string_lossy().into_owned() },
                            source_size: w.size,
                            source_modified,
                            destination_size: size,
                            destination_modified: modified,
                            can_resume: size < w.size,
                        };
                        match self.prompts.ask(w.connection, Hop::Target, kind).await {
                            PromptAnswer::Conflict { action, apply_to_all } => {
                                if apply_to_all {
                                    *w.batch.policy.lock().unwrap() = Some(action);
                                }
                                action
                            }
                            _ => return Err(CoreError::Cancelled),
                        }
                    }
                }
            }
        };
        let offset = match action {
            ConflictAction::Skip => return Ok(Finished::Skipped),
            ConflictAction::Overwrite => 0,
            ConflictAction::Resume => existing.map(|(s, _)| s).filter(|s| *s <= w.size).unwrap_or(0),
            ConflictAction::Rename => {
                match w.direction {
                    Direction::Upload => remote = free_remote_name(&w.files, &remote).await?,
                    Direction::Download => local = free_local_name(&local).await,
                }
                0
            }
        };
        if offset >= w.size && existing.is_some() && action == ConflictAction::Resume {
            w.progress.store(w.size, Ordering::Relaxed);
            return Ok(Finished::Done { remote, local: local.to_string_lossy().into_owned() });
        }
        w.progress.store(offset, Ordering::Relaxed);
        match w.direction {
            Direction::Upload => w.files.upload(&local, &remote, offset, &w.progress).await?,
            Direction::Download => w.files.download(&remote, &local, offset, &w.progress).await?,
        }
        Ok(Finished::Done { remote, local: local.to_string_lossy().into_owned() })
    }

    /// Emits progress for running items, ~10 times a second.
    fn start_ticker(self: &Arc<Self>) {
        if self.ticking.swap(true, Ordering::Relaxed) {
            return;
        }
        let me = Arc::downgrade(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(TICK);
            loop {
                tick.tick().await;
                let Some(me) = me.upgrade() else { break };
                let mut items = me.items.lock().unwrap();
                for item in items.values_mut().filter(|i| i.info.state == TransferState::Running) {
                    let now = item.progress.load(Ordering::Relaxed);
                    if now == item.info.transferred {
                        continue;
                    }
                    let (t0, b0) = item.last_sample;
                    let dt = t0.elapsed().as_secs_f64();
                    if dt >= 0.5 {
                        let rate = (now.saturating_sub(b0) as f64 / dt) as u64;
                        // Smooth so the ETA does not jump around.
                        item.info.bytes_per_sec = if item.info.bytes_per_sec == 0 { rate } else { (item.info.bytes_per_sec * 3 + rate) / 4 };
                        item.last_sample = (Instant::now(), now);
                    }
                    item.info.transferred = now;
                    me.sink.emit(Event::Transfer(item.info.clone()));
                }
            }
        });
    }
}

enum Finished {
    Done { remote: String, local: String },
    Skipped,
}

struct Work {
    connection: ConnectionId,
    direction: Direction,
    local: PathBuf,
    remote: String,
    size: u64,
    files: Files,
    batch: Arc<Batch>,
    progress: Arc<AtomicU64>,
    resume: bool,
}

async fn local_stat(path: &Path) -> Option<(u64, Option<u64>)> {
    let m = tokio::fs::metadata(path).await.ok()?;
    let modified = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs());
    Some((m.len(), modified))
}

/// `name.ext` → `name (1).ext`, `name (2).ext`, …
pub(crate) fn numbered(name: &str, n: u32) -> String {
    match name.rfind('.').filter(|&i| i > 0) {
        Some(i) => format!("{} ({n}){}", &name[..i], &name[i..]),
        None => format!("{name} ({n})"),
    }
}

async fn free_remote_name(files: &Files, path: &str) -> Result<String, CoreError> {
    let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
    for n in 1..1000 {
        let candidate = format!("{dir}/{}", numbered(name, n));
        if files.stat(&candidate).await?.is_none() {
            return Ok(candidate);
        }
    }
    Err(CoreError::Local { message: "no free file name".into() })
}

async fn free_local_name(path: &Path) -> PathBuf {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    for n in 1..1000 {
        let candidate = path.with_file_name(numbered(&name, n));
        if tokio::fs::metadata(&candidate).await.is_err() {
            return candidate;
        }
    }
    path.to_path_buf()
}

/// Expands local paths (files or folders) into upload jobs under `remote_dir`,
/// creating remote folders on the way.
pub(crate) async fn plan_upload(files: &Files, locals: &[PathBuf], remote_dir: &str) -> Result<Vec<Job>, CoreError> {
    let local_err = |e: std::io::Error| CoreError::Local { message: e.to_string() };
    let join = |a: &str, b: &str| if a.ends_with('/') { format!("{a}{b}") } else { format!("{a}/{b}") };
    let mut jobs = Vec::new();
    for root in locals {
        let name = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let meta = tokio::fs::metadata(root).await.map_err(local_err)?;
        if !meta.is_dir() {
            jobs.push(Job { direction: Direction::Upload, local: root.clone(), remote: join(remote_dir, &name), size: meta.len() });
            continue;
        }
        let base = join(remote_dir, &name);
        files.mkdir_all(&base).await?;
        let mut stack = vec![(root.clone(), base)];
        while let Some((dir, remote)) = stack.pop() {
            let mut rd = tokio::fs::read_dir(&dir).await.map_err(local_err)?;
            while let Some(e) = rd.next_entry().await.map_err(local_err)? {
                let n = e.file_name().to_string_lossy().into_owned();
                let m = e.metadata().await.map_err(local_err)?;
                let r = join(&remote, &n);
                if m.is_dir() {
                    files.mkdir_all(&r).await?;
                    stack.push((e.path(), r));
                } else if m.is_file() {
                    jobs.push(Job { direction: Direction::Upload, local: e.path(), remote: r, size: m.len() });
                }
            }
        }
    }
    Ok(jobs)
}

/// Expands remote paths (files or folders) into download jobs under `local_dir`,
/// creating local folders on the way.
pub(crate) async fn plan_download(files: &Files, remotes: &[String], local_dir: &Path) -> Result<Vec<Job>, CoreError> {
    let local_err = |e: std::io::Error| CoreError::Local { message: e.to_string() };
    let mut jobs = Vec::new();
    for root in remotes {
        let name = root.trim_end_matches('/').rsplit('/').next().unwrap_or(root).to_string();
        let Some(stat) = files.stat(root).await? else {
            return Err(CoreError::Server { hop: Hop::Target, message: format!("{root}: no such file"), detail: None });
        };
        let target = local_dir.join(&name);
        if !stat.is_dir {
            jobs.push(Job { direction: Direction::Download, local: target, remote: root.clone(), size: stat.size });
            continue;
        }
        tokio::fs::create_dir_all(&target).await.map_err(local_err)?;
        for (rel, RemoteStat { size, is_dir, .. }) in files.walk(root).await? {
            let local = target.join(&rel);
            if is_dir {
                tokio::fs::create_dir_all(&local).await.map_err(local_err)?;
            } else {
                jobs.push(Job { direction: Direction::Download, local, remote: format!("{}/{rel}", root.trim_end_matches('/')), size });
            }
        }
    }
    Ok(jobs)
}

#[cfg(test)]
mod tests {
    #[test]
    fn numbered_keeps_the_extension() {
        assert_eq!(super::numbered("report.tar.gz", 1), "report.tar (1).gz");
        assert_eq!(super::numbered("notes.txt", 2), "notes (2).txt");
        assert_eq!(super::numbered(".bashrc", 1), ".bashrc (1)");
        assert_eq!(super::numbered("README", 3), "README (3)");
    }
}
