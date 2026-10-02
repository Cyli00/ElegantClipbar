#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
UNIVERSAL=false
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

usage() {
  printf '%s\n' 'Usage: scripts/package-app.sh [--debug] [--universal]' \
    'Default: release build for the current Mac.' \
    'Optional environment: APP_VERSION (x.y.z), BUILD_NUMBER (integer).' \
    'For restricted build hosts: SWIFT_CACHE_DIRECTORY, SWIFT_DISABLE_SANDBOX=1.'
}

for argument in "$@"; do
  case "$argument" in
    --debug) CONFIGURATION=debug ;;
    --universal) UNIVERSAL=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'ElegantClipbar requires macOS.' >&2
  exit 1
fi
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'APP_VERSION must be x.y.z and BUILD_NUMBER must be an integer.' >&2
  exit 2
fi

cd "$ROOT"
BUILD_ARGS=(--configuration "$CONFIGURATION" --product ElegantClipbar)
if [[ -n "${SWIFT_CACHE_DIRECTORY:-}" ]]; then
  mkdir -p "$SWIFT_CACHE_DIRECTORY"
  SWIFT_CACHE_DIRECTORY="$(cd "$SWIFT_CACHE_DIRECTORY" && pwd)"
  export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE_DIRECTORY/clang"
  export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_CACHE_DIRECTORY/modules"
  BUILD_ARGS+=(
    --cache-path "$SWIFT_CACHE_DIRECTORY/swiftpm"
    --config-path "$SWIFT_CACHE_DIRECTORY/configuration"
    --security-path "$SWIFT_CACHE_DIRECTORY/security"
  )
fi
if [[ "${SWIFT_DISABLE_SANDBOX:-0}" == 1 ]]; then
  BUILD_ARGS+=(--disable-sandbox)
fi
OUTPUT_DIRECTORY="$ROOT/build"
BINARIES=()
if [[ "$UNIVERSAL" == true ]]; then
  OUTPUT_DIRECTORY="$OUTPUT_DIRECTORY/universal"
  for architecture in arm64 x86_64; do
    swift build "${BUILD_ARGS[@]}" --arch "$architecture"
    BIN_DIRECTORY="$(swift build "${BUILD_ARGS[@]}" --arch "$architecture" --show-bin-path)"
    BINARIES+=("$BIN_DIRECTORY/ElegantClipbar")
  done
else
  swift build "${BUILD_ARGS[@]}"
  BIN_DIRECTORY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
  BINARIES+=("$BIN_DIRECTORY/ElegantClipbar")
fi

mkdir -p "$OUTPUT_DIRECTORY"
STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.ElegantClipbar-stage.XXXXXX")"
APP_PATH="$OUTPUT_DIRECTORY/ElegantClipbar.app"
STAGED_APP="$STAGING_DIRECTORY/ElegantClipbar.app"
PREVIOUS_APP=''

cleanup() {
  if [[ ! -e "$APP_PATH" && -n "$PREVIOUS_APP" && -d "$PREVIOUS_APP" ]]; then
    mv "$PREVIOUS_APP" "$APP_PATH"
  fi
  rm -rf "$STAGING_DIRECTORY"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
if [[ "$UNIVERSAL" == true ]]; then
  lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/ElegantClipbar"
else
  cp "${BINARIES[0]}" "$STAGED_APP/Contents/MacOS/ElegantClipbar"
fi
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/ElegantClipbar/Resources/BrandIcon.png" "$STAGED_APP/Contents/Resources/BrandIcon.png"
cp "$ROOT/Sources/ElegantClipbar/Resources/StatusIconTemplate.png" "$STAGED_APP/Contents/Resources/StatusIconTemplate.png"
chmod +x "$STAGED_APP/Contents/MacOS/ElegantClipbar"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist"

if [[ "$UNIVERSAL" == true ]]; then
  lipo "$STAGED_APP/Contents/MacOS/ElegantClipbar" -verify_arch arm64 x86_64
fi
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"

# Keep the old bundle recoverable until the newly signed bundle is in place.
if [[ -e "$APP_PATH" ]]; then
  PREVIOUS_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ElegantClipbar-previous.XXXXXX")"
  PREVIOUS_APP="$PREVIOUS_DIRECTORY/ElegantClipbar.app"
  mv "$APP_PATH" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$APP_PATH"
printf 'Built app: %s\n' "$APP_PATH"
if [[ -n "$PREVIOUS_APP" ]]; then
  printf 'Previous app preserved at: %s\n' "$PREVIOUS_APP"
fi
