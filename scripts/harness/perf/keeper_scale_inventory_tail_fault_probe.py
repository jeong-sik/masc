#!/usr/bin/env python3
"""Focused inventory/output fault checks; never audit a supplied packet's SQL."""
import argparse
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from unittest import mock


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    return {str(p.relative_to(directory)): digest(p) for p in directory.rglob('*') if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reader', type=Path, default=Path(__file__).with_name('keeper_scale_packet_audit.py'))
    parser.add_argument('--baseline-reader', type=Path)
    parser.add_argument('--packet', type=Path, help='optional supplied 650-record regression packet/capture; only four JSON files are read')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=False, exist_ok=False)
    output = args.output.resolve()
    spec = importlib.util.spec_from_file_location('staged_inventory_reader', args.reader)
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    results = []

    def case(name, function):
        try:
            details = function()
            results.append({'case': name, 'passed': True, 'details': details})
        except BaseException as error:
            results.append({'case': name, 'passed': False, 'error_type': type(error).__name__, 'error': str(error)})

    def rejected(function, expected=Exception):
        try:
            function()
        except expected as error:
            return type(error).__name__
        raise AssertionError('malformed input was accepted')

    with tempfile.TemporaryDirectory(prefix='inventory-tail-probe-', dir=output) as temporary:
        temporary = Path(temporary).resolve()
        base = temporary / 'synthetic-base'
        names = ['probe-owner-%04d' % i for i in range(300)]
        volumes = sorted('masc-keeper-' + kind + '-' + name for name in names for kind in ['work', 'build'])
        expected = set(volumes)
        phases = [{'phase': 'synthetic', 'wall_time_ns': 0}]

        def rows(selected):
            return [{'argv': [str(base / 'deny-guest-commands/container'), 'volume', 'inspect', volume],
                     'time_ns': 1_000_000_000 + i} for i, volume in enumerate(selected)]

        def coverage(selected):
            inventory, unclassified = reader.classify_inventory(rows(selected), base, expected)
            assert unclassified == []
            return reader.inventory_coverage(inventory, expected, phases)

        def count_case(count):
            selected = (volumes * (count // len(volumes))) + volumes[:count % len(volumes)]
            result = coverage(selected)
            assert result['observed_inspection_commands'] == count
            assert result['complete_observed_segments'] == count // len(volumes)
            partial = result['final_partial_segment']
            tail = count % len(volumes)
            assert (partial is not None) == bool(tail)
            if partial:
                assert partial['complete'] is False and partial['exact_expected_volume_set'] is False
                assert partial['commands'] == partial['observed_volume_count'] == tail
                assert partial['expected_volume_count'] == 600
                assert partial['missing_volumes'] == sorted(expected - set(selected[-tail:]))
            for group in result['sweeps'][:count // len(volumes)]:
                assert group['complete'] is True and group['exact_expected_volume_set'] is True
                assert group['commands'] == group['observed_volume_count'] == 600 and group['missing_volumes'] == []
            if count == 0:
                assert result['sweeps'] == [] and partial is None
            return {'commands': count, 'complete_segments': result['complete_observed_segments'],
                    'partial_observed_volumes': tail, 'partial_missing_volumes': len(partial['missing_volumes']) if partial else 0}

        # Block all SQL in this process, including accidental full-audit entry.
        with mock.patch.object(reader.sqlite3, 'connect', side_effect=AssertionError('SQL forbidden in focused probe')):
            for count in [0, 1, 48, 599, 600, 648, 1200, 1248]:
                case('observed_count_' + str(count), lambda count=count: count_case(count))
            case('partial_subset_need_not_be_prefix', lambda: coverage(volumes[51:99]))
            case('full_counter_is_order_independent', lambda: coverage(list(reversed(volumes))))
            for name, selected in [
                ('duplicate_partial', [volumes[0], volumes[0]]),
                ('unknown_partial', [volumes[0], 'unknown-volume']),
                ('duplicate_full', volumes[:-1] + [volumes[0]]),
                ('unknown_full', volumes[:-1] + ['unknown-volume']),
                ('duplicate_tail_after_complete', volumes + [volumes[0], volumes[0]]),
                ('unknown_tail_after_complete', volumes + ['unknown-volume']),
                ('partial_before_later_full_not_a_final_tail', volumes[:48] + volumes),
            ]:
                case(name, lambda selected=selected: rejected(lambda: coverage(selected), AssertionError))

            def direct_bad_tail():
                for selected in [[volumes[0], volumes[0]], [volumes[0], 'unknown-volume']]:
                    inventory = [('container_volume_inspect', row) for row in rows(selected)]
                    rejected(lambda: reader.inventory_coverage(inventory, expected, phases), AssertionError)
                return 'both duplicate and unknown rejected without depending on classifier'
            case('coverage_helper_independently_rejects_bad_partial', direct_bad_tail)

            allowed = [
                {'argv': [str(base / 'deny-guest-commands/container'), 'list', '--all', '--format', 'json'], 'time_ns': 1},
                {'argv': [str(base / 'deny-guest-commands/nerdctl'), 'ps', '-a', '--no-trunc', '--format', '{{json .}}'], 'time_ns': 2},
            ]
            def known_lists():
                actual, unclassified = reader.classify_inventory(allowed, base, expected)
                assert [kind for kind, _ in actual] == ['container_list', 'nerdctl_ps'] and unclassified == []
                return 'existing read-only forms preserved'
            case('known_list_argv', known_lists)
            dangerous = [
                ['container', 'exec', 'guest', 'sh'], ['container', 'volume', 'rm', volumes[0]],
                ['nerdctl', 'run', 'image'], ['container', 'list', '--all', '--format', 'json', '--extra'],
                ['nerdctl', 'ps', '-a', '--no-trunc', '--format', '{{json .}}', '--extra'],
                ['docker', 'ps'],
            ]
            for i, argv in enumerate(dangerous):
                row = {'argv': [str(base / 'deny-guest-commands' / argv[0]), *argv[1:]], 'time_ns': 1}
                case('dangerous_or_unclassified_argv_' + str(i),
                     lambda row=row: rejected(lambda: reader.classify_inventory([row], base, expected), AssertionError))
            malformed = [
                {'argv': [], 'time_ns': 1}, {'argv': 'container volume inspect', 'time_ns': 1},
                {'argv': [None], 'time_ns': 1}, {'time_ns': 1},
                {**rows([volumes[0]])[0], 'time_ns': '1'},
                {**rows([volumes[0]])[0], 'time_ns': True},
                {'argv': [str(base / 'foreign/container'), 'volume', 'inspect', volumes[0]], 'time_ns': 1},
            ]
            for i, row in enumerate(malformed):
                case('malformed_or_foreign_root_' + str(i),
                     lambda row=row: rejected(lambda: reader.classify_inventory([row], base, expected)))

            if args.packet:
                source_names = ['identity.json', 'workload.json', 'guest-command-attempts.json', 'workload-phases.json']
                provided_before = {name: digest(args.packet / name) for name in source_names}

                def supplied_regression():
                    identity = json.loads((args.packet / 'identity.json').read_bytes())
                    workload = json.loads((args.packet / 'workload.json').read_bytes())
                    guards = json.loads((args.packet / 'guest-command-attempts.json').read_bytes())
                    observed_phases = [row for row in json.loads((args.packet / 'workload-phases.json').read_bytes()) if 'phase' in row]
                    known = {'masc-keeper-' + kind + '-' + name for name in workload['keepers'] for kind in ['work', 'build']}
                    inventory, _ = reader.classify_inventory(guards, identity['base'], known)
                    result = reader.inventory_coverage(inventory, known, observed_phases)
                    assert len(guards) == 650 and len(known) == 600
                    assert result['observed_inspection_commands'] == 648 and result['complete_observed_segments'] == 1
                    full, tail = result['sweeps']
                    assert full['complete'] is True and full['commands'] == 600 and full['missing_volumes'] == []
                    assert tail['complete'] is False and tail['exact_expected_volume_set'] is False
                    assert tail['commands'] == tail['observed_volume_count'] == 48 and len(tail['missing_volumes']) == 552
                    assert sorted(tail['commands_by_workload_phase'].values()) == [19, 29]
                    assert provided_before == {name: digest(args.packet / name) for name in source_names}
                    (output / 'provided-650-inventory-coverage.json').write_text(json.dumps(result, indent=2) + '\n')
                    return {'classification_only': True, 'records': 650, 'inspect': 648, 'complete_segments': 1,
                            'tail_complete': False, 'tail_observed': 48, 'tail_missing': 552,
                            'source_files_unchanged': provided_before == {name: digest(args.packet / name) for name in source_names}}
                case('provided_650_guard_regression_no_SQL', supplied_regression)

            if args.baseline_reader:
                baseline_source = args.baseline_reader.read_text()
                baseline = ast.parse(baseline_source)
                candidate_source = args.reader.read_text()
                candidate = ast.parse(candidate_source)

                def baseline_and_conservation():
                    modulo = next(node.test for node in ast.walk(baseline) if isinstance(node, ast.Assert)
                                  and any(isinstance(child, ast.Mod) for child in ast.walk(node.test)))
                    for count, accepted in [(600, True), (648, False), (1200, True)]:
                        value = eval(compile(ast.Expression(modulo), '<frozen modulo assertion>', 'eval'),
                                     {'__builtins__': {}, 'len': len}, {'inspections': [None] * count, 'expected_volumes': expected})
                        assert value is accepted
                    old_fn = {n.name: ast.get_source_segment(baseline_source, n) for n in baseline.body if isinstance(n, ast.FunctionDef)}
                    new_fn = {n.name: ast.get_source_segment(candidate_source, n) for n in candidate.body if isinstance(n, ast.FunctionDef)}
                    for name in ['read', 'lines', 'sha', 'full_typed_digest', 'stats', 'objects', 'rpc_result', 'audit_original_payloads']:
                        assert old_fn[name] == new_fn[name]
                    old_body = old_fn['audit'].split('\n', 1)[1]
                    new_body = new_fn['_audit'].split('\n', 1)[1]
                    assert old_body.split('    guards = read(', 1)[0] == new_body.split('    guards = read(', 1)[0]
                    assert old_body.split('    cleanup = read(', 1)[1].split('    inspections = ', 1)[0] == new_body.split('    cleanup = read(', 1)[1].split('    inventory_audit = ', 1)[0]
                    old_connections = [ast.dump(n) for n in ast.walk(baseline) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                                       and isinstance(n.func.value, ast.Name) and n.func.value.id == 'sqlite3' and n.func.attr == 'connect']
                    new_connections = [ast.dump(n) for n in ast.walk(candidate) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                                       and isinstance(n.func.value, ast.Name) and n.func.value.id == 'sqlite3' and n.func.attr == 'connect']
                    assert old_connections == new_connections
                    audited = next(n for n in candidate.body if isinstance(n, ast.FunctionDef) and n.name == '_audit')
                    writes = [n for n in ast.walk(audited) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'write_text']
                    assert len(writes) == 5
                    assert all(isinstance(n.func.value, ast.BinOp) and isinstance(n.func.value.left, ast.Name)
                               and n.func.value.left.id == 'output' for n in writes)
                    return {'old_648_modulo_rejected': True, 'critical_payload_SQL_source_blocks_unchanged': True,
                            'all_five_derivative_writers_use_output': True}
                case('frozen_baseline_counterexample_and_semantic_conservation', baseline_and_conservation)

            def derived_records_hold_no_host_paths():
                # A derived record names the packet and files inside it; it
                # never holds where this host keeps them. str() of the packet
                # or output is allowed only inside an assert.
                source = args.reader.read_text()
                tree = ast.parse(source)
                parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}

                def root_name(node):
                    while isinstance(node, (ast.BinOp, ast.Attribute)):
                        node = node.left if isinstance(node, ast.BinOp) else node.value
                    return node.id if isinstance(node, ast.Name) else None

                def inside_assert(node):
                    while node in parents:
                        node = parents[node]
                        if isinstance(node, ast.Assert):
                            return True
                    return False
                functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in {'_audit', 'audit'}]
                assert len(functions) == 2
                leaks = [ast.get_source_segment(source, n) for function in functions for n in ast.walk(function)
                         if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'str'
                         and len(n.args) == 1 and root_name(n.args[0]) in {'packet', 'output'} and not inside_assert(n)]
                assert leaks == [], leaks
                return 'packet and output paths appear only in assertions'
            case('derived_records_hold_no_host_paths', derived_records_hold_no_host_paths)

            packet = temporary / 'mock-packet'
            packet.mkdir()
            (packet / 'original.json').write_text('{"mock_original":true}\n')
            (packet / 'original.db').write_bytes(b'mock DB bytes, never opened')
            (packet / 'original.db-wal').write_bytes(b'mock WAL bytes')
            original = snapshot(packet)
            filenames = ['inventory-sweep-audit.json', 'slow-status-completion-alignment.json', 'post-run-audit.json',
                         'operation-wall-samples.json', 'mcp-wire-outliers.json']

            def mock_audit(source, destination):
                assert source == packet.resolve() and destination.is_dir() and not destination.is_relative_to(source)
                for name in filenames:
                    (destination / name).write_text(json.dumps({'mock_only': True, 'derived_file': name}) + '\n')
                return {'mock_only': True, 'inventory_final_segment_complete': True}

            def mock_incomplete_audit(source, destination):
                mock_audit(source, destination)
                return {'mock_only': True, 'inventory_final_segment_complete': False}

            def external_success():
                destination = temporary / 'external-success'
                with mock.patch.object(reader, '_audit', side_effect=mock_audit) as invoked:
                    assert reader.main([str(packet), '--output', str(destination)]) == 0
                    assert invoked.call_count == 1
                assert set(p.name for p in destination.iterdir()) == set(filenames)
                assert snapshot(packet) == original
                return {'mocked_full_audit': True, 'external_derivatives': 5, 'original_DB_WAL_receipt_bytes_unchanged': True}
            case('CLI_required_external_output_success_mock_SQL_forbidden', external_success)

            def incomplete_final_segment_exit():
                destination = temporary / 'external-incomplete'
                with mock.patch.object(reader, '_audit', side_effect=mock_incomplete_audit):
                    code = reader.main([str(packet), '--output', str(destination)])
                assert code == reader.INCOMPLETE_INVENTORY_EXIT and code not in {0, 1, 2}
                assert set(p.name for p in destination.iterdir()) == set(filenames)
                assert snapshot(packet) == original
                return {'exit': code, 'external_derivatives': 5}
            case('CLI_incomplete_final_inventory_segment_exits_distinctly', incomplete_final_segment_exit)

            def refused_output(name, destination):
                before = snapshot(packet)
                with mock.patch.object(reader, '_audit') as invoked:
                    error = rejected(lambda: reader.audit(packet, destination))
                    assert not invoked.called
                assert snapshot(packet) == before == original
                return error
            existing = temporary / 'existing-output'; existing.mkdir(); (existing / 'keep').write_text('unchanged')
            existing_file = temporary / 'existing-file'; existing_file.write_text('unchanged')
            link = temporary / 'linked-output'; link.symlink_to(existing, target_is_directory=True)
            broken = temporary / 'broken-output'; broken.symlink_to(temporary / 'missing-target', target_is_directory=True)
            packet_alias = temporary / 'packet-alias'; packet_alias.symlink_to(packet, target_is_directory=True)
            for name, destination in [('existing_directory', existing), ('existing_file', existing_file), ('symlink_directory', link),
                                      ('broken_symlink', broken), ('inside_packet', packet / 'new-output'),
                                      ('symlink_parent_inside_packet', packet_alias / 'new-output'), ('packet_itself', packet),
                                      ('replay_same_output', temporary / 'external-success'),
                                      ('missing_parent', temporary / 'missing-parent' / 'new-output')]:
                case('reject_output_' + name, lambda name=name, destination=destination: refused_output(name, destination))

            def missing_or_legacy_CLI():
                with mock.patch.object(reader, '_audit') as invoked, contextlib.redirect_stderr(io.StringIO()):
                    for arguments in [[str(packet)], [str(packet), str(packet), '--output', str(temporary / 'legacy')]]:
                        try:
                            reader.main(arguments)
                        except SystemExit as error:
                            assert error.code == 2
                        else:
                            raise AssertionError('missing output or legacy multi-packet CLI accepted')
                    assert not invoked.called
                assert snapshot(packet) == original
                return 'both argument errors rejected before audit or output creation'
            case('required_output_and_no_legacy_CLI_shim', missing_or_legacy_CLI)

            def failed_audit_preserves_failure():
                error = AssertionError('injected join failure')
                destination = temporary / 'external-failure'
                def failing(source, target):
                    (target / 'inventory-sweep-audit.json').write_text('{"mock_partial":true}\n')
                    raise error
                with mock.patch.object(reader, '_audit', side_effect=failing):
                    try:
                        reader.audit(packet, destination)
                    except AssertionError as observed:
                        assert observed is error
                    else:
                        raise AssertionError('audit error swallowed')
                receipt = json.loads((destination / 'audit-failure.json').read_bytes())
                assert receipt['error_type'] == 'AssertionError' and receipt['error'] == 'injected join failure'
                assert receipt['packet'] == packet.name and 'output' not in receipt
                assert str(temporary) not in (destination / 'audit-failure.json').read_text()
                assert (destination / 'inventory-sweep-audit.json').exists()
                assert snapshot(packet) == original
                return 'original exception, partial derivative and external failure receipt retained'
            case('external_failure_receipt_and_original_exception', failed_audit_preserves_failure)

            def failure_receipt_error_does_not_mask_original():
                error = AssertionError('original audit failure')
                with mock.patch.object(reader, '_audit', side_effect=error), mock.patch.object(Path, 'write_text', side_effect=OSError('injected receipt failure')):
                    try:
                        reader.audit(packet, temporary / 'receipt-write-failure')
                    except AssertionError as observed:
                        assert observed is error and any('audit-failure.json' in note for note in observed.__notes__)
                    else:
                        raise AssertionError('original failure masked or swallowed')
                assert snapshot(packet) == original
                return 'original exception retained with secondary failure note'
            case('secondary_receipt_write_failure_preserves_original', failure_receipt_error_does_not_mask_original)

            def cancellation_preserved():
                error = KeyboardInterrupt('mock cancellation, no signal sent')
                destination = temporary / 'cancelled-audit'
                with mock.patch.object(reader, '_audit', side_effect=error):
                    try:
                        reader.audit(packet, destination)
                    except KeyboardInterrupt as observed:
                        assert observed is error
                    else:
                        raise AssertionError('cancellation swallowed')
                assert json.loads((destination / 'audit-failure.json').read_bytes())['error_type'] == 'KeyboardInterrupt'
                assert snapshot(packet) == original
                return 'in-memory cancellation retained; no OS signal or workload'
            case('mock_cancellation_is_rethrown', cancellation_preserved)

    document = {'scope': 'Pure inventory/classification functions, source AST, and mocked external-output ownership only. No supplied packet full audit, SQL, native, HTTP, CI or producer run.',
                'reader_sha256': digest(args.reader), 'probe_sha256': digest(Path(__file__)),
                'provided_packet': args.packet.name if args.packet else None,
                'cases': results, 'passed': sum(row['passed'] for row in results), 'failed': sum(not row['passed'] for row in results),
                'full_semantic_audit_executed': False, 'SQL_connections_allowed': False}
    (output / 'results.json').write_text(json.dumps(document, indent=2) + '\n')
    print(json.dumps({key: document[key] for key in ['reader_sha256', 'probe_sha256', 'passed', 'failed', 'full_semantic_audit_executed']}))
    return int(bool(document['failed']))


if __name__ == '__main__':
    raise SystemExit(main())
