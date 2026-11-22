#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
SCRATCH="$(mktemp -d /tmp/lifeboard-audit-tests.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
export CLANG_MODULE_CACHE_PATH="$SCRATCH/ModuleCache"
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"; fi
fi
swiftc -sdk "$SDKROOT" -emit-library -emit-module -module-name LifeBoardCore Sources/LifeBoardCore/*.swift -o "$SCRATCH/libLifeBoardCore.dylib" -emit-module-path "$SCRATCH/LifeBoardCore.swiftmodule"
ARGS=(-sdk "$SDKROOT" -I "$SCRATCH" -L "$SCRATCH" -lLifeBoardCore -Xlinker -rpath -Xlinker "$SCRATCH")
swiftc "${ARGS[@]}" Sources/LifeBoardApp/SyncService.swift Tests/Credentials/main.swift -o "$SCRATCH/credentials-policy"
LIFEBOARD_DATA_PATH="$SCRATCH/credentials/LifeBoard.json" "$SCRATCH/credentials-policy"
swiftc "${ARGS[@]}" -D APPSTORE_SAFETY Sources/LifeBoardApp/AppStore.swift Sources/LifeBoardApp/PlannerIndex.swift Sources/LifeBoardApp/DesignSystem.swift Tests/Safety/main.swift -o "$SCRATCH/safety"
if [[ -x .build/arm64-apple-macosx/release/LifeBoardHelper ]]; then
  "$SCRATCH/safety" --helper "$PWD/.build/arm64-apple-macosx/release/LifeBoardHelper"
elif [[ -x .build/release/LifeBoardHelper ]]; then
  "$SCRATCH/safety" --helper "$PWD/.build/release/LifeBoardHelper"
else
  "$SCRATCH/safety"
fi
{ echo 'import LifeBoardCore'; cat Tests/Planning/main.swift; } > "$SCRATCH/main.swift"
swiftc "${ARGS[@]}" "$SCRATCH/main.swift" -o "$SCRATCH/planning"
"$SCRATCH/planning" fixtures/capture.json
{ echo 'import LifeBoardCore'; cat Tests/TopicImport/main.swift; } > "$SCRATCH/main.swift"
swiftc "${ARGS[@]}" "$SCRATCH/main.swift" -o "$SCRATCH/topics"
"$SCRATCH/topics"
cp Tests/TopicChunks/main.swift "$SCRATCH/main.swift"
swiftc "${ARGS[@]}" Sources/LifeBoardApp/TopicImportIntelligence.swift "$SCRATCH/main.swift" -o "$SCRATCH/topic-chunks"
"$SCRATCH/topic-chunks"
swiftc "${ARGS[@]}" -parse-as-library Sources/LifeBoardApp/CaptureIntelligence.swift Tests/CaptureIntelligence/main.swift -o "$SCRATCH/capture-intelligence"
"$SCRATCH/capture-intelligence"
{ echo 'import LifeBoardCore'; cat Tests/Wire/main.swift; } > "$SCRATCH/WireGate.swift"
swiftc "${ARGS[@]}" -parse-as-library "$SCRATCH/WireGate.swift" -o "$SCRATCH/wire"
"$SCRATCH/wire" fixtures/wire-valid.json
if [[ -f dist/private/Cloud-api-before-audit-document.json ]]; then
  "$SCRATCH/wire" dist/private/Cloud-api-before-audit-document.json
fi
Tests/run-core-tests.sh
if [[ "${LIFEBOARD_SKIP_MOBILE:-0}" == "1" ]]; then echo "Mobile tests skipped (LIFEBOARD_SKIP_MOBILE=1)"; exit 0; fi
LIFEBOARD_WIRE_VALIDATOR="$SCRATCH/wire" npm test --prefix mobile
npm run build --prefix mobile
