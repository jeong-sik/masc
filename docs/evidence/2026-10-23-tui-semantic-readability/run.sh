#!/usr/bin/env bash
set -euo pipefail
task_repo="$(git rev-parse --show-toplevel)"
task_evidence="$task_repo/docs/evidence/2026-10-23-tui-semantic-readability"
task_output="$(mktemp -d "${TMPDIR:-/tmp}/masc-tui-contrast.XXXXXX")"
for task_module in masc_tui_terminal_palette masc_tui_color masc_tui_theme; do
  cp "$task_repo/bin/$task_module.ml" "$task_repo/bin/$task_module.mli" "$task_output/"
done
cp "$task_repo/bin/masc_tui_terminal_palette_stubs.c" "$task_evidence/probe.ml" "$task_output/"
python3 - "$task_repo" "$task_output" <<'PY'
import pathlib, sys, tomllib
repo, output = map(pathlib.Path, sys.argv[1:])
rows = []
for source in sorted((repo / 'config/themes').glob('*.toml')):
    palette = tomllib.loads(source.read_text()).get('palette', {})
    if 'base00' in palette and 'base05' in palette:
        rows.append('\t'.join((source.stem, palette['base05'], palette['base00'])))
(output / 'themes.tsv').write_text('\n'.join(rows) + '\n')
PY
cd "$task_output"
ocamlopt -I +unix -w +4+32+69 -warn-error +a -c \
  masc_tui_terminal_palette.mli masc_tui_terminal_palette.ml \
  masc_tui_color.mli masc_tui_color.ml masc_tui_theme.mli masc_tui_theme.ml
ocamlopt -c masc_tui_terminal_palette_stubs.c
ocamlopt -I +unix -o probe unix.cmxa masc_tui_terminal_palette_stubs.o \
  -cclib -lncurses masc_tui_terminal_palette.cmx masc_tui_color.cmx masc_tui_theme.cmx probe.ml
./probe > results.tsv
NO_COLOR=1 MASC_TUI_FORCE_COLOR=0 ./probe --no-color-env > no-color-env.txt
echo "Standalone colour observations: $task_output/results.tsv"
