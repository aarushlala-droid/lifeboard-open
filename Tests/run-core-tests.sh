#!/bin/zsh
# Fast Core checks added with the Preview overhaul: patch equivalence and
# calendar/time-zone behaviour. Synthetic data only.
set -euo pipefail
cd "${0:A:h}/.."
SCRATCH="$(mktemp -d /tmp/lifeboard-core-tests.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
swiftc -O -sdk "$SDK" -module-cache-path "$SCRATCH/mc" -module-name LifeBoardCore -emit-library -emit-module \
  Sources/LifeBoardCore/*.swift -o "$SCRATCH/libLifeBoardCore.dylib" -emit-module-path "$SCRATCH/LifeBoardCore.swiftmodule"
ARGS=(-O -sdk "$SDK" -module-cache-path "$SCRATCH/mc" -I "$SCRATCH" -L "$SCRATCH" -lLifeBoardCore -Xlinker -rpath -Xlinker "$SCRATCH")
for suite in Tests/PatchEquivalence Tests/CalendarTime; do
  [[ -f "$suite/main.swift" ]] || continue
  swiftc "${ARGS[@]}" "$suite/main.swift" -o "$SCRATCH/${suite:t}"
  "$SCRATCH/${suite:t}"
done
