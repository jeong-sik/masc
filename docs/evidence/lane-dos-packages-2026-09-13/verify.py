"""Offline verification of recorded bytes, not a new runtime execution."""
from pathlib import Path
import hashlib
import io
import json
import struct
import tarfile
from PIL import Image

ROOT = Path(__file__).resolve().parent
manifest = json.loads((ROOT / 'manifest.json').read_text())
sha = lambda data: hashlib.sha256(data).hexdigest()
with tarfile.open(ROOT / 'original-evidence.tar.gz', 'r:gz') as archive:
    members = archive.getmembers()
    assert len({m.name for m in members}) == len(members)
    assert all(m.isfile() for m in members)
    files = {m.name: archive.extractfile(m).read() for m in members}
assert set(files) == set(manifest['files'])
for name, metadata in manifest['files'].items():
    assert sha(files[name]) == metadata['sha256'] and len(files[name]) == metadata['bytes'], name
for name, metadata in manifest['screenshots'].items():
    assert sha((ROOT / name).read_bytes()) == metadata['sha256'], name

def read(name):
    return json.loads(files[name])

def check_guest(name, expected):
    state = files[name + '.STATE.BIN']
    assert len(state) == 8 and state[:4] == b'LANE'
    assert struct.unpack('<HH', state[4:]) == (1, expected)
    image = Image.open(io.BytesIO(files[name + '.png'])).convert('RGBA')
    assert image.size == (320, 200)
    for index in range(image.width * image.height):
        x, y = index % 320, index // 320
        pixel = image.getpixel((x, y))
        color = (255, 255, 255, 255) if 16 <= x < 304 and 32 <= y < 48 else (
            (0, 255, 0, 255) if 16 <= x < 17 + expected % 256 and 80 <= y < 96 else (0, 0, 0, 255))
        assert pixel == color, (name, x, y)

api_count = browser_count = 0
for probe in ('dos-host', 'dos-statistics'):
    prefix = probe + '/evidence/'
    process = read(prefix + 'process.json')
    assert process['source_commit'] == manifest['native_source']
    assert process['package_commit'] == manifest['dos_package_source']
    assert process['binary_sha256'] == '9f7f6896946c51dcf0fc3bad3ef847f62dd1cd0ef5560cef5e306d070d939a0c'
    for name in files:
        local = name.removeprefix(prefix)
        if name.startswith(prefix) and len(local) == 9 and local[:4].isdigit() and local.endswith('.json'):
            metadata = read(name)
            assert sha(files[name[:-5] + '.raw']) == metadata['sha256'], name
            assert metadata['path'] != '/api/v1/lane-addons/attach'
            api_count += 1
    browser = read(prefix + 'browser/result.json')
    assert browser['response_mocking'] is False and browser['page_errors'] == []
    assert browser['source_commit'] == manifest['dashboard_source']
    for receipt in browser['response_receipts']:
        assert sha(files[prefix + 'browser/' + receipt['file']]) == receipt['sha256']
        browser_count += 1
    submitted = [r for r in browser['response_receipts'] if r['method'] == 'POST' and r['path'] == '/api/v1/lane-addons/actions']
    assert len(submitted) == 1 and submitted[0]['request'] == browser['request']
    assert read(prefix + 'browser/' + submitted[0]['file'])['state'] == 'queued'
    action = browser['receipt']
    assert action['instance_id'] == browser['request']['instance_id']
    assert action['incarnation'] == browser['request']['expected_incarnation']
    assert action['action'] == browser['request']['action']
    assert read(prefix + 'container.json')['Config']['Labels']['masc.lane.instance'] == action['instance_id']
    assert action['state'] == 'confirmed' and action['request_id'] == browser['request']['request_id']
    assert any(read(prefix + 'browser/' + r['file']) == action for r in browser['response_receipts'])
    assert action['executor'] == read(prefix + 'container.json')['Id']
    for stage, counter in [('before', 0), ('after', 1), ('after-detach', 1)]:
        check_guest(prefix + stage, counter)
    for suffix in ('.STATE.BIN', '.png'):
        assert files[prefix + 'after' + suffix] == files[prefix + 'after-detach' + suffix]
    summary = read(prefix + 'summary.json')
    assert summary['status'] == 'passed' and summary['attach_request_count'] == 0
    assert summary['production_runtime_changed'] is False and summary['keeper_inference_exercised'] is False
    assert all(c.get('exit_code', 0) == 0 and c.get('container_absent', True) and not c.get('forced_removal', []) for c in summary['cleanup'])
    assert all(i['phase']['kind'] == 'detached' for i in summary['final_snapshot']['instances'])

# Link supplied-row gauges back to original HTTP snapshots, not only derived notes.
stats = 'dos-statistics/evidence/'
for stage, response in [('before', '0004'), ('after', '0007'), ('same-cursor-1', '0009'), ('same-cursor-2', '0011')]:
    recorded = read(stats + 'statistics-' + stage + '.json')
    row = recorded['statistics']
    assert row in read(stats + response + '.raw')['rows']
    assert row['fields']['observed_row_count'] == 1
    if stage.startswith('same-cursor'):
        assert row['fields']['producer']['observation_seq'] == 3
missing = read(stats + '0015.raw')
assert any(i['addon_id'] == 'output-statistics' and i['phase']['kind'] == 'attached' and i['rows_count'] == 0 for i in missing['instances'])
assert not any('observed_row_count' in r['fields'] for r in missing['rows'])
companion = read('dos-host/evidence/companion-progress.json')
for response, expected in [('0016', 2), ('0018', 3), ('0020', 4)]:
    current = read('dos-host/evidence/' + response + '.raw')
    assert any(i['instance_id'] == companion['instance_id'] and i['observation_seq'] == expected for i in current['instances'])

# Host-owned evidence is addressed by the original digest; .json may contain PNG or guest bytes.
blobs = 0
for name, data in files.items():
    if '/.masc/lane-addons/evidence/' in name:
        assert sha(data) == Path(name).stem, name
        blobs += 1
external = {r['original_uri']: r for r in manifest['external_evidence']}
references = 0
def check_refs(probe, value):
    global references
    if isinstance(value, dict):
        uri, digest = value.get('uri'), value.get('sha256')
        if isinstance(uri, str) and isinstance(digest, str):
            if uri.startswith('lane-evidence:'):
                assert uri == 'lane-evidence:' + digest
                assert sha(files[probe + '/.masc/lane-addons/evidence/' + digest + '.json']) == digest
                references += 1
            elif uri in external:
                assert sha(files[external[uri]['export_path']]) == digest
                references += 1
        for child in value.values():
            check_refs(probe, child)
    elif isinstance(value, list):
        for child in value:
            check_refs(probe, child)
for name, data in files.items():
    try:
        value = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        continue
    check_refs(name.split('/')[0], value)
print(json.dumps({'recorded_evidence_files': len(files), 'api_response_hashes': api_count, 'browser_response_hashes': browser_count, 'host_blobs': blobs, 'evidence_reference_checks': references, 'guest_transitions': ['0->1', '0->1'], 'full_pixel_checks': 6, 'fresh_runtime_execution': False}, indent=2))
