#!/bin/zsh
# Builds "LifeBoard Preview", a separately installable app with its own bundle
# identifiers, data folder, URL scheme, widget and Keychain service. It never
# reads or writes the installed LifeBoard's data, and mobile sync is compiled out.
#
#   scripts/build-preview.sh            build into dist/preview
#   scripts/build-preview.sh --install  also copy to ~/Applications (Preview bundle only)
set -euo pipefail

cd "${0:A:h}/.."
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1
SCRATCH_PATH="$PWD/.build-preview"
export CLANG_MODULE_CACHE_PATH="$SCRATCH_PATH/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH_PATH/ModuleCache"
SWIFT_BUILD_ARGS=(-Xswiftc -DLIFEBOARD_PREVIEW)
# Command Line Tools 27 omits the SwiftUI macro plug-in from its default SDK;
# use the installed compatible SDK, exactly as the release script does.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  SWIFT_BUILD_ARGS+=(--build-system native -Xswiftc -Xfrontend -Xswiftc -experimental-allow-module-with-compiler-errors)
fi

swift run --disable-sandbox --scratch-path "$SCRATCH_PATH" "${SWIFT_BUILD_ARGS[@]}" LifeBoardSelfTest
# The compatibility flag above lets SwiftPM report success despite compiler
# errors, so any "error:" in the log fails the Preview build outright.
BUILD_LOG="$(mktemp /tmp/lifeboard-preview-build.XXXXXX)"
swift build --disable-sandbox --scratch-path "$SCRATCH_PATH" "${SWIFT_BUILD_ARGS[@]}" -c release 2>&1 | tee "$BUILD_LOG"
if grep -q "error:" "$BUILD_LOG"; then
  echo "Preview build failed: compiler errors above." >&2
  rm -f "$BUILD_LOG"; exit 1
fi
rm -f "$BUILD_LOG"
BIN_DIR="$(swift build --disable-sandbox --scratch-path "$SCRATCH_PATH" "${SWIFT_BUILD_ARGS[@]}" -c release --show-bin-path)"

OUTPUT_DIR="$PWD/dist/preview"
# Assemble and sign outside synced folders: File Provider metadata on files in
# Documents invalidates code signatures (the release script does the same).
BUILD_ROOT="$(mktemp -d /tmp/lifeboard-preview.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
APP="$BUILD_ROOT/LifeBoard Preview.app"
CONTENTS="$APP/Contents"
WIDGET="$CONTENTS/PlugIns/LifeBoardWidget.appex"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/LifeBoard Preview.app" "$OUTPUT_DIR/LifeBoard Preview.app.zip"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WIDGET/Contents/MacOS"
install -m 755 "$BIN_DIR/LifeBoard" "$CONTENTS/MacOS/LifeBoard"
install -m 755 "$BIN_DIR/LifeBoardHelper" "$CONTENTS/Resources/lifeboard"
install -m 755 "$BIN_DIR/LifeBoardWidget" "$WIDGET/Contents/MacOS/LifeBoardWidget"
cp packaging/preview/WidgetInfo.plist "$WIDGET/Contents/Info.plist"
cp packaging/preview/Info.plist "$CONTENTS/Info.plist"

ICON_SOURCE="$SCRATCH_PATH/AppIcon-Preview.png"
swift scripts/preview-icon.swift Sources/LifeBoardApp/Resources/AppIcon-Source.png "$ICON_SOURCE"
LIFEBOARD_ICON_SOURCE="$ICON_SOURCE" scripts/make-icon.sh "$CONTENTS/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --sign - "$CONTENTS/Resources/lifeboard"
codesign --force --sign - --entitlements packaging/preview/Widget.entitlements "$WIDGET"
codesign --force --sign - --entitlements packaging/LifeBoard.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# Refuse to hand over a bundle that could be mistaken for, or collide with, the installed app.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")" == "app.lifeboard.preview" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET/Contents/Info.plist")" == "app.lifeboard.preview.widget" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$CONTENTS/Info.plist")" == "lifeboard-preview" ]]
grep -q "LifeBoard Preview" "$CONTENTS/MacOS/LifeBoard"
grep -q "app.lifeboard.preview.sync" "$CONTENTS/MacOS/LifeBoard"
grep -q "LifeBoard Preview" "$WIDGET/Contents/MacOS/LifeBoardWidget"
grep -q "LifeBoard Preview" "$CONTENTS/Resources/lifeboard"

ditto --norsrc -c -k --keepParent "$APP" "$OUTPUT_DIR/LifeBoard Preview.app.zip"
unzip -tq "$OUTPUT_DIR/LifeBoard Preview.app.zip"
echo "$OUTPUT_DIR/LifeBoard Preview.app.zip"

if (( INSTALL )); then
  TARGET="$HOME/Applications/LifeBoard Preview.app"
  if [[ -e "$TARGET" ]]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing" != "app.lifeboard.preview" ]]; then
      echo "Refusing to replace $TARGET: it is not a LifeBoard Preview bundle ($existing)." >&2
      exit 1
    fi
    rm -rf "$TARGET"
  fi
  mkdir -p "$HOME/Applications"
  ditto --norsrc "$APP" "$TARGET"
  codesign --verify --deep --strict "$TARGET"
  echo "$TARGET"
fi
