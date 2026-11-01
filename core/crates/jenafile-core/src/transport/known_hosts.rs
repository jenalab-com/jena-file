//! Host key trust. Reads the user's ~/.ssh/known_hosts but only ever writes the
//! app's own file (ADR-006). An entry in the app file wins over the user file,
//! so accepting a changed key works even if ~/.ssh/known_hosts still has the old one.

use std::fs;
use std::path::PathBuf;

use russh::keys::PublicKey;
use russh::keys::known_hosts::check_known_hosts_path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Trust {
    Known,
    Unknown,
    Changed,
}

pub(crate) struct KnownHosts {
    app_file: PathBuf,
    user_file: Option<PathBuf>,
}

impl KnownHosts {
    pub(crate) fn new(app_file: PathBuf, user_file: Option<PathBuf>) -> Self {
        Self { app_file, user_file }
    }

    pub(crate) fn check(&self, host: &str, port: u16, key: &PublicKey) -> Trust {
        let app = check_file(&self.app_file, host, port, key);
        if app != Trust::Unknown {
            return app;
        }
        match &self.user_file {
            Some(f) => check_file(f, host, port, key),
            None => Trust::Unknown,
        }
    }

    /// Trust `key` for host:port in the app file, replacing any previous entry for it.
    pub(crate) fn remember(&self, host: &str, port: u16, key: &PublicKey) -> std::io::Result<()> {
        let token = host_token(host, port);
        let existing = fs::read_to_string(&self.app_file).unwrap_or_default();
        let mut lines: Vec<String> = existing
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter(|l| l.split_whitespace().next() != Some(token.as_str()))
            .map(str::to_string)
            .collect();
        lines.push(format!("{token} {}", key.to_openssh().map_err(std::io::Error::other)?));
        if let Some(dir) = self.app_file.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(&self.app_file, lines.join("\n") + "\n")
    }
}

fn host_token(host: &str, port: u16) -> String {
    if port == 22 { host.to_string() } else { format!("[{host}]:{port}") }
}

fn check_file(path: &PathBuf, host: &str, port: u16, key: &PublicKey) -> Trust {
    if !path.exists() {
        return Trust::Unknown;
    }
    match check_known_hosts_path(host, port, key, path) {
        Ok(true) => Trust::Known,
        Ok(false) => Trust::Unknown,
        Err(russh::keys::Error::KeyChanged { .. }) => Trust::Changed,
        Err(e) => {
            log::warn!("known_hosts {}: {e}", path.display());
            Trust::Unknown
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::known_hosts::learn_known_hosts_path;
    // Two throwaway public keys (no private halves kept anywhere).
    const K1: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGmodU4tgcSnTLXNQ9tkHzisY8gnVH2Us7IE+mfLIimK";
    const K2: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGAcO1kKw9fNzizJmZqAiRMKGlxvwcpQgXsIu/IDE3/8";

    fn keys() -> (PublicKey, PublicKey) {
        (PublicKey::from_openssh(K1).unwrap(), PublicKey::from_openssh(K2).unwrap())
    }

    #[test]
    fn unknown_then_remembered_then_changed_then_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"), None);
        let (k1, k2) = keys();

        assert_eq!(kh.check("h", 2201, &k1), Trust::Unknown);
        kh.remember("h", 2201, &k1).unwrap();
        assert_eq!(kh.check("h", 2201, &k1), Trust::Known);
        assert_eq!(kh.check("h", 22, &k1), Trust::Unknown, "port is part of the identity");
        assert_eq!(kh.check("h", 2201, &k2), Trust::Changed);

        kh.remember("h", 2201, &k2).unwrap();
        assert_eq!(kh.check("h", 2201, &k2), Trust::Known);
        let text = fs::read_to_string(dir.path().join("known_hosts")).unwrap();
        assert_eq!(text.lines().count(), 1, "replaced, no blank lines: {text:?}");
        assert_eq!(kh.check("h", 2201, &k1), Trust::Changed, "old key no longer trusted");
    }

    #[test]
    fn app_file_wins_over_user_file() {
        let dir = tempfile::tempdir().unwrap();
        let user = dir.path().join("user_known_hosts");
        let (old, new) = keys();
        learn_known_hosts_path("h", 22, &old, &user).unwrap();
        let kh = KnownHosts::new(dir.path().join("app_known_hosts"), Some(user.clone()));

        assert_eq!(kh.check("h", 22, &old), Trust::Known, "user file is read");
        assert_eq!(kh.check("h", 22, &new), Trust::Changed);
        kh.remember("h", 22, &new).unwrap();
        assert_eq!(kh.check("h", 22, &new), Trust::Known);
        let user_after = fs::read_to_string(&user).unwrap();
        assert!(user_after.contains(&old.to_openssh().unwrap()), "user file untouched");
    }
}
