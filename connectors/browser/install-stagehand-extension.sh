#!/usr/bin/env bash
# Installs the unpacked Stagehand v4 extension for the Browser Lane stagehand
# target (docs/rfc/RFC-browser-lane-stagehand.md §3.6) and prints the
# [browser.stagehand] lines for runtime.toml.
#
#   connectors/browser/install-stagehand-extension.sh [--base-path PATH]
#
# The version is pinned here and only here. The npm tarball is checked against
# the registry's dist.integrity before anything is unpacked.
set -euo pipefail

version="4.1.0"
package="@browserbasehq/stagehand"
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
trap 'rm -rf "$work"' EXIT

integrity="$(npm view "$package@$version" dist.integrity)"
case "$integrity" in
  sha512-*) ;;
  *) echo "install-stagehand-extension: the registry gave no sha512 integrity for $package@$version" >&2; exit 1 ;;
esac

(cd "$work" && npm pack --silent "$package@$version" >/dev/null)
tarball="$(find "$work" -maxdepth 1 -name '*.tgz' -print -quit)"
actual="sha512-$(openssl dgst -sha512 -binary "$tarball" | base64 | tr -d '\n')"
if [ "$actual" != "$integrity" ]; then
  echo "install-stagehand-extension: the downloaded tarball does not match the registry integrity" >&2
  exit 1
fi

tar -xzf "$tarball" -C "$work" package/dist/extension
rm -rf "$target"
mkdir -p "$(dirname "$target")"
mv "$work/package/dist/extension" "$target"
chmod -R go-w "$target"

echo "installed the Stagehand $version extension into $target"
echo
echo "Add to runtime.toml:"
echo
echo "[browser.stagehand]"
echo "chrome = \"/absolute/path/to/chrome\""
echo "extension = \"$target\""
