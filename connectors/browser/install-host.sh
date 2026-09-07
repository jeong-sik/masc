#!/usr/bin/env bash
# Install the masc browser-lane native messaging host for Firefox/Zen (macOS).
#
# Registers the host manifest in Firefox's NativeMessagingHosts directory so
# the extension's connectNative("masc_browser_host") finds this repo's host.
# Re-run after moving the repo; the manifest carries absolute paths.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_js="$here/host/masc-browser-host.js"
wrapper="$here/host/masc-browser-host"
target_dir="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"

command -v node >/dev/null 2>&1 || { echo "node is required on PATH" >&2; exit 1; }

# The manifest's path must be an executable and takes no arguments, so the
# wrapper resolves node itself and execs the host script.
cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec "$(command -v node)" "$host_js"
EOF
chmod +x "$wrapper"

mkdir -p "$target_dir"
cat > "$target_dir/masc_browser_host.json" <<EOF
{
  "name": "masc_browser_host",
  "description": "masc browser lane host: bridges lane commands to this browser",
  "path": "$wrapper",
  "type": "stdio",
  "allowed_extensions": ["browser-lane@masc.local"]
}
EOF

# The lane token gates /browser-lane/* on the server (fail closed without
# it). One token serves both the live host and the automation daemon.
base="${MASC_BROWSER_LANE_BASE:-$HOME/me/.masc/browser-lane}"
mkdir -p "$base"
if [ ! -s "$base/token" ]; then
  token="$(openssl rand -hex 24)"
  printf '%s\n' "$token" > "$base/token"
  chmod 600 "$base/token"
  echo "lane token written: $base/token (0600)"
else
  echo "lane token present: $base/token"
fi

echo "installed: $target_dir/masc_browser_host.json -> $wrapper"
echo "extension source to load (about:debugging → Load Temporary Add-on):"
echo "  $here/extension/manifest.json"
