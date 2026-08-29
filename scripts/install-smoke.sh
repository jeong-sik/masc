#!/usr/bin/env bash
# install-smoke.sh — offline end-to-end check of scripts/install.sh.
#
# Stages the release binaries as a local file:// release, installs them
# through the real installer (detect_asset + SHA256SUMS verification +
# placement), then boots the installed server and asserts /health. This
# guards the installer's asset-name and checksum contract that a release
# depends on -- the contract that broke silently when nothing exercised the
# download path end to end -- without any network access.
#
# Config seeding fetches from raw.githubusercontent, so this runs the
# installer with --no-seed and seeds the base path from the repo's own
# config/runtime.toml the way release-binary-smoke.sh does.
#
# Usage: install-smoke.sh <binaries_dir> <arch>
#   binaries_dir holds the release-named files:
#     masc-<arch>, masc-tui-<arch>,
#     masc-deployment-preflight-helper-<arch>,
#     masc-check-runtime-deployment-preflight-<arch>
#   arch is the release arch label (e.g. linux-x64, linux-arm64, macos-arm64)
#   and must match the host so install.sh's detect_asset resolves to it.
set -euo pipefail

BIN_DIR="${1:?usage: install-smoke.sh <binaries_dir> <arch>}"
ARCH="${2:?usage: install-smoke.sh <binaries_dir> <arch>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
[ -x "$INSTALL_SH" ] || { echo "install-smoke: $INSTALL_SH not executable" >&2; exit 2; }
[ -f "$REPO_ROOT/config/runtime.toml" ] || {
  echo "install-smoke: config/runtime.toml missing" >&2; exit 2; }

ASSETS=(
  "masc-$ARCH"
  "masc-tui-$ARCH"
  "masc-deployment-preflight-helper-$ARCH"
  "masc-check-runtime-deployment-preflight-$ARCH"
)
for a in "${ASSETS[@]}"; do
  [ -f "$BIN_DIR/$a" ] || { echo "install-smoke: missing release asset $BIN_DIR/$a" >&2; exit 2; }
done

# SMOKE_VERSION is a label, not a real tag: it only names the file:// release
# directory and the SHA256SUMS the installer verifies against.
VERSION="v0.0.0-install-smoke"
work="$(mktemp -d)"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

stage="$work/release/$VERSION"
prefix="$work/bin"
base="$work/base"
mkdir -p "$stage" "$prefix" "$base"

# Stage the file:// release: the four assets plus a SHA256SUMS with exactly
# the format install.sh's verify_checksum parses ("<hash>  <name>").
for a in "${ASSETS[@]}"; do
  cp "$BIN_DIR/$a" "$stage/$a"
done
sha_tool() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
( cd "$stage" && sha_tool "${ASSETS[@]}" > SHA256SUMS )

echo "install-smoke: installing $VERSION ($ARCH) from file://$stage"
MASC_RELEASE_BASE_URL="file://$work/release" \
  bash "$INSTALL_SH" \
    --version "$VERSION" \
    --prefix "$prefix" \
    --base-path "$base" \
    --no-seed \
    --no-wizard

for a in masc masc-tui masc-deployment-preflight-helper masc-check-runtime-deployment-preflight; do
  [ -x "$prefix/$a" ] || { echo "install-smoke: installer did not place $a" >&2; exit 1; }
done
echo "install-smoke: installer placed all four binaries"

# Boot the installed server. --no-seed left no config, so seed runtime.toml
# from the repo checkout the same way release-binary-smoke.sh does.
mkdir -p "$base/.masc/config"
cp "$REPO_ROOT/config/runtime.toml" "$base/.masc/config/runtime.toml"

PORT="${INSTALL_SMOKE_PORT:-18946}"
log="$work/server.log"
MASC_BASE_PATH="$base" MASC_BASE_PATH_INPUT="$base" MASC_OTEL_ENABLED=0 \
  "$prefix/masc" --base-path "$base" --host 127.0.0.1 --port "$PORT" >"$log" 2>&1 &
PID=$!

health=""
for _ in $(seq 1 30); do
  if health="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null)"; then
    break
  fi
  kill -0 "$PID" 2>/dev/null || { echo "install-smoke: server exited before answering" >&2; cat "$log" >&2; exit 1; }
  sleep 1
done

case "$health" in
  *'"status":"ok"'*) echo "install-smoke: installed server answered /health ok" ;;
  *) echo "install-smoke: /health did not report ok: ${health:-<no response>}" >&2; cat "$log" >&2; exit 1 ;;
esac

echo "install-smoke: PASS"
