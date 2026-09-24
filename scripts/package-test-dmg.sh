#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Notchly.xcodeproj"
SCHEME="Notchly"
CONFIGURATION="Release"
VERSION="${NOTCHLY_VERSION:-1.0.0}"
ARCH="${NOTCHLY_ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    printf 'Unsupported architecture: %s (use arm64 or x86_64)\n' "$ARCH" >&2
    exit 2
    ;;
esac

DERIVED_DATA="${NOTCHLY_DERIVED_DATA:-$ROOT_DIR/build/DerivedData-$ARCH}"
SOURCE_PACKAGES="${NOTCHLY_SOURCE_PACKAGES:-$ROOT_DIR/build/SourcePackages}"
PACKAGE_CACHE="${NOTCHLY_PACKAGE_CACHE:-$ROOT_DIR/build/PackageCache}"
DIST_DIR="${NOTCHLY_DIST_DIR:-$ROOT_DIR/build/dist}"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Notchly.app"
DMG_PATH="$DIST_DIR/Notchly-$VERSION-$ARCH.dmg"

mkdir -p "$DIST_DIR"

if [[ -e "$DMG_PATH" || -e "$DMG_PATH.sha256" ]]; then
  printf 'Refusing to overwrite an existing package. Set NOTCHLY_VERSION or NOTCHLY_DIST_DIR to choose a new output path.\n' >&2
  exit 1
fi

printf 'Building Notchly %s for %s with an ad-hoc signature (no paid Apple account required)...\n' "$VERSION" "$ARCH"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -packageCachePath "$PACKAGE_CACHE" \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM= \
  MACOSX_DEPLOYMENT_TARGET=14.6 \
  build

if [[ ! -d "$APP_PATH" ]]; then
  printf 'Build completed but the expected app bundle was not produced: %s\n' "$APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
ACTUAL_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Notchly")"
if [[ "$ACTUAL_ARCHS" != *"$ARCH"* ]]; then
  printf 'Built app architecture mismatch: expected %s, got %s\n' "$ARCH" "$ACTUAL_ARCHS" >&2
  exit 1
fi

MINIMUM_OS="$(plutil -extract LSMinimumSystemVersion raw "$APP_PATH/Contents/Info.plist")"
if [[ "$MINIMUM_OS" != "14.6" ]]; then
  printf 'Unexpected minimum macOS version: %s (expected 14.6)\n' "$MINIMUM_OS" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "$DIST_DIR/.notchly-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/Notchly.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Notchly $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
  shasum -a 256 -c "$(basename "$DMG_PATH").sha256"
)

printf '\nCreated and verified:\n  %s\n  %s.sha256\n' "$DMG_PATH" "$DMG_PATH"
printf 'The app is ad-hoc signed and not notarized. Verify the checksum before sharing.\n'
