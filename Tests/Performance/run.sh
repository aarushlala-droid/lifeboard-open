#!/usr/bin/env bash
set -euo pipefail
benchmark_repo="${1:-$(git rev-parse --show-toplevel)}"
report_directory="${2:-$benchmark_repo/Tests/Performance/latest}"
benchmark_build="$(mktemp -d /private/tmp/lifeboard-performance.XXXXXX)"
trap 'rm -rf "$benchmark_build"' EXIT
mkdir -p "$report_directory"
compatible_sdk="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$compatible_sdk" ]]; then
  compatible_sdk="$(xcrun --show-sdk-path)"
fi
swiftc -O -sdk "$compatible_sdk" -Xfrontend -experimental-allow-module-with-compiler-errors -module-cache-path "$benchmark_build/modules" "$benchmark_repo"/Sources/LifeBoardCore/*.swift "$benchmark_repo/Tests/Performance/main.swift" -o "$benchmark_build/performance"
"$benchmark_build/performance" > "$report_directory/swift-results.json"
node "$benchmark_repo/Tests/Performance/mobile.mjs" "$benchmark_repo" > "$report_directory/mobile-results.json"
shasum -a 256 "$benchmark_repo/Sources/LifeBoardCore/Scheduling.swift" "$benchmark_repo/Sources/LifeBoardCore/TaskClassification.swift" "$benchmark_repo/Sources/LifeBoardCore/TopicImport.swift" "$benchmark_repo/mobile/web/scheduling.js" "$benchmark_repo/mobile/web/task-groups.js" "$benchmark_repo/mobile/web/sync.js" > "$report_directory/source-hashes.txt"
swift --version > "$report_directory/swift-toolchain.txt"
node --version > "$report_directory/node-toolchain.txt"
python3 - "$report_directory" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
rows = json.loads((folder / 'swift-results.json').read_text()) + json.loads((folder / 'mobile-results.json').read_text())
failures = [row for row in rows if not row['budgetPassed']]
for row in rows:
    status = 'PASS' if row['budgetPassed'] else 'FAIL'
    print(f"{status} {row['engine']} {row['operation']} {row['nominalRecords']}: median {row['medianMS']:.2f}ms, max {row['p95MS']:.2f}ms, budget {row['budgetMS']:.0f}ms")
print(f"{len(rows) - len(failures)}/{len(rows)} provisional desktop computation budgets passed")
sys.exit(bool(failures))
PY
