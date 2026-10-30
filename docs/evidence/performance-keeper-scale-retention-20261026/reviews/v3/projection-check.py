"""Pure Python source-extracted validator counterexample; never starts MASC."""
import ast
import collections
import copy
import hashlib
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
WT = pathlib.Path('/Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/perf-scale-evidence-retention-20261026')


def extracted(path, names, namespace):
    source = path.read_text()
    selected = [node for node in ast.parse(source).body
                if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    assert {node.name for node in selected} == set(names)
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), namespace)
    return hashlib.sha256(source.encode()).hexdigest()


producer = {'json': json, 'hashlib': hashlib, 'defaultdict': collections.defaultdict}
producer_sha = extracted(WT / 'scripts/harness/perf/keeper_scale_session.py',
    ['ProbeError', 'require', 'operation_key', 'index_operations', 'canonical_payload',
     'payload_digest', 'original_payload', 'validate_original_payloads'], producer)
reader = {'json': json, 'hashlib': hashlib, 'pathlib': pathlib, 'collections': collections}
reader_sha = extracted(WT / 'scripts/harness/perf/keeper_scale_packet_audit.py',
    ['read', 'lines', 'objects', 'rpc_result', 'audit_original_payloads'], reader)
manifest = json.loads((HERE / 'source-manifest.json').read_text())
assert producer_sha == next(row['sha256'] for row in manifest['files'] if row['path'].endswith('/keeper_scale_session.py'))
assert reader_sha == next(row['sha256'] for row in manifest['files'] if row['path'].endswith('/keeper_scale_packet_audit.py'))

name, marker = 'scale-keeper-0000', '0123456789abcdef0123456789abcdef'
operations = []
for seq in (1, 2):
    message = json.dumps({'schema': 'masc.keeper-scale-input.v1', 'marker': marker,
                          'keeper': name, 'sequence': seq}, sort_keys=True)
    operations.append({'keeper': name, 'sequence': seq, 'operation_id': 'op-' + str(seq),
                       'original': producer['original_payload'](name, message)})

combined = {**operations[0]['original']['input'],
    'message': '\n\n'.join(op['original']['input']['message'] for op in operations),
    'user_blocks': [{'type': 'text', 'text': op['original']['input']['message']} for op in operations]}
rows, members, public = [], [], {}
for position, op in enumerate(operations):
    execution = combined if position == 0 else op['original']['input']
    row = {'operation_id': op['operation_id'], 'sequence': position, 'created_at': 0.0,
           'state': 'running' if position == 0 else 'queued',
           'source_json': producer['canonical_payload'](op['original']['source']),
           'input_json': producer['canonical_payload'](execution),
           'admission_digest': producer['payload_digest'](op['original']),
           'execution_digest': producer['payload_digest'](execution)}
    rows.append(row)
    member = {'operation_id': op['operation_id'], 'execution_id': 'op-1', 'position': position,
              'admitted_digest': producer['payload_digest'](op['original']['input']),
              'admitted_input_json': producer['canonical_payload'](op['original']['input'])}
    members.append(member)
    # c3cb project_batch_with_db sets every public member.state = leader.state.
    public[(name, op['operation_id'])] = {'operation_id': op['operation_id'],
        'source': op['original']['source'], 'input': execution, 'sequence': str(position),
        'created_at': 0.0, 'state': 'Running', 'admission_digest': row['admission_digest'],
        'execution_digest': row['execution_digest'], 'batch_execution_id': 'op-1',
        'batch_input_digest': member['admitted_digest']}
snapshots = [{'keeper': name, 'snapshot': {'operations': {'columns': [], 'rows': rows},
    'operation_batch_members': {'columns': [], 'rows': members}}}]
cases = []


def observe(label, fn, rejects):
    try:
        fn()
    except (producer['ProbeError'], AssertionError) as error:
        assert rejects, (label, str(error))
        cases.append({'case': label, 'outcome': 'rejected', 'error': type(error).__name__, 'detail': str(error)})
    else:
        assert not rejects, label
        cases.append({'case': label, 'outcome': 'accepted'})


mirrored = copy.deepcopy(public)
mirrored[(name, 'op-2')]['state'] = 'Queued'
observe('main rejects invalid raw-state-mirrored follower',
        lambda: producer['validate_original_payloads'](operations, snapshots, mirrored, False), True)
observe('main accepts correct c3cb projected Running follower',
        lambda: producer['validate_original_payloads'](operations, snapshots, public, False), False)

packet = HERE / 'projection-packet'
packet.mkdir()
(packet / 'principal.json').write_text(json.dumps({'actor': 'dashboard', 'role': 'admin'}))
(packet / 'workload.json').write_text(json.dumps({'marker': marker}))


def reader_case(statuses):
    requests = []
    for number, op in enumerate(operations, 1):
        acceptance = {'operation_id': op['operation_id'], 'state': 'queued', 'queued_count': 1, 'existing': False}
        payload = {'id': number, 'params': {'name': 'masc_keeper_msg',
            'arguments': {'name': name, 'message': op['original']['input']['message']}}}
        requests.append({'phase': 'enqueue', 'status': 200, 'payload': payload,
            'body_utf8': json.dumps({'id': number, 'result': {'structuredContent': acceptance}})})
        payload = {'id': number + 100, 'params': {'name': 'masc_keeper_delegate_status',
            'arguments': {'target': {'kind': 'keeper', 'name': name}, 'operation_id': op['operation_id']}}}
        status = {'schema': 'masc.keeper_chat_operation.v1', **statuses[(name, op['operation_id'])]}
        requests.append({'phase': 'queue-held', 'status': 200, 'payload': payload,
            'body_utf8': json.dumps({'id': number + 100, 'result': {'structuredContent': status}})})
    (packet / 'requests.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in requests))
    reader['audit_original_payloads'](packet, operations, snapshots,
        {key: {'schema': 'masc.keeper_chat_operation.v1', **status} for key, status in statuses.items()}, False)


observe('reader rejects invalid raw-state-mirrored follower', lambda: reader_case(mirrored), True)
observe('reader accepts correct c3cb projected Running follower', lambda: reader_case(public), False)
terminal_snapshot, terminal_public = copy.deepcopy(snapshots), copy.deepcopy(public)
for row in terminal_snapshot[0]['snapshot']['operations']['rows']:
    row.update(state='succeeded', input_json=None)
for member in terminal_snapshot[0]['snapshot']['operation_batch_members']['rows']:
    member['admitted_input_json'] = None
for status in terminal_public.values():
    status.update(state='Succeeded', input=None)
observe('main accepts terminal batch after raw members settle',
        lambda: producer['validate_original_payloads'](operations, terminal_snapshot, terminal_public, True), False)
report = {'schema': 'masc.source-extracted-projection-fix.v1', 'producer_sha256': producer_sha,
          'reader_sha256': reader_sha, 'cases': cases, 'projection_fix_verified': True,
          'masc_processes_started': 0, 'scope': 'Pure Python validator behavior only; c3cb native state projection read from source, not executed.'}
(HERE / 'projection-check-result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
