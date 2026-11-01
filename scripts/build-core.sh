#!/bin/sh
# core (Rust) → Swift bindings → xcframework, for apps/macos.
# Outputs are build artifacts (gitignored): apps/macos/Vendor/, apps/macos/Sources/JenaFileCore/*.swift
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export MACOSX_DEPLOYMENT_TARGET=13.0   # must match apps/macos/Package.swift platforms

cd "$ROOT/core"
cargo build --release -p jenafile-ffi
LIB="$ROOT/core/target/release"
GEN="$ROOT/core/target/uniffi"
rm -rf "$GEN" && mkdir -p "$GEN/headers" "$GEN/swift"
BG="cargo run -q --release -p jenafile-ffi --bin uniffi-bindgen-swift --"
$BG "$LIB/libjenafile_ffi.dylib" "$GEN/headers" --headers --modulemap \
    --module-name jenafile_ffiFFI --modulemap-filename module.modulemap
$BG "$LIB/libjenafile_ffi.dylib" "$GEN/swift" --swift-sources

APP="$ROOT/apps/macos"
rm -rf "$APP/Vendor/JenaFileCore.xcframework"
mkdir -p "$APP/Vendor"
xcodebuild -create-xcframework -library "$LIB/libjenafile_ffi.a" \
    -headers "$GEN/headers" -output "$APP/Vendor/JenaFileCore.xcframework" >/dev/null
cp "$GEN/swift/"*.swift "$APP/Sources/JenaFileCore/"
echo "✓ core → apps/macos/Vendor/JenaFileCore.xcframework"
