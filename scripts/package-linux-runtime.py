#!/usr/bin/env python3
"""Package pinned standalone GNU/Linux Python in the existing verified runtime archive."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location('portable_runtime', Path(__file__).with_name('package-macos-runtime.py'))
portable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portable)


def package(dist, stage, platform, commit, lock_path):
    if stage.exists():
        raise ValueError('runtime stage must be new')
    lock = json.loads(lock_path.read_text())
    pinned = lock['platforms'][platform]
    archive_bytes = portable.fetch(pinned['browser_download_url'])
    if (len(archive_bytes) != pinned['size'] or
            'sha256:' + hashlib.sha256(archive_bytes).hexdigest() != pinned['digest']):
        raise ValueError('Python archive checksum differs from pin')
    stage.mkdir(parents=True)
    with tempfile.NamedTemporaryFile(suffix='.tar.gz') as archive:
        archive.write(archive_bytes)
        archive.flush()
        portable.unpack_python(Path(archive.name), stage)
    for name in portable.NAMES:
        shutil.copy2(dist / (name + '-' + platform), stage / name)
    if portable.run(str(stage.resolve() / 'masc'), 'build-commit').strip() != commit:
        raise ValueError('staged executable source commit differs')
    clean = dict(os.environ)
    clean.pop('PYTHONHOME', None)
    clean.pop('PYTHONPATH', None)
    subprocess.run([str(stage.resolve() / 'python/bin/python3'), '-I', '-c',
                    'import json,tarfile,ssl,urllib.request; assert urllib.request.urlopen("https://example.com",timeout=30).status == 200'],
                   env=clean, check=True)
    portable.freeze_python_bytecode(stage)
    provenance = dict(schema='masc.linux-runtime.v1', source_commit=commit, platform=platform,
                      python=dict(pinned, release=lock['release'], upstream=lock['upstream']))
    (stage / 'runtime-provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    output_path = dist / ('masc-runtime-' + platform + '.tar.gz')
    with tarfile.open(output_path, 'w:gz') as output:
        for path in sorted(stage.rglob('*')):
            if path.is_file() and path.name not in portable.NAMES:
                data = path.read_bytes()
                info = tarfile.TarInfo(path.relative_to(stage).as_posix())
                info.size, info.mode, info.mtime = len(data), path.stat().st_mode & 0o777, 0
                output.addfile(info, io.BytesIO(data))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--platform', choices=['linux-arm64', 'linux-x64'], required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--python-lock', type=Path, default=Path(__file__).with_name('portable-python-runtime.lock.json'))
    args = parser.parse_args()
    package(args.dist, args.stage, args.platform, args.source_commit, args.python_lock)
