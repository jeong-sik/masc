"""Compile/run actual activity leaf sources in isolation, not the full TUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

args = argparse.ArgumentParser()
args.add_argument('--label', choices=['before', 'after'], required=True)
label = args.parse_args().label
root = Path.cwd()
evidence = Path(__file__).resolve().parent
scratch = Path(tempfile.mkdtemp(prefix='masc-tui-browser-activity-'))
configured = os.environ.get('ACTIVITY_OCAML_BIN')
found = shutil.which('ocamlc') if configured is None else None
if configured is None and found is None:
    raise RuntimeError('Set ACTIVITY_OCAML_BIN to an OCaml 5.5.1 bin directory')
compiler = Path(configured) if configured is not None else Path(found).parent
env = {**os.environ, 'PATH': str(compiler) + os.pathsep + os.environ['PATH'], 'NO_COLOR': '1'}
version = subprocess.check_output([str(compiler / 'ocamlc'), '-version'], text=True).strip()
if version != '5.5.1':
    raise RuntimeError('Expected OCaml 5.5.1, got ' + version)
paths = ['lib/runtime_toml_namespace/runtime_toml_namespace',
         'lib/browser_configuration/browser_configuration',
         'lib/browser_lane/browser_lane_name', 'browser_lane',
         'lib/toml_line_editor/toml_line_editor', 'bin/masc_tui_runtime_config_edit',
         'bin/masc_tui_runtime_config_receipt', 'bin/masc_tui_browser_activity', 'test/test_tui_browser_activity']
(scratch/'browser_lane.ml').write_text('module Lane_name = Browser_lane_name\n')
sources, commands = {}, []
for path in paths:
    for suffix in ('.mli', '.ml'):
        source = root / (path + suffix)
        if source.exists():
            shutil.copyfile(source, scratch / source.name)
            sources[path + suffix] = hashlib.sha256(source.read_bytes()).hexdigest()


def run(command):
    print('+ ' + ' '.join(command), flush=True)
    result = subprocess.run(command, cwd=scratch, env=env)
    commands.append({'command': command, 'returncode': result.returncode})
    result.check_returncode()


try:
    packages = 'otoml,yojson,alcotest,ppx_enumerate,ppx_deriving.show,ppx_deriving.eq'
    for path in paths:
        name = Path(path).name
        for suffix in ('.mli', '.ml'):
            if (scratch / (name + suffix)).exists():
                run(['ocamlfind', 'ocamlc', '-package', packages, '-w', '+32+69', '-warn-error', '+a', '-c', name + suffix])
    run(['ocamlfind', 'ocamlc', '-package', packages, '-linkpkg',
         *[Path(path).name + '.cmo' for path in paths], '-o', 'test.exe'])
    run(['./test.exe'])
finally:
    (evidence / (label + '-provenance.json')).write_text(json.dumps({
        'scope': 'Actual Browser activity draft sources/tests; Browser_lane is a namespace alias to the actual Lane_name source only. No dispatch stub. Not full TUI type/link, PTY, backend or deployment.',
        'compiler': version, 'sources': sources, 'commands': commands, 'directory': str(scratch)}, indent=2) + '\n')
