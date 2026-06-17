#!/usr/bin/env bash
# Compile + sign the native macOS capture/transcription helper.
#
# Produces TWO artifacts (both git-ignored):
#   1. native/standby-capture-helper/build/standby-capture-helper — the bare
#      binary, used by the deterministic file-based smokes (transcribe-file needs
#      no TCC grant, so it stays unsigned for simplicity).
#   2. native/StandbyCapture.app — the SHIPPED helper the daemon spawns for LIVE
#      capture. It is signed with a STABLE code-signing identity (never ad-hoc),
#      because macOS TCC keys the Microphone + System-Audio grants on the signing
#      identity's designated requirement. Ad-hoc signing changes the cdhash every
#      build, so the grants would evaporate on each rebuild (the dogfood trap).
#
# Identity resolution order: $STANDBY_SIGN_IDENTITY → a Developer ID → an Apple
# Development cert → any valid codesigning identity → a persistent self-signed
# identity created in a dedicated keychain (CI / no-identity machines). Never ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="native/standby-capture-helper/main.swift"
BUILD_DIR="native/standby-capture-helper/build"
BIN="$BUILD_DIR/standby-capture-helper"
APP="native/StandbyCapture.app"
APP_BIN="$APP/Contents/MacOS/standby-capture-helper"
BUNDLE_ID="com.standby.capture-helper"
# Documented Core Audio process-tap floor. The effective runtime floor is higher
# (macOS 26, because SpeechAnalyzer), so we build against the host SDK rather than
# forcing -target 14.4 (which would make the 26-only Speech/Atomic symbols fail to
# resolve). 26 ≥ 14.4, so the tap's TCC category requirement is satisfied.
TAP_FLOOR="14.4"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "build-capture-helper: swiftc not found; native capture is macOS-only" >&2
  exit 3
fi

# Resolve (and if necessary create) a STABLE, non-ad-hoc signing identity.
resolve_identity() {
  if [ -n "${STANDBY_SIGN_IDENTITY:-}" ]; then
    printf '%s' "$STANDBY_SIGN_IDENTITY"; return 0
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [ -z "$found" ] && found="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/{print $2; exit}')"
  [ -z "$found" ] && found="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/[0-9]+\)/{print $2; exit}')"
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  ensure_self_signed_identity
}

# Fallback for machines with no codesigning identity (CI). Creates a persistent
# self-signed codesigning cert in a DEDICATED keychain whose password we own, so
# the whole flow is non-interactive (no login-keychain prompt). Idempotent.
# NOTE: untested on this machine (a Developer ID is present); the Developer ID
# path above is the exercised one.
ensure_self_signed_identity() {
  local name="Standby Capture Local Signing"
  local kc="$HOME/Library/Keychains/standby-codesign.keychain-db"
  local kpw="standby-local-signing"
  if security find-identity -v -p codesigning "$kc" 2>/dev/null | grep -q "$name"; then
    printf '%s' "$name"; return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $name
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -config "$tmp/cert.cnf" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
    -passout pass:tmp -name "$name" >/dev/null 2>&1
  security create-keychain -p "$kpw" "$kc" 2>/dev/null || true
  security set-keychain-settings "$kc"
  security unlock-keychain -p "$kpw" "$kc"
  security import "$tmp/id.p12" -k "$kc" -P tmp -T /usr/bin/codesign -A >/dev/null 2>&1
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kpw" "$kc" >/dev/null 2>&1
  local existing; existing="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$kc" $existing >/dev/null 2>&1
  rm -rf "$tmp"
  printf '%s' "$name"
}

# 1. Compile against the host SDK (macOS 26 here; Speech/Atomic require it).
mkdir -p "$BUILD_DIR"
echo "build-capture-helper: compiling $SRC"
swiftc -O "$SRC" -o "$BIN"

# 2. Assemble the .app bundle around the same compiled binary.
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP_BIN"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>StandbyCapture</string>
  <key>CFBundleExecutable</key><string>standby-capture-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${TAP_FLOOR}</string>
  <key>NSMicrophoneUsageDescription</key><string>Standby transcribes what you say in meetings, on device.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Standby transcribes what other participants say, on device.</string>
</dict>
</plist>
PLIST

# 3. Sign the bundle with a stable identity. --timestamp=none keeps it offline
#    (no Apple TSA round-trip); local execution needs no notarization.
IDENTITY="$(resolve_identity)"
if [ -z "$IDENTITY" ]; then
  echo "build-capture-helper: no stable signing identity available and self-signed fallback failed" >&2
  exit 4
fi
echo "build-capture-helper: signing $APP with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"

# 4. Guard: refuse ad-hoc (the TCC-persistence invariant; verify.sh re-checks it).
if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "build-capture-helper: refusing ad-hoc signature — TCC grants would evaporate on rebuild" >&2
  exit 5
fi

echo "build-capture-helper: built $BIN (bare, for file smokes)"
echo "build-capture-helper: built + signed $APP (shipped helper)"
