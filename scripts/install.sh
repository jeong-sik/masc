#!/usr/bin/env bash
# masc-mcp installer — download prebuilt binary, seed minimum config, smoke-check.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh | bash -s -- --version v0.8.0 --prefix /usr/local/bin
#
# Flags:
#   --version vX.Y.Z   Pin a specific release (default: latest)
#   --prefix DIR       Install dir for the binary (default: $HOME/.local/bin)
#   --base-path DIR    .masc seed target (default: $PWD)
#   --no-seed          Skip writing default tool_policy.toml
#   --force            Overwrite existing binary / config
#   --dry-run          Print what would happen, do not write
#
# Env:
#   MASC_MCP_VERSION   Same as --version
#   MASC_MCP_PREFIX    Same as --prefix
#   MASC_MCP_REPO      Override repo (default: jeong-sik/masc-mcp)

set -euo pipefail

REPO="${MASC_MCP_REPO:-jeong-sik/masc-mcp}"
VERSION="${MASC_MCP_VERSION:-}"
PREFIX="${MASC_MCP_PREFIX:-$HOME/.local/bin}"
BASE_PATH=""
SEED_CONFIG=1
FORCE=0
DRY_RUN=0

c_red=$(printf '\033[31m'); c_yel=$(printf '\033[33m'); c_grn=$(printf '\033[32m')
c_dim=$(printf '\033[2m'); c_off=$(printf '\033[0m')
[ -t 1 ] || { c_red=""; c_yel=""; c_grn=""; c_dim=""; c_off=""; }

log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --prefix)  PREFIX="$2";  shift 2 ;;
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --no-seed) SEED_CONFIG=0; shift ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

[ -z "$BASE_PATH" ] && BASE_PATH="$PWD"

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require curl
require uname
require chmod
require mkdir

# --- 1. detect platform -------------------------------------------------------
detect_asset() {
  local os arch
  os=$(uname -s); arch=$(uname -m)
  case "$os/$arch" in
    Darwin/arm64)  echo "masc-mcp-macos-arm64" ;;
    Linux/x86_64)  echo "masc-mcp-linux-x64"   ;;
    Darwin/x86_64) die "macOS x86_64 release asset not built. Build from source per README." ;;
    Linux/aarch64) die "Linux arm64 release asset not built yet. Track .github/workflows/release.yml." ;;
    *) die "unsupported platform: $os/$arch" ;;
  esac
}

ASSET=$(detect_asset)
log "platform: $ASSET"

# --- 2. resolve version -------------------------------------------------------
resolve_version() {
  if [ -n "$VERSION" ]; then echo "$VERSION"; return; fi
  log "resolving latest release from github.com/$REPO ..." >&2
  local api="https://api.github.com/repos/$REPO/releases/latest"
  curl -fsSL "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1
}

VERSION=$(resolve_version)
[ -n "$VERSION" ] || die "could not resolve version (network or rate limit?)"
log "version: $VERSION"

# --- 3. download binary -------------------------------------------------------
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
DEST="$PREFIX/masc-mcp"

SKIP_DL=0
if [ -e "$DEST" ] && [ "$FORCE" -eq 0 ]; then
  if existing_ver=$("$DEST" --version 2>/dev/null | tail -n1); then
    if [ "$existing_ver" = "${VERSION#v}" ]; then
      log "already at $VERSION ($DEST), skipping download"
      SKIP_DL=1
    else
      warn "existing $DEST is version $existing_ver, target is ${VERSION#v}; pass --force to overwrite"
      exit 1
    fi
  else
    warn "$DEST exists but does not respond to --version; pass --force to overwrite"
    exit 1
  fi
fi

if [ "$SKIP_DL" -ne 1 ]; then
  log "downloading $URL"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would download to $DEST"
  else
    mkdir -p "$PREFIX"
    tmp="$DEST.partial"
    curl -fL --progress-bar -o "$tmp" "$URL" \
      || die "download failed (asset missing for $VERSION?)"
    chmod +x "$tmp"
    mv "$tmp" "$DEST"
    log "installed: $DEST"
  fi
fi

# --- 4. seed minimum config ---------------------------------------------------
if [ "$SEED_CONFIG" -eq 1 ]; then
  CONFIG_DIR="$BASE_PATH/.masc/config"
  CONFIG_FILE="$CONFIG_DIR/tool_policy.toml"
  RAW="https://raw.githubusercontent.com/$REPO/$VERSION/config/tool_policy.toml"

  if [ -e "$CONFIG_FILE" ] && [ "$FORCE" -eq 0 ]; then
    log "config already present at $CONFIG_FILE, skipping seed"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would seed $CONFIG_FILE from $RAW"
  else
    log "seeding $CONFIG_FILE"
    mkdir -p "$CONFIG_DIR"
    curl -fsSL -o "$CONFIG_FILE.partial" "$RAW" \
      || die "config seed failed (raw fetch from $RAW)"
    mv "$CONFIG_FILE.partial" "$CONFIG_FILE"
  fi
fi

# --- 5. smoke check -----------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  if reported=$("$DEST" --version 2>/dev/null | tail -n1); then
    [ "$reported" = "${VERSION#v}" ] \
      || warn "binary reports $reported, expected ${VERSION#v}"
  else
    die "binary did not respond to --version"
  fi
fi

# --- 6. PATH guidance ---------------------------------------------------------
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) warn "$PREFIX is not in PATH. Add this to your shell rc:
      export PATH=\"$PREFIX:\$PATH\"" ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n%s[dry-run] no files written.%s\n\n' "$c_yel" "$c_off"
  exit 0
fi

cat <<EOF

${c_grn}masc-mcp ${VERSION} installed.${c_off}

Next:
  ${c_dim}# start server (loopback only)${c_off}
  $DEST --base-path "$BASE_PATH" --port 8935

  ${c_dim}# in another shell, sanity check${c_off}
  curl http://127.0.0.1:8935/health

  ${c_dim}# wire up your MCP client (Claude / Codex / Gemini)${c_off}
  See: https://github.com/$REPO#mcp-client-setup

EOF
