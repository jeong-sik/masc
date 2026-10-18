#!/bin/sh
# Native plug-ins stay on the user's audio host, outside Lane containers.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
python=python3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || exit 2; prefix=$2; shift 2 ;;
    --python) [ "$#" -ge 2 ] || exit 2; python=$2; shift 2 ;;
    *) printf '%s\n' 'usage: scripts/install-vst-host.sh [--prefix /path/to/bin] [--python python3]' >&2; exit 2 ;;
  esac
done
"$python" -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12 or newer is required"'
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
revision=$("$python" - "$repo_root/tools/vst" <<'FINGERPRINT'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
digest = hashlib.sha256()
for name in ('host.py', 'requirements.lock'):
    digest.update(name.encode() + b'\0' + (root / name).read_bytes() + b'\0')
print(digest.hexdigest())
FINGERPRINT
)
runtime="$prefix/../share/masc/vst/$revision"
if [ ! -f "$runtime/.installed" ]; then
  mkdir -p "$runtime"
  install -m 644 "$repo_root/tools/vst/host.py" "$runtime/host.py"
  install -m 644 "$repo_root/tools/vst/requirements.lock" "$runtime/requirements.lock"
  "$python" -m venv "$runtime/.venv"
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$runtime/.venv/bin/python" --require-hashes -r "$runtime/requirements.lock"
  else
    "$runtime/.venv/bin/python" -m pip install --require-hashes -r "$runtime/requirements.lock"
  fi
  # Discovery does not load every installed plug-in or open its editor.
  printf '%s\n' '{"operation":"candidates"}' | "$runtime/.venv/bin/python" "$runtime/host.py" > /dev/null
  touch "$runtime/.installed"
fi
launcher=$(mktemp "$prefix/.masc-vst-host.XXXXXX")
trap 'rm -f "$launcher"' EXIT HUP INT TERM
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER
printf 'exec "$bin_dir/../share/masc/vst/%s/.venv/bin/python" "$bin_dir/../share/masc/vst/%s/host.py" "$@"\n' "$revision" "$revision" >> "$launcher"
chmod 755 "$launcher"
mv -f "$launcher" "$prefix/masc-vst-host"
printf 'Installed native VST host %s\n' "$revision"
