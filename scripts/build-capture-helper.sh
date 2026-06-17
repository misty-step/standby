#!/usr/bin/env bash
# Compile the native macOS capture/transcription helper.
# Output is git-ignored; Rust resolves it via STANDBY_CAPTURE_HELPER or the
# default path below.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="native/standby-capture-helper/main.swift"
OUT_DIR="native/standby-capture-helper/build"
OUT="$OUT_DIR/standby-capture-helper"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "build-capture-helper: swiftc not found; native capture is macOS-only" >&2
  exit 3
fi

mkdir -p "$OUT_DIR"
echo "build-capture-helper: compiling $SRC"
swiftc -O "$SRC" -o "$OUT"
echo "build-capture-helper: built $OUT"
