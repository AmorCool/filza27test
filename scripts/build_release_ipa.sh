#!/bin/zsh
# build_release_ipa.sh — package a release Filza Airlift .ipa.
#
#   usage: $0 <base.ipa> <output.ipa> [AirliftIndex.json]
#
# The base is a decrypted (TrollStore-style) Filza IPA. It may be ad-hoc
# signed. We:
#   * rebuild the tweak dylib + Rust airlift core
#   * repair the base archive (some mirrors append a decoy EOCD that breaks
#     unzip, but leaves the real central directory intact)
#   * drop the dylib into Frameworks/
#   * inject an LC_LOAD_DYLIB @executable_path/Frameworks/FilzaApplySandboxExt.dylib
#     into Filza's main Mach-O (inside header slack; no segment relocation)
#   * strip every signature so the sideload tool re-signs the whole app
#   * rename the bundle to com.apple.mobile.MobileHouseArrest (required on jailed devices)
#   * inject Local Network + Bonjour declarations so the RPPairing host can
#     advertise over Bonjour (iOS 14+ silently blocks it otherwise)
#   * strip URL schemes, embed the AirliftIndex catalog + version tag
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 <base.ipa> <output.ipa> [AirliftIndex.json]" >&2
  exit 64
fi

BASE_IPA="${1:A}"
OUTPUT_IPA="${2:A}"
INDEX="${3:-}"
if [[ -n "$INDEX" ]]; then
  INDEX="${INDEX:A}"
fi

REPO_ROOT="${0:A:h:h}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

FILZAAL_VERSION="${FILZAAL_VERSION:-$(
  git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true
)}"
if [[ -z "$FILZAAL_VERSION" || ${#FILZAAL_VERSION} -gt 64 ||
      "$FILZAAL_VERSION" == *[^A-Za-z0-9._-]* ]]; then
  echo "invalid FilzaAl version: $FILZAAL_VERSION" >&2
  echo "tag the release commit or set FILZAAL_VERSION explicitly" >&2
  exit 65
fi

[[ -f "$BASE_IPA" ]] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
if [[ -n "$INDEX" ]]; then
  [[ -f "$INDEX" ]] || { echo "index not found: $INDEX" >&2; exit 66; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$INDEX"
fi

cd "$REPO_ROOT"
make clean
make package FINALPACKAGE=1

DYLIB="$REPO_ROOT/.theos/obj/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || { echo "built dylib not found: $DYLIB" >&2; exit 70; }

STAGE_ROOT="$(mktemp -d /tmp/FilzaAl-release.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

# Some TrollStore mirrors append a decoy EOCD so stock unzip fails; recover the
# real central directory first.
python3 "$REPO_ROOT/scripts/repair_ipa_zip.py" "$BASE_IPA" "$STAGE_ROOT/base.ipa"
unzip -q "$STAGE_ROOT/base.ipa" -d "$STAGE_ROOT/stage"

APP="$(find "$STAGE_ROOT/stage/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Payload app not found" >&2; exit 65; }

MAIN_BIN="$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")"
[[ -f "$MAIN_BIN" ]] || { echo "main binary not found: $MAIN_BIN" >&2; exit 65; }

# --- Bundle identity ---
# com.apple.mobile.MobileHouseArrest is the Apple-like identity required by
# iOS's first-open integrity path on jailed devices (same as 0xjohnnydev/FilzaSlop).
# Without it the signed app is rejected at launch with "Unable to install,
# please try again later".
plutil -replace CFBundleIdentifier -string "com.apple.mobile.MobileHouseArrest" "$APP/Info.plist"
plutil -replace CFBundleDisplayName -string "Filza Airlift" "$APP/Info.plist" 2>/dev/null ||
  plutil -insert CFBundleDisplayName -string "Filza Airlift" "$APP/Info.plist"

# --- Local Network / Bonjour ---
plutil -insert NSLocalNetworkUsageDescription \
  -string "Filza advertises an on-device pairing service (RPPairing) so this iPhone can pair with itself and reach its own lockdown/ATC over the LocalDevVPN loopback." \
  "$APP/Info.plist" 2>/dev/null || true
plutil -insert NSBonjourServices -json \
  '["_remotepairing-pairable-host._tcp","_filzaairliftprobe._tcp"]' \
  "$APP/Info.plist" 2>/dev/null || true

# --- Tweak dylib ---
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/FilzaApplySandboxExt.dylib"
codesign --remove-signature "$APP/Frameworks/FilzaApplySandboxExt.dylib"

# --- Strip all signatures, then inject the load command ---
codesign --remove-signature "$APP"
find "$APP/Frameworks" -type f -name '*.dylib' -exec codesign --remove-signature {} \; 2>/dev/null || true
python3 "$REPO_ROOT/scripts/inject_dylib_load.py" \
  "$MAIN_BIN" "@executable_path/Frameworks/FilzaApplySandboxExt.dylib"

# Everything must ship unsigned: the sideload tool performs the final signing,
# so the injected load command survives it.
if codesign -d "$MAIN_BIN" >/dev/null 2>&1; then
  echo "main binary still carries a signature; expected an unsigned IPA" >&2
  exit 65
fi

# --- Strip URL schemes (filza://, Dropbox, Box SDK) — detectable via canOpenURL ---
plutil -remove CFBundleURLTypes "$APP/Info.plist" 2>/dev/null || true
if plutil -extract CFBundleURLTypes xml1 -o /dev/null "$APP/Info.plist" >/dev/null 2>&1; then
  echo "failed to remove CFBundleURLTypes from the release app" >&2
  exit 65
fi

# --- Airlift catalog + version ---
plutil -replace FilzaAlVersion -string "$FILZAAL_VERSION" "$APP/Info.plist" 2>/dev/null ||
  plutil -insert FilzaAlVersion -string "$FILZAAL_VERSION" "$APP/Info.plist"

if [[ -n "$INDEX" ]]; then
  cp "$INDEX" "$APP/AirliftIndex.json"
elif [[ -e "$APP/AirliftIndex.json" ]]; then
  rm -f "$APP/AirliftIndex.json"
fi

if [[ -e "$OUTPUT_IPA" ]]; then
  rm -f "$OUTPUT_IPA"
fi
(
  cd "$STAGE_ROOT/stage"
  zip -qry "$OUTPUT_IPA" Payload
)

shasum -a 256 "$OUTPUT_IPA"