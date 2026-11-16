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
import zipfile

NAMES = ('masc', 'masc-tui', 'masc-deployment-preflight-helper',
         'masc-check-runtime-deployment-preflight', 'masc-exec-ssh-bootstrap',
         'masc-antigravity-path-hook')
MACH = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}

# The interpreter's OpenSSL reads only /private/etc/ssl, the operating system's
# static certificate file, so its trust ages with the macOS release. The
# runtime ships the pinned Mozilla bundle and makes it the default, unless the
# user names a certificate file or directory.
CA_BUNDLE = PurePosixPath('python/ssl/cacert.pem')
OCAML_NOTICES = PurePosixPath('licenses/ocaml')
SITECUSTOMIZE = '''"""MASC portable runtime: trust the CA bundle shipped with this Python.

The interpreter's OpenSSL otherwise reads only the operating system's static
certificate file. SSL_CERT_FILE or SSL_CERT_DIR set by the user keeps its
meaning; child processes inherit the same default.
"""
import os
import sys

if "SSL_CERT_FILE" not in os.environ and "SSL_CERT_DIR" not in os.environ:
    os.environ["SSL_CERT_FILE"] = os.path.join(sys.base_prefix, "ssl", "cacert.pem")
'''

# Run inside the staged interpreter. HTTP rejection is still a response over
# validated TLS; certificate, proxy CONNECT and network errors must propagate.
# The Linux runtime runs this probe as is; it ships no CA bundle.
PYTHON_HTTPS_PROBE = '''
import json, tarfile, ssl, urllib.request, urllib.error, urllib.parse
try:
    response = urllib.request.urlopen("https://example.com", timeout=30)
except urllib.error.HTTPError as error:
    response = error
with response:
    if urllib.parse.urlsplit(response.geturl()).scheme != "https":
        raise ValueError("HTTPS probe ended on a non-HTTPS response")
    print("staged Python: validated HTTPS response", response.status)
'''

# The macOS runtime first proves SITECUSTOMIZE made the shipped bundle its
# default, so the HTTPS probe below validates with that bundle.
MACOS_PYTHON_HTTPS_PROBE = '''
import os, sys
if os.environ.get("SSL_CERT_FILE") != os.path.join(sys.base_prefix, "ssl", "cacert.pem"):
    raise ValueError("staged Python does not default to its shipped CA bundle")
''' + PYTHON_HTTPS_PROBE


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


def stage_ca_bundle(stage, pinned):
    # Same rule as the interpreter: exact reviewed bytes before any extraction.
    wheel = fetch(pinned['browser_download_url'])
    if len(wheel) != pinned['size'] or 'sha256:' + hashlib.sha256(wheel).hexdigest() != pinned['digest']:
        raise ValueError('CA bundle archive checksum differs from pin')
    with zipfile.ZipFile(io.BytesIO(wheel)) as archive:
        bundle = archive.read(pinned['member'])
        notice = archive.read(pinned['license_member'])
    sites = sorted((stage / 'python/lib').glob('python3.*/site-packages'))
    if len(sites) != 1:
        raise ValueError('staged Python needs exactly one site-packages directory')
    for path, data in ((stage / CA_BUNDLE, bundle),
                       (sites[0] / 'sitecustomize.py', SITECUSTOMIZE.encode()),
                       (stage / 'licenses/certifi' / PurePosixPath(pinned['license_member']).name, notice)):
        if path.exists():
            raise ValueError('staged Python already has ' + path.relative_to(stage).as_posix())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o644)


def stage_ocaml_notices(stage, notices):
    # The OCaml libraries are linked into the executables, so their notices
    # come from scripts/collect-ocaml-notices.py, run where they were built.
    # Its directory ships unchanged; packages.json there names every file and
    # its sha256, and the directory must hold exactly those.
    manifest = notices / 'packages.json'
    if not manifest.is_file():
        raise ValueError('OCaml notice manifest missing: ' + str(manifest)
                         + '; scripts/collect-ocaml-notices.py printed why it did not write it')
    expected = {notice['file']: notice['sha256'] for package in json.loads(manifest.read_text())['packages']
                for notice in package['notices']}
    files = []
    for source in sorted(notices.rglob('*')):
        if source.is_symlink() or not (source.is_file() or source.is_dir()):
            raise ValueError('OCaml notice is not a regular file: ' + str(source))
        if source.is_file() and source != manifest:
            files.append(source)
    found = {source.relative_to(notices).as_posix(): sha(source) for source in files}
    differing = sorted({path for path, _ in set(found.items()) ^ set(expected.items())})
    if differing:
        raise ValueError('OCaml notices differ from ' + str(manifest) + ': ' + ', '.join(differing))
    for source in files + [manifest]:
        dest = stage / OCAML_NOTICES / source.relative_to(notices)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
        dest.chmod(0o644)


def add_ocaml_notice_arguments(parser):
    # Every caller says whether this runtime carries the notices, so a release
    # cannot lose them by leaving a flag out.
    notices = parser.add_mutually_exclusive_group(required=True)
    notices.add_argument('--ocaml-notices', type=Path,
                         help='directory written by scripts/collect-ocaml-notices.py (release)')
    notices.add_argument('--without-ocaml-notices', action='store_true',
                         help='probe or fixture runtime that is never published')


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


def publish_binary(source, destination):
    # Dune-derived distribution files can be read-only. Prepare a new inode in
    # the destination filesystem; replacing its directory entry neither writes
    # the previous file nor follows a previous symlink.
    descriptor, name = tempfile.mkstemp(prefix='.' + destination.name + '-', dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            with source.open('rb') as input_file:
                shutil.copyfileobj(input_file, output)
            output.flush()
            os.fchmod(output.fileno(), source.stat().st_mode & 0o777)
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)



def freeze_python_bytecode(stage):
    # Runtime extraction changes source mtimes. Timestamp-based bytecode then
    # rewrites itself on import, invalidating the immutable release receipt.
    # Compile with the shipped interpreter and source hashes instead, including
    # both optimized variants so ordinary -O/-OO use also remains read-only.
    python = stage / 'python'
    for bytecode in python.rglob('*.pyc'):
        bytecode.unlink()
    subprocess.run([str((python / 'bin/python3').resolve()), '-I', '-m', 'compileall',
                    '-q', '-f', '--invalidation-mode', 'checked-hash',
                    '-o', '0', '-o', '1', '-o', '2', '-s', str(stage.resolve()),
                    '-p', '', str(python.resolve())], check=True)


def package(dist, stage, platform, commit, lock_path, ocaml_notices):
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
    ca_pinned = lock['ca_bundle']
    stage_ca_bundle(stage, ca_pinned)
    if ocaml_notices is not None:
        stage_ocaml_notices(stage, ocaml_notices)
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
    # urllib TLS discovery. Certificate settings of the build environment are
    # dropped so the probe checks the runtime's own default, the shipped bundle.
    profile = '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))'
    clean = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
    for name in ('PYTHONHOME', 'PYTHONPATH', 'SSL_CERT_FILE', 'SSL_CERT_DIR'):
        clean.pop(name, None)
    for command in ([str(stage.resolve() / 'masc'), 'build-commit'],
                    [str(stage.resolve() / 'masc-tui'), '--help'],
                    [str(stage.resolve() / 'masc-deployment-preflight-helper'), '--help'],
                    [str(stage.resolve() / 'masc-exec-ssh-bootstrap'), '--help'],
                    [str(stage.resolve() / 'python/bin/python3'), '-I', '-c',
                     MACOS_PYTHON_HTTPS_PROBE]):
        subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, *command], env=clean, check=True)
    freeze_python_bytecode(stage)
    provenance = {'schema': 'masc.macos-runtime.v1', 'source_commit': commit, 'platform': platform,
                  'minimum_macos': '14.0' if platform == 'macos-arm64' else '15.0',
                  'python': dict(pinned, release=lock['release'], upstream=lock['upstream']),
                  'ca_bundle': dict(ca_pinned),
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
        publish_binary(stage / name, dist / (name + '-' + platform))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--platform', choices=['macos-arm64', 'macos-x64'], required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--python-lock', type=Path, default=Path(__file__).with_name('portable-python-runtime.lock.json'))
    add_ocaml_notice_arguments(parser)
    args = parser.parse_args()
    package(args.dist, args.stage, args.platform, args.source_commit, args.python_lock, args.ocaml_notices)
