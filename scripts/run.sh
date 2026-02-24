#!/usr/bin/env bash
set -euo pipefail

DMG_PATH=""
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work"
CODEX_CLI_PATH="${CODEX_CLI_PATH:-}"
REUSE=0
NO_LAUNCH=0

header() {
  printf "\n=== %s ===\n" "$1"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH."
}

ensure_7z() {
  if command -v 7z >/dev/null 2>&1; then
    echo "7z"
    return 0
  fi
  if [[ -x "/usr/lib/7zip/7z" ]]; then
    echo "/usr/lib/7zip/7z"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
    die "7z not found. Install package '7zip' or add 7z to PATH."
  fi

  local tools_dir pkg_dir out_dir deb
  tools_dir="$WORK_DIR/tools"
  pkg_dir="$tools_dir/debs"
  out_dir="$tools_dir/7zip"
  mkdir -p "$pkg_dir" "$out_dir"

  if [[ ! -x "$out_dir/usr/lib/7zip/7z" ]]; then
    echo "=== Bootstrapping local 7zip binary ===" >&2
    (
      cd "$pkg_dir"
      rm -f 7zip_*.deb
      apt-get download 7zip >/dev/null
      deb="$(ls -1t 7zip_*.deb | head -n 1)"
      dpkg-deb -x "$deb" "$out_dir"
    )
  fi

  [[ -x "$out_dir/usr/lib/7zip/7z" ]] || die "Unable to bootstrap 7z. Install package '7zip'."
  echo "$out_dir/usr/lib/7zip/7z"
}

resolve_dmg_path() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -n "$DMG_PATH" ]]; then
    [[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"
    DMG_PATH="$(readlink -f "$DMG_PATH")"
    return 0
  fi
  if [[ -f "$root/Codex.dmg" ]]; then
    DMG_PATH="$(readlink -f "$root/Codex.dmg")"
    return 0
  fi
  local first
  first="$(find "$root" -maxdepth 1 -type f -name '*.dmg' | head -n 1 || true)"
  [[ -n "$first" ]] || die "No DMG found in repo root."
  DMG_PATH="$(readlink -f "$first")"
}

resolve_codex_cli_path() {
  if [[ -n "$CODEX_CLI_PATH" ]]; then
    [[ -x "$CODEX_CLI_PATH" ]] || die "Codex CLI not executable: $CODEX_CLI_PATH"
    CODEX_CLI_PATH="$(readlink -f "$CODEX_CLI_PATH")"
    return 0
  fi
  if command -v codex >/dev/null 2>&1; then
    CODEX_CLI_PATH="$(command -v codex)"
    return 0
  fi
  die "codex CLI not found. Install with: npm i -g @openai/codex"
}

patch_preload() {
  local preload="$APP_DIR/.vite/build/preload.js"
  [[ -f "$preload" ]] || return 0
  node - "$preload" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
let raw = fs.readFileSync(path, "utf8");
const expose = 'const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld("process",P);';
if (!raw.includes(expose)) {
  const re = /n\.contextBridge\.exposeInMainWorld\("codexWindowType",[A-Za-z0-9_$]+\);n\.contextBridge\.exposeInMainWorld\("electronBridge",[A-Za-z0-9_$]+\);/;
  const m = raw.match(re);
  if (!m) {
    throw new Error("preload patch point not found");
  }
  raw = raw.replace(m[0], `${expose}${m[0]}`);
  fs.writeFileSync(path, raw);
}
NODE
}

arch_for_node_pty() {
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-x64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

copy_dir_contents() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
}

usage() {
  cat <<'EOF'
Usage:
  scripts/run.sh [options]

Options:
  --dmg <path>        Path to Codex.dmg
  --work-dir <path>   Working directory (default: ./work)
  --codex-cli <path>  Explicit codex CLI path
  --reuse             Reuse previously extracted/build artifacts
  --no-launch         Build/prepare only; do not launch Electron
  -h, --help          Show help

Environment:
  CODEX_OZONE_PLATFORM               auto|wayland|x11 (default: auto)
  CODEX_WAYLAND_DECORATIONS          1 to force Wayland CSD decorations
  CODEX_FORCE_DEVICE_SCALE_FACTOR    e.g. 1, 1.25, 1.5, 2
  CODEX_CURSOR_SIZE                  e.g. 16, 24, 32 (sets XCURSOR_SIZE)
  CODEX_WINDOW_POSITION              e.g. 80,80
  CODEX_WINDOW_SIZE                  e.g. 1400,900
  CODEX_START_MAXIMIZED              1 to request maximized start
  CODEX_DISABLE_GPU                  1 to launch with --disable-gpu
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG_PATH="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --codex-cli) CODEX_CLI_PATH="${2:-}"; shift 2 ;;
    --reuse) REUSE=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd node
need_cmd npm
need_cmd npx

for k in npm_config_runtime npm_config_target npm_config_disturl npm_config_arch npm_config_build_from_source; do
  unset "$k" || true
done

resolve_dmg_path
WORK_DIR="$(readlink -f "$(mkdir -p "$WORK_DIR" && printf '%s' "$WORK_DIR")")"
SEVEN_Z="$(ensure_7z)"

ELECTRON_DIR="$WORK_DIR/electron"
APP_DIR="$WORK_DIR/app"
NATIVE_DIR="$WORK_DIR/native-builds"
USER_DATA_DIR="$WORK_DIR/userdata"
CACHE_DIR="$WORK_DIR/cache"

if [[ "$REUSE" -eq 0 ]]; then
  header "Extracting app.asar"
  mkdir -p "$ELECTRON_DIR"
  "$SEVEN_Z" x -y "$DMG_PATH" \
    "Codex Installer/Codex.app/Contents/Resources/app.asar" \
    "Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/*" \
    "-o$ELECTRON_DIR" >/dev/null

  header "Unpacking app.asar"
  mkdir -p "$APP_DIR"
  ASAR="$ELECTRON_DIR/Codex Installer/Codex.app/Contents/Resources/app.asar"
  [[ -f "$ASAR" ]] || die "app.asar not found."
  npx --yes @electron/asar extract "$ASAR" "$APP_DIR"

  header "Syncing app.asar.unpacked"
  UNPACKED="$ELECTRON_DIR/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked"
  [[ -d "$UNPACKED" ]] && copy_dir_contents "$UNPACKED" "$APP_DIR"
fi

header "Patching preload"
patch_preload

header "Reading app metadata"
PKG_PATH="$APP_DIR/package.json"
[[ -f "$PKG_PATH" ]] || die "package.json not found in $APP_DIR"
ELECTRON_VERSION="$(node -e "const p=require('$PKG_PATH');console.log((p.devDependencies||{}).electron||'')")"
BETTER_VERSION="$(node -e "const p=require('$PKG_PATH');console.log((p.dependencies||{})['better-sqlite3']||'')")"
PTY_VERSION="$(node -e "const p=require('$PKG_PATH');console.log((p.dependencies||{})['node-pty']||'')")"
BUILD_NUMBER="$(node -e "const p=require('$PKG_PATH');console.log(p.codexBuildNumber||'510')")"
BUILD_FLAVOR="$(node -e "const p=require('$PKG_PATH');console.log(p.codexBuildFlavor||'prod')")"
[[ -n "$ELECTRON_VERSION" ]] || die "Electron version not found in package.json"

header "Preparing native modules"
NODE_PTY_ARCH="$(arch_for_node_pty)"
BS_DST="$APP_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
PTY_DST_PRE="$APP_DIR/node_modules/node-pty/prebuilds/$NODE_PTY_ARCH"
PTY_DST_REL="$APP_DIR/node_modules/node-pty/build/Release"
if [[ "$NO_LAUNCH" -eq 1 && "$REUSE" -eq 1 && -f "$BS_DST" && ( -f "$PTY_DST_PRE/pty.node" || -f "$PTY_DST_REL/pty.node" ) ]]; then
  echo "Native modules already present in app. Skipping rebuild."
else
  mkdir -p "$NATIVE_DIR"
  pushd "$NATIVE_DIR" >/dev/null

  [[ -f package.json ]] || npm init -y >/dev/null
  BS_SRC_PROBE="$NATIVE_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  PTY_SRC_PROBE="$NATIVE_DIR/node_modules/node-pty/prebuilds/$NODE_PTY_ARCH/pty.node"
  PTY_SRC_PROBE_FALLBACK="$NATIVE_DIR/node_modules/node-pty/build/Release/pty.node"
  ELECTRON_BIN="$NATIVE_DIR/node_modules/electron/dist/electron"
  HAVE_NATIVE=0
  if [[ -f "$BS_SRC_PROBE" && ( -f "$PTY_SRC_PROBE" || -f "$PTY_SRC_PROBE_FALLBACK" ) && -x "$ELECTRON_BIN" ]]; then
    HAVE_NATIVE=1
  fi

  if [[ "$HAVE_NATIVE" -eq 0 ]]; then
    npm install --no-save \
      "better-sqlite3@$BETTER_VERSION" \
      "node-pty@$PTY_VERSION" \
      "@electron/rebuild" \
      "prebuild-install" \
      "electron@$ELECTRON_VERSION"
  else
    echo "Native modules already present. Skipping rebuild."
  fi

  ELECTRON_BIN="$NATIVE_DIR/node_modules/electron/dist/electron"
  [[ -x "$ELECTRON_BIN" ]] || die "Electron binary not found at $ELECTRON_BIN"

  if [[ "$HAVE_NATIVE" -eq 0 ]]; then
    echo "Rebuilding native modules for Electron $ELECTRON_VERSION..."
    if ! node "$NATIVE_DIR/node_modules/@electron/rebuild/lib/cli.js" -v "$ELECTRON_VERSION" -w "better-sqlite3,node-pty"; then
      echo "electron-rebuild failed, trying prebuild-install for better-sqlite3..."
      pushd "$NATIVE_DIR/node_modules/better-sqlite3" >/dev/null
      node "$NATIVE_DIR/node_modules/prebuild-install/bin.js" -r electron -t "$ELECTRON_VERSION" --tag-prefix=electron-v
      popd >/dev/null
    fi
  fi

  export ELECTRON_RUN_AS_NODE=1
  "$ELECTRON_BIN" -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" >/dev/null
  unset ELECTRON_RUN_AS_NODE

  BS_SRC="$NATIVE_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  [[ -f "$BS_SRC" ]] || die "better_sqlite3.node not found after build."
  mkdir -p "$(dirname "$BS_DST")"
  cp -f "$BS_SRC" "$BS_DST"

  PTY_SRC_PRE_DIR="$NATIVE_DIR/node_modules/node-pty/prebuilds/$NODE_PTY_ARCH"
  PTY_SRC_REL_DIR="$NATIVE_DIR/node_modules/node-pty/build/Release"
  mkdir -p "$PTY_DST_PRE" "$PTY_DST_REL"
  cp -f "$PTY_SRC_PRE_DIR"/*.node "$PTY_DST_PRE/" 2>/dev/null || true
  cp -f "$PTY_SRC_PRE_DIR"/*.node "$PTY_DST_REL/" 2>/dev/null || true
  [[ -f "$PTY_SRC_REL_DIR/pty.node" ]] && cp -f "$PTY_SRC_REL_DIR/pty.node" "$PTY_DST_REL/pty.node"
  [[ -f "$PTY_SRC_REL_DIR/pty.node" ]] && cp -f "$PTY_SRC_REL_DIR/pty.node" "$PTY_DST_PRE/pty.node"
  [[ -f "$PTY_DST_REL/pty.node" ]] || die "node-pty pty.node not found after build."

  popd >/dev/null
fi

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  header "Resolving Codex CLI"
  resolve_codex_cli_path

  header "Launching Codex"
  ELECTRON_BIN="$NATIVE_DIR/node_modules/electron/dist/electron"
  [[ -x "$ELECTRON_BIN" ]] || die "Electron binary not found at $ELECTRON_BIN"
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || echo "Warning: DISPLAY/WAYLAND_DISPLAY not set. GUI launch may fail."

  mkdir -p "$USER_DATA_DIR" "$CACHE_DIR"
  export ELECTRON_RENDERER_URL="file://$APP_DIR/webview/index.html"
  export ELECTRON_FORCE_IS_PACKAGED=1
  export CODEX_BUILD_NUMBER="$BUILD_NUMBER"
  export CODEX_BUILD_FLAVOR="$BUILD_FLAVOR"
  export BUILD_FLAVOR="$BUILD_FLAVOR"
  export NODE_ENV=production
  export CODEX_CLI_PATH="$CODEX_CLI_PATH"
  export PWD="$APP_DIR"
  ELECTRON_ARGS=(
    "$APP_DIR"
    "--enable-logging"
    "--user-data-dir=$USER_DATA_DIR"
    "--disk-cache-dir=$CACHE_DIR"
  )

  OZONE_PLATFORM="${CODEX_OZONE_PLATFORM:-auto}"
  if [[ "$OZONE_PLATFORM" == "wayland" ]] || { [[ "$OZONE_PLATFORM" == "auto" ]] && [[ -n "${WAYLAND_DISPLAY:-}" ]]; }; then
    WAYLAND_FEATURES="UseOzonePlatform"
    if [[ "${CODEX_WAYLAND_DECORATIONS:-0}" == "1" ]]; then
      WAYLAND_FEATURES+=",WaylandWindowDecorations"
    fi
    ELECTRON_ARGS+=("--ozone-platform=wayland" "--enable-features=${WAYLAND_FEATURES}")
  elif [[ "$OZONE_PLATFORM" == "x11" ]]; then
    ELECTRON_ARGS+=("--ozone-platform=x11")
  fi

  if [[ -n "${CODEX_FORCE_DEVICE_SCALE_FACTOR:-}" ]]; then
    if [[ ! "${CODEX_FORCE_DEVICE_SCALE_FACTOR}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      die "CODEX_FORCE_DEVICE_SCALE_FACTOR must be numeric (example: 1.25)"
    fi
    ELECTRON_ARGS+=("--high-dpi-support=1" "--force-device-scale-factor=${CODEX_FORCE_DEVICE_SCALE_FACTOR}")
  fi

  if [[ "${CODEX_DISABLE_GPU:-0}" == "1" ]]; then
    echo "Warning: CODEX_DISABLE_GPU=1 can cause invisible/non-interactive UI on WSL for this app build." >&2
    ELECTRON_ARGS+=("--disable-gpu")
  fi

  if [[ -n "${CODEX_CURSOR_SIZE:-}" ]]; then
    if [[ ! "${CODEX_CURSOR_SIZE}" =~ ^[0-9]+$ ]]; then
      die "CODEX_CURSOR_SIZE must be an integer (example: 16)"
    fi
    if (( CODEX_CURSOR_SIZE < 12 || CODEX_CURSOR_SIZE > 128 )); then
      die "CODEX_CURSOR_SIZE must be between 12 and 128"
    fi
    export XCURSOR_SIZE="${CODEX_CURSOR_SIZE}"
  fi

  if [[ -n "${CODEX_WINDOW_POSITION:-}" ]]; then
    if [[ ! "${CODEX_WINDOW_POSITION}" =~ ^[0-9]+,[0-9]+$ ]]; then
      die "CODEX_WINDOW_POSITION must be like 80,80"
    fi
    ELECTRON_ARGS+=("--window-position=${CODEX_WINDOW_POSITION}")
  fi

  if [[ -n "${CODEX_WINDOW_SIZE:-}" ]]; then
    if [[ ! "${CODEX_WINDOW_SIZE}" =~ ^[0-9]+,[0-9]+$ ]]; then
      die "CODEX_WINDOW_SIZE must be like 1400,900"
    fi
    ELECTRON_ARGS+=("--window-size=${CODEX_WINDOW_SIZE}")
  fi

  if [[ "${CODEX_START_MAXIMIZED:-0}" == "1" ]]; then
    ELECTRON_ARGS+=("--start-maximized")
  fi

  "$ELECTRON_BIN" "${ELECTRON_ARGS[@]}"
fi
