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

def check_recorded_joins(recorded_files, export_manifest):
    """Cross-record claims, also exercised against in-memory negative controls."""
    def document(name):
        return json.loads(recorded_files[name])

    def one(items, predicate, description):
        matches = [item for item in items if predicate(item)]
        assert len(matches) == 1, description
        return matches[0]

    def owner(snapshot, instance_id):
        return one(snapshot['instances'], lambda item: item['instance_id'] == instance_id,
                   'exact instance must occur once in snapshot')

    def identity(instance):
        return {key: instance[key] for key in ('instance_id', 'incarnation', 'run_id',
                'addon_id', 'revision', 'configuration', 'container_id', 'binding', 'package')}

    def retained(probe, row):
        instance_id, sequence, _ = row['id'].split('/', 2)
        name = f"{probe}/.masc/lane-addons/observations/{sha(instance_id.encode())}/{int(sequence):020d}.json"
        record = document(name)
        assert row == one(record['output']['rows'], lambda item: item['id'] == row['id'],
                          'API row must occur once in original observation'), 'API row differs from retained observation'
        return record

    def installation(snapshot, instance):
        configured = instance['configuration']
        declaration = one(snapshot['configuration']['declarations'],
                          lambda item: item['id'] == configured['id'], 'installation identity must be unique')
        assert declaration['instance_id'] == instance['instance_id'], 'installation selects a different instance'
        assert declaration['applied_revision'] == configured['revision'], 'installation revision differs'
        assert declaration['source_path'] == configured['source_path'], 'installation source differs'

    capture_links = cleanup_instances = cleanup_attempts = 0
    dos_identities = {}
    for probe, before_response, after_response, slice_response, final_response in (
            ('dos-host', '0012', '0020', '0029', '0034'),
            ('dos-statistics', '0004', '0007', '0018', '0023')):
        prefix = probe + '/evidence/'
        process = document(prefix + 'process.json')
        summary = document(prefix + 'summary.json')
        browser = document(prefix + 'browser/result.json')
        dos_id = browser['request']['instance_id']
        before = document(prefix + before_response + '.raw')
        after = document(prefix + after_response + '.raw')
        dos = owner(before, dos_id)
        assert dos['addon_id'] == 'dos-world' and dos['run_id'] == process['run_id'], 'wrong DOS run or package'
        assert dos['incarnation'] == browser['request']['expected_incarnation'], 'DOS incarnation mismatch'
        assert identity(owner(after, dos_id)) == identity(dos), 'DOS owner changed between captures'
        installation(before, dos)
        installation(after, owner(after, dos_id))
        dos_identities[probe] = identity(dos)
        assert len(summary['measurements']) == 2, 'both capture measurements required'
        measurements = summary['measurements']
        after_row = None
        for stage, snapshot, measurement, expected in (
                ('before', before, measurements[0], 0), ('after', after, measurements[1], 1)):
            row = one(snapshot['rows'], lambda item: item['id'] == measurement['row_id'], 'measured capture missing from API')
            assert row['id'].split('/')[0] == dos_id, 'measured capture belongs to another DOS instance'
            assert row['lane_id'] == dos_id + '/dos/guest', 'measured capture belongs to another lane'
            assert row['fields']['machine_incarnation'] == dos['incarnation'], 'capture incarnation mismatch'
            assert row['fields']['counter'] == measurement['counter'] == expected, 'capture counter mismatch'
            retained(probe, row)
            for suffix, field in (('.STATE.BIN', 'state_sha256'), ('.png', 'png_sha256')):
                data = recorded_files[prefix + stage + suffix]
                digest = sha(data)
                assert digest == measurement[field], 'exported capture digest differs from measurement'
                assert {'uri': 'lane-evidence:' + digest, 'sha256': digest} in row['evidence'], 'capture export is not referenced by API row'
                assert data == recorded_files[f'{probe}/.masc/lane-addons/evidence/{digest}.json'], 'capture export differs from retained blob'
                capture_links += 1
            if stage == 'after':
                after_row = row
        assert browser['selected_row'] == after_row, 'browser selected a different capture'
        detached_slice = document(prefix + slice_response + '.raw')
        assert after_row in detached_slice['rows'], 'post-detach slice lost the measured capture'
        for suffix in ('.STATE.BIN', '.png'):
            assert recorded_files[prefix + 'after-detach' + suffix] == recorded_files[prefix + 'after' + suffix], 'post-detach export changed'
            capture_links += 1

        final = document(prefix + final_response + '.raw')
        assert final == summary['final_snapshot'], 'final snapshot differs from original HTTP response'
        final_instances = final['instances']
        assert final_instances, 'final instance list is absent'
        final_ids = {item['instance_id'] for item in final_instances}
        assert len(final_ids) == len(final_instances), 'duplicate final instance'
        assert final_ids == {item['instance_id'] for item in before['instances']}, 'final snapshot omits an installed instance'
        assert all(item['phase']['kind'] == 'detached' for item in final_instances), 'final instance is not detached'
        cleanup = summary['cleanup']
        servers = [entry for entry in cleanup if 'server_pid' in entry]
        assert len(servers) == 1 and servers[0]['server_pid'] == process['pid'], 'explicit owned server cleanup required'
        assert type(servers[0]['exit_code']) is int and servers[0]['exit_code'] == 0, 'server exit must be explicitly zero'
        containers = [entry for entry in cleanup if 'instance_id' in entry]
        assert len(cleanup) == len(containers) + 1, 'unknown cleanup entry'
        assert len(containers) == len(final_ids) and {entry['instance_id'] for entry in containers} == final_ids, 'cleanup must cover every final instance'
        for entry in containers:
            assert entry['container_absent'] is True and entry['forced_removal'] == [], 'normal container absence must be explicit'
            cleanup_instances += 1
        attempts = document(prefix + 'all-attempts-cleanup.json')
        assert attempts, 'all-attempts cleanup is missing'
        pairs = set()
        for entry in attempts:
            pair = (entry['attempt'], entry['instance_id'])
            assert all(isinstance(value, str) and value for value in pair) and pair not in pairs, 'invalid or duplicate attempt identity'
            assert entry['container_absent'] is True, 'all-attempts container absence must be explicit'
            assert type(entry['observed_at']) in (int, float), 'all-attempts observation time required'
            pairs.add(pair)
            cleanup_attempts += 1
        assert {instance_id for attempt, instance_id in pairs if attempt == export_manifest['original_roots'][probe]} == final_ids, 'all-attempts cleanup omits a final instance'

    stats = 'dos-statistics/evidence/'
    process = document(stats + 'process.json')
    producer_identity = dos_identities['dos-statistics']
    consumer_identity = None
    for stage, response, producer_sequence, consumer_sequence in (
            ('before', '0004', 1, 2), ('after', '0007', 3, 4),
            ('same-cursor-1', '0009', 3, 5), ('same-cursor-2', '0011', 3, 6)):
        recorded = document(stats + 'statistics-' + stage + '.json')
        snapshot = document(stats + response + '.raw')
        producer = owner(snapshot, producer_identity['instance_id'])
        assert recorded['producer'] == producer and identity(producer) == producer_identity, 'statistics producer/run/configuration changed'
        consumer_id = recorded['consumer']['instance_id'] if consumer_identity is None else consumer_identity['instance_id']
        consumer = owner(snapshot, consumer_id)
        assert recorded['consumer'] == consumer, 'statistics consumer differs from API instance'
        if consumer_identity is None:
            consumer_identity = identity(consumer)
            assert consumer['addon_id'] == 'output-statistics', 'wrong statistics package'
            assert consumer['configuration']['id'] == process['companion_id'], 'wrong statistics installation'
            assert consumer['run_id'] == producer['run_id'] == process['run_id'], 'producer and consumer run differ'
            container = document(stats + 'statistics-container.json')
            assert container['Id'] == consumer['container_id'] and container['Config']['Labels']['masc.lane.instance'] == consumer_id, 'statistics container identity mismatch'
        assert identity(consumer) == consumer_identity, 'statistics consumer identity changed'
        installation(snapshot, producer)
        installation(snapshot, consumer)
        assert producer['observation_seq'] == producer_sequence and consumer['observation_seq'] == consumer_sequence, 'recorded producer/consumer cursor differs'
        row = recorded['statistics']
        assert row in snapshot['rows'], 'statistics row missing from API'
        assert row['id'].split('/')[:2] == [consumer_id, str(consumer_sequence)], 'statistics row belongs to another consumer observation'
        record = retained('dos-statistics', row)
        fields = row['fields']
        expected_producer = {'installation_id': producer['configuration']['id'], 'instance_id': producer['instance_id'],
            'run_id': producer['run_id'], 'configuration_revision': producer['configuration']['revision'],
            'package_revision': producer['revision'], 'observation_seq': producer_sequence}
        assert fields['producer'] == expected_producer, 'statistics attribution differs from actual producer'
        assert expected_producer['installation_id'] == process['producer_installation_id'], 'statistics installation target differs'
        assert consumer['binding']['sources'] == [{'kind': 'lane_output', 'source_id': fields['source_id'],
            'installation_id': expected_producer['installation_id'], 'selection': 'latest_completed'}], 'consumer binding differs from supplied producer'
        assert fields['incarnation'] == producer['incarnation'], 'statistics source incarnation differs'
        assert fields['source_event_id'] == f"{producer['instance_id']}/output/{producer_sequence}", 'statistics source event differs'
        assert fields['observed_row_count'] == 1 and fields['observed_by_kind'] == {'event': 0, 'value': 1, 'relation': 0}, 'supplied-row gauge differs'
        dos_row = recorded['dos_observation']
        assert dos_row in snapshot['rows'], 'upstream DOS row missing from original API'
        assert dos_row['id'].split('/')[:2] == [producer['instance_id'], str(producer_sequence)], 'upstream DOS row belongs to another producer observation'
        retained('dos-statistics', dos_row)
        assert dos_row['fields']['counter'] == recorded['dos_counter'] == (0 if stage == 'before' else 1), 'upstream guest counter differs'
        upstream = {key: dos_row[key] for key in ('id', 'lane_id', 'kind', 'subject_id', 'observed_at', 'clock', 'actor', 'evidence')}
        assert fields['upstream_rows'] == [upstream], 'statistics upstream projection differs from DOS row'
        supplied = one(record['sources'], lambda item: item['source_id'] == fields['source_id'], 'retained consumer source missing')
        observation = one(supplied['observations'], lambda item: item['id'] == fields['source_event_id'], 'retained producer observation missing')
        assert observation['producer'] == expected_producer and observation['output']['rows'] == [dos_row], 'retained supplied output differs from producer'
    missing = document(stats + '0015.raw')
    consumer = owner(missing, consumer_identity['instance_id'])
    assert identity(consumer) == consumer_identity and consumer['phase']['kind'] == 'attached' and consumer['rows_count'] == 0, 'missing input must retain the same attached consumer'
    missing_producer = owner(missing, producer_identity['instance_id'])
    assert identity(missing_producer) == producer_identity and missing_producer['phase']['kind'] == 'detached', 'same missing-input producer must be detached'
    assert not any('observed_row_count' in row['fields'] for row in missing['rows']), 'missing input invented a count'

    host = 'dos-host/evidence/'
    companion = document(host + 'companion-progress.json')
    companion_identity = None
    for response, sequence in (('0016', 2), ('0018', 3), ('0020', 4)):
        current = owner(document(host + response + '.raw'), companion['instance_id'])
        if companion_identity is None:
            companion_identity = identity(current)
        assert identity(current) == companion_identity and current['observation_seq'] == sequence, 'companion identity or cursor changed'
    after_detach = document(host + '0026.raw')
    remaining = owner(after_detach, companion['instance_id'])
    assert identity(remaining) == companion_identity and remaining['phase']['kind'] == 'attached', 'same companion must remain attached after DOS detach'
    assert remaining['observation_seq'] == 4, 'post-detach companion cursor changed'
    detached_dos = owner(after_detach, dos_identities['dos-host']['instance_id'])
    assert identity(detached_dos) == dos_identities['dos-host'] and detached_dos['phase']['kind'] == 'detached', 'same DOS owner must be detached'
    return {'capture_api_blob_joins': capture_links, 'normal_cleanup_instances': cleanup_instances,
            'all_attempts_absence_records': cleanup_attempts, 'statistics_identity_stages': 4,
            'companion_after_dos_detach_verified': True}

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
joins = check_recorded_joins(files, manifest)
print(json.dumps({'recorded_evidence_files': len(files), 'api_response_hashes': api_count, 'browser_response_hashes': browser_count, 'host_blobs': blobs, 'evidence_reference_checks': references, 'guest_transitions': ['0->1', '0->1'], 'full_pixel_checks': 6, 'fresh_runtime_execution': False, **joins}, indent=2))
