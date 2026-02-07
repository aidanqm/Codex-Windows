# Codex DMG -> Windows

This repository provides a **Windows-only runner and packager** that extracts the macOS Codex DMG and runs the Electron app on Windows. It unpacks `app.asar`, swaps mac-only native modules for Windows builds, and launches the app with a compatible Electron runtime. It **does not** ship OpenAI binaries or assets; you must supply your own DMG and install the Codex CLI.

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

The script will:
- Extract the DMG to `work/`
- Build a Windows-ready app directory
- Auto-detect `codex.exe`
- Launch Codex

## Build Portable Artifact
Build a portable distribution folder (and optional zip) with a `Codex.exe` launcher:

```powershell
.\scripts\build-portable.ps1 -DmgPath .\Codex.dmg
```

Optional switches:

```powershell
.\scripts\build-portable.ps1 -DmgPath .\Codex.dmg -Reuse -Zip
```

Output:
- `dist\Codex-portable\Codex.exe`
- `dist\Codex-portable\launch.exe`
- `dist\Codex-portable\launch.cmd`
- `dist\Codex-portable\launch.ps1`
- `dist\Codex-portable\electron.exe`
- `dist\Codex-portable\resources\app\...`
- `dist\Codex-portable.zip` (when `-Zip` is used)

## Packaged Launch Behavior
- `codex.exe` is still an external dependency and is **not** bundled.
- Preferred clickable entrypoint is `Codex.exe` (also `launch.exe`, with fallbacks `launch.cmd`/`launch.ps1`) because it prepares required environment variables before starting the packaged Electron runtime.
- If `codex.exe` is missing, install it with:

```powershell
npm i -g @openai/codex
```

## Notes
- This is not an official OpenAI project.
- Do not redistribute OpenAI app binaries or DMG files.
- The Electron version is read from the app's `package.json` to keep ABI compatibility.

## License
MIT (For the scripts only)
