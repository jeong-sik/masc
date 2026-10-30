"""Offline integrity and three recorded-outcome checks; never reruns MASC/DOS."""
if not __debug__:
    raise RuntimeError('Remove -O/PYTHONOPTIMIZE: evidence verification requires assertions')

from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import tarfile
from PIL import Image

ROOT = Path(__file__).resolve().parent
sha = lambda raw: hashlib.sha256(raw).hexdigest()


def load_bundle():
    manifest = json.loads((ROOT / 'manifest.json').read_bytes())
    archive_bytes = (ROOT / 'original-evidence.tar.gz').read_bytes()
    assert sha(archive_bytes) == manifest['archive_sha256']
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as archive:
        members = archive.getmembers()
        assert len({m.name for m in members}) == len(members)
        assert all(m.isfile() and not PurePosixPath(m.name).is_absolute()
                   and '..' not in PurePosixPath(m.name).parts for m in members)
        files = {m.name: archive.extractfile(m).read() for m in members}
    assert set(files) == set(manifest['files'])
    for name, entry in manifest['files'].items():
        assert sha(files[name]) == entry['sha256'] and len(files[name]) == entry['bytes'], name
    for name, entry in manifest['screenshots'].items():
        assert sha((ROOT / name).read_bytes()) == entry['sha256']
    return files, manifest


def check_recorded_joins(files, manifest):
    def document(name): return json.loads(files[name])
    def one(items, predicate, label):
        found = [item for item in items if predicate(item)]
        assert len(found) == 1, label
        return found[0]
    def api(number):
        receipt = document(f'evidence/{number:04d}.json')
        raw = files[f'evidence/{number:04d}.raw']
        assert receipt['status'] == 200 and sha(raw) == receipt['sha256']
        return receipt, json.loads(raw)
    def blob(ref):
        digest = ref['sha256']
        assert type(digest) is str and len(digest) == 64
        assert ref['uri'] == 'lane-evidence:' + digest
        raw = files[f'.masc/lane-addons/evidence/{digest}.json']
        assert sha(raw) == digest
        return raw
    def retained(row):
        instance, sequence, suffix = row['id'].split('/', 2)
        assert suffix and sequence.isdigit()
        name = f'.masc/lane-addons/observations/{sha(instance.encode())}/{int(sequence):020d}.json'
        record = document(name)
        assert one(record['output']['rows'], lambda r: r['id'] == row['id'], 'retained row missing') == row
        return record
    def owner(snapshot, ident):
        return one(snapshot['instances'], lambda item: item['instance_id'] == ident, 'owner missing or ambiguous')
    def identity(instance):
        return {key: instance[key] for key in ['instance_id', 'incarnation', 'run_id', 'addon_id', 'revision', 'configuration', 'container_id', 'binding', 'package']}
    initial = api(8)[1]
    dos = one(initial['instances'], lambda i: i['configuration']['id'] == 'dos', 'initial DOS')
    metric = one(initial['instances'], lambda i: i['configuration']['id'] == 'difference', 'initial metric')
    statistics = one(initial['instances'], lambda i: i['configuration']['id'] == 'statistics', 'initial statistics')
    assert dos['addon_id'] == 'dos-world' and dos['instance_id'] == dos['incarnation']
    assert metric['binding'] == {'field': 'counter', 'unit': 'count', 'sources': [{'kind': 'lane_output', 'source_id': 'guest', 'installation_id': 'dos', 'output_id': 'guest', 'selection': 'latest_completed'}]}
    assert metric['package']['outputs'] == {'difference': {'all_lanes': True}}
    assert dos['package']['outputs'] == {'guest': {'lanes': ['dos/guest']}}
    checked_captures = {}
    def guest(row):
        assert row['actor'] is None and row['kind'] == 'value'
        assert row['lane_id'] == dos['instance_id'] + '/dos/guest'
        assert row['subject_id'] == 'dos/' + dos['instance_id']
        assert row['fields']['machine_incarnation'] == dos['incarnation']
        assert row['clock'] == {'domain': f"dos/{dos['instance_id']}/{dos['incarnation']}/capture", 'value': str(row['fields']['capture_sequence'])}
        retained(row)
        values = [blob(ref) for ref in row['evidence']]
        state = one(values, lambda v: len(v) == 8 and v[:4] == b'LANE', 'one raw guest state')
        png = one(values, lambda v: v.startswith(b'\x89PNG\r\n\x1a\n'), 'one VGA PNG')
        build = one(values, lambda v: v not in [state, png], 'one original guest build digest record')
        build_digests = dict(line.split(None, 1)[::-1] for line in build.decode().splitlines())
        assert row['fields']['program_sha256'] == build_digests['guest/LANEDEMO.COM']
        assert state[:6] == b'LANE\x01\x00'
        counter = int.from_bytes(state[6:], 'little')
        assert type(row['fields']['counter']) is int and row['fields']['counter'] == counter
        assert type(row['fields']['bar_width']) is int and row['fields']['bar_width'] == 1 + counter % 256
        if sha(png) not in checked_captures:
            image = Image.open(io.BytesIO(png)).convert('RGBA')
            assert image.size == (320, 200)
            for y in range(200):
                for x in range(320):
                    expected = ((255, 255, 255, 255) if 16 <= x < 304 and 32 <= y < 48
                                else (0, 255, 0, 255) if 16 <= x < 17 + counter % 256 and 80 <= y < 96
                                else (0, 0, 0, 255))
                    assert image.getpixel((x, y)) == expected
            checked_captures[sha(png)] = {'counter': counter, 'state_sha256': sha(state), 'png_sha256': sha(png), 'pixels': 64000}
        return counter
    freeze_request, freeze_receipt = api(29)
    bundle = json.loads(blob(freeze_receipt['evidence']))
    assert freeze_request['request'] == {'instance_id': metric['instance_id'], 'row_ids': [manifest['selected_increment_row_id']]}
    assert bundle['instance_id'] == metric['instance_id'] and bundle['row_ids'] == freeze_request['request']['row_ids']
    assert freeze_receipt['row_count'] == 1
    selected = one([row for ref in bundle['observations'] for row in json.loads(blob(ref))['output']['rows']],
                   lambda row: row['id'] == manifest['selected_increment_row_id'], 'frozen original metric')
    assert selected['id'].split('/')[0] == metric['instance_id'] and selected['actor'] is None
    retained(selected)
    fields = selected['fields']
    assert (fields['scope'], fields['field'], fields['unit'], fields['state']) == ('between_supplied_values', 'counter', 'count', 'measured')
    endpoint_values = []
    for label in ['previous', 'current']:
        sample = fields[label]
        assert sample is not None and sample['output_actor'] is None
        producer = sample['producer']; sequence = producer['observation_seq']
        assert producer == {'installation_id': 'dos', 'instance_id': dos['instance_id'], 'run_id': dos['run_id'],
                            'configuration_revision': dos['configuration']['revision'], 'package_revision': dos['revision'],
                            'observation_seq': sequence, 'output_id': 'guest', 'output_selection': {'lanes': ['dos/guest']},
                            'coverage_scope': 'whole_producer'}
        assert sample['source_event_id'] == f"{dos['instance_id']}/output/{sequence}"
        assert sample['source']['source_id'] == metric['binding']['sources'][0]['source_id'], 'endpoint source differs from metric binding'
        assert sample['source']['cursor'] == sample['producer_status']['cursor'] == str(sequence)
        assert sample['source']['incarnation'] == sample['producer_status']['incarnation'] == dos['instance_id']
        assert sample['producer_status']['source_id'] == dos['instance_id']
        upstream = sample['upstream_coverage']
        assert isinstance(upstream, list) and upstream, 'endpoint upstream coverage is empty'
        source_ids = [status['source_id'] for status in upstream]
        assert all(type(source_id) is str and source_id for source_id in source_ids), 'invalid upstream source identity'
        assert len(source_ids) == len(set(source_ids)), 'duplicate upstream source identity'
        assert all(status['complete'] is True for status in [sample['source'], sample['producer_status'], *sample['upstream_coverage']])
        packet = one([json.loads(blob(ref)) for ref in sample['output_evidence']], lambda p: p['producer'] == producer, 'original endpoint packet')
        assert packet['output'] == {'rows': [sample['row']], 'coverage': sample['upstream_coverage']}
        assert sample['row']['id'].startswith(f"{dos['instance_id']}/{sequence}/")
        endpoint_values.append(guest(sample['row']))
        for ref in sample['output_evidence'] + sample['row']['evidence']: assert ref in selected['evidence']
    assert endpoint_values == [0, 1] and type(fields['value']) is int and fields['value'] == 1 and fields['direction'] == 'up'
    assert fields['input_complete'] is True and selected['clock'] == fields['current']['row']['clock']
    assert fields['previous']['producer']['observation_seq'] < fields['current']['producer']['observation_seq']
    for ref in selected['evidence']: blob(ref)
    def action(post, confirmation, before, after):
        request_meta, queued = api(post); request = request_meta['request']
        response_meta, receipt = api(confirmation)
        assert request_meta['path'] == '/api/v1/lane-addons/actions'
        assert request == {'instance_id': dos['instance_id'], 'expected_incarnation': dos['incarnation'], 'request_id': receipt['request_id'], 'action': {'kind': 'increment'}}
        assert response_meta['path'] == f"/api/v1/lane-addons/actions?instance_id={dos['instance_id']}&request_id={receipt['request_id']}"
        assert queued['request_id'] == receipt['request_id'] and queued['state'] == 'queued'
        assert receipt['state'] == 'confirmed' and receipt['instance_id'] == receipt['incarnation'] == dos['instance_id']
        assert receipt['executor'] == dos['container_id'] and receipt['action'] == request['action']
        canonical = {'context': {'instance_id': dos['instance_id'], 'incarnation': dos['incarnation']}, 'request_id': receipt['request_id'], 'action': request['action']}
        assert receipt['input_sha256'] == sha(json.dumps(canonical, sort_keys=True, separators=(',', ':')).encode())
        result = receipt['result']
        assert (result['before_counter'], result['after_counter']) == (before, after)
        assert result['instance_id'] == result['incarnation'] == dos['instance_id'] and result['request_id'] == receipt['request_id']
        return receipt['request_id']
    requests = [action(12, 13, 0, 1), action(33, 34, 1, 2), action(46, 47, 2, 3)]
    assert len(set(requests)) == 3
    assert api(30)[0]['request'] == {'instance_id': statistics['instance_id']}
    assert api(30)[0]['observed_at'] < api(33)[0]['observed_at']
    statistics_removed = api(31)[1]
    assert owner(statistics_removed, statistics['instance_id'])['phase']['kind'] == 'detached'
    progressed = api(35)[1]
    assert identity(owner(progressed, dos['instance_id'])) == identity(dos)
    assert identity(owner(progressed, metric['instance_id'])) == identity(metric)
    assert owner(progressed, dos['instance_id'])['phase']['kind'] == owner(progressed, metric['instance_id'])['phase']['kind'] == 'attached'
    assert owner(progressed, statistics['instance_id'])['phase']['kind'] == 'detached'
    assert guest(one(progressed['rows'], lambda r: r['lane_id'] == dos['instance_id'] + '/dos/guest', 'DOS after statistics detach')) == 2
    restored = api(42)[1]
    new_statistics = one(restored['instances'], lambda i: i['configuration']['id'] == 'statistics' and i['phase']['kind'] == 'attached', 'restored statistics')
    assert new_statistics['instance_id'] != statistics['instance_id']
    assert api(43)[0]['request'] == {'instance_id': metric['instance_id']}
    assert api(43)[0]['observed_at'] < api(46)[0]['observed_at']
    assert owner(api(44)[1], metric['instance_id'])['phase']['kind'] == 'detached'
    progressed = api(48)[1]
    assert identity(owner(progressed, dos['instance_id'])) == identity(dos) and owner(progressed, dos['instance_id'])['phase']['kind'] == 'attached'
    assert guest(one(progressed['rows'], lambda r: r['lane_id'] == dos['instance_id'] + '/dos/guest', 'DOS after metric detach')) == 3
    current_statistics = owner(progressed, new_statistics['instance_id'])
    assert identity(current_statistics) == identity(new_statistics) and current_statistics['phase']['kind'] == 'attached'
    assert current_statistics['rows_count'] == 0 and not any(r['lane_id'].startswith(current_statistics['instance_id'] + '/') for r in progressed['rows'])
    assert current_statistics['binding']['sources'] == [{'kind': 'lane_output', 'source_id': 'difference', 'installation_id': 'difference', 'output_id': 'difference', 'selection': 'latest_completed'}]
    record = document(f".masc/lane-addons/observations/{sha(current_statistics['instance_id'].encode())}/{current_statistics['observation_seq']:020d}.json")
    assert record['output']['rows'] == []
    source = one(record['sources'], lambda s: s['source_id'] == 'difference', 'missing source')
    coverage = one(record['output']['coverage'], lambda s: s['source_id'] == 'difference', 'missing coverage')
    assert source['observations'] == [] and coverage in progressed['coverage']
    for status in [source, coverage]: assert status['complete'] is False and status['cursor'] is None and status['incarnation'] == 'unobserved'
    final = api(67)[1]; final_ids = {i['instance_id'] for i in final['instances']}
    assert len(final_ids) == len(final['instances']) == 5 and all(i['phase']['kind'] == 'detached' for i in final['instances'])
    replacement_metric = one(final['instances'], lambda i: i['configuration']['id'] == 'difference' and i['instance_id'] != metric['instance_id'], 'replacement metric in final history')
    for number, instance in [(62, new_statistics), (64, replacement_metric), (66, dos)]:
        meta, response = api(number)
        assert meta['path'] == '/api/v1/lane-addons/detach' and meta['request'] == {'instance_id': instance['instance_id']}
        assert response['instance_id'] == instance['instance_id']
        assert meta['observed_at'] < api(67)[0]['observed_at']
    assert selected in api(68)[1]['rows'], 'final Slice lost the frozen measured row'
    summary = document('evidence/summary.json')
    assert summary['status'] == 'passed' and summary['final_snapshot'] == final
    cleanup = [item for item in summary['cleanup'] if 'instance_id' in item]
    servers = [item for item in summary['cleanup'] if 'server_pid' in item]
    assert len(servers) == 1 and type(servers[0]['exit_code']) is int and servers[0]['exit_code'] == 0
    assert len(cleanup) == 5 and {item['instance_id'] for item in cleanup} == final_ids == set(summary['owned_instances'])
    assert all(item['container_absent'] is True and item['forced_removal'] == [] for item in cleanup)
    for name, entry in manifest['screenshots'].items():
        original = PurePosixPath(entry['original_relative_path'])
        result = document(str(original.parent / 'result.json'))
        assert result['screenshots'][original.name] == entry['sha256'] and result['page_errors'] == []
        assert result['response_mocking'] is False and result['actual_dos_guest'] is True and result['controlled_snapshot_fixture'] is False
        assert result['source_commit'] == manifest['source_identity']['host_commit'] and result['dashboard_source'] == manifest['source_identity']['dashboard_commit']
        for response in result['responses']:
            assert sha(files[str(original.parent / response['file'])]) == response['sha256'] and response['status'] == 200
    return {'status': 'passed', 'claims': ['0_to_1_original_endpoint_change', 'derived_detach_preserves_DOS_progress_and_honest_missing_input', 'frozen_metric_survives_final_detach'],
            'original_endpoint_values': endpoint_values, 'metric': {'value': fields['value'], 'direction': fields['direction']},
            'guest_captures': sorted(checked_captures.values(), key=lambda item: item['counter']),
            'same_DOS_instance': dos['instance_id'], 'actual_action_executor': dos['container_id'],
            'frozen_metric_row': selected['id'], 'normal_cleanup_instances_recorded': len(cleanup),
            'scope': 'Selected historical bytes only; no live rerun, CI authenticity, current deployment, gameplay, interval coverage or causal claim.'}


if __name__ == '__main__':
    files, manifest = load_bundle()
    print(json.dumps(check_recorded_joins(files, manifest), indent=2))
