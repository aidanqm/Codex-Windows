param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliPath,
  [switch]$Reuse,
  [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
}

function Resolve-CommandPath([string[]]$Names) {
  foreach ($name in $Names) {
    if (-not $name) { continue }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
  }
  return $null
}

function Resolve-7z([string]$BaseDir) {
  $cmd = Get-Command 7z -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Path }
  $p1 = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
  $p2 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
  if (Test-Path $p1) { return $p1 }
  if (Test-Path $p2) { return $p2 }
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if ($wg) {
    & winget install --id 7zip.7zip -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
    if (Test-Path $p1) { return $p1 }
    if (Test-Path $p2) { return $p2 }
  }
  if (-not $BaseDir) { return $null }
  $tools = Join-Path $BaseDir "tools"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $sevenZipDir = Join-Path $tools "7zip"
  New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
  $home = "https://www.7-zip.org/"
  try { $html = (Invoke-WebRequest -Uri $home -UseBasicParsing).Content } catch { return $null }
  $extra = [regex]::Match($html, 'href="a/(7z[0-9]+-extra\.7z)"').Groups[1].Value
  if (-not $extra) { return $null }
  $extraUrl = "https://www.7-zip.org/a/$extra"
  $sevenRUrl = "https://www.7-zip.org/a/7zr.exe"
  $sevenR = Join-Path $tools "7zr.exe"
  $extraPath = Join-Path $tools $extra
  if (-not (Test-Path $sevenR)) { Invoke-WebRequest -Uri $sevenRUrl -OutFile $sevenR }
  if (-not (Test-Path $extraPath)) { Invoke-WebRequest -Uri $extraUrl -OutFile $extraPath }
  & $sevenR x -y $extraPath -o"$sevenZipDir" | Out-Null
  $p3 = Join-Path $sevenZipDir "7z.exe"
  if (Test-Path $p3) { return $p3 }
  return $null
}

function Resolve-CodexCliPath([string]$Explicit) {
  if ($Explicit) {
    if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride -and (Test-Path $envOverride)) {
    return (Resolve-Path $envOverride).Path
  }

  $candidates = @()

  try {
    $whereExe = & where.exe codex.exe 2>$null
    if ($whereExe) { $candidates += $whereExe }
    $whereCmd = & where.exe codex 2>$null
    if ($whereCmd) { $candidates += $whereCmd }
  } catch {}

  try {
    $npmCmd = Resolve-CommandPath @("npm.cmd", "npm")
    $npmRoot = if ($npmCmd) { (& $npmCmd root -g 2>$null).Trim() } else { $null }
    if ($npmRoot) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\$arch\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($c in $candidates) {
    if (-not $c) { continue }
    if ($c -match '\.cmd$' -and (Test-Path $c)) {
      try {
        $cmdDir = Split-Path $c -Parent
        $vendor = Join-Path $cmdDir "node_modules\@openai\codex\vendor"
        if (Test-Path $vendor) {
          $found = Get-ChildItem -Recurse -Filter "codex.exe" $vendor -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($found) { return (Resolve-Path $found.FullName).Path }
        }
      } catch {}
    }
    if (Test-Path $c) {
      return (Resolve-Path $c).Path
    }
  }

  return $null
}

function Write-Header([string]$Text) {
  Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Patch-Preload([string]$AppDir) {
  $preload = Join-Path $AppDir ".vite\build\preload.js"
  if (-not (Test-Path $preload)) { return }
  $raw = Get-Content -Raw $preload
  $processExpose = 'const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld("process",P);'
  if ($raw -notlike "*$processExpose*") {
    $re = 'n\.contextBridge\.exposeInMainWorld\("codexWindowType",[A-Za-z0-9_$]+\);n\.contextBridge\.exposeInMainWorld\("electronBridge",[A-Za-z0-9_$]+\);'
    $m = [regex]::Match($raw, $re)
    if (-not $m.Success) { throw "preload patch point not found." }
    $raw = $raw.Replace($m.Value, "$processExpose$m")
    Set-Content -NoNewline -Path $preload -Value $raw
  }
}


function Ensure-GitOnPath() {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\bin\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin\git.exe")
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates -or $candidates.Count -eq 0) { return }
  $gitDir = Split-Path $candidates[0] -Parent
  if ($env:PATH -notlike "*$gitDir*") {
    $env:PATH = "$gitDir;$env:PATH"
  }
}

Ensure-Command node
$script:NpmCmd = Resolve-CommandPath @("npm.cmd", "npm")
if (-not $script:NpmCmd) { throw "npm not found." }
$script:NpxCmd = Resolve-CommandPath @("npx.cmd", "npx")

foreach ($k in @("npm_config_runtime","npm_config_target","npm_config_disturl","npm_config_arch","npm_config_build_from_source")) {
  if (Test-Path "Env:$k") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

if (-not $DmgPath) {
  $default = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "Codex.dmg"
  if (Test-Path $default) {
    $DmgPath = $default
  } else {
    $cand = Get-ChildItem -Path (Resolve-Path (Join-Path $PSScriptRoot "..")) -Filter "*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) {
      $DmgPath = $cand.FullName
    } else {
      throw "No DMG found."
    }
  }
}

$DmgPath = (Resolve-Path $DmgPath).Path
$WorkDir = (Resolve-Path (New-Item -ItemType Directory -Force -Path $WorkDir)).Path

$sevenZip = Resolve-7z $WorkDir
if (-not $sevenZip) { throw "7z not found." }

$extractedDir = Join-Path $WorkDir "extracted"
$electronDir  = Join-Path $WorkDir "electron"
$appDir       = Join-Path $WorkDir "app"
$nativeDir    = Join-Path $WorkDir "native-builds"
$userDataDir  = Join-Path $WorkDir "userdata"
$cacheDir     = Join-Path $WorkDir "cache"

if (-not $Reuse) {
  Write-Header "Extracting DMG"
  New-Item -ItemType Directory -Force -Path $extractedDir | Out-Null
  & $sevenZip x -y $DmgPath -o"$extractedDir" | Out-Null

  Write-Header "Extracting app.asar"
  New-Item -ItemType Directory -Force -Path $electronDir | Out-Null
  $hfs = Join-Path $extractedDir "4.hfs"
  if (Test-Path $hfs) {
    & $sevenZip x -y $hfs "Codex Installer/Codex.app/Contents/Resources/app.asar" "Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked" -o"$electronDir" | Out-Null
  } else {
    $directApp = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
    if (-not (Test-Path $directApp)) {
      throw "app.asar not found."
    }
    $directUnpacked = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
    New-Item -ItemType Directory -Force -Path (Split-Path $directApp -Parent) | Out-Null
    $destBase = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources"
    New-Item -ItemType Directory -Force -Path $destBase | Out-Null
    Copy-Item -Force $directApp (Join-Path $destBase "app.asar")
    if (Test-Path $directUnpacked) {
      & robocopy $directUnpacked (Join-Path $destBase "app.asar.unpacked") /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }
  }

  Write-Header "Unpacking app.asar"
  if (Test-Path $appDir) {
    Remove-Item -Recurse -Force $appDir
  }
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  $asar = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
  if (-not (Test-Path $asar)) { throw "app.asar not found." }
  $extracted = $false
  if ($script:NpxCmd) {
    & $script:NpxCmd --yes @electron/asar extract $asar $appDir
    if ($LASTEXITCODE -eq 0) {
      $extracted = $true
    } else {
      Write-Host "npx extract failed; falling back to npm exec." -ForegroundColor Yellow
    }
  }
  if (-not $extracted) {
    & $script:NpmCmd exec --yes --package=@electron/asar -- asar extract $asar $appDir
    if ($LASTEXITCODE -ne 0) { throw "app.asar extraction failed." }
  }

  Write-Header "Syncing app.asar.unpacked"
  $unpacked = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
  if (Test-Path $unpacked) {
    & robocopy $unpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }
}

Write-Header "Patching preload"
Patch-Preload $appDir

Write-Header "Reading app metadata"
$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path $pkgPath)) { throw "package.json not found." }
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
$electronVersion = $pkg.devDependencies.electron
$betterVersion = $pkg.dependencies."better-sqlite3"
$ptyVersion = $pkg.dependencies."node-pty"

if (-not $electronVersion) { throw "Electron version not found." }

Write-Header "Preparing native modules"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$bsDst = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"
$skipNative = $NoLaunch -and $Reuse -and (Test-Path $bsDst) -and (Test-Path (Join-Path $ptyDstPre "pty.node"))
if ($skipNative) {
  Write-Host "Native modules already present in app. Skipping rebuild." -ForegroundColor Cyan
} else {
New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
Push-Location $nativeDir
if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
  & $script:NpmCmd init -y | Out-Null
}

$bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptySrcProbe = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch\pty.node"
$electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
$haveNative = (Test-Path $bsSrcProbe) -and (Test-Path $ptySrcProbe) -and (Test-Path $electronExe)

if (-not $haveNative) {
  $deps = @(
    "better-sqlite3@$betterVersion",
    "node-pty@$ptyVersion",
    "@electron/rebuild",
    "prebuild-install",
    "electron@$electronVersion"
  )
  & $script:NpmCmd install --no-save @deps
  if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
} else {
  Write-Host "Native modules already present. Skipping rebuild." -ForegroundColor Cyan
}

Write-Host "Rebuilding native modules for Electron $electronVersion..." -ForegroundColor Cyan
$rebuildOk = $true
if (-not $haveNative) {
  try {
    $rebuildCli = Join-Path $nativeDir "node_modules\@electron\rebuild\lib\cli.js"
    if (-not (Test-Path $rebuildCli)) { throw "electron-rebuild not found." }
    & node $rebuildCli -v $electronVersion -w "better-sqlite3,node-pty" | Out-Null
  } catch {
    $rebuildOk = $false
    Write-Host "electron-rebuild failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

if (-not $rebuildOk -and -not $haveNative) {
  Write-Host "Trying prebuilt Electron binaries for better-sqlite3..." -ForegroundColor Yellow
  $bsDir = Join-Path $nativeDir "node_modules\better-sqlite3"
  if (Test-Path $bsDir) {
    Push-Location $bsDir
    $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
    if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
    & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v | Out-Null
    Pop-Location
  }
}

$env:ELECTRON_RUN_AS_NODE = "1"
if (-not (Test-Path $electronExe)) { throw "electron.exe not found." }
if (-not (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3"))) {
  throw "better-sqlite3 not installed."
}
& $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "better-sqlite3 failed to load." }

Pop-Location

$bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$bsDstDir = Split-Path $bsDst -Parent
New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
if (-not (Test-Path $bsSrc)) { throw "better_sqlite3.node not found." }
Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")

$ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
$ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null

$ptyFiles = @("pty.node", "conpty.node", "conpty_console_list.node")
foreach ($f in $ptyFiles) {
  $src = Join-Path $ptySrcDir $f
  if (Test-Path $src) {
    Copy-Item -Force $src (Join-Path $ptyDstPre $f)
    Copy-Item -Force $src (Join-Path $ptyDstRel $f)
  }
}
}

if (-not $NoLaunch) {
  Write-Header "Resolving Codex CLI"
  $cli = Resolve-CodexCliPath $CodexCliPath
  if (-not $cli) {
    throw "codex.exe not found."
  }

  Write-Header "Launching Codex"
  $rendererUrl = (New-Object System.Uri (Join-Path $appDir "webview\index.html")).AbsoluteUri
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_RENDERER_URL = $rendererUrl
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $buildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $buildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $cli
  $env:PWD = $appDir
  Ensure-GitOnPath

  New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

  Start-Process -FilePath $electronExe -ArgumentList "$appDir","--enable-logging","--user-data-dir=`"$userDataDir`"","--disk-cache-dir=`"$cacheDir`"" -NoNewWindow -Wait
}
