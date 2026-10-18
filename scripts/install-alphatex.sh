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
support_dir="$prefix/../share/masc/alphatex"
mkdir -p "$support_dir"
for file in package.json pnpm-lock.yaml engine.mjs audio.mjs diagnostics.mjs worker.mjs terminal.mjs viewer.mjs; do
  install -m 644 "$repo_root/tools/alphatex/$file" "$support_dir/$file"
done
pnpm --dir "$support_dir" install --prod --frozen-lockfile
# The relative layout is shared by every prefix; no checkout or workspace path
# is embedded in the launcher and the installed viewer survives worktree removal.
cat > "$prefix/masc-alphatex" <<'LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec node "$bin_dir/../share/masc/alphatex/viewer.mjs" "$@"
LAUNCHER
chmod 755 "$prefix/masc-alphatex"
"$prefix/masc-alphatex" --help
