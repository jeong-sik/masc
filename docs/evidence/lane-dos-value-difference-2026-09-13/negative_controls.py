"""Corrupt only in-memory copies to verify the recorded cross-file checks."""
import json
import verify

files, manifest = verify.load_bundle()
assert verify.check_recorded_joins(files, manifest)['status'] == 'passed'


def mutate_response(copied, number, change):
    path = f'evidence/{number:04d}.raw'
    response = json.loads(copied[path]); change(response)
    copied[path] = json.dumps(response).encode()
    receipt_path = f'evidence/{number:04d}.json'
    receipt = json.loads(copied[receipt_path])
    receipt['sha256'] = verify.sha(copied[path])
    copied[receipt_path] = json.dumps(receipt).encode()


def dos_replaced(copied):
    def change(snapshot):
        next(i for i in snapshot['instances'] if i['configuration']['id'] == 'dos')['container_id'] = 'another-container'
    mutate_response(copied, 35, change)


def fabricated_zero_count(copied):
    def change(snapshot):
        worker = next(i for i in snapshot['instances'] if i['configuration']['id'] == 'statistics' and i['phase']['kind'] == 'attached')
        worker['rows_count'] = 1
        snapshot['rows'].append({'lane_id': worker['instance_id'] + '/statistics', 'fields': {'observed_row_count': 0}})
    mutate_response(copied, 48, change)


def frozen_row_lost(copied):
    def change(snapshot):
        snapshot['rows'] = [row for row in snapshot['rows'] if row['id'] != manifest['selected_increment_row_id']]
    mutate_response(copied, 68, change)


def mutate_endpoint(copied, change):
    """Rehash the observation and frozen bundle, then its HTTP receipt.

    The new controls must reach the endpoint contract instead of failing an
    earlier blob/receipt digest or original-retained-row equality check.
    """
    freeze = json.loads(copied['evidence/0029.raw'])
    blob_path = lambda ref: '.masc/lane-addons/evidence/' + ref['sha256'] + '.json'
    bundle = json.loads(copied[blob_path(freeze['evidence'])])
    original_ref, = bundle['observations']
    record = json.loads(copied[blob_path(original_ref)])
    selected = next(row for row in record['output']['rows'] if row['id'] == manifest['selected_increment_row_id'])
    change(selected['fields']['current'])
    raw_record = json.dumps(record).encode()
    owner, sequence, _ = selected['id'].split('/', 2)
    copied[f'.masc/lane-addons/observations/{verify.sha(owner.encode())}/{int(sequence):020d}.json'] = raw_record

    def rehashed(ref, raw):
        digest = verify.sha(raw)
        new = {**ref, 'sha256': digest, 'uri': 'lane-evidence:' + digest}
        if 'path' in new:
            new['path'] = new['path'].rsplit('/', 1)[0] + '/' + digest + '.json'
        copied[blob_path(new)] = raw
        return new

    bundle['observations'] = [rehashed(original_ref, raw_record)]
    replacement = rehashed(freeze['evidence'], json.dumps(bundle).encode())
    mutate_response(copied, 29, lambda response: response.update(evidence=replacement))


def wrong_endpoint_source(copied):
    mutate_endpoint(copied, lambda endpoint: endpoint['source'].update(source_id='different-input'))


def empty_endpoint_coverage(copied):
    mutate_endpoint(copied, lambda endpoint: endpoint.update(upstream_coverage=[]))


controls = []
for name, mutate, reason in [('DOS replaced after statistics removal', dos_replaced, None),
                             ('Missing metric reported as zero count', fabricated_zero_count, None),
                             ('Frozen row absent from final Slice', frozen_row_lost, None),
                             ('Endpoint source differs from binding', wrong_endpoint_source, 'endpoint source differs from metric binding'),
                             ('Endpoint upstream coverage is empty', empty_endpoint_coverage, 'endpoint upstream coverage is empty')]:
    copied = dict(files); mutate(copied)
    try:
        verify.check_recorded_joins(copied, manifest)
    except AssertionError as error:
        if reason is not None:
            assert str(error) == reason, 'Endpoint control failed before its semantic boundary'
        controls.append({'name': name, 'rejected': True, 'semantic_check': reason})
    else:
        raise AssertionError('Corrupted evidence was accepted: ' + name)
print(json.dumps({'status': 'passed', 'controls': controls,
                  'scope': 'In-memory corrupted inputs only, not runtime observations. Endpoint controls rehash the retained observation, frozen bundle and HTTP receipt, and require the exact semantic rejection.'}, indent=2))
