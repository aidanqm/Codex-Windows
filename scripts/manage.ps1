param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "workspaces.json"),
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($SelfTest) {
  Write-Output "ok"
  exit 0
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runScript = Join-Path $PSScriptRoot "run.ps1"
$defaultDmg = Join-Path $repoRoot "Codex.dmg"
$codexGlobalStatePath = Join-Path $env:USERPROFILE ".codex\.codex-global-state.json"

$themeBg = [System.Drawing.Color]::FromArgb(18, 22, 30)
$themePanel = [System.Drawing.Color]::FromArgb(28, 33, 44)
$themeInput = [System.Drawing.Color]::FromArgb(36, 42, 56)
$themeAccent = [System.Drawing.Color]::FromArgb(88, 166, 255)
$themeAccentAlt = [System.Drawing.Color]::FromArgb(60, 130, 210)
$themeText = [System.Drawing.Color]::FromArgb(230, 236, 245)
$themeSubtle = [System.Drawing.Color]::FromArgb(174, 188, 208)
$themeDanger = [System.Drawing.Color]::FromArgb(196, 76, 76)

function Get-DefaultWorkspaces {
  @(
    "C:\Users\$env:USERNAME\source\repos\Drop tool",
    "C:\Users\$env:USERNAME\source\repos\Shiaya Grade Tool"
  )
}

function Get-RealWorkspaceRoots {
  $roots = @()
  if (Test-Path $codexGlobalStatePath) {
    try {
      $state = Get-Content -Raw $codexGlobalStatePath | ConvertFrom-Json
      if ($state."active-workspace-roots") {
        $roots += @($state."active-workspace-roots")
      }
      if ($state."electron-saved-workspace-roots") {
        $roots += @($state."electron-saved-workspace-roots")
      }
    } catch {}
  }
  return @($roots | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)
}

function Load-Workspaces {
  $all = @()
  $all += Get-RealWorkspaceRoots
  if (Test-Path $ConfigPath) {
    try {
      $raw = Get-Content -Raw $ConfigPath | ConvertFrom-Json
      if ($raw -and $raw.workspaces) {
        $all += @($raw.workspaces)
      }
    } catch {}
  }
  $all += Get-DefaultWorkspaces
  return @($all | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)
}

function Save-Workspaces([string[]]$items) {
  $payload = @{ workspaces = @($items | Select-Object -Unique) }
  $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Write-Log([System.Windows.Forms.TextBox]$box, [string]$msg) {
  $box.AppendText(("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg) + [Environment]::NewLine)
}

function Ensure-Workspace([string]$path) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $gitDir = Join-Path $path ".git"
  if (-not (Test-Path $gitDir)) {
    & git -C $path init | Out-Null
  }
  & git -C $path rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) {
    & git -C $path config user.name "Codex Workspace Bootstrap" | Out-Null
    & git -C $path config user.email "codex-local@example.invalid" | Out-Null
    & git -C $path commit --allow-empty -m "chore: initialize workspace" | Out-Null
  }
}

function Style-Button(
  [System.Windows.Forms.Button]$button,
  [System.Drawing.Color]$back,
  [System.Drawing.Color]$fore
) {
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 0
  $button.BackColor = $back
  $button.ForeColor = $fore
  $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Style-TextInput([System.Windows.Forms.Control]$control) {
  $control.BackColor = $themeInput
  $control.ForeColor = $themeText
  if ($control -is [System.Windows.Forms.TextBox]) {
    $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex Windows Launcher"
$form.Size = New-Object System.Drawing.Size(940, 680)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = $themeBg
$form.ForeColor = $themeText

$lblDmg = New-Object System.Windows.Forms.Label
$lblDmg.Text = "DMG Path"
$lblDmg.Location = New-Object System.Drawing.Point(16, 16)
$lblDmg.Size = New-Object System.Drawing.Size(80, 24)
$form.Controls.Add($lblDmg)
$lblDmg.ForeColor = $themeSubtle

$txtDmg = New-Object System.Windows.Forms.TextBox
$txtDmg.Location = New-Object System.Drawing.Point(16, 38)
$txtDmg.Size = New-Object System.Drawing.Size(720, 26)
$txtDmg.Text = $defaultDmg
$form.Controls.Add($txtDmg)
Style-TextInput $txtDmg

$btnBrowseDmg = New-Object System.Windows.Forms.Button
$btnBrowseDmg.Location = New-Object System.Drawing.Point(746, 36)
$btnBrowseDmg.Size = New-Object System.Drawing.Size(80, 30)
$btnBrowseDmg.Text = "Browse"
$form.Controls.Add($btnBrowseDmg)
Style-Button $btnBrowseDmg $themePanel $themeText

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Location = New-Object System.Drawing.Point(16, 78)
$btnLaunch.Size = New-Object System.Drawing.Size(170, 34)
$btnLaunch.Text = "Launch Codex"
$form.Controls.Add($btnLaunch)
Style-Button $btnLaunch $themeAccent ([System.Drawing.Color]::White)

$chkReuse = New-Object System.Windows.Forms.CheckBox
$chkReuse.Location = New-Object System.Drawing.Point(204, 84)
$chkReuse.Size = New-Object System.Drawing.Size(90, 24)
$chkReuse.Text = "Reuse"
$chkReuse.Checked = $true
$form.Controls.Add($chkReuse)
$chkReuse.ForeColor = $themeText
$chkReuse.BackColor = $themeBg

$chkLogs = New-Object System.Windows.Forms.CheckBox
$chkLogs.Location = New-Object System.Drawing.Point(300, 84)
$chkLogs.Size = New-Object System.Drawing.Size(140, 24)
$chkLogs.Text = "Verbose Logging"
$chkLogs.Checked = $false
$form.Controls.Add($chkLogs)
$chkLogs.ForeColor = $themeText
$chkLogs.BackColor = $themeBg

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Location = New-Object System.Drawing.Point(452, 78)
$btnStop.Size = New-Object System.Drawing.Size(170, 34)
$btnStop.Text = "Stop Codex"
$form.Controls.Add($btnStop)
Style-Button $btnStop $themePanel $themeText

$btnResetUserdata = New-Object System.Windows.Forms.Button
$btnResetUserdata.Location = New-Object System.Drawing.Point(634, 78)
$btnResetUserdata.Size = New-Object System.Drawing.Size(192, 34)
$btnResetUserdata.Text = "Reset Local Userdata"
$form.Controls.Add($btnResetUserdata)
Style-Button $btnResetUserdata $themeDanger ([System.Drawing.Color]::White)

$grpWs = New-Object System.Windows.Forms.GroupBox
$grpWs.Text = "Workspace Placeholders"
$grpWs.Location = New-Object System.Drawing.Point(16, 126)
$grpWs.Size = New-Object System.Drawing.Size(892, 300)
$form.Controls.Add($grpWs)
$grpWs.ForeColor = $themeText
$grpWs.BackColor = $themePanel

$lstWs = New-Object System.Windows.Forms.ListBox
$lstWs.Location = New-Object System.Drawing.Point(14, 28)
$lstWs.Size = New-Object System.Drawing.Size(610, 220)
$grpWs.Controls.Add($lstWs)
Style-TextInput $lstWs

$txtWs = New-Object System.Windows.Forms.TextBox
$txtWs.Location = New-Object System.Drawing.Point(14, 256)
$txtWs.Size = New-Object System.Drawing.Size(610, 26)
$grpWs.Controls.Add($txtWs)
Style-TextInput $txtWs

$btnAddWs = New-Object System.Windows.Forms.Button
$btnAddWs.Location = New-Object System.Drawing.Point(640, 28)
$btnAddWs.Size = New-Object System.Drawing.Size(230, 32)
$btnAddWs.Text = "Add Path"
$grpWs.Controls.Add($btnAddWs)
Style-Button $btnAddWs $themeAccentAlt ([System.Drawing.Color]::White)

$btnRemoveWs = New-Object System.Windows.Forms.Button
$btnRemoveWs.Location = New-Object System.Drawing.Point(640, 68)
$btnRemoveWs.Size = New-Object System.Drawing.Size(230, 32)
$btnRemoveWs.Text = "Remove Selected"
$grpWs.Controls.Add($btnRemoveWs)
Style-Button $btnRemoveWs $themePanel $themeText

$btnEnsureWs = New-Object System.Windows.Forms.Button
$btnEnsureWs.Location = New-Object System.Drawing.Point(640, 108)
$btnEnsureWs.Size = New-Object System.Drawing.Size(230, 32)
$btnEnsureWs.Text = "Ensure Selected Exists + Git"
$grpWs.Controls.Add($btnEnsureWs)
Style-Button $btnEnsureWs $themePanel $themeText

$btnEnsureAll = New-Object System.Windows.Forms.Button
$btnEnsureAll.Location = New-Object System.Drawing.Point(640, 148)
$btnEnsureAll.Size = New-Object System.Drawing.Size(230, 32)
$btnEnsureAll.Text = "Ensure All"
$grpWs.Controls.Add($btnEnsureAll)
Style-Button $btnEnsureAll $themePanel $themeText

$btnOpenWs = New-Object System.Windows.Forms.Button
$btnOpenWs.Location = New-Object System.Drawing.Point(640, 188)
$btnOpenWs.Size = New-Object System.Drawing.Size(230, 32)
$btnOpenWs.Text = "Open Selected Folder"
$grpWs.Controls.Add($btnOpenWs)
Style-Button $btnOpenWs $themePanel $themeText

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Location = New-Object System.Drawing.Point(640, 228)
$btnDefaults.Size = New-Object System.Drawing.Size(230, 32)
$btnDefaults.Text = "Load Default Paths"
$grpWs.Controls.Add($btnDefaults)
Style-Button $btnDefaults $themePanel $themeText

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 438)
$txtLog.Size = New-Object System.Drawing.Size(892, 190)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)
Style-TextInput $txtLog

function Refresh-WorkspaceList {
  $lstWs.Items.Clear()
  $workspaces = Load-Workspaces
  foreach ($w in $workspaces) { [void]$lstWs.Items.Add($w) }
}

function Persist-CurrentList {
  $items = @()
  foreach ($i in $lstWs.Items) { $items += [string]$i }
  Save-Workspaces $items
}

$btnBrowseDmg.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "DMG files (*.dmg)|*.dmg|All files (*.*)|*.*"
  $dlg.InitialDirectory = $repoRoot
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtDmg.Text = $dlg.FileName
  }
})

$btnLaunch.Add_Click({
  try {
    $dmg = $txtDmg.Text.Trim()
    if (-not (Test-Path $dmg)) { throw "DMG not found: $dmg" }
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$runScript`"", "-DmgPath", "`"$dmg`"")
    if ($chkReuse.Checked) { $args += "-Reuse" }
    if ($chkLogs.Checked) { $args += "-EnableLogging" }
    Start-Process -FilePath "powershell" -ArgumentList ($args -join " ")
    Write-Log $txtLog "Launch command started."
  } catch {
    Write-Log $txtLog ("Launch failed: " + $_.Exception.Message)
  }
})

$btnStop.Add_Click({
  try {
    Get-Process electron -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Log $txtLog "Stopped electron processes."
  } catch {
    Write-Log $txtLog ("Stop failed: " + $_.Exception.Message)
  }
})

$btnResetUserdata.Add_Click({
  try {
    $workDir = Join-Path $repoRoot "work"
    $userData = Join-Path $workDir "userdata"
    if (Test-Path $userData) {
      $backup = "$userData.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
      Move-Item $userData $backup
      Write-Log $txtLog "Backed up userdata to: $backup"
    }
    New-Item -ItemType Directory -Force -Path $userData | Out-Null
    Write-Log $txtLog "Created fresh userdata directory."
  } catch {
    Write-Log $txtLog ("Reset userdata failed: " + $_.Exception.Message)
  }
})

$btnAddWs.Add_Click({
  $p = $txtWs.Text.Trim()
  if (-not $p) { return }
  if (-not $lstWs.Items.Contains($p)) {
    [void]$lstWs.Items.Add($p)
    Persist-CurrentList
    Write-Log $txtLog "Added workspace path."
  }
  $txtWs.Clear()
})

$btnRemoveWs.Add_Click({
  if ($lstWs.SelectedIndex -ge 0) {
    $removed = [string]$lstWs.SelectedItem
    $lstWs.Items.RemoveAt($lstWs.SelectedIndex)
    Persist-CurrentList
    Write-Log $txtLog "Removed workspace path: $removed"
  }
})

$btnEnsureWs.Add_Click({
  try {
    if ($lstWs.SelectedIndex -lt 0) { return }
    $p = [string]$lstWs.SelectedItem
    Ensure-Workspace $p
    Write-Log $txtLog "Ensured workspace path and Git repo: $p"
  } catch {
    Write-Log $txtLog ("Ensure selected failed: " + $_.Exception.Message)
  }
})

$btnEnsureAll.Add_Click({
  try {
    foreach ($item in $lstWs.Items) {
      Ensure-Workspace ([string]$item)
    }
    Write-Log $txtLog "Ensured all workspace paths and Git repos."
  } catch {
    Write-Log $txtLog ("Ensure all failed: " + $_.Exception.Message)
  }
})

$btnOpenWs.Add_Click({
  if ($lstWs.SelectedIndex -ge 0) {
    $p = [string]$lstWs.SelectedItem
    if (Test-Path $p) {
      Start-Process explorer.exe $p
      Write-Log $txtLog "Opened folder: $p"
    } else {
      Write-Log $txtLog "Path does not exist yet: $p"
    }
  }
})

$btnDefaults.Add_Click({
  $lstWs.Items.Clear()
  foreach ($d in Get-DefaultWorkspaces) { [void]$lstWs.Items.Add($d) }
  Persist-CurrentList
  Write-Log $txtLog "Loaded default workspace paths."
})

Refresh-WorkspaceList
Write-Log $txtLog "Manager ready."
[void]$form.ShowDialog()
