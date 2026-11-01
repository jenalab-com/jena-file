#!/bin/sh
# Rust core → Swift bindings → xcframework → swift-host build.
set -e
cd "$(dirname "$0")"
. "$HOME/.cargo/env"
export MACOSX_DEPLOYMENT_TARGET=13.0   # match Package.swift platforms, avoids ld version warnings
cargo build --release
rm -rf out && mkdir -p out/headers out/swift
BG="cargo run -q --release --bin uniffi-bindgen-swift --"
$BG target/release/libjenafile_core.dylib out/headers --headers --modulemap \
    --module-name jenafile_coreFFI --modulemap-filename module.modulemap
$BG target/release/libjenafile_core.dylib out/swift --swift-sources
xcodebuild -create-xcframework -library target/release/libjenafile_core.a \
    -headers out/headers -output out/JenaFileCore.xcframework >/dev/null
cp out/swift/jenafile_core.swift ../swift-host/Sources/JenaFileCore/
cd ../swift-host && swift build -c release
