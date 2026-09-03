#!/usr/bin/env sh
# install.sh -- fetch prebuilt masc binaries and place them on PATH.
#
# The release workflow builds masc (the server, which also serves the web
# dashboard) and masc-tui (the terminal interface) for three platforms. This
# script downloads the pair that matches the host and installs them; it does
# not build from source and needs no OCaml toolchain. Config and provider keys
# are handled by masc's own first-run setup the first time the server starts.
#
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/install.sh | sh
#
# Env:
#   MASC_INSTALL_DIR   Where to place the binaries (default: $HOME/.local/bin)
#   MASC_VERSION       Release tag to install (default: latest)

set -eu

REPO="jeong-sik/masc"
INSTALL_DIR="${MASC_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${MASC_VERSION:-latest}"

say() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required"

# Host -> the arch suffix the release assets carry. Only the three combinations
# the release workflow builds are accepted; anything else fails rather than
# guessing at a binary that does not exist.
os="$(uname -s)"
machine="$(uname -m)"
case "$os" in
  Darwin)
    case "$machine" in
      arm64 | aarch64) arch="macos-arm64" ;;
      *) die "no prebuilt masc for macOS $machine (only Apple Silicon is built)" ;;
    esac
    ;;
  Linux)
    case "$machine" in
      x86_64 | amd64) arch="linux-x64" ;;
      arm64 | aarch64) arch="linux-arm64" ;;
      *) die "no prebuilt masc for Linux $machine" ;;
    esac
    ;;
  *) die "unsupported OS: $os" ;;
esac

# /releases/latest/download/ redirects to the newest release's asset; a pinned
# tag reads /releases/download/<tag>/ instead.
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

mkdir -p "$INSTALL_DIR"

# Download to a temp file and move into place only on success, so an
# interrupted download never leaves a half-written binary on PATH.
fetch() {
  asset="$1"
  dest="$2"
  say "downloading $asset"
  tmp="$(mktemp)"
  if ! curl -fL --progress-bar "$base/$asset" -o "$tmp"; then
    rm -f "$tmp"
    die "download failed: $base/$asset"
  fi
  chmod +x "$tmp"
  mv "$tmp" "$dest"
}

fetch "masc-$arch" "$INSTALL_DIR/masc"
fetch "masc-tui-$arch" "$INSTALL_DIR/masc-tui"

say "installed:"
say "  $INSTALL_DIR/masc      -- server (serves the dashboard on http://127.0.0.1:8935/dashboard)"
say "  $INSTALL_DIR/masc-tui  -- terminal interface"

# PATH hint, only when the install dir is not already reachable.
case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *)
    say ""
    say "$INSTALL_DIR is not on PATH; add it, e.g.:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

say ""
say "next:"
say "  masc       # start the server; the first run sets up a provider and config"
say "  masc-tui   # open the terminal interface in another shell"
