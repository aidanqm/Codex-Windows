# Codex DMG -> Windows

This repository provides a **Windows-only runner** that extracts the macOS Codex DMG and runs the Electron app on Windows. It unpacks `app.asar`, swaps mac-only native modules for Windows builds, and launches the app with a compatible Electron runtime. It **does not** ship OpenAI binaries or assets; you must supply your own DMG and install the Codex CLI.

## Requirements
- Windows 10/11
- Node.js
- 7-Zip (`7z` in PATH)
- If 7-Zip is not installed, the runner will try `winget` or download a portable copy
- Codex CLI installed (`npm i -g @openai/codex`)

## Quick Start
1. Place your DMG in the repo root (default name `Codex.dmg`).
2. Run:

```powershell
.\scripts\run.ps1
```

Or explicitly:

```powershell
.\scripts\run.ps1 -DmgPath .\Codex.dmg
```

Or use the shortcut launcher:

```cmd
run.cmd
```

If `Codex.dmg` exists in the repo root, `run.cmd` now auto-uses it.

### Manager UI
You can launch a Windows manager UI for common tasks:

```cmd
manage.cmd
```

Or:

```cmd
run.cmd -Manage
```

The manager can:
- Launch/stop Codex
- Toggle reuse and verbose logging
- Reset local userdata (with timestamped backup)
- Load/save workspace placeholders
- Ensure selected/all workspaces exist and are initialized as Git repos
- Open selected workspace folders

The script will:
- Extract the DMG to `work/`
- Build a Windows-ready app directory
- Auto-detect `codex.exe`
- Launch Codex

## Fixes And Improvements Included
- Added `manage.cmd` and `scripts/manage.ps1` for GUI-based launching and workspace operations.
- Added `scripts/workspaces.json` to persist workspace placeholder paths.
- Added `-EnableLogging` support in `scripts/run.ps1` so logging is opt-in.
- Improved `codex.exe` detection to cover additional npm install layouts and nested package paths.
- Added `npm.cmd` / `npx.cmd` alias handling for better PowerShell 5.1 compatibility under strict mode.
- Updated native rebuild behavior to rebuild only `better-sqlite3` (skip unnecessary `node-pty` rebuild on Windows).
- Improved `run.cmd` usage/help output and added `-Manage` entrypoint.

## Notes
- This is not an official OpenAI project.
- Do not redistribute OpenAI app binaries or DMG files.
- The Electron version is read from the app's `package.json` to keep ABI compatibility.

## License
MIT (For the scripts only)
