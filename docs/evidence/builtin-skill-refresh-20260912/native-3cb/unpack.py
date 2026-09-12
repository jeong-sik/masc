from pathlib import Path
import hashlib
import json
import shutil
import sys
import tarfile

root = Path(sys.argv[1])
expected = sys.argv[2]
proof = next(root.glob('lane-addon-native-macos-arm64-*'))
assert (proof / 'SOURCE_COMMIT').read_text().strip() == expected
dist = root / 'dist'
dist.mkdir(exist_ok=True)
with tarfile.open(proof / 'masc-lane-addon-macos-arm64.tar.gz') as archive:
    archive.extractall(dist, filter='data')
for line in (proof / 'SHA256SUMS').read_text().splitlines():
    sha, name = line.split(maxsplit=1)
    assert hashlib.sha256((dist / Path(name).name).read_bytes()).hexdigest() == sha
runtime = root / 'runtime'
runtime.mkdir(exist_ok=True)
with tarfile.open(dist / 'masc-runtime-macos-arm64.tar.gz') as archive:
    archive.extractall(runtime, filter='data')
digests = {}
for name in ['masc-macos-arm64', 'masc-tui-macos-arm64', 'masc-browser-host-macos-arm64']:
    shutil.copy2(dist / name, runtime / name)
    digests[name] = hashlib.sha256((runtime / name).read_bytes()).hexdigest()
print(json.dumps({'source_commit': expected, 'runtime': str(runtime), 'sha256': digests}))
