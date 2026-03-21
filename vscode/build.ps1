$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path $root

$binDir = Join-Path $root "bin"
$repoRoot = Resolve-Path (Join-Path $root "..")

function Copy-Bin([string]$os, [string]$arch, [string]$exe) {
  $src = Join-Path $repoRoot ("zig-out/bin/$os/$arch/release/$exe")
  if (!(Test-Path $src)) {
    throw "Missing binary: $src"
  }
  $dest = Join-Path $binDir "$os/$arch"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item -Force $src $dest
}

Copy-Bin "windows" "x86_64" "jade_toml_lsp.exe"
Copy-Bin "windows" "aarch64" "jade_toml_lsp.exe"
Copy-Bin "linux" "x86_64" "jade_toml_lsp"
Copy-Bin "linux" "aarch64" "jade_toml_lsp"
Copy-Bin "macos" "x86_64" "jade_toml_lsp"
Copy-Bin "macos" "aarch64" "jade_toml_lsp"

npm install
npm run build
npx --yes @vscode/vsce package
