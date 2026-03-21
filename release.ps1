$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

zig build release-all

Set-Location (Join-Path $root "vscode")
if (Test-Path ".\\build.ps1") {
  .\\build.ps1
} else {
  .\\build.sh
}
