param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliPath,
  [string]$CodexHome,
  [switch]$Reuse,
  [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Parse-DotEnvValue([string]$Value) {
  if ($null -eq $Value) { return $null }
  $v = $Value.Trim()
  if ($v.StartsWith('"') -and $v.EndsWith('"') -and $v.Length -ge 2) {
    return $v.Substring(1, $v.Length - 2) -replace '\"', '"'
  }
  if ($v.StartsWith("'") -and $v.EndsWith("'") -and $v.Length -ge 2) {
    return $v.Substring(1, $v.Length - 2) -replace "''", "'"
  }
  return $v
}

function Read-DotEnv([string]$Path) {
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
    if ($null -eq $line) { continue }
    $t = $line.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t.StartsWith("#")) { continue }
    $idx = $t.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $t.Substring(0, $idx).Trim()
    if ($k.Length -gt 0 -and $k[0] -eq [char]0xFEFF) { $k = $k.TrimStart([char]0xFEFF) }
    $v = $t.Substring($idx + 1)
    if (-not $k) { continue }
    $map[$k] = (Parse-DotEnvValue $v)
  }
  return $map
}

function Set-DotEnvVar([string]$Path, [string]$Key, [string]$Value) {
  $dir = Split-Path $Path -Parent
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $lines = @()
  if (Test-Path $Path) {
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
  }

  $escaped = ($Value -replace '"', '\"')
  $newLine = "$Key=""$escaped"""

  $updated = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $current = $lines[$i]
    if ($null -eq $current) { $current = "" }
    $t = $current.Trim()
    if ($t.StartsWith("#")) { continue }
    if ($t -match ("^\s*" + [regex]::Escape($Key) + "\s*=")) {
      $lines[$i] = $newLine
      $updated = $true
      break
    }
  }

  if (-not $updated) {
    $last = $null
    if ($lines.Count -gt 0) { $last = $lines[$lines.Count - 1] }
    if ($null -eq $last) { $last = "" }
    if ($lines.Count -gt 0 -and $last.Trim().Length -ne 0) {
      $lines += ""
    }
    $lines += $newLine
  }

  # Avoid UTF-8 BOM (it can break simple dotenv key parsing).
  [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
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
    $npmRoot = (& npm root -g 2>$null).Trim()
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

function Patch-AppMainJs([string]$AppDir) {
  $mainJs = Join-Path $AppDir ".vite\\build\\main.js"
  if (-not (Test-Path $mainJs)) { return }

  $text = Get-Content -LiteralPath $mainJs -Raw
  $insertions = @()

  # Implement "open-config-toml" in Electron by opening (and creating if needed) $CODEX_HOME/config.toml.
  if ($text -notmatch "Failed to open config\\.toml") {
    $insertions += ';(()=>{try{const e=Sue?.prototype?.handleMessage;if(typeof e!="function")return;Sue.prototype.handleMessage=async function(t,n){if(n?.type==="open-config-toml"){try{const r=[zn({preferWsl:!0}),zn({preferWsl:!1})].filter(i=>typeof i=="string"&&i.length>0),a=r.map(i=>ae.join(i,"config.toml"));let o=a.find(i=>be.existsSync(i))??a[a.length-1];o&&(be.mkdirSync(ae.dirname(o),{recursive:!0}),be.existsSync(o)||be.writeFileSync(o,"# Codex configuration\n","utf8"),await F.shell.openPath(o))}catch(r){try{Ft().error("Failed to open config.toml",r)}catch{}}return}return e.call(this,t,n)}}catch{}})();'
  }

  # If a persisted host config points at a Windows npm shim (e.g. %APPDATA%\\npm\\codex),
  # patch child_process.spawn to transparently resolve a real codex.exe instead.
  if ($text -notmatch "__codexWindowsPatched") {
    $insertions += ';(()=>{try{if(process.platform!=="win32")return;const e=require("child_process"),t=require("fs"),n=require("path");if(e.spawn&&e.spawn.__codexWindowsPatched)return;const r=e.spawn;function i(){try{const a=process.env.CODEX_CLI_PATH||process.env.CUSTOM_CLI_PATH;if(a&&/\\.exe$/i.test(a)&&t.existsSync(a))return a}catch{}try{const a=process.env.APPDATA;if(a){for(const o of["x86_64-pc-windows-msvc","aarch64-pc-windows-msvc"]){const s=n.join(a,"npm","node_modules","@openai","codex","vendor",o,"codex","codex.exe");if(t.existsSync(s))return s}}}catch{}return null}e.spawn=function(a,o,s){try{if(typeof a=="string"){const c=n.basename(a.toLowerCase());if(c==="codex"||c==="codex.cmd"||c==="codex.ps1"){const u=i();u&&(a=u)}}}catch{}return r.call(this,a,o,s)};e.spawn.__codexWindowsPatched=!0}catch{}})();'
  }

  if ($insertions.Count -eq 0) { return }

  $insertionText = ($insertions -join "`n") + "`n"
  $pattern = "(?m)^//# sourceMappingURL=main\\.js\\.map\\s*$"
  if ($text -match $pattern) {
    $text = [regex]::Replace($text, $pattern, $insertionText + "//# sourceMappingURL=main.js.map", 1)
  } else {
    $text = $text + "`n" + $insertionText
  }

  [System.IO.File]::WriteAllText($mainJs, $text, [System.Text.UTF8Encoding]::new($false))

  # Patch renderer bundle logging so errors don't show up as "[object Object]".
  $assetsDir = Join-Path $AppDir "webview\\assets"
  if (Test-Path $assetsDir) {
    $indexFiles = Get-ChildItem -LiteralPath $assetsDir -Filter "index-*.js" -File -ErrorAction SilentlyContinue
    foreach ($f in $indexFiles) {
      try {
        $rt = Get-Content -LiteralPath $f.FullName -Raw
        $orig = $rt

        # Prefer a more verbose formatter than sanitizeLogValue() for key error logs.
        # sanitizeLogValue intentionally collapses objects to "object(keys=N)", which is still too opaque for debugging.
        $verboseLt = '${(()=>{try{return typeof lt==="string"?lt:lt&&typeof lt==="object"?JSON.stringify(lt,(k,v)=>v instanceof Error?{name:v.name,message:v.message,stack:v.stack}:v):String(lt)}catch(e){try{return String(lt)}catch(e2){return "unserializable"}}})()}'
        $verboseKt = '${(()=>{try{return typeof Kt==="string"?Kt:Kt&&typeof Kt==="object"?JSON.stringify(Kt,(k,v)=>v instanceof Error?{name:v.name,message:v.message,stack:v.stack}:v):String(Kt)}catch(e){try{return String(Kt)}catch(e2){return "unserializable"}}})()}'

        # Update older variants and the intermediate sanitizeLogValue variant.
        $rt = $rt.Replace('Received app server error: ${Ye} ${String(lt)}', ('Received app server error: ${Ye} ' + $verboseLt))
        $rt = $rt.Replace('Received app server error: ${Ye} ${sanitizeLogValue(lt)}', ('Received app server error: ${Ye} ' + $verboseLt))

        $rt = $rt.Replace('[worktree-cleanup] failed to refresh cleanup inputs: ${String(Kt)}', ('[worktree-cleanup] failed to refresh cleanup inputs: ' + $verboseKt))
        $rt = $rt.Replace('[worktree-cleanup] failed to refresh cleanup inputs: ${sanitizeLogValue(Kt)}', ('[worktree-cleanup] failed to refresh cleanup inputs: ' + $verboseKt))

        # A few other common noisy logs.
        $rt = $rt.Replace('[automation-run-cleanup] failed to refresh conversations: ${String(St)}', '[automation-run-cleanup] failed to refresh conversations: ${sanitizeLogValue(St)}')
        $rt = $rt.Replace('[automation-run-cleanup] failed to load more conversations: ${String(St)}', '[automation-run-cleanup] failed to load more conversations: ${sanitizeLogValue(St)}')
        $rt = $rt.Replace('[automation-run-cleanup] failed to archive conversation ${Et}: ${String(Ct)}', '[automation-run-cleanup] failed to archive conversation ${Et}: ${sanitizeLogValue(Ct)}')
        $rt = $rt.Replace('[automation-run-cleanup] failed to mark run archived ${Et}: ${String(Ct)}', '[automation-run-cleanup] failed to mark run archived ${Et}: ${sanitizeLogValue(Ct)}')

        if ($rt -ne $orig) {
          [System.IO.File]::WriteAllText($f.FullName, $rt, [System.Text.UTF8Encoding]::new($false))
        }
      } catch {}
    }
  }
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dotEnvPath = Join-Path $repoRoot ".env"
$dotEnv = Read-DotEnv $dotEnvPath

$dotEnvCodexHome = if ($dotEnv.ContainsKey("CODEX_HOME")) { $dotEnv["CODEX_HOME"] } else { $null }
$envCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($env:CODEX_Home) { $env:CODEX_Home } else { $null }

function Normalize-PathString([string]$Path) {
  if (-not $Path) { return $null }
  $p = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"').Trim("'")
  $p = $p -replace "/", "\"
  try {
    $full = [System.IO.Path]::GetFullPath($p)
    return $full.TrimEnd("\")
  } catch {
    return $p.TrimEnd("\")
  }
}

$defaultCodexHome = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"
$envIsDefaultHome = (Normalize-PathString $envCodexHome) -eq (Normalize-PathString $defaultCodexHome)
$envDiffersFromDotEnv = $dotEnvCodexHome -and ((Normalize-PathString $envCodexHome) -ne (Normalize-PathString $dotEnvCodexHome))

# Treat CODEX_HOME from the environment as an explicit override only when:
# - there is no `.env` yet, OR
# - it differs from `.env` AND it's not the default "~/.codex" value (avoids a system default overriding a chosen profile).
$envCodexHomeExplicit = $false
if ($envCodexHome) {
  if (-not $dotEnvCodexHome) { $envCodexHomeExplicit = $true }
  elseif ($envDiffersFromDotEnv -and -not $envIsDefaultHome) { $envCodexHomeExplicit = $true }
}

# Precedence:
# - `-CodexHome` (always explicit + persist)
# - env CODEX_HOME (if explicit per rules above + persist)
# - `.env` (persisted default)
# - env CODEX_HOME (system/user env fallback)
$desiredCodexHome = if ($CodexHome) { $CodexHome } elseif ($envCodexHomeExplicit) { $envCodexHome } elseif ($dotEnvCodexHome) { $dotEnvCodexHome } elseif ($envCodexHome) { $envCodexHome } else { $null }
if ($desiredCodexHome) {
  Write-Header "Configuring CODEX_HOME"
  $resolvedCodexHome = [Environment]::ExpandEnvironmentVariables($desiredCodexHome)
  New-Item -ItemType Directory -Force -Path $resolvedCodexHome | Out-Null
  $env:CODEX_HOME = (Resolve-Path $resolvedCodexHome).Path

  # Only rewrite `.env` when the user explicitly requests a change.
  if ($CodexHome -or $envCodexHomeExplicit) {
    Set-DotEnvVar $dotEnvPath "CODEX_HOME" $env:CODEX_HOME
  }
  Write-Host "CODEX_HOME=$($env:CODEX_HOME)" -ForegroundColor Cyan
}

Ensure-Command node
Ensure-Command npm
Ensure-Command npx

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
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  $asar = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
  if (-not (Test-Path $asar)) { throw "app.asar not found." }
  & npx --yes @electron/asar extract $asar $appDir

  Write-Header "Syncing app.asar.unpacked"
  $unpacked = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
   if (Test-Path $unpacked) {
     & robocopy $unpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
   }

}

Write-Header "Patching Electron bundle"
Patch-AppMainJs $appDir

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
  & npm init -y | Out-Null
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
  & npm install --no-save @deps
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
