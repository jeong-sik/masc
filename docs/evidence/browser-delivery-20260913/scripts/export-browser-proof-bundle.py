import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--runtime-dir', type=Path, required=True)
parser.add_argument('--source-commit', required=True)
parser.add_argument('--out-dir', type=Path, required=True)
args = parser.parse_args()
runtime = args.runtime_dir.resolve()
source = json.loads((runtime / 'runtime-provenance.json').read_text())['source_commit']
assert source == args.source_commit, 'runtime provenance differs from requested source'
server = runtime / 'masc-macos-arm64'
out = args.out_dir.resolve()
out.mkdir(parents=True, exist_ok=False)
env = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'USER', 'LOGNAME', 'SHELL')}
manifest = {'source_commit': source, 'server_sha256': hashlib.sha256(server.read_bytes()).hexdigest(),
            'packages': {}, 'exports': [], 'origin': 'candidate binary skills-refresh --export-to'}
for name in ('browser-lanes', 'browser-navigate-content'):
    command = [str(server), 'skills-refresh', '--base-path', str(out / 'workspace'),
               name, '--export-to', str(out / name)]
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    manifest['exports'].append({'package': name, 'exit_code': result.returncode,
                                'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        manifest['result'] = 'export_failed'
        (out / 'export-failure.json').write_text(json.dumps(manifest, indent=2))
        print('Bundle export failed for', name, '- no source-tree fallback; receipt:', out / 'export-failure.json')
        raise SystemExit(result.returncode)
    package = out / name
    assert (package / 'SKILL.md').is_file()
    manifest['packages'][name] = {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(package.rglob('*')) if p.is_file()}
manifest['result'] = 'exported'
(out / 'bundle.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps({'result': 'exported', 'source_commit': source, 'packages': list(manifest['packages']), 'manifest': str(out / 'bundle.json')}))
