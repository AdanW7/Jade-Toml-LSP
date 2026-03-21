#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT_DIR"
zig build release-all

cd "$ROOT_DIR/vscode"
./build.sh
