from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = Path('/Users/dancer/me/workspace/yousleepwhen/masc')
WORK = Path('/Users/dancer/.codex/worktrees/window-shrink-snapshot-20261117/masc')
REVISION = 'c97d0f9b850c812885a7f89a4fcdc280a6738416'
PREVIOUS = REPO / 'artifacts/cpu-memory-20261116/gc-retention-offline-audit-20261117/window-error-proof-r1/commands.json'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    root = ROOT / 'native-r1'
    root.mkdir()
    old = json.loads(PREVIOUS.read_text())
    argv = old[0]['argv']
    prefix = [argv[0], '-I', str(root)] + argv[3:-2]
    link = next(row['argv'] for row in old if row['label'] == 'link')
    link = link[:link.index('-o')]
    manifest = {'base': REVISION, 'sources': {}, 'scope': 'Complete actual Window/codec, complete adapter MLI and ML with one leading alias seam; prebuilt real dependencies; no Dune, product build or runtime operation'}
    units = [
        ('window_under_base', 'lib/runtime/runtime_model_input_tail_window', True, False),
        ('window_under_test', 'lib/runtime/runtime_model_input_tail_window', False, False),
        ('codec_under_test', 'lib/keeper/keeper_official_client_context_codec', False, False),
        ('claude_under_test', 'lib/keeper/keeper_claude_code_runtime', False, True),
        ('codex_under_test', 'lib/keeper/keeper_codex_runtime', False, True),
    ]
    for unit, path, baseline, alias in units:
        for suffix in ['mli', 'ml']:
            source_path = path + '.' + suffix
            data = (subprocess.check_output(['git', 'show', REVISION + ':' + source_path], cwd=REPO)
                    if baseline else (WORK / source_path).read_bytes())
            transformed = (b'module Runtime_model_input_tail_window = Window_under_test\n' + data
                           if alias and suffix == 'ml' else data)
            name = unit + '.' + suffix
            (root / name).write_bytes(transformed)
            manifest['sources'][name] = {'path': source_path, 'source_sha256': digest(data),
                'compiled_sha256': digest(transformed), 'baseline': baseline,
                'transformation': 'one leading module alias' if transformed != data else 'basename only'}
    source = (WORK / 'test/test_runtime_model_input_tail_window.ml').read_bytes()
    transformed = source.replace(b'module Window = Runtime_model_input_tail_window', b'module Window = Window_under_test').replace(b'Keeper_official_client_context_codec.', b'Codec_under_test.')
    (root / 'window_suite.ml').write_bytes(transformed)
    manifest['sources']['window_suite.ml'] = {'path': 'test/test_runtime_model_input_tail_window.ml',
        'source_sha256': digest(source), 'compiled_sha256': digest(transformed),
        'transformation': 'Window and codec aliases only; complete maintained suite'}
    manifest['prebuilt_archives'] = {arg: digest(Path(arg).read_bytes()) for arg in link if arg.endswith('.cmxa')}
    records = []
    def execute(label, command, env=None):
        start = time.monotonic()
        result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
        records.append({'label': label, 'argv': command, 'exit_code': result.returncode,
                        'wall_seconds': time.monotonic() - start})
        (root / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
        (root / (label + '.stdout')).write_text(result.stdout)
        (root / (label + '.stderr')).write_text(result.stderr)
        (root / 'input-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(label, result.returncode, flush=True)
        if result.returncode:
            print(result.stderr[:6500], flush=True)
            raise SystemExit(result.returncode)
    for unit, _, _, _ in units:
        for suffix in ['mli', 'ml']:
            execute(unit + '.' + suffix, prefix + ['-c', unit + '.' + suffix])
    execute('window_suite.ml', prefix + ['-c', 'window_suite.ml'])
    execute('window_suite.link', link + ['-o', str(root / 'window_suite.exe'),
        str(root / 'window_under_test.cmx'), str(root / 'codec_under_test.cmx'), str(root / 'window_suite.cmx')])
    manifest['executable_sha256'] = digest((root / 'window_suite.exe').read_bytes())
    with tempfile.TemporaryDirectory(prefix='masc-owned-shrink-snapshot-') as owned:
        env = os.environ.copy()
        env['MASC_BASE_PATH'] = owned
        execute('window_suite.run', [str(root / 'window_suite.exe'), '--color=never'], env)
    print('native-r1 complete', flush=True)

if __name__ == '__main__':
    main()
