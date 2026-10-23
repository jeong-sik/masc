#!/usr/bin/env python3
"""Interpret complete before/after metadata-key modules with their signatures.

Checks exact result equality for malformed/reordered keys, then measures warm
valid objects. No metadata value decoding, filesystem I/O, Eio, native server
or active Keeper behavior is measured.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--before', default='5f1002b04848ca14506155a55211e099bdb916c9')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, out = args.repo.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
manifest = {'before': args.before, 'scope': __doc__, 'source_sha256': {}}


def read(path):
    content = (repo/path).read_text()
    manifest['source_sha256'][path] = hashlib.sha256(content.encode()).hexdigest()
    return content


relative = 'lib/keeper/keeper_meta_json_current_schema'
code = '#use "topfind";;\n#require "yojson,mtime.clock.os";;\n'
code += 'module Json_kind = struct\n' + read('lib/shared_types/json_kind.ml') + '\nend;;\n'
code += 'module Shared_types = struct module Json_kind = Json_kind end;;\n'
kind = next(line for line in read('lib/core/json_util.ml').splitlines()
            if line.startswith('let kind_name ='))
code += f'module Json_util = struct {kind} end;;\n'
for label in ('Before', 'After'):
    parts = {}
    for extension in ('ml', 'mli'):
        path = f'{relative}.{extension}'
        content = (subprocess.check_output(['git', 'show', f'{args.before}:{path}'],
                   cwd=repo, text=True) if label == 'Before' else read(path))
        manifest['source_sha256'][f'{label}:{path}'] = hashlib.sha256(content.encode()).hexdigest()
        parts[extension] = content
    code += f'module {label} : sig\n{parts["mli"]}\nend = struct\n{parts["ml"]}\nend;;\n'
fixture = read('test/fixtures/item-http/keeper.json')
code += f'let fixture = Yojson.Safe.from_string {json.dumps(fixture)};;\n'
code += read('docs/evidence/performance-scale-20261023/meta_key_cases.ml')
runner = out/'probe.ml'
runner.write_text(code)
(out/'sources.json').write_text(json.dumps(manifest, indent=2)+'\n')
with (out/'measurements.csv').open('w') as output, (out/'checks.txt').open('w') as errors:
    subprocess.run(['ocaml', '-noinit', str(runner)], cwd=out,
                   stdout=output, stderr=errors, check=True)
print((out/'checks.txt').read_text(), end='')
print(f'Measurements: {out / "measurements.csv"}')
