#!/bin/sh
# Build a self-contained Yjs transformer; no source checkout is needed at runtime.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != '--prefix' ]; then
    printf '%s\n' 'usage: scripts/install-artifact-document.sh [--prefix /path/to/bin]' >&2
    exit 2
  fi
  prefix=$2
fi
command -v node >/dev/null 2>&1
command -v pnpm >/dev/null 2>&1
pnpm --dir "$repo_root/dashboard" exec vite build --config vite.artifact-document.config.ts
bundle="$repo_root/dashboard/dist-artifact-document/artifact-document.mjs"
revision=$(node --input-type=module - "$bundle" <<'HASH'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
console.log(createHash('sha256').update(readFileSync(process.argv[2])).digest('hex'))
HASH
)
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
support_dir="$prefix/../share/masc/artifact-document/$revision"
mkdir -p "$support_dir"
if [ ! -f "$support_dir/artifact-document.mjs" ]; then
  install -m 644 "$bundle" "$support_dir/artifact-document.mjs"
fi
launcher=$(mktemp "$prefix/.masc-artifact-document.XXXXXX")
trap 'rm -f "$launcher"' EXIT HUP INT TERM
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER
printf 'exec node "$bin_dir/../share/masc/artifact-document/%s/artifact-document.mjs"\n' "$revision" >> "$launcher"
chmod 755 "$launcher"
printf '%s\n' '{"kind":"seed","content":"설치 확인 😀"}' | "$launcher" >/dev/null
mv -f "$launcher" "$prefix/masc-artifact-document"
printf 'Installed %s/masc-artifact-document (%s)\n' "$prefix" "$revision"
