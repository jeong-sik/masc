"""Inspect captured Keeper turn evidence; never attest semantic adoption.

Inputs are operator-captured artifacts, not authenticated runtime attestations.
This performs no HTTP request, model call, memory write or process control.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


def require(value, message):
    if not value:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON object key')
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda _: require(False, 'Non-finite JSON value'))


def read(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'Expected regular evidence file')
        return stream.read()


def inspect(turns, provider, trace, keeper, turn_ref, proposal_id, fragment):
    require(turns['keeper'] == keeper, 'Turn listing keeper mismatch')
    matches = [e['record'] for e in turns['entries'] if e['record']['turn_ref'] == turn_ref]
    require(len(matches) == 1, 'Expected exactly one selected TurnRecord')
    turn = matches[0]
    require(type(turn['absolute_turn']) is int and turn['absolute_turn'] > 0, 'Invalid absolute turn')
    require(provider['schema'] == 'masc.resolved-provider-input.v1', 'Provider input schema mismatch')
    for key in ('keeper', 'trace_id', 'absolute_turn', 'turn_ref'):
        require(provider[key] == turn[key], 'Provider input and TurnRecord identity mismatch')
    require(turn['keeper'] == keeper and turn['turn_ref'] == turn_ref, 'Selected turn mismatch')
    run = turn['raw_trace_run_ref']
    worker = run['worker_run_id']
    require(isinstance(worker, str) and worker, 'Missing worker identity')
    session = run['session_id']
    agent = run['agent_name']
    require(isinstance(session, str) and session and session == turn['trace_id'],
            'Run reference and TurnRecord session mismatch')
    require(isinstance(agent, str) and agent, 'Missing run reference agent identity')
    require(provider['wire']['capture_id'] == worker, 'Provider capture and trace worker mismatch')
    require(provider['wire']['phase'] == ['Pre_dispatch_serialization'], 'Unsupported wire observation phase')
    require(provider['wire']['body_bytes'] == turn['request_body_bytes'], 'Wire byte count mismatch')
    require(provider['runtime_profile'] == turn['request_runtime_profile'], 'Requested runtime mismatch')
    require(trace and all(r['trace_version'] == 4 and r['worker_run_id'] == worker
                         and r['session_id'] == session and r['agent_name'] == agent
                         for r in trace),
            'Raw trace identity mismatch')
    require(all(type(r['seq']) is int for r in trace) and
            [r['seq'] for r in trace] == list(range(run['start_seq'], run['end_seq'] + 1)),
            'Raw trace is incomplete, duplicated or out of order')
    require(trace[0]['record_type'] == 'run_started' and trace[-1]['record_type'] == 'run_finished',
            'Expected a complete captured run')
    texts = []
    system_prompt_integrity = 'not_present'
    if provider['system_prompt'] is not None:
        prompt = provider['system_prompt']
        prompt_bytes = prompt['text'].encode('utf-8')
        require(type(prompt['bytes']) is int and prompt['bytes'] == len(prompt_bytes),
                'System prompt byte count mismatch')
        require(prompt['sha256'] == hashlib.sha256(prompt_bytes).hexdigest(),
                'System prompt SHA-256 mismatch')
        system_prompt_integrity = 'verified'
        texts.append(prompt['text'])
    for message in provider['messages']:
        require(message['content']['role'] == message['role'], 'Captured message role mismatch')
        for block in message['content']['content_blocks']:
            if block['type'] == 'text':
                texts.append(block['text'])
    fragment_count = sum(text.count(fragment) for text in texts)
    calls = []
    seen = set()
    for start in trace:
        if start['record_type'] != 'tool_execution_started':
            continue
        identity = (start['tool_use_id'], start['tool_turn'], start['tool_planned_index'])
        require(identity not in seen, 'Duplicate tool invocation coordinates')
        seen.add(identity)
        if start['tool_name'] != 'keeper_workspace_memory_read' or start['tool_input'] != {'id': proposal_id}:
            continue
        finishes = [r for r in trace if r['record_type'] == 'tool_execution_finished'
                    and (r['tool_use_id'], r['tool_turn'], r['tool_planned_index']) == identity]
        require(len(finishes) <= 1, 'Duplicate tool completion')
        observation = {'tool_use_id': identity[0], 'started_seq': start['seq'],
                       'completion': 'not_recorded', 'proposal_result': 'not_examined'}
        if finishes:
            finish = finishes[0]
            require(finish['seq'] > start['seq'] and finish['tool_name'] == start['tool_name'],
                    'Tool completion order or name mismatch')
            require(type(finish['tool_error']) is bool, 'Missing tool error observation')
            observation.update(completion='error' if finish['tool_error'] else 'success',
                               finished_seq=finish['seq'],
                               result_sha256=hashlib.sha256(finish['tool_result'].encode()).hexdigest())
        calls.append(observation)
    return {'status': 'inspected', 'keeper': keeper, 'turn_ref': turn_ref, 'worker_run_id': worker,
            'turn_kind': turn['turn_kind'], 'finish_reason': turn['finish_reason'],
            'raw_stop_reason': trace[-1]['stop_reason'], 'proposal_id': proposal_id,
            'complete_fragment_occurrences_in_captured_input': fragment_count,
            'exact_id_read_invocations': calls,
            'system_prompt_integrity': system_prompt_integrity,
            'message_artifact_integrity': 'not_verified',
            'semantic_adoption': 'not_verified', 'source_authenticity': 'not_attested',
            'limits': ['Captured pre-dispatch input does not prove remote provider receipt.',
                       'Message artifact byte counts and hashes are not verified; Python JSON serialization is not the original Yojson byte stream.',
                       'Text occurrence does not establish its dynamic-context origin.',
                       'A successful tool completion does not prove full proposal delivery, reading or understanding.',
                       'Inspect raw tool results, artifact reads and subsequent behavior before claiming adoption.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('turn-records', 'provider-input', 'raw-trace', 'publication', 'fragment'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--keeper', required=True)
    parser.add_argument('--turn-ref', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    inputs = {}
    report = {'status': 'invalid_evidence', 'semantic_adoption': 'not_verified'}
    try:
        for name in ('turn_records', 'provider_input', 'raw_trace', 'publication', 'fragment'):
            raw = read(getattr(args, name))
            inputs[name] = raw
            with (args.output / (name + '.raw')).open('xb') as stream:
                os.chmod(stream.name, 0o600)
                stream.write(raw)
        publication = decode(inputs['publication'])
        require(set(publication) == {'schema', 'proposal_id', 'context_sha256'} and
                publication['schema'] == 'workspace.memory.publication.v1', 'Invalid publication schema')
        for key in ('proposal_id', 'context_sha256'):
            value = publication[key]
            require(isinstance(value, str) and len(value) == 64 and
                    all(c in '0123456789abcdef' for c in value), 'Invalid publication digest')
        fragment = inputs['fragment'].decode()
        require(fragment.strip() and all(marker in fragment for marker in
                (publication['proposal_id'], publication['context_sha256'], 'keeper_workspace_memory_read',
                 'model_proposed', 'not_performed', 'not_checked_against_current_memory')),
                'Incomplete expected discovery fragment')
        trace = [decode(line) for line in inputs['raw_trace'].splitlines() if line.strip()]
        report = inspect(decode(inputs['turn_records']), decode(inputs['provider_input']), trace,
                         args.keeper, args.turn_ref, publication['proposal_id'], fragment)
    except (ValueError, KeyError, TypeError, OSError) as error:
        report['error_type'] = type(error).__name__
        # Do not echo potentially private input, filesystem paths or provider text.
        report['error'] = str(error) if type(error) is ValueError else 'Malformed or unreadable evidence'
    report['source_sha256'] = {name: hashlib.sha256(raw).hexdigest() for name, raw in inputs.items()}
    with (args.output / 'receipt.json').open('x') as stream:
        os.chmod(stream.name, 0o600)
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'status': report['status'], 'output': str(args.output)}))
    return 0 if report['status'] == 'inspected' else 1


if __name__ == '__main__':
    raise SystemExit(main())
