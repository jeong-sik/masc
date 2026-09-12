import hashlib
import json
from pathlib import Path
import stat
import subprocess
import tempfile

previous = Path('/tmp/skill-refresh-native-39ab/runtime/masc-macos-arm64')
candidate = Path('/tmp/skill-refresh-native-575/runtime/masc-macos-arm64')
parent = Path(tempfile.mkdtemp(prefix='masc-mounted-skill-probe-'))
base, volume = parent / 'workspace', parent / 'volume'
base.mkdir(); volume.mkdir()
(base / '.masc').symlink_to(volume, target_is_directory=True)
out = Path('/tmp/skill-refresh-native-575/mounted-root-proof.json')
proof = {'workspace': str(base), 'physical_root': str(volume.resolve()),
         'layout': '.masc symlink to sibling owned temporary directory; no actual mount needed',
         'commands': [], 'checks': [],
         'binary_sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for name, path in [('before_39ab', previous), ('candidate_575', candidate)]}}

def run(label, binary, args, succeeds=True):
    r = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=60)
    proof['commands'].append({'label': label, 'binary': str(binary), 'arguments': list(map(str,args)),
                              'exit': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr})
    out.write_text(json.dumps(proof, indent=2))
    assert (r.returncode == 0) == succeeds, proof['commands'][-1]
    return r.stdout

def fields(text):
    return dict(line.split(': ',1) for line in text.splitlines() if ': ' in line)

def snapshot(directory):
    return {str(p.relative_to(directory)): [stat.S_IMODE(p.stat().st_mode),
            'directory' if p.is_dir() else hashlib.sha256(p.read_bytes()).hexdigest()]
            for p in [directory, *sorted(directory.rglob('*'))]}

source = run('candidate-identity',candidate,['build-commit']).strip()
assert source == '575fd0f948d4b1929ab88693c7f8587ef2677ae0'
proof['candidate_source_commit'] = source
run('before-mounted-deployment',previous,['init','--skills-only','--base-path',base],succeeds=False)
run('candidate-mounted-deployment',candidate,['init','--skills-only','--base-path',base])
package = volume / 'skills/browser-lanes'
assert package.is_dir() and (base / '.masc').is_symlink()
(package / 'operator-note.txt').write_text('Synthetic operator change in mounted-root topology.\n')
common = ['skills-refresh','browser-lanes','--base-path',base]
preview = fields(run('inspect-linked-operator-tree',candidate,common))
assert preview['ownership'].startswith('modified')
exported = parent / 'reviewed-export'
bundle = fields(run('export-candidate-bundle',candidate,[*common,'--export-to',exported]))['bundled revision']
before = snapshot(package)
result = run('apply-reviewed-tree-through-link',candidate,[*common,'--apply',
    '--expected-revision',preview['installed revision'],'--expected-bundle-revision',bundle])
backup = Path(result.split('previous package: ',1)[1].splitlines()[0])
assert backup.parent == volume.resolve() / 'skill-packages'
assert snapshot(backup) == before
assert snapshot(package) == snapshot(exported)
receipt = volume / 'skill-packages/browser-lanes.sha256'
assert receipt.read_text() == bundle + '\n'
result = fields(run('inspect-recorded-physical-tree',candidate,common))
assert result['ownership'] == 'recorded, unchanged since installation'
assert result['installed revision'] == bundle
proof['checks'] = ['39ab rejects supported deployment symlink; 575 installs through same link',
                   'physical root outside base contains package, receipt and complete backup',
                   'inspect and explicit reviewed replacement both follow the deployment root',
                   'published package matches actual reviewed export including paths, bytes and modes',
                   'operator deployment symlink remains unchanged']
proof['limitations'] = ['Only isolated synthetic files; no live runtime or installed binary changed',
                        'No physical filesystem mount or concurrent external-editor race exercised']
out.write_text(json.dumps(proof,indent=2))
print(json.dumps({'proof':str(out),'checks':proof['checks']}))
