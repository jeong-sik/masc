"""Resource/source qualification of one owned run; no screen assertions."""
import hashlib
import json
from pathlib import Path
from probe import tui_observer as frozen_observer


PIN_LENGTHS = {'source': 40, 'server_sha256': 64, 'tui_sha256': 64,
               'runner_sha256': 64, 'observer_sha256': 64,
               'trace_sha256': 64, 'runtime_fixture_sha256': 64}


def valid_pins(expected):
    return all(isinstance(expected.get(key), str) and len(expected[key]) == size
               and set(expected[key]) <= set('0123456789abcdef')
               for key, size in PIN_LENGTHS.items())


def qualify_arm(directory, execution, expected):
    directory = Path(directory)
    inputs = {}
    missing = []

    def read(name, optional=False):
        path = directory / name
        if not path.exists() and optional:
            return {}
        try:
            data = path.read_bytes()
            inputs[name] = hashlib.sha256(data).hexdigest()
            value = json.loads(data)
            if not isinstance(value, dict):
                raise ValueError("expected object")
            return value
        except (OSError, ValueError):
            missing.append(name)
            return {}

    cleanup = read('cleanup.json')
    fallback = read('fallback-cleanup.json', optional=True)
    failure = read('failure.json', optional=True)
    identity = read('identity.json')
    owned = read('owned-process.json')
    observation = read('tui-observer/observation.json')
    summary = read('summary.json')
    checks = {}
    checks['expected_pins_valid'] = valid_pins(expected)
    checks['qualifier_parser_source'] = (
        hashlib.sha256(Path(frozen_observer.__file__).read_bytes()).hexdigest()
        == expected.get('observer_sha256')
    )

    def exact(record, key, wanted):
        return type(record.get(key)) is type(wanted) and record[key] == wanted

    resource = {
        'server_reaped': True, 'server_returncode': 0, 'forced_kill': False,
        'model_server_stopped': True, 'sampler_stopped': True,
        'provider_requests_drained': True, 'active_provider_requests': 0,
        'provider_handler_threads': 0,
    }
    checks['main_cleanup_complete'] = all(exact(cleanup, k, v) for k, v in resource.items())
    checks['no_cleanup_errors'] = cleanup.get('cleanup_errors', []) == [] and all(
        not (directory / name).exists() or r.get('cleanup_errors') == []
        for name, r in (('fallback-cleanup.json', fallback), ('failure.json', failure))
    )
    checks['cleanup_receipts_readable'] = not any(
        name in missing for name in ('cleanup.json', 'fallback-cleanup.json', 'failure.json')
    )
    checks['fallback_consistent'] = not (directory / 'fallback-cleanup.json').exists() or all(
        exact(fallback, k, v) for k, v in (
            ('server_reaped', True), ('server_returncode', 0), ('model_server_stopped', True),
        )
    )
    receipt_presence = [(directory / name).exists()
                        for name in ('failure.json', 'fallback-cleanup.json')]
    checks['failure_receipts_match_exit'] = (
        type(execution.get('returncode')) is int
        and ((execution['returncode'] == 0 and not any(receipt_presence))
             or (execution['returncode'] != 0 and all(receipt_presence)
                 and isinstance(failure.get('type'), str) and bool(failure['type'])
                 and isinstance(failure.get('message'), str)))
    )
    base = identity.get('base')
    command = execution.get('command', [])
    original_output = None
    if isinstance(command, list) and command.count('--output') == 1:
        at = command.index('--output') + 1
        if at < len(command) and isinstance(command[at], str) and Path(command[at]).is_absolute():
            original_output = Path(command[at])
    checks['execution_output_binding'] = (
        original_output is not None
        and original_output.name == f"owners-{execution.get('population')}-{execution.get('variant')}"
        and base == str(original_output / 'owned-base')
    )
    bases = [owned.get('base'), cleanup.get('base_path')]
    bases += [observation.get(when, {}).get('paths', {}).get('effective_base_path')
              for when in ('server_before', 'server_after')]
    if (directory / 'fallback-cleanup.json').exists():
        bases.append(fallback.get('base_path'))
    checks['owned_base_binding'] = isinstance(base, str) and bool(base) and all(x == base for x in bases)
    # A fallback receipt cannot supply missing main-cleanup fields.
    cleanup_ok = all(checks[k] for k in (
        'main_cleanup_complete', 'no_cleanup_errors', 'cleanup_receipts_readable',
        'fallback_consistent', 'failure_receipts_match_exit', 'owned_base_binding', 'execution_output_binding',
    ))
    source = expected.get('source')
    checks['source_identity'] = all(x == source for x in (
        identity.get('source'), observation.get('source'),
        execution.get('source_expected'), execution.get('source_actual'),
    ))
    checks['server_digest'] = identity.get('sha256') == expected['server_sha256']
    checks['owned_process_binding'] = (
        type(owned.get('pid')) is int and owned['pid'] > 0
        and owned['pid'] == observation.get('server_pid')
        and owned.get('source') == source and owned.get('binary_sha256') == expected['server_sha256']
    )
    checks['tui_digest'] = all(observation.get(k) == expected['tui_sha256'] for k in (
        'binary_sha256', 'binary_sha256_after',
    ))
    for when in ('server_before', 'server_after'):
        build = observation.get(when, {}).get('build', {})
        checks[when + '_identity'] = (
            build.get('binary_commit') == source
            and build.get('executable_sha256') == expected['server_sha256']
        )
    runtime_ids = [observation.get(when, {}).get('build', {}).get('runtime_instance_id')
                   for when in ('server_before', 'server_after')]
    checks['same_runtime'] = (observation.get('same_runtime') is True
                              and isinstance(runtime_ids[0], str) and bool(runtime_ids[0])
                              and runtime_ids[0] == runtime_ids[1])
    checks['probe_identity'] = all(identity.get(k) == expected[k] for k in (
        'runner_sha256', 'observer_sha256', 'runtime_fixture_sha256',
    )) and observation.get('observer_source_sha256') == expected['observer_sha256']
    checks['tui_exit'] = (
        exact(observation, 'exit_code', 0) and exact(observation, 'forced_kill', False)
        and observation.get('error', 'missing') is None
    )
    checks['capture_record'] = all(observation.get(k) is True for k in (
        'capture_qualified', 'native_report_consistent', 'pty_eof_observed',
    ))
    frames = []
    reparsed = {}
    try:
        data = (directory / 'tui-observer/frame-timing.txt').read_bytes()
        inputs['tui-observer/frame-timing.txt'] = hashlib.sha256(data).hexdigest()
        reparsed = frozen_observer.parse_native_report(data.decode())
        for line in data.decode().splitlines():
            if line.startswith('{'):
                row = json.loads(line)
                if row.get('schema') == 'masc.tui.frame.v2':
                    elapsed = int(row['elapsed_ns'])
                    if elapsed < 0:
                        raise ValueError('negative elapsed')
                    frames.append(row)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        missing.append('tui-observer/frame-timing.txt')
    checks['current_native_report_consistent'] = (
        reparsed.get('native_report_consistent') is True
        and all(observation.get(k) == v for k, v in reparsed.items())
    )
    copies_ok = True
    for filename, key in (('keeper_scale_session.py', 'runner_sha256'),
                          ('tui_observer.py', 'observer_sha256'),
                          ('keeper_scale_trace.py', 'trace_sha256')):
        try:
            inputs[filename] = hashlib.sha256((directory / filename).read_bytes()).hexdigest()
            copies_ok = copies_ok and inputs[filename] == expected.get(key)
        except OSError:
            copies_ok = False
    checks['captured_probe_copies_match'] = copies_ok
    list_builds = [r for r in frames if r.get('phase') == 'build' and r.get('surface') == 'keeper-list']
    checks['list_builds_observed'] = bool(list_builds)
    checks['workload'] = (
        exact(execution, 'returncode', 0) and summary.get('keepers') == execution.get('population')
        and summary.get('messages') == 2 * execution.get('population', -1)
        and summary.get('succeeded_operations') == summary.get('messages')
        and not (directory / 'failure.json').exists()
    )
    checks['required_inputs_readable'] = not missing
    safety_keys = ('expected_pins_valid', 'qualifier_parser_source', 'main_cleanup_complete', 'no_cleanup_errors',
                   'cleanup_receipts_readable', 'fallback_consistent', 'failure_receipts_match_exit',
                   'owned_base_binding', 'execution_output_binding', 'owned_process_binding', 'source_identity', 'server_digest',
                   'tui_digest', 'server_before_identity', 'server_after_identity',
                   'same_runtime', 'probe_identity', 'captured_probe_copies_match', 'tui_exit')
    return {
        'scope': 'Direct owned resource receipts and recorded source/digests only; no global host quiescence, descendant absence, applied key, UI row cardinality or physical paint claim.',
        'cleanup_ok': cleanup_ok, 'next_arm_safe': all(checks[k] for k in safety_keys),
        'eligible': all(checks.values()), 'checks': checks,
        'missing_or_invalid': missing, 'native_list_builds': len(list_builds),
        'inputs_sha256': inputs,
    }
