#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library "$ROOT/Sources/InputMap.swift" "$ROOT/Tests/InputMapTests.swift" -o "$TMP/InputMapTests"
"$TMP/InputMapTests"
