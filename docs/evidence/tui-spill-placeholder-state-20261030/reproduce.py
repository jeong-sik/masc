#!/usr/bin/env python3
"""Compile exact spill sources and their tests with a small layout shim."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True)
parser.add_argument('--candidate', required=True, help='Git revision, or WORKTREE while developing')
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
here = Path(__file__).resolve().parent

def source(rev, name):
    if rev == 'WORKTREE':
        return (root / name).read_text()
    return subprocess.check_output(['git', 'show', f'{rev}:{name}'], cwd=root, text=True)

def layout(rev):
    contents = source(rev, 'bin/masc_tui_message_layout.ml')
    match = re.search(r'^let composer_max_rows = ([0-9]+)$', contents, re.M)
    assert match
    return f'let composer_max_rows = {match.group(1)}\n'

def shared(rev, directory):
    (directory / 'masc_tui_message_layout.ml').write_text(layout(rev))
    (directory / 'keeper_paste_naming.ml').write_text(source(rev, 'lib/keeper_paste_naming/keeper_paste_naming.ml'))
    (directory / 'string_util.ml').write_text(source(rev, 'lib/string_util/string_util.ml'))

for name in ['lib/keeper_paste_naming/keeper_paste_naming.ml', 'lib/string_util/string_util.ml']:
    assert source(args.baseline, name) == source(args.candidate, name)
assert layout(args.baseline) == layout(args.candidate)

for label, rev in [('old', args.baseline), ('new', args.candidate)]:
    directory = out / ('tests-' + label)
    directory.mkdir(exist_ok=True)
    shared(rev, directory)
    for name in ['bin/masc_tui_paste_spill.ml', 'bin/masc_tui_paste_spill.mli', 'test/test_tui_paste_spill.ml']:
        (directory / Path(name).name).write_text(source(rev, name))
    subprocess.run(['ocamlfind', 'ocamlopt', '-O3', '-package', 'alcotest', '-linkpkg', '-o', 'test_spill',
                    'masc_tui_message_layout.ml', 'keeper_paste_naming.ml', 'string_util.ml',
                    'masc_tui_paste_spill.mli', 'masc_tui_paste_spill.ml', 'test_tui_paste_spill.ml'],
                   cwd=directory, check=True)
    print('Running', label, 'repository tests', flush=True)
    subprocess.run(['./test_spill', '--color=never'], cwd=directory, check=True)

    types = source(rev, 'bin/masc_tui_types.ml')
    start = types.index('let message_spill_in_text (state : state) text =\n')
    end = types.index('\nlet expand_message_draft_spill', start)
    extracted = types[start:end]
    (directory / 'state_check.ml').write_text('''type state = { msg_spill : Masc_tui_paste_spill.t option }\n''' + extracted + '''
let () =
  let spill = Option.get (Masc_tui_paste_spill.of_paste ~now_iso:"20261030" ~nonce:"abc" (String.make 8193 'x')) in
  let marker = Masc_tui_paste_spill.draft_line spill in
  assert (message_spill_in_text {msg_spill=None} marker = None);
  assert (message_spill_in_text {msg_spill=Some spill} "missing" = None);
  assert (message_spill_in_text {msg_spill=Some spill} ("x" ^ marker ^ "y") = Some spill);
  print_endline "extracted message_spill_in_text passed"
''')
    subprocess.run(['ocamlfind', 'ocamlopt', '-O3', '-o', 'state_check',
                    'masc_tui_message_layout.ml', 'keeper_paste_naming.ml', 'string_util.ml',
                    'masc_tui_paste_spill.ml', 'state_check.ml'], cwd=directory, check=True)
    subprocess.run(['./state_check'], cwd=directory, check=True)

directory = out / 'compare'
directory.mkdir(exist_ok=True)
shared(args.candidate, directory)
(directory / 'old_spill.ml').write_text(source(args.baseline, 'bin/masc_tui_paste_spill.ml'))
(directory / 'new_spill.ml').write_text(source(args.candidate, 'bin/masc_tui_paste_spill.ml'))
shutil.copyfile(here / 'harness.ml.txt', directory / 'harness.ml')
subprocess.run(['ocamlfind', 'ocamlopt', '-O3', '-package', 'unix', '-linkpkg', '-o', 'compare',
                'masc_tui_message_layout.ml', 'keeper_paste_naming.ml', 'string_util.ml',
                'old_spill.ml', 'new_spill.ml', 'harness.ml'], cwd=directory, check=True)
subprocess.run(['./compare', 'samples.csv'], cwd=directory, check=True)
