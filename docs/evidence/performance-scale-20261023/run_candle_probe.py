#!/usr/bin/env python3
"""Interpret pinned historical Candle and observation-sequence sources.

Portrait enumerations use the installed ppx_enumerate, as in their Dune file.
Only pure Candle configuration/observation declarations and functions are loaded;
this does not run the ledger I/O, Eio, HTTP handlers, or the installed server.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--before', default='fce421ab4966cfe07b22f65cd06dd73b59da38f7')
parser.add_argument('--after', default='196f1f7134dc0bb3835c5e1d74e19d4cd4c6871c')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, out = args.repo.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
source_root = out / 'source'
manifest = {'before': args.before, 'after': args.after, 'scope': __doc__, 'source_sha256': {}}

def quoted(path):
    return '"' + ''.join(f'\\{byte:03d}' for byte in os.fsencode(path)) + '"'

def read(path):
    source = subprocess.check_output(['git', 'show', f'{args.after}:{path}'], cwd=repo)
    manifest['source_sha256'][path] = hashlib.sha256(source).hexdigest()
    destination = source_root / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(source)
    return source.decode()

def execute(name, code, extra=()):
    runner = out / f'{name}.ml'
    runner.write_text(code)
    with (out / f'{name}.txt').open('w') as log:
        subprocess.run(['ocaml', '-noinit', str(runner), *extra], cwd=out,
                       stdout=log, stderr=subprocess.STDOUT, check=True)

ppx = '''#use "topfind";;
Topfind.add_predicates ["ppx_driver"];;
#require "ppx_enumerate,ppxlib";;
Ppxlib.Driver.standalone ();;
'''
portraits = ['keeper_portrait_look', 'keeper_portrait_item']
for name in portraits:
    source = f'lib/keeper_portrait/{name}.ml'
    read(source)
    execute(f'ppx_{name}', ppx, ['-impl', str(source_root/source), '-o', str(out/f'{name}.ml')])
paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', args.after,
                                 'lib/candle'], cwd=repo, text=True).splitlines()
paths = [path for path in paths if path.endswith('.ml')]
paths += [f'lib/keeper_portrait/{name}.ml' for name in portraits]
for path in paths:
    read(path)
files = [source_root/path for path in paths]
ordered = subprocess.check_output(['ocamldep', '-sort', *map(str, files)], text=True).split()
prelude = '#use "topfind";;\n#require "yojson,ptime,zarith,digestif.c,ppx_enumerate.runtime-lib";;\n'
read('lib/shared_types/json_kind.ml')
prelude += f'#mod_use {quoted(source_root/"lib/shared_types/json_kind.ml")};;\n'
prelude += 'module Shared_types = struct module Json_kind = Json_kind end;;\n'
kind = next(line for line in read('lib/core/json_util.ml').splitlines() if line.startswith('let kind_name ='))
prelude += f'module Json_util = struct {kind} end;;\n'
for file in ordered:
    path = Path(file)
    if path.stem in portraits:
        path = out / path.name
    prelude += f'#mod_use {quoted(path)};;\n'
read('test/test_candle_balance.ml')
execute('balance_tests', prelude + '#require "alcotest";;\n'
        + f'#use {quoted(source_root/"test/test_candle_balance.ml")};;\n')
code = prelude + '#require "threads";;\n'
config = read('lib/candle_config/candle_config.ml').split(' type t =', 1)[0]
observation = read('lib/candle_runtime/candle_observe.ml').split('let read ~now', 1)[0]
code += f'module Candle_config = struct\n{config}\nend;;\n'
code += f'module Candle_observe = struct\n{observation}\nend;;\n'
relative = 'lib/dashboard/dashboard_projection_cache.ml'
before = subprocess.check_output(['git', 'show', f'{args.before}:{relative}'], cwd=repo, text=True)
manifest['before_sequence_source_sha256'] = hashlib.sha256(before.encode()).hexdigest()
for label, source in [('Before', before), ('After', read(relative))]:
    fragment = source[source.index('let candle_read_sequence ='):source.index('let with_current_keeper_observations_using')]
    code += f'module {label} = struct\n{fragment}\nend;;\n'
cases = read('docs/evidence/performance-scale-20261023/candle_sequence_cases.ml')
execute('sequence_probe', code + cases)
(out/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print((out/'balance_tests.txt').read_text())
print((out/'sequence_probe.txt').read_text())
