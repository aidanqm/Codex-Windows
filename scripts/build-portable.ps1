param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$DistDir = (Join-Path $PSScriptRoot "..\dist"),
  [string]$CodexCliPath,
  [switch]$Reuse,
  [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$libPath = Join-Path $PSScriptRoot "lib.ps1"
if (-not (Test-Path $libPath)) {
  throw "Missing shared library: $libPath"
}
. $libPath

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedDmg = Resolve-DmgPath -DmgPath $DmgPath -BaseDir $repoRoot

if ($CodexCliPath) {
  $validatedCli = Resolve-CodexCliPath $CodexCliPath
  if (-not $validatedCli) {
    throw "Codex CLI not found: $CodexCliPath"
  }
  Write-Host "Validated Codex CLI at $validatedCli" -ForegroundColor Cyan
}

$ctx = Prepare-CodexApp -DmgPath $resolvedDmg -WorkDir $WorkDir -Reuse:$Reuse
$ctx = Ensure-CodexNativeModules -Context $ctx -NoLaunch
$bundle = New-PortableBundle -Context $ctx -DistDir $DistDir -Zip:$Zip

Write-Host ""
Write-Host "Portable bundle created:" -ForegroundColor Green
Write-Host "  Folder:   $($bundle.PortableDir)"
Write-Host "  EXE:      $($bundle.Executable)"
Write-Host "  LaunchEXE:$($bundle.LauncherExe)"
Write-Host "  Launcher: $($bundle.LauncherCmd)"
if ($Zip) {
  Write-Host "  ZIP:      $($bundle.ZipPath)"
}
