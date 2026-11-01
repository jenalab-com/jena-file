//! Thin UniFFI surface over jenafile-core: type conversion and exports only.

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn core_version() -> String {
    jenafile_core::version().to_string()
}
