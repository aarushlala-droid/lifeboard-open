#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}/.."
SOURCE="${LIFEBOARD_ICON_SOURCE:-$ROOT/Sources/LifeBoardApp/Resources/AppIcon-Source.png}"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUTPUT="${1:-$ROOT/.build/AppIcon.icns}"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for entry in 16:icon_16x16.png 32:icon_16x16@2x.png 32:icon_32x32.png 64:icon_32x32@2x.png 128:icon_128x128.png 256:icon_128x128@2x.png 256:icon_256x256.png 512:icon_256x256@2x.png 512:icon_512x512.png 1024:icon_512x512@2x.png; do
  size="${entry%%:*}"
  name="${entry#*:}"
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
done
if iconutil -c icns "$ICONSET" -o "$OUTPUT" 2>/dev/null; then
  exit 0
fi

# iconutil is unreliable on some macOS preview builds. The Codex desktop
# runtime includes Pillow, which produces a standards-compliant ICNS fallback.
if [[ -n "${LIFEBOARD_PYTHON:-}" ]] && "$LIFEBOARD_PYTHON" -c 'import PIL' 2>/dev/null; then
  PYTHON_BIN="$LIFEBOARD_PYTHON"
elif command -v python3 >/dev/null && python3 -c 'import PIL' 2>/dev/null; then
  PYTHON_BIN="$(command -v python3)"
elif [[ -n "${HOME:-}" ]] && [[ -x "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3" ]]; then
  PYTHON_BIN="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
else
  print -u2 "iconutil failed and no Python installation with Pillow was found."
  exit 1
fi
"$PYTHON_BIN" -c 'import sys; from PIL import Image; image = Image.open(sys.argv[1]).convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS); image.save(sys.argv[2], format="ICNS")' "$SOURCE" "$OUTPUT"
