#!/usr/bin/env bash
# Installs the unpacked Stagehand v4 extension for the Browser Lane stagehand
# target (docs/rfc/RFC-browser-lane-stagehand.md §3.6) and prints the
# [browser.stagehand] lines for runtime.toml.
#
#   connectors/browser/install-stagehand-extension.sh [--base-path PATH]
#
# The version and its reviewed npm integrity are pinned together. The tarball
# is checked against that digest before anything is unpacked.
set -euo pipefail

version="4.1.0"
package="@browserbasehq/stagehand"
# npm view @browserbasehq/stagehand@4.1.0 dist.integrity (2026-09-24).
integrity="sha512-PJikMBVoaCRh6TFD7GcmeISmsMq4IwUu1BD5FOsGUVDUxrVqZomWa6W6dF+a/zu4xRZu2Z2xX1nXVMDaCuZWsw=="
base_path="${MASC_BASE_PATH:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-path) base_path="${2:?--base-path needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "install-stagehand-extension: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$base_path" ]; then
  echo "install-stagehand-extension: --base-path or MASC_BASE_PATH is required" >&2
  exit 2
fi

base_path="$(cd "$base_path" && pwd -P)"
target="$base_path/.masc/browser-lane/stagehand-extension/$version"
work="$(mktemp -d)"
stage=""
backup=""
installed=false

cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$backup" ] && { [ -e "$backup/extension" ] || [ -L "$backup/extension" ]; }; then
    if [ "$installed" = true ]; then
      rm -rf "$backup"
    elif [ ! -e "$target" ] && [ ! -L "$target" ]; then
      if mv "$backup/extension" "$target"; then
        rm -rf "$backup"
      else
        echo "install-stagehand-extension: previous extension remains at $backup/extension" >&2
        status=1
      fi
    else
      echo "install-stagehand-extension: previous extension remains at $backup/extension" >&2
      status=1
    fi
  elif [ -n "$backup" ]; then
    rm -rf "$backup"
  fi
  [ -z "$stage" ] || rm -rf "$stage"
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

(cd "$work" && npm pack --silent "$package@$version" >/dev/null)
tarball="$(find "$work" -maxdepth 1 -name '*.tgz' -print -quit)"
actual="sha512-$(openssl dgst -sha512 -binary "$tarball" | base64 | tr -d '\n')"
if [ "$actual" != "$integrity" ]; then
  echo "install-stagehand-extension: the downloaded tarball does not match the registry integrity" >&2
  exit 1
fi

tar -xzf "$tarball" -C "$work" package/dist/extension
parent="$(dirname "$target")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.stagehand-extension-stage.XXXXXX")"
mv "$work/package/dist/extension" "$stage/extension"
chmod -R go-w "$stage/extension"

if [ -e "$target" ] || [ -L "$target" ]; then
  backup="$(mktemp -d "$parent/.stagehand-extension-backup.XXXXXX")"
  mv "$target" "$backup/extension"
fi
mv "$stage/extension" "$target"
installed=true

echo "installed the Stagehand $version extension into $target"
echo
echo "Add to runtime.toml:"
echo
echo "[browser.stagehand]"
echo "chrome = \"/absolute/path/to/chrome\""
echo "extension = \"$target\""
