#!/usr/bin/env bash
# Pure layout tests: runnable with Swift 6.2 on Linux, without Apple frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/main.swift" <<'SWIFT'
import XCTest
XCTMain([testCase([
    ("nested columns", TmuxLayoutTests.testNestedThreeColumnsKeepPaneOrderAndRows),
    ("vertical rounding", TmuxLayoutTests.testNestedVerticalSplitsAndRounding),
    ("minimum sizes", TmuxLayoutTests.testPerpendicularGroupRetainsMinimumWidth),
    ("too small", TmuxLayoutTests.testTooSmallLayoutIsRejected),
    ("empty split", TmuxLayoutTests.testEmptySplitIsRejected),
    ("checksum and zero ID", TmuxLayoutTests.testSinglePaneChecksumAndZeroID),
])])
SWIFT
swiftc rootshell/Features/Tmux/TmuxLayoutNode.swift \
    rootshellTests/TmuxLayoutTests.swift "$test_dir/main.swift" \
    -o "$test_dir/tmux-layout-tests"
"$test_dir/tmux-layout-tests" | tee "$test_dir/results"
if command -v tmux >/dev/null; then
    layout=$(sed -n "s/^TMUX_LAYOUT_FIXTURE=//p" "$test_dir/results")
    bash scripts/test-tmux-layout-integration.sh "$layout"
fi
