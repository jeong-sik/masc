#!/bin/sh
# Install the official-engine terminal viewer separately from the OCaml build.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${HOME}/.local/bin
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--prefix" ]; then
    printf '%s\n' 'usage: scripts/install-alphatex.sh [--prefix /path/to/bin]' >&2
    exit 2
  fi
  prefix=$2
fi
command -v node >/dev/null 2>&1 || { printf '%s\n' 'Node.js 22 or newer is required' >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { printf '%s\n' 'pnpm is required to install the locked viewer dependencies' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)'
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd)
runtime_files='package.json pnpm-lock.yaml engine.mjs audio.mjs diagnostics.mjs worker.mjs terminal.mjs viewer.mjs'
revision=$(node --input-type=module - "$repo_root/tools/alphatex" $runtime_files <<'FINGERPRINT'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
const hash = createHash('sha256')
for (const name of process.argv.slice(3)) {
  hash.update(name).update('\0').update(readFileSync(join(process.argv[2], name))).update('\0')
}
console.log(hash.digest('hex'))
FINGERPRINT
)
support_dir="$prefix/../share/masc/alphatex/$revision"
if [ ! -f "$support_dir/.installed" ]; then
  mkdir -p "$support_dir"
  for file in $runtime_files; do
    install -m 644 "$repo_root/tools/alphatex/$file" "$support_dir/$file"
  done
  pnpm --dir "$support_dir" install --prod --frozen-lockfile
  # Prove the native backend can load before changing an installed launcher.
  node --input-type=module -e '
    import { pathToFileURL } from "node:url";
    import { resolve } from "node:path";
    const engine = await import(pathToFileURL(resolve(process.argv[1], "engine.mjs")));
    engine.renderScore(":4 0.6", {page: 0});
  ' "$support_dir"
  touch "$support_dir/.installed"
fi
# The relative layout is shared by every prefix; no checkout or workspace path
# is embedded in the launcher and the installed viewer survives worktree removal.
launcher=$(mktemp "$prefix/.masc-alphatex.XXXXXX")
trap 'rm -f "$launcher"' EXIT HUP INT TERM
cat > "$launcher" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER
printf 'exec node "$bin_dir/../share/masc/alphatex/%s/viewer.mjs" "$@"\n' "$revision" >> "$launcher"
chmod 755 "$launcher"
mv -f "$launcher" "$prefix/masc-alphatex"
"$prefix/masc-alphatex" --help
