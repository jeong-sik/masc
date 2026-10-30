from pathlib import Path
import hashlib
import os
import shlex
import stat
import subprocess
import sys
import tempfile

worktree = Path.cwd()
artifact = Path(sys.argv[1]).resolve()
artifact.mkdir(parents=True, exist_ok=False)
(artifact / 'tmp').mkdir()
english = (worktree / 'docs/KEEPER-USER-MANUAL.md').read_text()
korean = (worktree / 'docs/KEEPER-USER-MANUAL.ko.md').read_text()
def script(text, heading):
    section = text.split(heading, 1)[1]
    return section.split('```sh\n', 1)[1].split('\n```', 1)[0]
en = script(english, '#### Inspecting `_build` entries')
ko = script(korean, '#### `_build` 항목 확인하기')
assert en == ko
assert '"$guest_python" -I -S -B -' in en
fixture = Path(tempfile.mkdtemp(prefix='manual-scan-', dir=artifact / 'tmp'))
root = fixture / 'work root'
root.mkdir()
def checkout(name, kind, marker='missing'):
    folder = root / name
    folder.mkdir(parents=True)
    (folder / 'dune-project').write_text('fixture')
    entry = folder / '_build'
    if kind == 'directory':
        entry.mkdir()
        (entry / 'result').write_text('preserve-this-fixture')
    elif kind == 'file':
        entry.write_text('existing-file')
    else:
        entry.symlink_to('/masc-build/old\nfixture')
    keep = folder / '.masc-keep-build'
    if marker == 'present':
        keep.write_text('keep')
    elif marker == 'dangling':
        keep.symlink_to('missing-marker')
    elif marker == 'loop':
        keep.symlink_to('.masc-keep-build')
    return folder
checkout('kept', 'directory', 'present')
checkout('real:odd\nname', 'directory')
checkout('regular', 'file', 'dangling')
checkout('link', 'symlink')
checkout('invalid-marker', 'directory', 'loop')
checkout('one/two/three/four', 'directory')
checkout('.git/hidden', 'directory')
checkout('.masc-build-removing/staged', 'directory')
(root / 'alias').symlink_to(root / 'kept', target_is_directory=True)

def snapshot():
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            details = path.lstat()
            value = (details.st_mode, details.st_ino)
            if stat.S_ISLNK(details.st_mode):
                value += (os.readlink(path),)
            elif stat.S_ISREG(details.st_mode):
                value += (hashlib.sha256(path.read_bytes()).hexdigest(),)
            result[str(path.relative_to(root))] = value
    return result

def run(root_path):
    assignment = 'keeper_work_root=' + shlex.quote(str(root_path)) + '  # replace with the actual guest path'
    text = en.replace('keeper_work_root=/masc-work/reviewer  # replace with the actual guest path', assignment, 1)
    assert text != en
    return subprocess.run(['/bin/sh'], input=text, text=True, capture_output=True,
                          cwd=fixture, timeout=20)

before = snapshot()
result = run(root)
assert result.returncode == 0, result.stderr
assert snapshot() == before
lines = result.stdout.splitlines()
assert 'pending cleanup: present; contents not inspected' in lines
assert any("checkout: 'kept' _build: directory" in line and '.masc-keep-build: True' in line for line in lines)
assert any("checkout: 'real:odd\\nname' _build: directory" in line and '.masc-keep-build: False' in line for line in lines)
assert any("checkout: 'regular' _build: other" in line and '.masc-keep-build: False' in line for line in lines)
assert any("checkout: 'link' _build: symlink" in line and '/masc-build/old\\nfixture' in line for line in lines)
assert any("checkout: 'invalid-marker' _build: directory" in line and '.masc-keep-build: unverified' in line for line in lines)
assert 'cannot inspect:' in result.stderr
assert all("one/two/three/four" not in line and '.git/hidden' not in line
           and '.masc-build-removing/staged' not in line and "checkout: 'alias'" not in line for line in lines)
alias = fixture / 'root-alias'
alias.symlink_to(root, target_is_directory=True)
refused = run(alias)
assert refused.returncode != 0 and 'Work root is a symlink; stop.' in refused.stderr
assert snapshot() == before
print('PASS: EN/KO manual scans match; entries, markers, pruning, errors, symlink-root refusal and fixture contents checked')
print('synthetic fixture:', fixture)
