"""Reject broken recorded joins in memory, after verifying the untouched archive.

Mutations are test inputs only. They never rewrite the archived evidence or its
manifest, and exercise semantic checks independently of manifest-hash rejection.
"""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recorded_verifier', ROOT / 'verify.py')
verifier = importlib.util.module_from_spec(spec)
with redirect_stdout(io.StringIO()) as baseline_output:
    spec.loader.exec_module(verifier)
baseline = json.loads(baseline_output.getvalue())


def change(files, name, mutate):
    value = json.loads(files[name])
    mutate(value)
    files[name] = json.dumps(value).encode()


def summary(probe, mutate):
    return lambda files: change(files, probe + '/evidence/summary.json', mutate)


def statistics_attribution(files, field, value):
    prefix = 'dos-statistics/evidence/'
    recorded = json.loads(files[prefix + 'statistics-after.json'])
    row = recorded['statistics']
    row_id = row['id']
    owner, sequence, _ = row_id.split('/', 2)
    def mutate_row(row):
        if field == 'upstream_id':
            row['fields']['upstream_rows'][0]['id'] = value
        else:
            row['fields']['producer'][field] = value
    change(files, prefix + 'statistics-after.json', lambda value: mutate_row(value['statistics']))
    def mutate_api(value):
        mutate_row(next(row for row in value['rows'] if row['id'] == row_id))
    change(files, prefix + '0007.raw', mutate_api)
    retained = f"dos-statistics/.masc/lane-addons/observations/{verifier.sha(owner.encode())}/{int(sequence):020d}.json"
    change(files, retained, lambda value: mutate_api(value['output']))


cases = [
    ('execution_image_mismatch', lambda f: change(f, 'dos-host/evidence/container.json', lambda v: v.update(Image='sha256:unrelated')), 'DOS execution image differs'),
    ('skill_writable', lambda f: change(f, 'dos-host/evidence/0014.raw', lambda v: v.update(access='writable')), 'Skill read is not ready and read-only'),
    ('skill_wrong_installation', lambda f: change(f, 'dos-host/evidence/0014.raw', lambda v: v['reference']['identity'].update(source_id='another-source')), 'Skill belongs to another installation'),
    ('skill_read_after_removal', lambda f: change(f, 'dos-host/evidence/0028.json', lambda v: v.update(status=200)), 'removed Skill still readable'),
    ('retained_statistics_missing', lambda f: change(f, 'dos-statistics/evidence/0018.raw', lambda v: v.update(rows=[r for r in v['rows'] if 'observed_row_count' not in r['fields']])), 'post-detach statistics row missing'),
    ('retained_consumer_coverage_missing', lambda f: change(f, 'dos-statistics/evidence/0018.raw', lambda v: v.update(coverage=[c for c in v['coverage'] if c['source_id']!='retained:01a0962f-beac-7000-9f49-61da64f6290a'])), 'retained consumer coverage absent'),
    ('missing_input_coverage_complete', lambda f: change(f, 'dos-statistics/evidence/0015.raw', lambda v: next(c for c in v['coverage'] if c['source_id']=='dos-output').update(complete=True)), 'missing input coverage is not unavailable'),
    ('missing_input_coverage_absent', lambda f: change(f, 'dos-statistics/evidence/0015.raw', lambda v: v.update(coverage=[c for c in v['coverage'] if c['source_id']!='dos-output'])), 'missing bound-source coverage absent'),
    ('capture_measurement_wrong_row', summary('dos-host', lambda v: v['measurements'][0].update(row_id='another-instance/1/capture-2')), 'measured capture missing'),
    ('capture_export_changed', lambda f: f.__setitem__('dos-host/evidence/after.png', f['dos-host/evidence/before.png']), 'exported capture digest differs'),
    ('capture_blob_changed', lambda f: f.__setitem__('dos-host/.masc/lane-addons/evidence/' + hashlib.sha256(f['dos-host/evidence/before.png']).hexdigest() + '.json', b'unrelated blob'), 'capture export differs from retained blob'),
    ('cleanup_empty', summary('dos-host', lambda v: v.update(cleanup=[])), 'explicit owned server cleanup required'),
    ('cleanup_server_exit_missing', summary('dos-host', lambda v: v['cleanup'][0].pop('exit_code')), 'exit_code'),
    ('cleanup_server_exit_nonzero', summary('dos-host', lambda v: v['cleanup'][0].update(exit_code=1)), 'server exit must be explicitly zero'),
    ('cleanup_final_instance_missing', summary('dos-host', lambda v: v['cleanup'].pop()), 'cleanup must cover every final instance'),
    ('cleanup_absence_missing', summary('dos-host', lambda v: v['cleanup'][1].pop('container_absent')), 'container_absent'),
    ('cleanup_forced_removal_missing', summary('dos-host', lambda v: v['cleanup'][1].pop('forced_removal')), 'forced_removal'),
    ('cleanup_forced_removal_present', summary('dos-host', lambda v: v['cleanup'][1].update(forced_removal=['docker rm -f'])), 'normal container absence must be explicit'),
    ('all_attempts_empty', lambda f: f.__setitem__('dos-host/evidence/all-attempts-cleanup.json', b'[]'), 'all-attempts cleanup is missing'),
    ('all_attempts_final_instance_missing', lambda f: change(f, 'dos-host/evidence/all-attempts-cleanup.json', lambda v: v.pop(0)), 'all-attempts cleanup omits a final instance'),
    ('all_attempts_prior_absence_missing', lambda f: change(f, 'dos-host/evidence/all-attempts-cleanup.json', lambda v: v[-1].pop('container_absent')), 'container_absent'),
    ('statistics_wrong_producer', lambda f: statistics_attribution(f, 'instance_id', 'unrelated-producer'), 'statistics attribution differs'),
    ('statistics_wrong_run', lambda f: statistics_attribution(f, 'run_id', 'unrelated-run'), 'statistics attribution differs'),
    ('statistics_wrong_installation', lambda f: statistics_attribution(f, 'installation_id', 'unrelated-installation'), 'statistics attribution differs'),
    ('statistics_wrong_consumer', lambda f: change(f, 'dos-statistics/evidence/statistics-after.json', lambda v: v['consumer'].update(instance_id='unrelated-consumer')), 'statistics consumer differs'),
    ('statistics_wrong_upstream_row', lambda f: statistics_attribution(f, 'upstream_id', 'another-producer/3/capture-5'), 'statistics upstream projection differs'),
    ('statistics_reused_consumer_sequence', lambda f: change(f, 'dos-statistics/evidence/0011.raw', lambda v: next(i for i in v['instances'] if i['addon_id'] == 'output-statistics').update(observation_seq=5)), 'statistics consumer differs'),
    ('companion_detached_with_dos', lambda f: change(f, 'dos-host/evidence/0026.raw', lambda v: next(i for i in v['instances'] if i['addon_id'] == 'msx-observer').update(phase={'kind': 'detached'})), 'same companion must remain attached'),
    ('companion_identity_replaced', lambda f: change(f, 'dos-host/evidence/0026.raw', lambda v: next(i for i in v['instances'] if i['addon_id'] == 'msx-observer').update(instance_id='replacement-companion')), 'exact instance must occur once'),
    ('dos_not_detached', lambda f: change(f, 'dos-host/evidence/0026.raw', lambda v: next(i for i in v['instances'] if i['addon_id'] == 'dos-world').update(phase={'kind': 'attached'})), 'same DOS owner must be detached'),
]
results = []
for name, mutate, expected in cases:
    copied = dict(verifier.files)
    mutate(copied)
    try:
        verifier.check_recorded_joins(copied, verifier.manifest)
    except (AssertionError, KeyError) as error:
        assert expected in str(error), (name, expected, str(error))
        results.append({'case': name, 'rejected': True, 'reason': str(error)})
    else:
        raise AssertionError('corrupted join was accepted: ' + name)
print(json.dumps({'untouched_archive_sha256': verifier.sha((ROOT / 'original-evidence.tar.gz').read_bytes()),
                  'baseline_passed': baseline, 'mutations_in_memory_only': True,
                  'fresh_runtime_execution': False, 'rejected_controls': len(results), 'controls': results}, indent=2))
