"""Compare independently captured runs; elapsed time is descriptive, not causal."""
import argparse
import hashlib
import json
from pathlib import Path


def load(root, name):
    return json.loads((root / name).read_text())


def summarize(root):
    report = load(root, 'report.json')
    turns = load(root, 'keeper-turn-records.json')['response']['entries']
    assert len(turns) == 1
    turn = turns[0]['record']
    ids = turn['execution_ids']
    assert len(ids) == len(set(ids))
    rows = load(root, 'keeper-tool-calls.json')['response']['entries']
    durable = [row for row in rows if row['record_kind'] == 'tool_call']
    assert len(durable) == len({row['execution_id'] for row in durable}), 'duplicate durable execution ID'
    by_id = {row['execution_id']: row for row in durable}
    raw = load(root, 'raw-tool-results.json')
    by_use = {event['tool_use_id']: event for event in raw}
    assert len(by_use) == len(raw) == len(ids)
    outer = []
    compositions = []
    for identity in ids:
        row = by_id[identity]
        event = by_use[row['tool_use_id']]
        assert row['tool'] == event['tool_name']
        assert row['success'] == (not event['tool_error'])
        outer.append({'tool': row['tool'], 'success': row['success'],
                      'bytes': len(event['tool_result'].encode())})
        if row['tool'] == 'keeper_compose_browser-live-click-content':
            payload, _ = json.JSONDecoder().raw_decode(event['tool_result'])
            nodes = payload['actions'] if row['success'] else payload['settled']
            assert [node['node_id'] for node in nodes] == ['click', 'content']
            for node in nodes:
                actual = by_id[node['execution_id']]
                assert actual['tool'] == node['tool_name']
                assert actual['input'] == node['input']
                assert actual['tool_use_id'] == node['tool_use_id']
                assert actual['success'] == (node['result']['disposition'] == 'completed')
            compositions.append({'success': row['success'],
                'follow_disposition': nodes[0]['result']['disposition'],
                'read_disposition': nodes[1]['result']['disposition']})
    context_bytes = (root / 'tui-context.json').read_text()
    message = load(root, '08-user-message.json')['message']
    assert message.endswith(context_bytes)
    request = message[:-len(context_bytes)]
    fixtures = load(root, 'fixture-pages.json')
    fixture_digest = hashlib.sha256(json.dumps(fixtures, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    bundle = load(root, 'bundle.json')
    return {'source_commit': report['composition_source_commit'],
        'operation_id': report['operation_id'], 'state': report['operation_state'],
        'runtime_id': report['runtime_id'], 'fixture_sha256': fixture_digest,
        'request_sha256': hashlib.sha256(request.encode()).hexdigest(),
        'packages': bundle['packages'], 'prompt_blocks': turn['blocks'],
        'outer_calls': len(outer), 'outer_errors': sum(not row['success'] for row in outer),
        'raw_outer_result_bytes': sum(row['bytes'] for row in outer),
        'successful_compositions': sum(item['success'] for item in compositions),
        'compositions': compositions, 'outer_tool_sequence': outer,
        'observed_elapsed_seconds': report['turn_observed_elapsed_seconds']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    before, after = summarize(args.before), summarize(args.after)
    result = {'before': before, 'after': after,
        'same_fixture': before['fixture_sha256'] == after['fixture_sha256'],
        'same_request': before['request_sha256'] == after['request_sha256'],
        'same_runtime': before['runtime_id'] == after['runtime_id'],
        'same_browser_packages': before['packages'] == after['packages'],
        'same_prompt_blocks': before['prompt_blocks'] == after['prompt_blocks'],
        'delta_after_minus_before': {key: after[key] - before[key] for key in
            ['outer_calls', 'outer_errors', 'raw_outer_result_bytes', 'successful_compositions', 'observed_elapsed_seconds']},
        'scope': 'One run per source. Counts join typed turn IDs, durable tool records and raw outer replies. Prompt/source drift is reported; elapsed time and result bytes are not provider-token or causal speed measurements.'}
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ['before', 'after']}, ensure_ascii=False))
