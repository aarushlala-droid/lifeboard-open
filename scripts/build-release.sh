#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
SWIFT_BUILD_ARGS=()
# Command Line Tools 27 currently omits the SwiftUI macro plug-in from its
# default SDK. Keep release builds reproducible with the installed compatible
# SDK until Apple ships the matching plug-in in CLT.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  SWIFT_BUILD_ARGS=(--build-system native -Xswiftc -Xfrontend -Xswiftc -experimental-allow-module-with-compiler-errors)
fi
swift run --disable-sandbox --scratch-path .build "${SWIFT_BUILD_ARGS[@]}" LifeBoardSelfTest

ARCHITECTURES=("$(uname -m)")
if [[ "${LIFEBOARD_UNIVERSAL:-0}" == "1" ]]; then
  ARCHITECTURES=(arm64 x86_64)
fi
BIN_DIRS=()
for architecture in "${ARCHITECTURES[@]}"; do
  swift build --disable-sandbox --scratch-path .build "${SWIFT_BUILD_ARGS[@]}" --triple "$architecture-apple-macosx" -c release
  BIN_DIRS+=("$(swift build --disable-sandbox --scratch-path .build "${SWIFT_BUILD_ARGS[@]}" --triple "$architecture-apple-macosx" -c release --show-bin-path)")
done

BUILD_ROOT="$(mktemp -d /tmp/lifeboard-release.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
SIGN_IDENTITY="${LIFEBOARD_SIGN_IDENTITY:--}"
OUTPUT_DIR="${LIFEBOARD_OUTPUT_DIR:-$PWD/dist}"
SIGN_OPTIONS=()
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Distribution signing requires a Developer ID Application identity." >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning | /usr/bin/grep -F -- "$SIGN_IDENTITY" >/dev/null; then
    echo "The requested Developer ID Application identity is unavailable in Keychain." >&2
    exit 1
  fi
  # Developer ID distribution requires hardened runtime and a secure timestamp.
  SIGN_OPTIONS=(--options runtime --timestamp)
fi
APP="$BUILD_ROOT/LifeBoard.app"
CONTENTS="$APP/Contents"
WIDGET="$CONTENTS/PlugIns/LifeBoardWidget.appex"
DMG_ROOT="$BUILD_ROOT/dmg-root"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/LifeBoard.dmg" "$OUTPUT_DIR/LifeBoard.app.zip"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WIDGET/Contents/MacOS" "$DMG_ROOT"
copy_product() {
  local product="$1" destination="$2"
  local inputs=()
  for bin_dir in "${BIN_DIRS[@]}"; do inputs+=("$bin_dir/$product"); done
  if (( ${#inputs[@]} == 1 )); then
    cp "${inputs[1]}" "$destination"
  else
    lipo -create "${inputs[@]}" -output "$destination"
  fi
  chmod 755 "$destination"
}
copy_product LifeBoard "$CONTENTS/MacOS/LifeBoard"
copy_product LifeBoardHelper "$CONTENTS/Resources/lifeboard"
copy_product LifeBoardWidget "$WIDGET/Contents/MacOS/LifeBoardWidget"
cp packaging/WidgetInfo.plist "$WIDGET/Contents/Info.plist"
if [[ -f Sources/LifeBoardApp/Resources/AppIcon-Source.png ]]; then
  scripts/make-icon.sh "$CONTENTS/Resources/AppIcon.icns"
fi
cp packaging/Info.plist "$CONTENTS/Info.plist"

# Synced folders can attach Finder/File Provider metadata that codesign rejects.
xattr -cr "$APP"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" "$CONTENTS/Resources/lifeboard"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" --entitlements packaging/Widget.entitlements "$WIDGET"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_OPTIONS[@]}" --entitlements packaging/LifeBoard.entitlements "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc "$APP" "$DMG_ROOT/LifeBoard.app"
xattr -cr "$DMG_ROOT/LifeBoard.app"
codesign --verify --deep --strict "$DMG_ROOT/LifeBoard.app"
ln -s /Applications "$DMG_ROOT/Applications"
if [[ "${LIFEBOARD_BETA_DOCS:-0}" == "1" ]]; then
  cp packaging/beta/START-HERE.md packaging/beta/PRIVACY.md "$DMG_ROOT/"
fi
if [[ "${SKIP_DMG:-0}" != "1" ]]; then
  hdiutil create -volname LifeBoard -srcfolder "$DMG_ROOT" -ov -format UDZO "$OUTPUT_DIR/LifeBoard.dmg"
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUTPUT_DIR/LifeBoard.dmg"
  fi
  echo "$OUTPUT_DIR/LifeBoard.dmg"
fi
# Preserve the signed app in an archive: File Provider can attach metadata to
# an unpacked app in dist after xattr has removed it, invalidating its seal.
ditto --norsrc -c -k --keepParent "$APP" "$OUTPUT_DIR/LifeBoard.app.zip"
unzip -tq "$OUTPUT_DIR/LifeBoard.app.zip"
echo "$OUTPUT_DIR/LifeBoard.app.zip"
