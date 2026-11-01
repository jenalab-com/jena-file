import JenaFileCore

/// Facts about the linked Rust core. UI code talks to JenaFileKit, never to
/// the generated UniFFI types directly (docs/ARCHITECTURE.md §9).
public enum CoreInfo {
    public static var version: String { coreVersion() }
}
