//! jena-file core. Everything stateful lives here; the native UIs stay thin.
//! See docs/ARCHITECTURE.md §2 for the module plan.

/// Core library version, shown in the app so a stale xcframework is easy to spot.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_matches_manifest() {
        assert_eq!(super::version(), env!("CARGO_PKG_VERSION"));
        assert!(!super::version().is_empty());
    }
}
