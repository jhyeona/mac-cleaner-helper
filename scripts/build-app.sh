#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-debug}"
BUILD_CACHE_DIR="$PROJECT_DIR/.build/local-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE_DIR/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE_DIR/ModuleCache"

case "$CONFIGURATION" in
  debug)
    PRODUCT_DIR="$PROJECT_DIR/.build/out/Products/Debug"
    ;;
  release)
    PRODUCT_DIR="$PROJECT_DIR/.build/out/Products/Release"
    ;;
  *)
    print -u2 "usage: $0 [debug|release]"
    exit 64
    ;;
esac

swift build \
  --package-path "$PROJECT_DIR" \
  --cache-path "$BUILD_CACHE_DIR/SwiftPM" \
  --config-path "$BUILD_CACHE_DIR/Configuration" \
  --security-path "$BUILD_CACHE_DIR/Security" \
  -c "$CONFIGURATION"

APP_DIR="$PROJECT_DIR/.build/Biu-${CONFIGURATION}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp -f "$PROJECT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp -f "$PROJECT_DIR/Support/Biu.icns" "$RESOURCES_DIR/Biu.icns"
cp -f "$PRODUCT_DIR/MacCleanHelper" "$MACOS_DIR/Biu"
chmod +x "$MACOS_DIR/Biu"
ditto "$PRODUCT_DIR/MacCleanHelper_MacCleanHelper.bundle" \
  "$RESOURCES_DIR/MacCleanHelper_MacCleanHelper.bundle"

# SwiftPM signs the standalone executable. Copying that signature into an app
# bundle makes macOS validate it with the wrong resource envelope, so sign the
# completed bundle once all resources are in place.
codesign --force --deep --sign - "$APP_DIR"

print "$APP_DIR"
