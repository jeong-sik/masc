#!/usr/bin/env bash
# masc installer — download prebuilt binary, seed minimum config, smoke-check.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh -o /tmp/masc-install.sh
#   less /tmp/masc-install.sh
#   bash /tmp/masc-install.sh --version <release-tag>
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash -s -- --version <release-tag> --prefix /usr/local/bin
#
# Flags:
#   --version vX.Y.Z   Pin a specific release (default: latest)
#   --prefix DIR       Install dir for the binary (default: $HOME/.local/bin)
#   --base-path DIR    .masc seed target (default: $PWD)
#   --no-seed          Skip writing default config files
#   --force            Overwrite existing binary / config
#   --dry-run          Print what would happen, do not write
#   --allow-unverified Continue if SHA256SUMS cannot be fetched (unsafe)
#
# Env:
#   MASC_VERSION   Same as --version
#   MASC_PREFIX    Same as --prefix
#   MASC_REPO      Override repo (default: jeong-sik/masc)
#   MASC_PORT      Port used in the post-install local-start hint (default: 8935)
#   MASC_ALLOW_UNVERIFIED=1  Same as --allow-unverified

set -euo pipefail

REPO="${MASC_REPO:-jeong-sik/masc}"
VERSION="${MASC_VERSION:-}"
PREFIX="${MASC_PREFIX:-$HOME/.local/bin}"
MASC_PORT="${MASC_PORT:-8935}"
BASE_PATH=""
SEED_CONFIG=1
FORCE=0
DRY_RUN=0
ALLOW_UNVERIFIED="${MASC_ALLOW_UNVERIFIED:-0}"

c_red=$(printf '\033[31m'); c_yel=$(printf '\033[33m'); c_grn=$(printf '\033[32m')
c_dim=$(printf '\033[2m'); c_off=$(printf '\033[0m')
[ -t 1 ] || { c_red=""; c_yel=""; c_grn=""; c_dim=""; c_off=""; }

log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --prefix)  PREFIX="$2";  shift 2 ;;
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --no-seed) SEED_CONFIG=0; shift ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

case "$ALLOW_UNVERIFIED" in
  0|1) ;;
  *) die "MASC_ALLOW_UNVERIFIED must be 0 or 1" ;;
esac

[ -z "$BASE_PATH" ] && BASE_PATH="$PWD"

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require curl
require uname
require chmod
require mkdir
require mktemp

# --- checksum helpers ---------------------------------------------------------
has_sha256sum() { command -v sha256sum >/dev/null 2>&1; }
has_shasum()    { command -v shasum    >/dev/null 2>&1; }

sha256_file() {
  if has_sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif has_shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

expected_hash() {
  local file="$1"
  awk -v f="$file" '$2 == f {print $1; exit}' "$CHECKSUMS_FILE"
}

verify_checksum() {
  local file="$1" name="$2"
  if [ "$CHECKSUMS_AVAILABLE" -ne 1 ]; then
    [ "$ALLOW_UNVERIFIED" = "1" ] \
      || die "release checksums unavailable; refusing to install unverified $name (pass --allow-unverified or set MASC_ALLOW_UNVERIFIED=1 to override)"
    warn "skipping checksum for $name because unverified install override is enabled"
    return 0
  fi
  local expected actual
  expected=$(expected_hash "$name")
  if [ -z "$expected" ]; then
    die "no checksum entry for $name in SHA256SUMS"
  fi
  actual=$(sha256_file "$file")
  if [ -z "$actual" ]; then
    die "cannot compute sha256 for $name (missing sha256sum/shasum)"
  fi
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $name (expected $expected, got $actual)"
  fi
  log "verified $name checksum"
}

# --- 1. detect platform -------------------------------------------------------
detect_asset() {
  local os arch
  os=$(uname -s); arch=$(uname -m)
  case "$os/$arch" in
    Darwin/arm64)  echo "masc-macos-arm64" ;;
    Linux/x86_64)  echo "masc-linux-x64"   ;;
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
  local tag
  if command -v jq >/dev/null 2>&1; then
    tag=$(curl -fsSL --max-time 30 --retry 3 "$api" | jq -er '.tag_name // empty') \
      || die "could not parse latest release tag from GitHub API response"
  else
    tag=$(curl -fsSL --max-time 30 --retry 3 "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$tag" ] || die "could not parse latest release tag from GitHub API response (fallback regex failed)"
  fi
  echo "$tag"
}

VERSION=$(resolve_version)
[ -n "$VERSION" ] || die "could not resolve version (network or rate limit?)"
log "version: $VERSION"

# --- 2b. fetch release checksums ----------------------------------------------
CHECKSUMS_FILE="$(mktemp)"
cleanup_checksums() { rm -f "$CHECKSUMS_FILE"; }
trap cleanup_checksums EXIT
CHECKSUMS_AVAILABLE=0
CHECKSUMS_URL="https://github.com/$REPO/releases/download/$VERSION/SHA256SUMS"
if curl -fsSL --max-time 30 --retry 3 -o "$CHECKSUMS_FILE" "$CHECKSUMS_URL"; then
  CHECKSUMS_AVAILABLE=1
elif [ "$DRY_RUN" -eq 1 ]; then
  warn "could not fetch release checksums ($CHECKSUMS_URL); dry-run only, no files will be written"
elif [ "$ALLOW_UNVERIFIED" = "1" ]; then
  warn "could not fetch release checksums ($CHECKSUMS_URL); continuing because unverified install override is enabled"
else
  die "could not fetch release checksums ($CHECKSUMS_URL); refusing unverified install (pass --allow-unverified or set MASC_ALLOW_UNVERIFIED=1 to override)"
fi

# --- 3. download binary -------------------------------------------------------
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
DEST="$PREFIX/masc"

SKIP_DL=0
if [ -e "$DEST" ] && [ "$FORCE" -eq 0 ]; then
  # The pipeline `... | tail -n1` masks the binary's own exit status, so
  # ask the binary directly first, then capture its output.
  if "$DEST" --version >/dev/null 2>&1; then
    existing_ver=$("$DEST" --version 2>/dev/null | tail -n1)
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
    curl -fL --max-time 300 --retry 3 --progress-bar -o "$tmp" "$URL" \
      || die "download failed (asset missing for $VERSION?)"
    verify_checksum "$tmp" "$ASSET"
    chmod +x "$tmp"
    mv "$tmp" "$DEST"
    log "installed: $DEST"
  fi
fi

# --- 4. seed minimum config ---------------------------------------------------
if [ "$SEED_CONFIG" -eq 1 ]; then
  CONFIG_DIR="$BASE_PATH/.masc/config"
  CONFIG_FILE="$CONFIG_DIR/tool_policy.toml"
  RUNTIME_FILE="$CONFIG_DIR/runtime.toml"
  MODEL_CATALOG_FILE="$CONFIG_DIR/oas-models.toml"

  if [ -e "$CONFIG_FILE" ] && [ -e "$RUNTIME_FILE" ] && [ -e "$MODEL_CATALOG_FILE" ] && [ "$FORCE" -eq 0 ]; then
    log "config already present at $CONFIG_DIR, skipping seed"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would seed configs and model catalog to $CONFIG_DIR from release"
  else
    log "seeding configs and model catalog to $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"

    seed_raw() {
      local raw_path="$1" name="$2" dest="$3"
      local raw="https://raw.githubusercontent.com/$REPO/$VERSION/$raw_path"
      local tmp="$dest.partial"
      curl -fsSL --max-time 60 --retry 3 -o "$tmp" "$raw" \
        || die "config seed failed (raw fetch from $raw)"
      verify_checksum "$tmp" "$name"
      mv "$tmp" "$dest"
    }

    seed_raw_if_missing() {
      local raw_path="$1" name="$2" dest="$3"
      if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
        log "config already present: $dest, skipping seed"
      else
        seed_raw "$raw_path" "$name" "$dest"
      fi
    }

    seed_config_if_missing() {
      local name="$1" dest="$2"
      seed_raw_if_missing "config/$name" "$name" "$dest"
    }

    seed_config_if_missing "tool_policy.toml" "$CONFIG_FILE"
    seed_config_if_missing "runtime.toml" "$RUNTIME_FILE"
    seed_raw_if_missing "oas-models.toml" "oas-models.toml" "$MODEL_CATALOG_FILE"
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

${c_grn}masc ${VERSION} installed.${c_off}

Next:
  ${c_dim}# start server (loopback only)${c_off}
  $DEST --base-path "$BASE_PATH"

  ${c_dim}# if runtime.toml uses cloud providers, export their required API keys first${c_off}
  See: https://github.com/$REPO/blob/main/docs/runtime-tunables.md

  ${c_dim}# in another shell, sanity check${c_off}
  curl http://127.0.0.1:${MASC_PORT}/health

  ${c_dim}# wire up your MCP client (local agent)${c_off}
  See: https://github.com/$REPO#mcp-client-setup

EOF
