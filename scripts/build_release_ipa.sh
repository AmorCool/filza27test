#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 <base-unsigned.ipa> <output.ipa> [MCMIdentifiers.plist]" >&2
  exit 64
fi

BASE_IPA="${1:A}"
OUTPUT_IPA="${2:A}"
CATALOG="${3:-}"
if [[ -n "$CATALOG" ]]; then
  CATALOG="${CATALOG:A}"
fi

REPO_ROOT="${0:A:h:h}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

FILZASLOP_VERSION="${FILZASLOP_VERSION:-$(
  git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true
)}"
if [[ -z "$FILZASLOP_VERSION" || ${#FILZASLOP_VERSION} -gt 64 ||
      "$FILZASLOP_VERSION" == *[^A-Za-z0-9._-]* ]]; then
  echo "invalid FilzaSlop version: $FILZASLOP_VERSION" >&2
  echo "tag the release commit or set FILZASLOP_VERSION explicitly" >&2
  exit 65
fi

[[ -f "$BASE_IPA" ]] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
if [[ -n "$CATALOG" ]]; then
  [[ -f "$CATALOG" ]] || { echo "catalog not found: $CATALOG" >&2; exit 66; }
  plutil -lint "$CATALOG" >/dev/null
  plutil -extract AppData xml1 -o /dev/null "$CATALOG"
fi

cd "$REPO_ROOT"
make clean
make package FINALPACKAGE=1

DYLIB="$REPO_ROOT/.theos/obj/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || { echo "built dylib not found: $DYLIB" >&2; exit 70; }

STAGE_ROOT="$(mktemp -d /tmp/FilzaSlop-release.XXXXXX)"
trap 'trash "$STAGE_ROOT"' EXIT
unzip -q "$BASE_IPA" -d "$STAGE_ROOT/stage"

APP="$(find "$STAGE_ROOT/stage/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Payload app not found" >&2; exit 65; }

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist")"
[[ "$BUNDLE_ID" == "com.apple.mobile.MobileHouseArrest" ]] || {
  echo "unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 65
}

if codesign -d "$APP" >/dev/null 2>&1; then
  echo "base app is signed; use an unsigned base IPA" >&2
  exit 65
fi

cp "$DYLIB" "$APP/Frameworks/FilzaApplySandboxExt.dylib"
codesign --remove-signature "$APP/Frameworks/FilzaApplySandboxExt.dylib"

# Strip URL schemes (filza://, Dropbox, Box SDK) — detectable via canOpenURL:
plutil -remove CFBundleURLTypes "$APP/Info.plist" 2>/dev/null || true
if plutil -extract CFBundleURLTypes xml1 -o /dev/null "$APP/Info.plist" \
    >/dev/null 2>&1; then
  echo "failed to remove CFBundleURLTypes from the release app" >&2
  exit 65
fi

plutil -replace FilzaSlopVersion -string "$FILZASLOP_VERSION" \
  "$APP/Info.plist" 2>/dev/null ||
  plutil -insert FilzaSlopVersion -string "$FILZASLOP_VERSION" "$APP/Info.plist"

if [[ -n "$CATALOG" ]]; then
  cp "$CATALOG" "$APP/MCMIdentifiers.plist"
elif [[ -e "$APP/MCMIdentifiers.plist" ]]; then
  trash "$APP/MCMIdentifiers.plist"
fi

if [[ -e "$OUTPUT_IPA" ]]; then
  trash "$OUTPUT_IPA"
fi
(
  cd "$STAGE_ROOT/stage"
  zip -qry "$OUTPUT_IPA" Payload
)

shasum -a 256 "$OUTPUT_IPA"
