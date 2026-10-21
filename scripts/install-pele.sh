#!/bin/sh
# Keep the JS renderer separate from the OCaml binary, like alphaTex.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != '--prefix' ]; then
    printf '%s\n' 'usage: scripts/install-pele.sh [--prefix /path/to/bin]' >&2
    exit 2
  fi
  prefix=$2
fi
command -v node >/dev/null 2>&1
command -v pnpm >/dev/null 2>&1
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) throw Error("Node.js 22 or newer is required")'
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
runtime_files='package.json pnpm-lock.yaml engine.mjs render.mjs'
revision=$(node --input-type=module - "$repo_root/tools/pele" $runtime_files <<'FINGERPRINT'
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const hash = createHash('sha256');
for (const name of process.argv.slice(3)) {
  hash.update(name).update('\0').update(readFileSync(join(process.argv[2], name))).update('\0');
}
console.log(hash.digest('hex'));
FINGERPRINT
)
support_root="$prefix/../share/masc/pele"
support_dir="$support_root/$revision"
mkdir -p "$support_root"
staging=''
launcher=''
trap 'test -z "$staging" || rm -rf "$staging"; test -z "$launcher" || rm -f "$launcher"' EXIT HUP INT TERM
if [ ! -d "$support_dir" ]; then
  staging=$(mktemp -d "$support_root/.install.XXXXXX")
  for file in $runtime_files; do
    install -m 644 "$repo_root/tools/pele/$file" "$staging/$file"
  done
  pnpm --dir "$staging" install --prod --frozen-lockfile --ignore-scripts
  printf '%s\n' '{"format":"mermaid","source":"flowchart TD\n A --> B","maxWidth":640}' |
    node "$staging/render.mjs" >/dev/null
  # A concurrent installer may already have published the identical runtime.
  node --input-type=module - "$staging" "$support_dir" <<'PUBLISH'
import { renameSync, existsSync } from 'node:fs';
try { renameSync(process.argv[2], process.argv[3]); }
catch (error) { if (!existsSync(process.argv[3])) throw error; }
PUBLISH
fi
launcher=$(mktemp "$prefix/.masc-pele.XXXXXX")
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER
printf 'exec node "$bin_dir/../share/masc/pele/%s/render.mjs" "$@"\n' "$revision" >> "$launcher"
chmod 755 "$launcher"
mv -f "$launcher" "$prefix/masc-pele"
"$prefix/masc-pele" --help
