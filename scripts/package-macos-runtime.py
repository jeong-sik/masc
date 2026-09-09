#!/usr/bin/env python3
"""Build relocatable macOS release bytes; Homebrew is a build input only."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

NAMES = ('masc', 'masc-tui', 'masc-browser-host', 'masc-deployment-preflight-helper',
         'masc-check-runtime-deployment-preflight')
MACH = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in MACH


def dependencies(path):
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in run('otool', '-L', str(path)).splitlines()[1:]]


def system(path):
    return path.startswith(('/usr/lib/', '/System/Library/'))


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def unpack_python(archive, target):
    # Upstream uses internal aliases. Resolve only after rejecting traversal and
    # escaping links, then materialize regular bytes in our bootstrap archive.
    with tarfile.open(archive, 'r:gz') as source:
        members = {}
        for member in source.getmembers():
            name = PurePosixPath(member.name)
            if not name.parts or '\\' in member.name or name.is_absolute() or '..' in name.parts or name.parts[0] != 'python':
                raise ValueError('unsafe upstream Python path')
            if member.name in members or not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
                raise ValueError('unsupported upstream Python member')
            members[member.name] = member
        def content(member, seen):
            if member.name in seen:
                raise ValueError('cyclic upstream Python link')
            if member.isfile():
                return source.extractfile(member).read(), member.mode
            link = PurePosixPath(member.linkname)
            if link.is_absolute():
                raise ValueError('absolute upstream Python link')
            path = (PurePosixPath(member.name).parent / link) if member.issym() else link
            parts = []
            for part in path.parts:
                if part == '..':
                    if not parts:
                        raise ValueError('escaping upstream Python link')
                    parts.pop()
                elif part != '.':
                    parts.append(part)
            if not parts or parts[0] != 'python':
                raise ValueError('escaping upstream Python link')
            return content(members['/'.join(parts)], seen | {member.name})
        for member in members.values():
            if member.isdir():
                continue
            data, mode = content(member, set())
            dest = target / member.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            dest.chmod(0o755 if mode & 0o111 else 0o644)


def audit_macho_tree(stage):
    # Verify every Mach-O, including Python extensions, after materialization.
    for binary in sorted(stage.rglob('*')):
        if not binary.is_file() or not macho(binary):
            continue
        if binary.suffix == '.dylib':
            run('install_name_tool', '-id', '@loader_path/' + binary.name, str(binary))
        commands = run('otool', '-l', str(binary))
        rpaths = []
        for block in commands.split('Load command ')[1:]:
            lines = [line.strip() for line in block.splitlines()]
            if 'cmd LC_RPATH' in lines:
                path = next(line[5:].rsplit(' (offset ', 1)[0] for line in lines if line.startswith('path '))
                if path.startswith('@loader_path/'):
                    rpaths.append(binary.parent / path[len('@loader_path/'):])
                elif path.startswith('@executable_path/') and binary.parent in (stage, stage / 'python/bin'):
                    rpaths.append(binary.parent / path[len('@executable_path/'):])
                else:
                    raise ValueError('nonportable rpath: ' + str(binary) + ': ' + path)
        for dep in dependencies(binary):
            if system(dep):
                continue
            if dep.startswith('@loader_path/'):
                candidates = [binary.parent / dep[len('@loader_path/'):]]
            elif dep.startswith('@rpath/'):
                candidates = [base / dep[len('@rpath/'):] for base in rpaths]
            else:
                raise ValueError('nonportable dependency: ' + str(binary) + ': ' + dep)
            if not any(target.is_file() and stage.resolve() in target.resolve().parents for target in candidates):
                raise ValueError('bundled dependency is missing or escapes runtime: ' + str(binary) + ': ' + dep)
        if '/opt/homebrew' in commands or '/usr/local/' in commands:
            raise ValueError('build-prefix loader command survives: ' + str(binary))
        run('codesign', '--force', '--sign', '-', str(binary))
        run('codesign', '--verify', '--strict', str(binary))

def package(dist, stage, platform, commit, lock_path):
    if stage.exists():
        raise ValueError('runtime stage must be new')
    stage.mkdir(parents=True)
    lock = json.loads(lock_path.read_text())
    pinned = lock['platforms'][platform]
    # The checked-in lock records reviewed upstream metadata. Build from those
    # exact bytes without adding an unauthenticated, rate-limited metadata API
    # dependency; size and SHA-256 remain mandatory before extraction.
    python_bytes = fetch(pinned['browser_download_url'])
    if len(python_bytes) != pinned['size'] or 'sha256:' + hashlib.sha256(python_bytes).hexdigest() != pinned['digest']:
        raise ValueError('Python archive checksum differs from pin')
    with tempfile.NamedTemporaryFile(suffix='.tar.gz') as archive:
        archive.write(python_bytes)
        archive.flush()
        unpack_python(Path(archive.name), stage)
    sources = {}
    for name in NAMES:
        shutil.copy2(dist / (name + '-' + platform), stage / name)
    queue = [stage / name for name in NAMES if macho(stage / name)]
    while queue:
        binary = queue.pop()
        for dep in dependencies(binary):
            if system(dep) or dep.startswith('@'):
                continue
            source = Path(dep).resolve(strict=True)
            name = source.name
            if name in sources:
                if sources[name] != source:
                    raise ValueError('ambiguous dylib basename: ' + name)
                continue
            sources[name] = source
            dest = stage / 'lib' / name
            dest.parent.mkdir(exist_ok=True)
            shutil.copy2(source, dest)
            dest.chmod(0o644)
            queue.append(dest)
    for name, source in sources.items():
        notices = [p for p in source.parent.parent.iterdir()
                   if p.is_file() and p.name.startswith(('LICENSE', 'COPYING', 'AUTHORS', 'NOTICE'))]
        if not notices:
            raise ValueError('dependency license missing: ' + str(source))
        for notice in notices:
            dest = stage / 'licenses' / name / notice.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(notice, dest)
            dest.chmod(0o644)
    targets = [stage / name for name in NAMES if macho(stage / name)] + list((stage / 'lib').iterdir())
    for binary in targets:
        signature = subprocess.run(['codesign', '-dv', str(binary)], capture_output=True, text=True)
        if 'TeamIdentifier=' in signature.stderr and 'TeamIdentifier=not set' not in signature.stderr:
            raise ValueError('refusing to replace a Developer ID signature with ad-hoc signing')
        changes = []
        for dep in dependencies(binary):
            if system(dep):
                continue
            if dep.startswith('@'):
                raise ValueError('unexpected unresolved native dependency: ' + dep)
            dest = ('@loader_path/' if binary.parent.name == 'lib' else '@loader_path/lib/') + Path(dep).resolve().name
            changes += ['-change', dep, dest]
        if binary.parent.name == 'lib':
            changes += ['-id', '@loader_path/' + binary.name]
        if changes:
            run('install_name_tool', *changes, str(binary))
        run('codesign', '--force', '--sign', '-', str(binary))
    audit_macho_tree(stage)
    if run(str(stage.resolve() / 'masc'), 'build-commit').strip() != commit:
        raise ValueError('rewritten executable source commit differs')
    # Test actual staged bytes with both Homebrew roots unreadable, including
    # urllib TLS discovery. User-supplied certificate settings remain honored.
    profile = '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))'
    clean = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    clean.pop('PYTHONHOME', None)
    clean.pop('PYTHONPATH', None)
    for command in ([str(stage.resolve() / 'masc'), 'build-commit'],
                    [str(stage.resolve() / 'masc-tui'), '--help'],
                    [str(stage.resolve() / 'masc-deployment-preflight-helper'), '--help'],
                    [str(stage.resolve() / 'python/bin/python3'), '-I', '-c',
                     'import json,tarfile,ssl,urllib.request; assert urllib.request.urlopen("https://example.com",timeout=30).status == 200']):
        subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, *command], env=clean, check=True)
    provenance = {'schema': 'masc.macos-runtime.v1', 'source_commit': commit, 'platform': platform,
                  'minimum_macos': '14.0' if platform == 'macos-arm64' else '15.0',
                  'python': dict(pinned, release=lock['release'], upstream=lock['upstream']),
                  'libraries': [{'name': name, 'upstream_sha256': sha(source)} for name, source in sorted(sources.items())]}
    (stage / 'runtime-provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    archive = dist / ('masc-runtime-' + platform + '.tar.gz')
    with tarfile.open(archive, 'w:gz') as output:
        for path in sorted(stage.rglob('*')):
            if path.is_file() and path.name not in NAMES:
                data = path.read_bytes()
                info = tarfile.TarInfo(path.relative_to(stage).as_posix())
                info.size, info.mode, info.mtime = len(data), path.stat().st_mode & 0o777, 0
                output.addfile(info, io.BytesIO(data))
    for name in NAMES:
        shutil.copy2(stage / name, dist / (name + '-' + platform))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--platform', choices=['macos-arm64', 'macos-x64'], required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--python-lock', type=Path, default=Path(__file__).with_name('macos-python-runtime.lock.json'))
    args = parser.parse_args()
    package(args.dist, args.stage, args.platform, args.source_commit, args.python_lock)
