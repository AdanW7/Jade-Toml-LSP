#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")"

ROOT_DIR="$(cd .. && pwd)"
BIN_DIR="$PWD/bin"

copy_bin() {
  os="$1"
  arch="$2"
  exe="$3"
  src="$ROOT_DIR/zig-out/bin/$os/$arch/release/$exe"
  dest="$BIN_DIR/$os/$arch"
  if [ ! -f "$src" ]; then
    echo "Missing binary: $src" >&2
    exit 1
  fi
  mkdir -p "$dest"
  cp "$src" "$dest/"
}

copy_bin windows x86_64 jade_toml_lsp.exe
copy_bin windows aarch64 jade_toml_lsp.exe
copy_bin linux x86_64 jade_toml_lsp
copy_bin linux aarch64 jade_toml_lsp
copy_bin macos x86_64 jade_toml_lsp
copy_bin macos aarch64 jade_toml_lsp

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to build the VS Code extension." >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required to build the VS Code extension." >&2
  exit 1
fi

npm install
npm run build
npx --yes @vscode/vsce package
