#!/usr/bin/env python3
"""Compile actual trail sources against explicit event/redactor shims; never run Dune."""
import argparse
import pathlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True)
candidate_option = parser.add_mutually_exclusive_group()
candidate_option.add_argument('--candidate', help='commit containing candidate source; default is working tree')
candidate_option.add_argument('--candidate-file', type=pathlib.Path, help='saved exploratory candidate')
parser.add_argument('--out', required=True, type=pathlib.Path)
parser.add_argument('--scenario', choices=['valid', 'initial'], default='valid')
args = parser.parse_args()
root = pathlib.Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
here = pathlib.Path(__file__).resolve().parent
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)

def git_file(rev, path):
    return subprocess.check_output(['git', 'show', f'{rev}:{path}'], cwd=root)

def write(path, data):
    path.write_bytes(data)

def common(path):
    path.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(here / 'keeper_chat_events.ml', path / 'keeper_chat_events.ml')
    for source, name in [('lib/secret_patterns/secret_patterns.ml', 'secret_patterns.ml'),
                         ('lib/keeper/keeper_text_processing.ml', 'keeper_text_processing.ml')]:
        write(path / name, git_file(args.baseline, source))
    # This is the exact body used by Observability_redact.redact_text; the rest
    # of that module depends on unrelated product modules.
    (path / 'observability_redact.ml').write_text('let redact_text = Secret_patterns.redact_text\n')

trail = 'lib/keeper/keeper_chat_tool_trail.ml'
interface = 'lib/keeper/keeper_chat_tool_trail.mli'
test_path = 'test/test_keeper_chat_tool_trail.ml'
candidate = (args.candidate_file.read_bytes() if args.candidate_file else
             git_file(args.candidate, trail) if args.candidate else (root / trail).read_bytes())
test = git_file(args.candidate, test_path) if args.candidate else (root / test_path).read_bytes()
sources = [
    'secret_patterns.ml', 'keeper_text_processing.ml', 'keeper_chat_events.ml',
    'observability_redact.ml', 'keeper_chat_tool_trail.mli', 'keeper_chat_tool_trail.ml',
    'masc.ml', 'test_keeper_chat_tool_trail.ml',
]
for label, source in [('old', git_file(args.baseline, trail)), ('new', candidate)]:
    path = out / label
    common(path)
    write(path / 'keeper_chat_tool_trail.ml', source)
    write(path / 'keeper_chat_tool_trail.mli', git_file(args.baseline, interface))
    write(path / 'test_keeper_chat_tool_trail.ml', test)
    (path / 'masc.ml').write_text('module Keeper_chat_tool_trail = Keeper_chat_tool_trail\nmodule Keeper_chat_events = Keeper_chat_events\n')
    subprocess.run(['ocamlfind', 'ocamlopt', '-O3', '-package', 'yojson,re,alcotest',
                    '-linkpkg', '-o', 'trail_tests', *sources], cwd=path, check=True)
    print(f'Running {label} source against the same test file:', flush=True)
    subprocess.run(['./trail_tests', '--color=never'], cwd=path, check=True)

path = out / 'compare'
common(path)
write(path / 'old_trail.ml', git_file(args.baseline, trail))
write(path / 'new_trail.ml', candidate)
benchmark_name = 'equivalence_bench.ml.txt' if args.scenario == 'valid' else 'equivalence_bench-initial.ml.txt'
shutil.copyfile(here / benchmark_name, path / 'equivalence_bench.ml')
subprocess.run(['ocamlfind', 'ocamlopt', '-O3', '-package', 'yojson,re,unix', '-linkpkg',
                '-o', 'equivalence_bench', 'secret_patterns.ml', 'keeper_text_processing.ml',
                'keeper_chat_events.ml', 'observability_redact.ml', 'old_trail.ml', 'new_trail.ml',
                'equivalence_bench.ml'], cwd=path, check=True)
subprocess.run(['./equivalence_bench', str(path / 'samples.csv')], cwd=path, check=True)
