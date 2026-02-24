# Codex DMG Wrapper (Windows / WSL)

This repository is a wrapper around the official macOS Codex app package (`Codex.dmg`): it extracts `app.asar`, patches platform-specific native modules, and launches with a compatible Electron runtime on Windows or WSL/Linux.

It is **not** an OpenAI binary distribution and it does **not** auto-download Codex for you. You must download `Codex.dmg` yourself and provide it locally.

## Requirements (Windows runner)
- Windows 10/11
- Node.js
- 7-Zip (`7z` in PATH)
- If 7-Zip is not installed, the runner will try `winget` or download a portable copy
- Codex CLI installed (`npm i -g @openai/codex`)

## Quick Start (Windows)
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

## Quick Start (WSL/Linux)
1. Download `Codex.dmg` from the official source, then copy or reference it (example from Windows Downloads):

```bash
cp "/mnt/c/Users/<you>/Downloads/Codex.dmg" ./Codex.dmg
```

2. Ensure Node.js + Codex CLI are installed:

```bash
npm i -g @openai/codex
```

3. Run the WSL/Linux runner:

```bash
chmod +x ./scripts/run.sh
./scripts/run.sh --dmg ./Codex.dmg
```

Recommended default on WSL (best visual quality in most setups):

```bash
CODEX_OZONE_PLATFORM=wayland ./scripts/run.sh --dmg ./Codex.dmg --reuse
```

Useful options:

```bash
./scripts/run.sh --dmg ./Codex.dmg --no-launch
./scripts/run.sh --dmg ./Codex.dmg --reuse
./scripts/run.sh --dmg ./Codex.dmg --codex-cli "$(command -v codex)"
```

Notes for WSL/Linux:
- `scripts/run.sh` needs `7z`. If not present, it tries to bootstrap a local `7zip` binary under `work/tools/` using `apt-get download` (no `sudo` install required).
- GUI launch requires WSLg/X forwarding (`DISPLAY` or `WAYLAND_DISPLAY`).
- If the window looks blurry/pixelated on WSL, force Wayland + scale factor:

```bash
CODEX_OZONE_PLATFORM=wayland CODEX_FORCE_DEVICE_SCALE_FACTOR=1 ./scripts/run.sh --dmg ./Codex.dmg --reuse
```

- If Fullscreen/Maximize is broken on Wayland, run without forced Wayland decorations (default):

```bash
CODEX_OZONE_PLATFORM=wayland ./scripts/run.sh --dmg ./Codex.dmg --reuse
```

- If the cursor is too large, set a cursor size explicitly:

```bash
CODEX_OZONE_PLATFORM=wayland CODEX_CURSOR_SIZE=16 ./scripts/run.sh --dmg ./Codex.dmg --reuse
```

(`CODEX_CURSOR_SIZE` valid range: `12-128`)

- If the window is invisible/off-screen, force explicit position/size:

```bash
CODEX_OZONE_PLATFORM=x11 XCURSOR_SIZE=16 CODEX_WINDOW_POSITION=80,80 CODEX_WINDOW_SIZE=1400,900 ./scripts/run.sh --dmg ./Codex.dmg --reuse
```

- `CODEX_DISABLE_GPU=1` is currently not recommended for this app build on WSL, because it can make the UI non-interactive/invisible.

## Notes
- This is not an official OpenAI project.
- Do not redistribute OpenAI app binaries or DMG files.
- The Electron version is read from the app's `package.json` to keep ABI compatibility.
- Auto-downloading the macOS Codex DMG is intentionally not included.

## License
MIT (For the scripts only)
