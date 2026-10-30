#!/usr/bin/env python3
"""Run the real JSONL module and focused tests in the OCaml interpreter.

Only Fs_compat.file_size is replaced with its synchronous Unix.stat behavior.
This does not exercise Eio, the server, or native-code performance. No Dune
build is performed. The output directory retains exact sources and hashes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--before', default='68ec8fb2c52545c68600928524dcc12945e55ee7')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = args.repo.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
relative = 'lib/jsonl_incremental_projection.ml'
sources = {
    'baseline': subprocess.check_output(['git', 'show', f'{args.before}:{relative}'], cwd=repo),
    'candidate': (repo / relative).read_bytes(),
}
prelude = '''#use "topfind";;
#require "unix";;
module Fs_compat = struct
  let file_size path = try Some (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> None
end;;
'''
def quoted(path):
    return json.dumps(str(path), ensure_ascii=False)

def run(name, source):
    runner = out / f'{name}.ml'
    runner.write_text(source)
    with (out / f'{name}.txt').open('w') as log:
        return subprocess.run(['ocaml', '-noinit', str(runner)], cwd=out,
                              stdout=log, stderr=subprocess.STDOUT).returncode

manifest = {'before_ref': args.before, 'scope': __doc__, 'sha256': {}, 'exit_codes': {}}
for label, source in sources.items():
    path = out / f'jsonl_{label}.ml'
    path.write_bytes(source)
    manifest['sha256'][label] = hashlib.sha256(source).hexdigest()
    code = prelude + '#require "alcotest";;\n'
    code += f'#mod_use {quoted(path)};;\n'
    code += f'module Masc = struct module Jsonl_incremental_projection = Jsonl_{label} end;;\n'
    code += f'#use {quoted(repo / "test/test_jsonl_incremental_projection.ml")};;\n'
    manifest['exit_codes'][label] = run(f'tests_{label}', code)
code = prelude + '#require "mtime.clock.os";;\n'
for label in sources:
    code += f'#mod_use {quoted(out / f"jsonl_{label}.ml")};;\n'
code += f'#mod_use {quoted(Path(__file__).resolve().with_name("jsonl_probe.ml"))};;\n'
manifest['exit_codes']['benchmark'] = run('benchmark', code)
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
# The old source is intentionally exercised against the new reproduction.
raise SystemExit(0 if manifest['exit_codes'] == {'baseline': 1, 'candidate': 0, 'benchmark': 0} else 1)
