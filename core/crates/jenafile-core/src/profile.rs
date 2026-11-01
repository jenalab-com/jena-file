//! Saved servers (기획서 FR-02, S-02). JSON in the app data folder; never secrets —
//! passwords live in the OS store, keyed by profile id (ADR-005).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::ssh_command::ParsedSsh;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProfileVia {
    /// Another saved server is the bastion.
    Server { id: String },
    /// A bastion that is not saved on its own.
    Endpoint { host: String, port: u16, user: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    /// Empty when new; [`ProfileStore::save`] assigns one.
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub group: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    /// None = direct (FR-02a: bastion only when needed).
    #[serde(default)]
    pub via: Option<ProfileVia>,
    #[serde(default)]
    pub remote_dir: Option<String>,
    #[serde(default)]
    pub local_dir: Option<String>,
    /// The UI keeps the password in the OS store when true.
    #[serde(default)]
    pub save_password: bool,
}

#[derive(Serialize, Deserialize)]
struct File {
    version: u32,
    profiles: Vec<Profile>,
}

pub struct ProfileStore {
    path: PathBuf,
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn new_id() -> String {
    let ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    format!("p{ms:x}{:x}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

fn io(e: impl std::fmt::Display) -> CoreError {
    CoreError::Local { message: format!("profiles: {e}") }
}

impl ProfileStore {
    pub fn new(data_dir: &Path) -> Self {
        Self { path: data_dir.join("profiles.json") }
    }

    /// Sorted by group, then name. A missing file is an empty list.
    pub fn list(&self) -> Result<Vec<Profile>, CoreError> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(io(e)),
        };
        let mut profiles = serde_json::from_str::<File>(&text).map_err(io)?.profiles;
        profiles.sort_by(|a, b| (a.group.to_lowercase(), a.name.to_lowercase()).cmp(&(b.group.to_lowercase(), b.name.to_lowercase())));
        Ok(profiles)
    }

    /// Insert or replace by id. Returns the stored profile (with its id).
    pub fn save(&self, mut profile: Profile) -> Result<Profile, CoreError> {
        if profile.host.trim().is_empty() || profile.user.trim().is_empty() {
            return Err(CoreError::Local { message: "host and user are required".into() });
        }
        let mut all = self.list()?;
        if profile.id.is_empty() {
            profile.id = new_id();
        }
        if profile.name.trim().is_empty() {
            profile.name = profile.host.clone();
        }
        if let Some(ProfileVia::Server { id }) = &profile.via {
            if *id == profile.id {
                return Err(CoreError::Local { message: "a server cannot be its own bastion".into() });
            }
            if !all.iter().any(|p| &p.id == id) {
                return Err(CoreError::Local { message: "bastion server not found".into() });
            }
        }
        match all.iter_mut().find(|p| p.id == profile.id) {
            Some(slot) => *slot = profile.clone(),
            None => all.push(profile.clone()),
        }
        self.write(all)?;
        Ok(profile)
    }

    /// Refuses while another server uses it as bastion (would break that server).
    pub fn delete(&self, id: &str) -> Result<(), CoreError> {
        let all = self.list()?;
        if let Some(user) = all.iter().find(|p| matches!(&p.via, Some(ProfileVia::Server { id: b }) if b == id)) {
            return Err(CoreError::Local { message: format!("used as bastion by \"{}\"", user.name) });
        }
        self.write(all.into_iter().filter(|p| p.id != id).collect())
    }

    /// Atomic: write a temp file, then rename over the old one.
    fn write(&self, profiles: Vec<Profile>) -> Result<(), CoreError> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(io)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(&File { version: 1, profiles }).map_err(io)?;
        std::fs::write(&tmp, text).map_err(io)?;
        std::fs::rename(&tmp, &self.path).map_err(io)
    }
}

/// Profiles for a pasted `ssh` command (FR-09): the bastion (if any) and the
/// target pointing at it. Not saved yet; the UI fills gaps (e.g. target user).
pub fn profiles_from_ssh(parsed: &ParsedSsh) -> Option<(Option<Profile>, Profile)> {
    let t = parsed.target.as_ref()?;
    let blank = |host: &str, port: u16, user: &str| Profile {
        id: String::new(),
        name: host.to_string(),
        group: String::new(),
        host: host.to_string(),
        port,
        user: user.to_string(),
        via: None,
        remote_dir: None,
        local_dir: None,
        save_password: false,
    };
    let bastion = parsed.bastion.as_ref().map(|b| {
        let mut p = blank(&b.host, b.port, b.user.as_deref().unwrap_or(""));
        p.name = format!("bastion {}", b.host);
        p.id = new_id(); // so the target can point at it before saving
        p
    });
    let mut target = blank(&t.host, t.port, t.user.as_deref().unwrap_or(""));
    target.via = bastion.as_ref().map(|b| ProfileVia::Server { id: b.id.clone() });
    Some((bastion, target))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(name: &str, host: &str) -> Profile {
        Profile {
            id: String::new(),
            name: name.into(),
            group: String::new(),
            host: host.into(),
            port: 22,
            user: "u".into(),
            via: None,
            remote_dir: None,
            local_dir: None,
            save_password: true,
        }
    }

    #[test]
    fn save_list_update_delete() {
        let dir = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(dir.path());
        assert!(store.list().unwrap().is_empty(), "missing file = empty");

        let b = store.save(p("bastion", "203.0.113.10")).unwrap();
        assert!(!b.id.is_empty());
        let mut t = p("app", "10.0.0.5");
        t.via = Some(ProfileVia::Server { id: b.id.clone() });
        let t = store.save(t).unwrap();
        assert_eq!(store.list().unwrap().len(), 2);

        let mut renamed = t.clone();
        renamed.name = "app-01".into();
        store.save(renamed).unwrap();
        assert!(store.list().unwrap().iter().any(|x| x.name == "app-01" && x.id == t.id));
        assert_eq!(store.list().unwrap().len(), 2, "update, not insert");

        assert!(store.delete(&b.id).is_err(), "bastion in use");
        store.delete(&t.id).unwrap();
        store.delete(&b.id).unwrap();
        assert!(store.list().unwrap().is_empty());
        assert!(!std::fs::read_to_string(dir.path().join("profiles.json")).unwrap().contains("password"), "no secrets on disk");
    }

    #[test]
    fn rejects_bad_profiles() {
        let dir = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(dir.path());
        assert!(store.save(p("x", "")).is_err());
        let mut loop_ = p("x", "h");
        loop_.id = "same".into();
        loop_.via = Some(ProfileVia::Server { id: "same".into() });
        assert!(store.save(loop_).is_err());
        let mut dangling = p("x", "h");
        dangling.via = Some(ProfileVia::Server { id: "nope".into() });
        assert!(store.save(dangling).is_err());
    }

    #[test]
    fn ssh_command_becomes_bastion_and_target() {
        let parsed = crate::ssh_command::parse_ssh_command("ssh -L 2222:10.0.2.6:22 ops@203.0.113.10").unwrap();
        let (b, t) = profiles_from_ssh(&parsed).unwrap();
        let b = b.unwrap();
        assert_eq!((b.host.as_str(), b.user.as_str()), ("203.0.113.10", "ops"));
        assert_eq!(t.host, "10.0.2.6");
        assert_eq!(t.user, "", "-L has no target user; the UI asks");
        assert_eq!(t.via, Some(ProfileVia::Server { id: b.id }));
    }
}
