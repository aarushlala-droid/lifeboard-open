#!/bin/zsh
# Per-action persistence benchmark on synthetic data. Usage: Tests/Performance/commit-benchmark.sh
set -euo pipefail
cd "${0:A:h}/../.."
CORE="${LIFEBOARD_BENCH_CORE:-Sources/LifeBoardCore}"
SCRATCH="$(mktemp -d /tmp/lifeboard-commit-bench.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
swiftc -O -sdk "$SDK" -module-cache-path "$SCRATCH/mc" -module-name LifeBoardCore -emit-library -emit-module \
  "$CORE"/*.swift -o "$SCRATCH/libLifeBoardCore.dylib" -emit-module-path "$SCRATCH/LifeBoardCore.swiftmodule" 2>/dev/null
swiftc -O -sdk "$SDK" -module-cache-path "$SCRATCH/mc" -I "$SCRATCH" -L "$SCRATCH" -lLifeBoardCore \
  -Xlinker -rpath -Xlinker "$SCRATCH" Tests/Performance/CommitBenchmark/main.swift -o "$SCRATCH/bench"
"$SCRATCH/bench"
