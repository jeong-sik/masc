import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

binary = Path('/tmp/skill-refresh-native-39ab/runtime/masc-macos-arm64')
records = []
out = Path('/tmp/skill-refresh-native-39ab/native-refresh-proof.json')
proof = {'source_commit': '39ab9c606f9120d3439ea4792d73f589558e9661',
         'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
         'euid': os.geteuid(), 'commands': records, 'checks': []}

def run(label, args, expected=0):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=60)
    records.append({'label': label, 'arguments': list(map(str, args)),
                    'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
    out.write_text(json.dumps(proof, indent=2))
    assert result.returncode == expected, records[-1]
    return result.stdout

def fields(text):
    return dict(line.split(': ', 1) for line in text.splitlines() if ': ' in line)

def snapshot(directory):
    return {str(p.relative_to(directory)): [stat.S_IMODE(p.stat().st_mode),
             'directory' if p.is_dir() else hashlib.sha256(p.read_bytes()).hexdigest()]
            for p in [directory, *sorted(directory.rglob('*'))]}

before = json.loads(Path('/tmp/skill-refresh-native-1254/permission-before.json').read_text())
base = Path(before['workspace'])
package = base / '.masc/skills/browser-lanes'
receipt = base / '.masc/skill-packages/browser-lanes.sha256'
original = snapshot(package)
original_receipt = receipt.read_bytes()
directory = package / 'references'
mode = stat.S_IMODE(directory.stat().st_mode)
try:
    directory.chmod(0)
    run('unreadable-operator-directory-after-fix', ['init', '--skills-only', '--base-path', base])
    assert receipt.read_bytes() == original_receipt
finally:
    directory.chmod(mode)
assert snapshot(package) == original
proof['checks'].append('paired unreadable-directory init now exits 0; complete package and receipt preserved')

base = Path(tempfile.mkdtemp(prefix='masc-refresh-39-review-'))
proof['review_workspace'] = str(base)
run('seed-isolated-workspace', ['init', '--skills-only', '--base-path', base])
common = ['skills-refresh', 'browser-lanes', '--base-path', base]
installed = fields(run('inspect-before-edit', common))
exported = base / 'exported-for-review'
bundle = fields(run('export-reviewed-bundle', [*common, '--export-to', exported]))['bundled revision']
package = base / '.masc/skills/browser-lanes'
operator_file = package / 'operator-note.txt'
operator_file.write_text('Synthetic operator resource, edited after first inspection.\n')
run('reject-stale-installed-revision', [*common, '--apply', '--expected-revision', installed['installed revision'],
    '--expected-bundle-revision', bundle], expected=1)
current = fields(run('inspect-operator-tree', common))
assert current['ownership'].startswith('modified')
original = snapshot(package)
run('reject-unreviewed-bundle', [*common, '--apply', '--expected-revision', current['installed revision'],
    '--expected-bundle-revision', '0' * 64], expected=1)
assert snapshot(package) == original
result = run('apply-reviewed-complete-package', [*common, '--apply', '--expected-revision', current['installed revision'],
    '--expected-bundle-revision', bundle])
backup = Path(result.split('previous package: ', 1)[1].splitlines()[0])
assert snapshot(backup) == original
assert snapshot(package) == snapshot(exported)
after = fields(run('inspect-published-package', common))
assert after['installed revision'] == bundle and after['bundled revision'] == bundle
assert after['ownership'] == 'recorded, unchanged since installation'
proof['checks'].extend(['stale installed digest rejects without mutation', 'wrong reviewed bundle digest rejects without mutation',
                         'explicit apply publishes exact exported bytes and retains complete previous tree',
                         'receipt and inspected installed revision match actual exported bundle revision'])
proof['limitations'] = ['No live installation changed or server started.',
                        'Source39ab predates mounted-root fix; this does not validate that later change.',
                        'Post-publication fsync injection is covered by compiled suite, not this CLI probe.']
out.write_text(json.dumps(proof, indent=2))
print(json.dumps({'proof': str(out), 'checks': proof['checks'], 'commands': len(records)}))
