#!/usr/bin/env python3
"""Compare exact transcript functions using explicit synthetic TUI records."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True)
parser.add_argument('--candidate', help='candidate commit; default is the current worktree')
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--rejected', action='store_true', help='reproduce the rejected duplicate-ID mismatch')
args = parser.parse_args()
root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
here = Path(__file__).resolve().parent
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
path = 'bin/masc_tui_keeper_chat_transcript.ml'
def read_rev(rev):
    return subprocess.check_output(['git', 'show', f'{rev}:{path}'], cwd=root, text=True)
def section(source, start, end):
    assert source.count(start) == 1, start
    tail = source.split(start, 1)[1]
    assert end in tail, end
    return start + tail.split(end, 1)[0]

before = read_rev(args.baseline)
after = read_rev(args.candidate) if args.candidate else (root / path).read_text()
old = section(before, 'let update_local_call t local_id f =\n', '\nlet update_unique_call ')
new = section(after, 'let rec has_local_id local_id = function\n', '\nlet update_unique_call ')
helpers = section(before, 'let same_occurrence\n', '\nlet occurrence_label ')
assert helpers == section(after, 'let same_occurrence\n', '\nlet occurrence_label ')
old_occurrence = section(before, 'let update_occurrence t occurrence f =\n', '\nlet apply_tool_result ')
new_occurrence = section(after, 'let update_occurrence t occurrence f =\n', '\nlet apply_tool_result ')
for name, source in [('old.ml.txt',old),('new.ml.txt',new),('helpers.ml.txt',helpers),
                     ('old-occurrence.ml.txt',old_occurrence),('new-occurrence.ml.txt',new_occurrence)]:
    (out/name).write_text(source)

def compile_run(template, name, substitutions):
    text = (here/template).read_text()
    for marker, source in substitutions:
        assert text.count(marker)==1
        text=text.replace(marker,source)
    (out/(name+'.ml')).write_text(text)
    subprocess.run(['ocamlfind','ocamlopt','-O3','-package','unix','-linkpkg',
                    '-o',name,name+'.ml'],cwd=out,check=True)
    subprocess.run(['./'+name,name+'-samples.csv'],cwd=out,check=True)

if args.rejected:
    rejected=(here/'rejected-first-match.ml.txt').read_text()
    compile_run('rejected_example.ml.txt','rejected',[('(* OLD *)',old),('(* NEW *)',rejected)])
else:
    compile_run('harness.ml.txt','replace',[('(* OLD *)',old),('(* NEW *)',new)])
    compile_run('occurrence_harness.ml.txt','occurrence',
                [('(* HELPERS *)',helpers),('(* OLD *)',old),('(* NEW *)',new),
                 ('(* OLD_OCCURRENCE *)',old_occurrence),('(* NEW_OCCURRENCE *)',new_occurrence)])
