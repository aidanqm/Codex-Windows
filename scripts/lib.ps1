function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
}

function Write-Header([string]$Text) {
  Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Copy-Directory([string]$Source, [string]$Destination) {
  if (-not (Test-Path $Source)) {
    throw "Source directory not found: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed from $Source to $Destination (exit code: $LASTEXITCODE)."
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
  try {
    $html = (Invoke-WebRequest -Uri $home -UseBasicParsing).Content
  } catch {
    return $null
  }

  $extra = [regex]::Match($html, 'href="a/(7z[0-9]+-extra\.7z)"').Groups[1].Value
  if (-not $extra) { return $null }

  $extraUrl = "https://www.7-zip.org/a/$extra"
  $sevenRUrl = "https://www.7-zip.org/a/7zr.exe"
  $sevenR = Join-Path $tools "7zr.exe"
  $extraPath = Join-Path $tools $extra

  if (-not (Test-Path $sevenR)) {
    Invoke-WebRequest -Uri $sevenRUrl -OutFile $sevenR
  }
  if (-not (Test-Path $extraPath)) {
    Invoke-WebRequest -Uri $extraUrl -OutFile $extraPath
  }

  & $sevenR x -y $extraPath -o"$sevenZipDir" | Out-Null
  $p3 = Join-Path $sevenZipDir "7z.exe"
  if (Test-Path $p3) { return $p3 }
  return $null
}

function Resolve-CodexCliPath([string]$Explicit) {
  function Resolve-CodexExeFromVendor([string]$VendorRoot) {
    if (-not $VendorRoot -or -not (Test-Path $VendorRoot)) { return $null }

    $preferredArches = @("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc")
    try {
      $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
      if ($osArch -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        $preferredArches = @("aarch64-pc-windows-msvc", "x86_64-pc-windows-msvc")
      }
    } catch {}

    foreach ($archName in $preferredArches) {
      $candidate = Join-Path $VendorRoot "$archName\codex\codex.exe"
      if (Test-Path $candidate) {
        return (Resolve-Path $candidate).Path
      }
    }

    $fallback = Get-ChildItem -Recurse -Filter "codex.exe" $VendorRoot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) { return (Resolve-Path $fallback.FullName).Path }
    return $null
  }

  function Resolve-CodexCliCandidate([string]$RawCandidate) {
    if (-not $RawCandidate) { return $null }
    $candidate = $RawCandidate.Trim()
    if (-not (Test-Path $candidate)) { return $null }

    $resolvedCandidate = (Resolve-Path $candidate).Path
    $candidateDir = Split-Path $resolvedCandidate -Parent
    $candidateName = [System.IO.Path]::GetFileName($resolvedCandidate)
    if (@("Codex.exe", "launch.exe", "launch.cmd", "launch.ps1") -contains $candidateName -and (Test-Path (Join-Path $candidateDir "resources\app"))) {
      return $null
    }

    $extension = [System.IO.Path]::GetExtension($resolvedCandidate).ToLowerInvariant()
    if ($extension -eq ".exe") {
      return $resolvedCandidate
    }

    if ($extension -eq ".cmd" -or $extension -eq ".bat" -or $extension -eq "") {
      try {
        $shimDir = Split-Path $resolvedCandidate -Parent
        $vendor = Join-Path $shimDir "node_modules\@openai\codex\vendor"
        $resolvedFromVendor = Resolve-CodexExeFromVendor $vendor
        if ($resolvedFromVendor) { return $resolvedFromVendor }
      } catch {}
    }

    return $null
  }

  if ($Explicit) {
    $resolvedExplicit = Resolve-CodexCliCandidate $Explicit
    if ($resolvedExplicit) { return $resolvedExplicit }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride) {
    $resolvedOverride = Resolve-CodexCliCandidate $envOverride
    if ($resolvedOverride) { return $resolvedOverride }
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
      $vendor = Join-Path $npmRoot "@openai\codex\vendor"
      $preferredFromVendor = Resolve-CodexExeFromVendor $vendor
      if ($preferredFromVendor) { $candidates += $preferredFromVendor }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($candidate in $candidates) {
    $resolvedCandidate = Resolve-CodexCliCandidate $candidate
    if ($resolvedCandidate) { return $resolvedCandidate }
  }

  return $null
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

function Initialize-NodeTooling() {
  Ensure-Command node
  Ensure-Command npm
  Ensure-Command npx

  foreach ($k in @(
      "npm_config_runtime",
      "npm_config_target",
      "npm_config_disturl",
      "npm_config_arch",
      "npm_config_build_from_source"
    )) {
    if (Test-Path "Env:$k") {
      Remove-Item "Env:$k" -ErrorAction SilentlyContinue
    }
  }
}

function Resolve-DmgPath([string]$DmgPath, [string]$BaseDir) {
  if ($DmgPath) {
    if (-not (Test-Path $DmgPath)) {
      throw "DMG not found: $DmgPath"
    }
    return (Resolve-Path $DmgPath).Path
  }

  $default = Join-Path $BaseDir "Codex.dmg"
  if (Test-Path $default) {
    return (Resolve-Path $default).Path
  }

  $candidate = Get-ChildItem -Path $BaseDir -Filter "*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($candidate) {
    return $candidate.FullName
  }

  throw "No DMG found."
}

function New-WorkLayout([string]$WorkDir) {
  $resolvedWorkDir = (Resolve-Path (New-Item -ItemType Directory -Force -Path $WorkDir)).Path
  return @{
    WorkDir = $resolvedWorkDir
    ExtractedDir = Join-Path $resolvedWorkDir "extracted"
    ElectronDir = Join-Path $resolvedWorkDir "electron"
    AppDir = Join-Path $resolvedWorkDir "app"
    NativeDir = Join-Path $resolvedWorkDir "native-builds"
    UserDataDir = Join-Path $resolvedWorkDir "userdata"
    CacheDir = Join-Path $resolvedWorkDir "cache"
  }
}

function Prepare-CodexApp([string]$DmgPath, [string]$WorkDir, [switch]$Reuse) {
  Initialize-NodeTooling

  $resolvedDmg = (Resolve-Path $DmgPath).Path
  $layout = New-WorkLayout $WorkDir
  $sevenZip = Resolve-7z $layout.WorkDir
  if (-not $sevenZip) { throw "7z not found." }

  if (-not $Reuse) {
    Write-Header "Extracting DMG"
    New-Item -ItemType Directory -Force -Path $layout.ExtractedDir | Out-Null
    & $sevenZip x -y $resolvedDmg -o"$($layout.ExtractedDir)" | Out-Null

    Write-Header "Extracting app.asar"
    New-Item -ItemType Directory -Force -Path $layout.ElectronDir | Out-Null
    $hfs = Join-Path $layout.ExtractedDir "4.hfs"
    if (Test-Path $hfs) {
      & $sevenZip x -y $hfs "Codex Installer/Codex.app/Contents/Resources/app.asar" "Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked" -o"$($layout.ElectronDir)" | Out-Null
    } else {
      $directApp = Join-Path $layout.ExtractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
      if (-not (Test-Path $directApp)) {
        throw "app.asar not found."
      }
      $directUnpacked = Join-Path $layout.ExtractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
      $destBase = Join-Path $layout.ElectronDir "Codex Installer\Codex.app\Contents\Resources"
      New-Item -ItemType Directory -Force -Path $destBase | Out-Null
      Copy-Item -Force $directApp (Join-Path $destBase "app.asar")
      if (Test-Path $directUnpacked) {
        Copy-Directory -Source $directUnpacked -Destination (Join-Path $destBase "app.asar.unpacked")
      }
    }

    Write-Header "Unpacking app.asar"
    New-Item -ItemType Directory -Force -Path $layout.AppDir | Out-Null
    $asar = Join-Path $layout.ElectronDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
    if (-not (Test-Path $asar)) { throw "app.asar not found." }
    & npx --yes @electron/asar extract $asar $layout.AppDir

    Write-Header "Syncing app.asar.unpacked"
    $unpacked = Join-Path $layout.ElectronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
    if (Test-Path $unpacked) {
      Copy-Directory -Source $unpacked -Destination $layout.AppDir
    }
  }

  if (-not (Test-Path $layout.AppDir)) {
    throw "App directory not found at $($layout.AppDir). Try running without -Reuse."
  }

  Write-Header "Patching preload"
  Patch-Preload $layout.AppDir

  Write-Header "Reading app metadata"
  $pkgPath = Join-Path $layout.AppDir "package.json"
  if (-not (Test-Path $pkgPath)) { throw "package.json not found." }

  $pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
  $electronVersion = $pkg.devDependencies.electron
  $betterVersion = $pkg.dependencies."better-sqlite3"
  $ptyVersion = $pkg.dependencies."node-pty"
  if (-not $electronVersion) { throw "Electron version not found." }

  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }

  return @{
    DmgPath = $resolvedDmg
    WorkDir = $layout.WorkDir
    Reuse = [bool]$Reuse
    SevenZip = $sevenZip
    ExtractedDir = $layout.ExtractedDir
    ElectronDir = $layout.ElectronDir
    AppDir = $layout.AppDir
    NativeDir = $layout.NativeDir
    UserDataDir = $layout.UserDataDir
    CacheDir = $layout.CacheDir
    PackagePath = $pkgPath
    Package = $pkg
    ElectronVersion = $electronVersion
    BetterVersion = $betterVersion
    PtyVersion = $ptyVersion
    Arch = $arch
    ElectronExe = (Join-Path $layout.NativeDir "node_modules\electron\dist\electron.exe")
  }
}

function Ensure-CodexNativeModules([hashtable]$Context, [switch]$NoLaunch) {
  Write-Header "Preparing native modules"

  $appDir = $Context.AppDir
  $nativeDir = $Context.NativeDir
  $arch = $Context.Arch
  $electronVersion = $Context.ElectronVersion
  $betterVersion = $Context.BetterVersion
  $ptyVersion = $Context.PtyVersion

  $bsDst = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"
  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"

  $skipNative = $NoLaunch -and $Context.Reuse -and (Test-Path $bsDst) -and (Test-Path (Join-Path $ptyDstPre "pty.node")) -and (Test-Path $electronExe)
  if ($skipNative) {
    Write-Host "Native modules already present in app. Skipping rebuild." -ForegroundColor Cyan
    $Context.ElectronExe = $electronExe
    return $Context
  }

  New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
  Push-Location $nativeDir
  try {
    if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
      & npm init -y | Out-Null
    }

    $bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
    $ptySrcProbe = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch\pty.node"
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
        try {
          $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
          if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
          & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v | Out-Null
        } finally {
          Pop-Location
        }
      }
    }

    $env:ELECTRON_RUN_AS_NODE = "1"
    try {
      if (-not (Test-Path $electronExe)) { throw "electron.exe not found." }
      if (-not (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3"))) {
        throw "better-sqlite3 not installed."
      }
      & $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "better-sqlite3 failed to load." }
    } finally {
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
  } finally {
    Pop-Location
  }

  $bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  if (-not (Test-Path $bsSrc)) { throw "better_sqlite3.node not found." }
  $bsDstDir = Split-Path $bsDst -Parent
  New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
  Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")

  $ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
  $ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
  New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
  New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null
  foreach ($f in @("pty.node", "conpty.node", "conpty_console_list.node")) {
    $src = Join-Path $ptySrcDir $f
    if (Test-Path $src) {
      Copy-Item -Force $src (Join-Path $ptyDstPre $f)
      Copy-Item -Force $src (Join-Path $ptyDstRel $f)
    }
  }

  $Context.ElectronExe = $electronExe
  return $Context
}

function Set-CodexRuntimeEnvironment([string]$AppDir, [object]$Package, [string]$CodexCliPath) {
  $rendererUrl = (New-Object System.Uri (Join-Path $AppDir "webview\index.html")).AbsoluteUri
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_RENDERER_URL = $rendererUrl
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"

  $buildNumber = if ($Package.PSObject.Properties.Name -contains "codexBuildNumber" -and $Package.codexBuildNumber) { $Package.codexBuildNumber } else { "510" }
  $buildFlavor = if ($Package.PSObject.Properties.Name -contains "codexBuildFlavor" -and $Package.codexBuildFlavor) { $Package.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $CodexCliPath
  $env:PWD = $AppDir
  Ensure-GitOnPath
}

function Start-CodexApplication([string]$ElectronExe, [string]$AppDir, [string]$UserDataDir, [string]$CacheDir) {
  if (-not (Test-Path $ElectronExe)) { throw "electron.exe not found." }
  New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  Start-Process -FilePath $ElectronExe -ArgumentList "$AppDir", "--enable-logging", "--user-data-dir=`"$UserDataDir`"", "--disk-cache-dir=`"$CacheDir`"" -NoNewWindow -Wait
}

function Write-PortableLauncherExecutable([string]$OutputDir, [string]$ExecutableName = "launch.exe") {
  $launcherExePath = Join-Path $OutputDir $ExecutableName
  if (Test-Path $launcherExePath) {
    Remove-Item -Force $launcherExePath
  }

  $launcherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace CodexPortableLauncher {
  internal static class Program {
    [STAThread]
    private static int Main(string[] args) {
      try {
        string artifactRoot = AppDomain.CurrentDomain.BaseDirectory;
        string launchScript = Path.Combine(artifactRoot, "launch.ps1");
        if (!File.Exists(launchScript)) {
          MessageBox.Show("launch.ps1 not found next to launcher executable.", "Codex Portable Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
          return 1;
        }

        string powershellExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershellExe)) {
          powershellExe = "powershell.exe";
        }

        var commandLine = new StringBuilder();
        commandLine.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        commandLine.Append(QuoteArgument(launchScript));
        foreach (string argument in args) {
          commandLine.Append(' ');
          commandLine.Append(QuoteArgument(argument));
        }

        var startInfo = new ProcessStartInfo {
          FileName = powershellExe,
          Arguments = commandLine.ToString(),
          WorkingDirectory = artifactRoot,
          UseShellExecute = false,
          CreateNoWindow = true
        };

        using (Process process = Process.Start(startInfo)) {
          if (process == null) {
            MessageBox.Show("Failed to start powershell.exe.", "Codex Portable Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
          }

          process.WaitForExit();
          return process.ExitCode;
        }
      } catch (Exception exception) {
        MessageBox.Show(exception.Message, "Codex Portable Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return 1;
      }
    }

    private static string QuoteArgument(string value) {
      if (string.IsNullOrEmpty(value)) {
        return "\"\"";
      }

      bool needsQuotes = value.IndexOfAny(new[] { ' ', '\t', '\n', '"' }) >= 0;
      if (!needsQuotes) {
        return value;
      }

      var builder = new StringBuilder();
      builder.Append('"');
      int backslashCount = 0;
      foreach (char character in value) {
        if (character == '\\') {
          backslashCount++;
          continue;
        }

        if (character == '"') {
          builder.Append('\\', backslashCount * 2 + 1);
          builder.Append('"');
          backslashCount = 0;
          continue;
        }

        if (backslashCount > 0) {
          builder.Append('\\', backslashCount);
          backslashCount = 0;
        }
        builder.Append(character);
      }

      if (backslashCount > 0) {
        builder.Append('\\', backslashCount * 2);
      }

      builder.Append('"');
      return builder.ToString();
    }
  }
}
'@

  $compiler = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  if (-not (Test-Path $compiler)) {
    $compiler = "powershell.exe"
  }
  $launcherSourcePath = Join-Path $OutputDir "__launcher_source.cs"
  $compileScriptPath = Join-Path $OutputDir "__compile_launcher.ps1"

  try {
    Set-Content -Path $launcherSourcePath -Value $launcherSource -Encoding UTF8

    $compileScript = @'
param(
  [string]$SourcePath,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceCode = Get-Content -Raw -Path $SourcePath
Add-Type -TypeDefinition $sourceCode -Language CSharp -ReferencedAssemblies @("System.dll", "System.Windows.Forms.dll") -OutputAssembly $OutputPath -OutputType WindowsApplication | Out-Null
'@
    Set-Content -Path $compileScriptPath -Value $compileScript -Encoding UTF8
    & $compiler -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $compileScriptPath -SourcePath $launcherSourcePath -OutputPath $launcherExePath

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $launcherExePath)) {
      throw "launcher compilation process failed."
    }
  } catch {
    throw "Failed to compile ${ExecutableName}: $($_.Exception.Message)"
  } finally {
    Remove-Item -Force $compileScriptPath -ErrorAction SilentlyContinue
    Remove-Item -Force $launcherSourcePath -ErrorAction SilentlyContinue
  }
}

function Write-PortableLaunchScripts([string]$OutputDir) {
  $launchPs1 = @'
param(
  [string]$CodexCliPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-CodexCliPath([string]$Explicit) {
  function Resolve-CodexExeFromVendor([string]$VendorRoot) {
    if (-not $VendorRoot -or -not (Test-Path $VendorRoot)) { return $null }

    $preferredArches = @("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc")
    try {
      $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
      if ($osArch -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        $preferredArches = @("aarch64-pc-windows-msvc", "x86_64-pc-windows-msvc")
      }
    } catch {}

    foreach ($archName in $preferredArches) {
      $candidate = Join-Path $VendorRoot "$archName\codex\codex.exe"
      if (Test-Path $candidate) {
        return (Resolve-Path $candidate).Path
      }
    }

    $fallback = Get-ChildItem -Recurse -Filter "codex.exe" $VendorRoot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) { return (Resolve-Path $fallback.FullName).Path }
    return $null
  }

  function Resolve-CodexCliCandidate([string]$RawCandidate) {
    if (-not $RawCandidate) { return $null }
    $candidate = $RawCandidate.Trim()
    if (-not (Test-Path $candidate)) { return $null }

    $resolvedCandidate = (Resolve-Path $candidate).Path
    $candidateDir = Split-Path $resolvedCandidate -Parent
    $candidateName = [System.IO.Path]::GetFileName($resolvedCandidate)
    if (@("Codex.exe", "launch.exe", "launch.cmd", "launch.ps1") -contains $candidateName -and (Test-Path (Join-Path $candidateDir "resources\app"))) {
      return $null
    }

    $extension = [System.IO.Path]::GetExtension($resolvedCandidate).ToLowerInvariant()
    if ($extension -eq ".exe") {
      return $resolvedCandidate
    }

    if ($extension -eq ".cmd" -or $extension -eq ".bat" -or $extension -eq "") {
      try {
        $shimDir = Split-Path $resolvedCandidate -Parent
        $vendor = Join-Path $shimDir "node_modules\@openai\codex\vendor"
        $resolvedFromVendor = Resolve-CodexExeFromVendor $vendor
        if ($resolvedFromVendor) { return $resolvedFromVendor }
      } catch {}
    }

    return $null
  }

  if ($Explicit) {
    $resolvedExplicit = Resolve-CodexCliCandidate $Explicit
    if ($resolvedExplicit) { return $resolvedExplicit }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride) {
    $resolvedOverride = Resolve-CodexCliCandidate $envOverride
    if ($resolvedOverride) { return $resolvedOverride }
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
      $vendor = Join-Path $npmRoot "@openai\codex\vendor"
      $preferredFromVendor = Resolve-CodexExeFromVendor $vendor
      if ($preferredFromVendor) { $candidates += $preferredFromVendor }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($candidate in $candidates) {
    $resolvedCandidate = Resolve-CodexCliCandidate $candidate
    if ($resolvedCandidate) { return $resolvedCandidate }
  }

  return $null
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

$artifactRoot = (Resolve-Path $PSScriptRoot).Path
$runtimeExe = Join-Path $artifactRoot "Codex-runtime.exe"
$exePath = if (Test-Path $runtimeExe) { $runtimeExe } else { Join-Path $artifactRoot "electron.exe" }
$appDir = Join-Path $artifactRoot "resources\app"

if (-not (Test-Path $exePath)) { throw "Electron runtime not found (expected electron.exe)." }
if (-not (Test-Path $appDir)) { throw "App resources not found." }

$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path $pkgPath)) { throw "package.json not found." }
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json

$cli = Resolve-CodexCliPath $CodexCliPath
if (-not $cli) {
  throw "codex.exe not found. Install with: npm i -g @openai/codex"
}

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

$userDataDir = Join-Path $artifactRoot "userdata"
$cacheDir = Join-Path $artifactRoot "cache"
New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

Start-Process -FilePath $exePath -ArgumentList "$appDir", "--enable-logging", "--user-data-dir=`"$userDataDir`"", "--disk-cache-dir=`"$cacheDir`"" -WorkingDirectory $artifactRoot | Out-Null
'@

  $launchCmd = @'
@echo off
setlocal
if exist "%~dp0launch.exe" (
  "%~dp0launch.exe" %*
  exit /b %errorlevel%
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
'@

  Set-Content -Path (Join-Path $OutputDir "launch.ps1") -Value $launchPs1 -Encoding UTF8
  Set-Content -Path (Join-Path $OutputDir "launch.cmd") -Value $launchCmd -Encoding ASCII
  Write-PortableLauncherExecutable -OutputDir $OutputDir -ExecutableName "launch.exe"
  Copy-Item -Force (Join-Path $OutputDir "launch.exe") (Join-Path $OutputDir "Codex.exe")
}

function New-PortableBundle([hashtable]$Context, [string]$DistDir, [switch]$Zip) {
  $resolvedDist = (Resolve-Path (New-Item -ItemType Directory -Force -Path $DistDir)).Path
  $portableDir = Join-Path $resolvedDist "Codex-portable"
  $appTarget = Join-Path $portableDir "resources\app"

  if (Test-Path $portableDir) {
    Remove-Item -Recurse -Force $portableDir
  }

  Write-Header "Staging portable output"
  New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $portableDir "resources") | Out-Null

  $electronExe = $Context.ElectronExe
  if (-not (Test-Path $electronExe)) {
    throw "electron.exe not found at $electronExe"
  }
  $runtimeDir = Split-Path $electronExe -Parent
  Copy-Directory -Source $runtimeDir -Destination $portableDir

  $sourceElectronExe = Join-Path $portableDir "electron.exe"
  $codexExe = Join-Path $portableDir "Codex.exe"
  if (-not (Test-Path $sourceElectronExe)) {
    throw "electron.exe missing from staged runtime."
  }

  Copy-Directory -Source $Context.AppDir -Destination $appTarget
  Write-PortableLaunchScripts -OutputDir $portableDir

  if ($Zip) {
    Write-Header "Creating ZIP artifact"
    $zipPath = Join-Path $resolvedDist "Codex-portable.zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path $portableDir -DestinationPath $zipPath -Force
  }

  return @{
    DistDir = $resolvedDist
    PortableDir = $portableDir
    Executable = $codexExe
    LauncherExe = (Join-Path $portableDir "launch.exe")
    LauncherCmd = (Join-Path $portableDir "launch.cmd")
    LauncherPs1 = (Join-Path $portableDir "launch.ps1")
    ZipPath = (Join-Path $resolvedDist "Codex-portable.zip")
  }
}
