"""Logic of the write-reach measurement on small synthetic Keeper stores; nothing is read from a live base path."""
import collections
import contextlib
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'keeper-recall-write-reach.py'
spec = importlib.util.spec_from_file_location('keeper_recall_write_reach', SCRIPT)
assert spec is not None and spec.loader is not None
reach = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = reach  # the script's dataclasses read their own module while they are defined
spec.loader.exec_module(reach)

PENDING = 'persisted_pending_admission'
# The fixtures sit on 2026-10-27 UTC so that --since 2026-10-28 separates them from later rows.
T0 = datetime.datetime(2026, 10, 27, tzinfo=datetime.timezone.utc).timestamp()
DAY = 86400.0
NOW = '2026-10-28T00:00:00Z'
T0_ISO = '2026-10-27T00:00:00Z'


def mid(claim):
    return reach.memory_id_of(claim)


def receipt_text(**fields):
    return json.dumps({'ok': True, 'error_kind': '', **fields})


def queued_text(request_id):
    return receipt_text(outcome=PENDING, store='pending_memory_admission', request_id=request_id, sequence=1)


def rejected_text(error_kind):
    # A rejection is the receipt, a newline and prose lines, as the live traces hold it.
    return json.dumps({'ok': False, 'error_kind': error_kind, 'effect_disposition': 'proven_pre_effect'}) + '\nfailure_class=policy_rejection - prose'


def finished(ts, result, call='c1', run='r1', tool='keeper_memory_write', error=False):
    return {'record_type': 'tool_execution_finished', 'ts': ts, 'tool_name': tool, 'tool_use_id': call, 'worker_run_id': run, 'tool_result': result, 'tool_error': error}


def started(ts, call='c1', run='r1', tool='keeper_memory_write'):
    return {'record_type': 'tool_execution_started', 'ts': ts, 'tool_name': tool, 'tool_use_id': call, 'worker_run_id': run}


def native_finished(ts, identity, run='r1'):
    return {'record_type': 'native_tool_finished', 'ts': ts, 'tool_name': 'mcp_masc_keeper_memory_write', 'native_tool_identity': identity, 'worker_run_id': run}


def bound(request_id, source_claim, target_claim, revision, first_seen, state='committed'):
    return {
        'state': state,
        'admission_recall_binding': {
            'candidate_id': {'queue_generation': 'g', 'request_id': request_id, 'sequence': 1, 'input_sha256': 'x'},
            'source_fact': {'claim': source_claim, 'category': 'fact', 'first_seen': first_seen, 'last_seen': first_seen},
            'target_memory_id': mid(target_claim),
        },
        'snapshot_revision': revision,
        'snapshot_sha256': 'h',
    }


def unbound(request_id, revision):
    return {'state': 'committed', 'explicit_candidate_id': {'queue_generation': 'g', 'request_id': request_id, 'sequence': 1, 'input_sha256': 'x'}, 'snapshot_revision': revision, 'snapshot_sha256': 'h'}


def range_receipt(revision, key='range_id'):
    return {'state': 'committed', key: 'range-1', 'snapshot_revision': revision, 'snapshot_sha256': 'h'}


def commit_row(revision, recorded_at, added=(), removed=(), effect='rewritten', source='librarian', dropped=()):
    """A committed journal row. dropped: (claim, reason) pairs."""
    change = {'added': [{'claim': claim} for claim in added], 'removed': [{'claim': claim} for claim in removed]}
    return {
        'outcome': 'committed', 'commit_effect': effect, 'revision': revision, 'recorded_at': recorded_at,
        'source': {'kind': source, 'trace_id': 'trace-1'}, 'change': change,
        'dropped': [{'memory_id': mid(claim), 'reason': reason} for claim, reason in dropped],
    }


class Store:
    """A temporary base path with the two directories the script reads."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.keepers = root / 'keepers'
        self.memory = root / 'config' / 'keepers'
        self.keepers.mkdir(parents=True)
        self.memory.mkdir(parents=True)

    def close(self):
        self._tmp.cleanup()

    def trace(self, keeper, records, start=T0, name=None):
        """One raw trace file named after the start of its turn, as the live ones are."""
        folder = self.keepers / keeper / 'raw-traces'
        folder.mkdir(parents=True, exist_ok=True)
        file_name = name or f'turn-{int(start * 1000)}-abcd-000001.jsonl'
        (folder / file_name).write_text(''.join(json.dumps(record) + '\n' for record in records), encoding='utf-8')

    def keeper(self, keeper, receipts=(), pending=(), journal=(), current=(), revised=None, retracted=(), absorbed=None):
        """revised: claim -> the claim that replaced it. absorbed: claim -> the claim it was merged into."""

        def put(suffix, value):
            (self.memory / f'{keeper}{suffix}').write_text(value, encoding='utf-8')

        put('.librarian-range-commit.json', json.dumps({'receipts': list(receipts)}))
        def row(entry):
            """A pending row. An entry is a request id, or a (request id, fact.first_seen) pair; None leaves first_seen out."""
            request_id, first_seen = entry if isinstance(entry, tuple) else (entry, T0)
            return {'sequence': 9, 'request_id': request_id, 'fact': {} if first_seen is None else {'first_seen': first_seen}}

        put('.memory-admission.json', json.dumps({'generation': 'g', 'last_sequence': 9, 'pending': [row(entry) for entry in pending]}))
        put('.memory-journal.jsonl', ''.join(json.dumps(row) + '\n' for row in journal))
        put('.memory-current.json', json.dumps({'facts': [{'claim': claim} for claim in current]}))
        events = [{'kind': 'revised', 'memory_id': mid(old), 'superseded_by': mid(new)} for old, new in (revised or {}).items()]
        events += [{'kind': 'retracted', 'memory_id': mid(claim)} for claim in retracted]
        put('.memory-events.jsonl', ''.join(json.dumps(row) + '\n' for row in events))
        put('.memory-absorbed.jsonl', ''.join(json.dumps({'memory_id': mid(old), 'into': mid(into), 'fact': {}}) + '\n' for old, into in (absorbed or {}).items()))

    def run(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = reach.main([str(self.keepers), '--memory-dir', str(self.memory), '--now', NOW, *extra])
        return code, out.getvalue(), err.getvalue()

    def state(self, keeper):
        return reach.load_state(str(self.memory), keeper, collections.Counter())


class HelperTests(unittest.TestCase):
    def test_a_memory_id_is_the_sha256_of_the_claim_bytes(self):
        self.assertEqual(reach.memory_id_of('abc'), 'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')

    def test_a_lone_surrogate_does_not_stop_the_run_and_matches_nothing(self):
        self.assertNotEqual(reach.memory_id_of('\ud800'), reach.memory_id_of(''))

    def test_a_boolean_is_neither_a_number_nor_an_integer(self):
        self.assertEqual((reach.number_of(True), reach.int_of(True), reach.number_of(2), reach.int_of(2), reach.number_of('2')), (None, None, 2.0, 2, None))

    def test_a_number_too_large_for_a_float_is_not_a_number(self):
        self.assertIsNone(reach.number_of(10 ** 400))

    def test_a_moment_is_a_number_the_calendar_can_print(self):
        self.assertEqual((reach.moment_of(0), reach.moment_of(T0)), (0.0, T0))
        # An epoch in milliseconds, NaN, the infinities, an integer too large for a float, a boolean, a string and null are not moments.
        for value in (T0 * 1000, float('nan'), float('inf'), float('-inf'), 10 ** 400, True, '1793059200', None):
            self.assertIsNone(reach.moment_of(value), value)

    def test_quantile_picks_the_value_at_the_floor_of_the_rank(self):
        values = [float(number) for number in range(1, 12)]
        self.assertEqual((reach.quantile(values, 0.5), reach.quantile(values, 0.9), reach.quantile(values, 1.0), reach.quantile([], 0.5)), (6.0, 10.0, 11.0, 0.0))

    def test_since_is_a_utc_date_and_now_is_utc_without_an_offset(self):
        self.assertEqual(reach.parse_utc_date('2026-10-28'), T0 + DAY)
        with self.assertRaises(ValueError):
            reach.parse_utc_date('2026-10-28+09:00')
        self.assertEqual(reach.parse_utc_time('2026-10-28T00:00:00'), T0 + DAY)
        self.assertEqual(reach.parse_utc_time('2026-10-28T00:00:00Z'), T0 + DAY)
        self.assertEqual(reach.parse_utc_time('2026-10-28T09:00:00+09:00'), T0 + DAY)

    def test_a_naive_now_is_utc_whatever_the_local_zone_is(self):
        previous = os.environ.get('TZ')
        os.environ['TZ'] = 'Asia/Seoul'
        time.tzset()
        try:
            self.assertEqual(reach.parse_utc_time('2026-10-28T00:00:00'), T0 + DAY)
        finally:
            if previous is None:
                del os.environ['TZ']
            else:
                os.environ['TZ'] = previous
            time.tzset()

    def test_only_a_current_fact_or_a_path_to_one_reaches_current(self):
        reaching = {reach.Standing.CURRENT, reach.Standing.BY_REWRITE, reach.Standing.BY_ABSORPTION}
        self.assertEqual({standing for standing in reach.Standing if standing.reaches_current}, reaching)

    def test_a_dead_end_a_removal_and_no_record_are_the_ends_without_a_current_fact_or_a_retraction(self):
        ends = {reach.Standing.DEAD_END, reach.Standing.REMOVED, reach.Standing.NO_RECORD}
        self.assertEqual({standing for standing in reach.Standing if standing.ends_nowhere}, ends)

    def test_a_trace_file_is_dated_by_its_name(self):
        self.assertEqual(reach.turn_start_of('/x/raw-traces/turn-1793059200123-abcd-000001.jsonl'), 1793059200.123)
        self.assertIsNone(reach.turn_start_of('/x/raw-traces/notes.jsonl'))
        self.assertIsNone(reach.turn_start_of('/x/raw-traces/turn-12-abcd-000001.jsonl'))


class StandingTests(unittest.TestCase):
    def follow(self, memory_id, current=(), revised=None, absorbed=None, retracted=(), removed=()):
        lineage = reach.Lineage(frozenset(current), dict(revised or {}), dict(absorbed or {}), frozenset(retracted))
        return reach.follow(memory_id, lineage, {removed_id: reach.Removal(False, False, 0.0, True) for removed_id in removed})

    def standing(self, *args, **kwargs):
        return self.follow(*args, **kwargs).standing

    def test_a_current_id_is_current_even_when_a_record_names_it(self):
        self.assertEqual(self.standing('a', current=['a'], revised={'a': 'b'}, retracted=['a']), reach.Standing.CURRENT)

    def test_revised_records_lead_to_a_current_fact(self):
        result = self.follow('a', current=['c'], revised={'a': 'b', 'b': 'c'})
        self.assertEqual((result.standing, result.last_id), (reach.Standing.BY_REWRITE, 'c'))

    def test_a_path_that_crosses_an_absorption_is_named_for_it(self):
        self.assertEqual(self.standing('a', current=['c'], absorbed={'a': 'b'}, revised={'b': 'c'}), reach.Standing.BY_ABSORPTION)

    def test_a_path_to_a_missing_id_and_a_cycle_are_dead_ends_that_end_where_the_records_stop(self):
        result = self.follow('a', revised={'a': 'lost'})
        self.assertEqual((result.standing, result.last_id), (reach.Standing.DEAD_END, 'lost'))
        self.assertEqual(self.standing('a', revised={'a': 'b', 'b': 'a'}), reach.Standing.DEAD_END)

    def test_an_id_without_records_is_split_by_whether_a_commit_removed_it(self):
        self.assertEqual(self.standing('a'), reach.Standing.NO_RECORD)
        result = self.follow('a', removed=['a'])
        self.assertEqual((result.standing, result.last_id), (reach.Standing.REMOVED, 'a'))

    def test_a_revised_record_wins_over_a_retraction_of_the_same_id(self):
        self.assertEqual(self.standing('a', current=['b'], revised={'a': 'b'}, retracted=['a']), reach.Standing.BY_REWRITE)
        self.assertEqual(self.standing('a', retracted=['a']), reach.Standing.RETRACTED)

    def test_a_revised_record_is_followed_before_an_absorbed_record_of_the_same_id(self):
        self.assertEqual(self.standing('a', current=['b', 'c'], revised={'a': 'b'}, absorbed={'a': 'c'}), reach.Standing.BY_REWRITE)


class CallKindTests(unittest.TestCase):
    def call(self, record):
        return reach.call_of('k', record, 1.0)

    def test_a_queued_receipt_carries_its_request_id(self):
        call = self.call(finished(1, queued_text('memory-admission-a')))
        self.assertEqual((call.kind, call.outcome, call.request_id), (reach.Kind.RECEIPT_OK, PENDING, 'memory-admission-a'))

    def test_other_ok_outcomes_keep_their_name(self):
        call = self.call(finished(1, receipt_text(outcome='persisted_current_snapshot')))
        self.assertEqual((call.kind, call.outcome, call.request_id), (reach.Kind.RECEIPT_OK, 'persisted_current_snapshot', ''))

    def test_a_rejection_is_read_from_the_first_line_and_keeps_its_error_kind(self):
        call = self.call(finished(1, rejected_text('supersedes_not_current')))
        self.assertEqual((call.kind, call.error_kind), (reach.Kind.REJECTED, 'supersedes_not_current'))

    def test_text_that_is_not_a_receipt_is_split_by_the_tool_error_flag(self):
        text = 'Your call to "keeper_memory_write": {"_blob": {}}\nErrors (fix these and call again)'
        self.assertEqual(self.call(finished(1, text, error=True)).kind, reach.Kind.TOOL_ERROR)
        self.assertEqual(self.call(finished(1, text, error=False)).kind, reach.Kind.UNREADABLE)
        self.assertEqual(self.call(finished(1, None)).kind, reach.Kind.UNREADABLE)

    def test_json_without_an_ok_flag_is_not_a_receipt(self):
        self.assertEqual(self.call(finished(1, json.dumps({'outcome': PENDING, 'request_id': 'x'}))).kind, reach.Kind.UNREADABLE)

    def test_a_queued_receipt_without_a_request_id_is_unreadable_not_matched_to_the_empty_id(self):
        self.assertEqual(self.call(finished(1, receipt_text(outcome=PENDING))).kind, reach.Kind.UNREADABLE)

    def test_a_native_call_has_no_result_text(self):
        self.assertEqual(self.call(native_finished(1, ['Provider_step', {'step_index': 1}])).kind, reach.Kind.NOT_RECORDED)

    def test_an_empty_tool_use_id_names_no_call(self):
        self.assertIsNone(reach.call_key('k', {'tool_use_id': '', 'worker_run_id': 'r1'}))
        self.assertIsNotNone(reach.call_key('k', {'tool_use_id': 'c1', 'worker_run_id': 'r1'}))


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        self.skipped = collections.Counter()

    def scan(self, only=(), excluded=(), since=None):
        return reach.scan_traces(str(self.store.keepers), set(only), set(excluded), since, self.skipped)

    def test_each_call_is_counted_once_and_a_start_without_a_finish_is_reported(self):
        self.store.trace('a', [
            started(1, 'c1'), finished(2, queued_text('memory-admission-a'), 'c1'),
            started(3, 'c2'), finished(4, rejected_text('source_read_failed'), 'c2'),
            finished(4, rejected_text('source_read_failed'), 'c2'),  # the same call written twice
            started(5, 'c3'),
        ])
        scan = self.scan()
        self.assertEqual([call.kind for call in scan.calls], [reach.Kind.RECEIPT_OK, reach.Kind.REJECTED])
        self.assertEqual((scan.started_without_finished, scan.finished_twice), (1, 1))

    def test_the_same_tool_use_id_in_two_runs_is_two_calls(self):
        self.store.trace('a', [finished(1, queued_text('memory-admission-a'), 'c1', run='r1'), finished(2, queued_text('memory-admission-b'), 'c1', run='r2')])
        scan = self.scan()
        self.assertEqual((len(scan.calls), scan.finished_twice), (2, 0))

    def test_two_records_with_an_empty_tool_use_id_are_two_calls_and_are_reported(self):
        self.store.trace('a', [finished(1, queued_text('memory-admission-a'), ''), finished(2, queued_text('memory-admission-b'), '')])
        scan = self.scan()
        self.assertEqual((len(scan.calls), scan.finished_twice), (2, 0))
        self.assertEqual(self.skipped['write records that name no call (not paired)'], 2)

    def test_every_name_the_tool_is_called_by_counts_and_other_tools_do_not(self):
        self.store.trace('a', [
            finished(1, queued_text('memory-admission-a'), 'c1', tool='keeper_memory_write'),
            finished(2, queued_text('memory-admission-b'), 'c2', tool='mcp__masc__keeper_memory_write'),
            finished(3, 'a board comment that mentions keeper_memory_write', 'c3', tool='masc_board_comment'),
        ])
        self.assertEqual(len(self.scan().calls), 2)

    def test_native_calls_pair_by_their_identity_and_keep_no_result(self):
        identity = ['Provider_step', {'step_index': 7}]
        self.store.trace('a', [
            {'record_type': 'native_tool_started', 'ts': 1, 'tool_name': 'mcp_masc_keeper_memory_write', 'native_tool_identity': identity, 'worker_run_id': 'r1'},
            native_finished(2, identity),
        ])
        scan = self.scan()
        self.assertEqual(([call.kind for call in scan.calls], scan.started_without_finished), ([reach.Kind.NOT_RECORDED], 0))

    def test_a_native_call_pairs_by_its_identity_whatever_the_order_of_its_keys(self):
        self.store.trace('a', [
            {'record_type': 'native_tool_started', 'ts': 1, 'tool_name': 'mcp_masc_keeper_memory_write', 'native_tool_identity': {'step': 1, 'kind': 'p'}, 'worker_run_id': 'r1'},
            native_finished(2, {'kind': 'p', 'step': 1}),
        ])
        scan = self.scan()
        self.assertEqual(([call.kind for call in scan.calls], scan.started_without_finished), ([reach.Kind.NOT_RECORDED], 0))

    def test_since_includes_a_record_at_the_boundary_and_only_exclude_bound_the_read(self):
        for keeper in ('a', 'b'):
            self.store.trace(keeper, [finished(10, queued_text(f'memory-admission-{keeper}1'), 'c1'), finished(20, queued_text(f'memory-admission-{keeper}2'), 'c2')])
        self.assertEqual(len(self.scan().calls), 4)
        self.assertEqual({call.request_id for call in self.scan(since=20.0).calls}, {'memory-admission-a2', 'memory-admission-b2'})
        self.assertEqual({call.keeper for call in self.scan(only=['a']).calls}, {'a'})
        self.assertEqual({call.keeper for call in self.scan(excluded=['a']).calls}, {'b'})
        self.assertEqual(set(self.scan(only=['a']).windows), {'a'})
        self.assertEqual(set(self.scan(excluded=['a']).windows), {'b'})

    def test_input_the_scan_cannot_use_is_counted_not_dropped(self):
        folder = self.store.keepers / 'a' / 'raw-traces'
        folder.mkdir(parents=True)
        good = json.dumps(finished(5, queued_text('memory-admission-a')))
        no_ts = json.dumps({**finished(6, queued_text('memory-admission-b'), 'c2'), 'ts': None})
        (folder / f'turn-{int(T0 * 1000)}-abcd-000001.jsonl').write_text(f'{good}\n{{keeper_memory_write broken\n\n{no_ts}\n[1, "keeper_memory_write"]\n', encoding='utf-8')
        scan = self.scan()
        self.assertEqual(len(scan.calls), 1)
        self.assertEqual(
            dict(self.skipped),
            {'trace lines that were not JSON': 1, 'write records whose ts is not a usable time': 1, 'trace lines that were not a JSON object': 1},
        )

    def test_a_ts_past_the_calendar_is_counted_and_does_not_stop_the_scan(self):
        folder = self.store.keepers / 'a' / 'raw-traces'
        folder.mkdir(parents=True)
        good = json.dumps(finished(5, queued_text('memory-admission-a')))
        in_milliseconds = json.dumps(finished(T0 * 1000, queued_text('memory-admission-b'), 'c2'))
        not_a_number = json.dumps(finished(7, queued_text('memory-admission-c'), 'c3')).replace('"ts": 7', '"ts": NaN')
        (folder / f'turn-{int(T0 * 1000)}-abcd-000001.jsonl').write_text(f'{good}\n{in_milliseconds}\n{not_a_number}\n', encoding='utf-8')
        scan = self.scan()
        self.assertEqual([call.request_id for call in scan.calls], ['memory-admission-a'])
        self.assertEqual(dict(self.skipped), {'write records whose ts is not a usable time': 2})

    def test_the_trace_window_of_a_keeper_comes_from_its_file_names(self):
        self.store.trace('a', [], start=T0 + 50)
        self.store.trace('a', [], name=f'turn-{int((T0 + 20) * 1000)}-abcd-000002.jsonl')
        self.store.trace('a', [], name='notes.jsonl')
        scan = self.scan()
        self.assertEqual(scan.windows['a'], reach.TraceWindow(3, T0 + 20))
        self.assertEqual(self.skipped['raw trace files whose name has no turn start'], 1)

    def test_a_keeper_whose_files_carry_no_turn_start_has_no_oldest_trace(self):
        self.store.trace('a', [], name='notes.jsonl')
        self.assertEqual(self.scan().windows['a'], reach.TraceWindow(1, None))


# One Keeper whose queue had every ending. Offsets are seconds after T0. Journal rows, committed:
#   revision 0 at 100 adds the claims that already existed, revision 1 at 1000 adds NEW and an unchanged pass keeps it at 1200,
#   revision 2 at 2000 removes TAKEN (with a reason) and an unchanged pass keeps it at 2500, an explicit write names revision 3
#   at 2550, and revision 3 at 3000 adds OWN.
OWN, NEW, OLD, SUCC, INTO, LOST, STRANGER = 'own sentence', 'claim written by the Librarian', 'claim that was already there', 'successor of the revised claim', 'claim that absorbed another', 'successor that is gone', 'claim no commit added'
REV, RET, ABS, GONE, TAKEN, DEAD = 'claim later revised', 'claim later retracted', 'claim later absorbed', 'left without a record', 'claim a commit removed', 'claim revised into nothing'


def keeper_a(store):
    store.keeper(
        'a',
        receipts=[
            bound('rid-new', 'a reworded sentence', NEW, 1, T0 + 900),
            bound('rid-own', OWN, OWN, 3, T0 + 2500),
            bound('rid-old', 'x1', OLD, 2, T0 + 1500),
            bound('rid-rev', 'x2', REV, 2, T0 + 1600),
            bound('rid-ret', 'x3', RET, 2, T0 + 1700),
            bound('rid-abs', 'x4', ABS, 2, T0 + 1800),
            bound('rid-gone', 'x5', GONE, 2, T0 + 1900),
            bound('rid-taken', 'x6', TAKEN, 2, T0 + 1950),
            bound('rid-dead', 'x7', DEAD, 2, T0 + 1960),
            bound('rid-unknown', 'x8', STRANGER, 2, T0 + 1970),
            unbound('rid-none', 2),
            bound('rid-undated', 'x9', OLD, 99, T0 + 1500),
            bound('rid-prepared', 'x10', OLD, 2, T0 + 1500, state='prepared'),
            bound('rid-new', 'a reworded sentence again', NEW, 1, T0 + 950),  # the same request id settled twice
            range_receipt(2),
            range_receipt(2, key='official_range_id'),
            {'state': 'committed', 'snapshot_revision': 2},
            {'state': 'committed', 'snapshot_revision': 3, 'note': 'a shape nobody writes'},
        ],
        pending=['rid-wait'],
        journal=[
            commit_row(0, T0 + 100, [OLD, REV, RET, ABS, GONE, TAKEN, DEAD]),
            commit_row(1, T0 + 1000, [NEW]), commit_row(1, T0 + 1200, effect='unchanged'),
            commit_row(2, T0 + 2000, [SUCC, INTO], [TAKEN], dropped=[(TAKEN, 'a written reason')]), commit_row(2, T0 + 2500, effect='unchanged'),
            # A row of another source at a revision a receipt names: it dates no pass, and what it adds is still added.
            commit_row(3, T0 + 2550, source='explicit_write'),
            commit_row(3, T0 + 3000, [OWN]),
            {'outcome': 'failed', 'kind': 'lane_cancelled', 'recorded_at': T0 + 3500},
            # A row that is not a commit but names revision 2: it must not add a pass at revision 2 or a fact.
            {'outcome': 'failed', 'revision': 2, 'recorded_at': T0 + 9999, 'change': {'added': [{'claim': STRANGER}]}},
        ],
        current=[NEW, OWN, OLD, SUCC, INTO],
        revised={REV: SUCC, DEAD: LOST},
        retracted=[RET],
        absorbed={ABS: INTO},
    )


class StateTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.skipped = collections.Counter()
        self.state = reach.load_state(str(self.store.memory), 'a', self.skipped)

    def test_candidates_are_read_from_both_receipt_shapes_and_the_rest_is_counted_by_reason(self):
        self.assertEqual(len(self.state.settled), 12)
        self.assertEqual(self.state.settled['rid-none'].target, '')
        self.assertEqual(self.state.settled['rid-new'].target, mid(NEW))
        self.assertEqual(self.state.settled['rid-new'].first_seen, T0 + 900, 'the first receipt of a repeated request id is the one kept')
        self.assertEqual(
            dict(self.state.not_candidates),
            {reach.Skip.NOT_COMMITTED: 1, reach.Skip.REPEATED: 1, reach.Skip.RANGE: 1, reach.Skip.OFFICIAL_RANGE: 1, reach.Skip.OTHER_SHAPE: 2},
        )
        self.assertEqual(self.state.waiting, frozenset({'rid-wait'}))
        self.assertEqual(self.state.problems, ())
        self.assertEqual(dict(self.skipped), {})

    def test_a_target_equal_to_the_keepers_own_claim_is_flagged(self):
        self.assertTrue(self.state.settled['rid-own'].own_sentence)
        self.assertFalse(self.state.settled['rid-new'].own_sentence)

    def test_a_revision_with_a_boolean_is_not_a_settlement(self):
        self.assertEqual(reach.settlement_of({**unbound('x', 1), 'snapshot_revision': True}, collections.Counter()), reach.Skip.NOT_COMMITTED)

    def test_a_binding_needs_both_a_request_id_and_a_target(self):
        no_target = bound('rid-x', 's', 't', 1, T0)
        no_target['admission_recall_binding']['target_memory_id'] = ''
        no_id = bound('rid-y', 's', 't', 1, T0)
        no_id['admission_recall_binding']['candidate_id']['request_id'] = ''
        self.assertEqual(reach.settlement_of(no_target, collections.Counter()), reach.Skip.OTHER_SHAPE)
        self.assertEqual(reach.settlement_of(no_id, collections.Counter()), reach.Skip.OTHER_SHAPE)

    def test_only_librarian_rows_date_a_revision_and_every_distinct_stamp_of_it_is_kept(self):
        times = self.state.journal.revision_times
        self.assertEqual({revision: [when - T0 for when in rows] for revision, rows in times.items()}, {0: [100], 1: [1000, 1200], 2: [2000, 2500], 3: [3000]})

    def test_a_fact_is_first_added_by_its_earliest_row_and_a_removal_keeps_its_reason_and_replacement(self):
        journal = self.state.journal
        self.assertEqual((journal.first_added[mid(NEW)] - T0, journal.first_added[mid(OLD)] - T0), (1000, 100))
        self.assertNotIn(mid(STRANGER), journal.first_added)
        self.assertEqual(journal.removals, {mid(TAKEN): reach.Removal(True, True, T0 + 2000, True)})

    def test_a_row_of_another_source_dates_an_addition_but_not_a_pass(self):
        self.store.keeper('x', journal=[commit_row(1, T0 + 50, [OLD], source='explicit_write'), commit_row(1, T0 + 300, effect='unchanged')])
        journal = self.store.state('x').journal
        self.assertEqual(journal.revision_times, {1: (T0 + 300,)})
        self.assertEqual(journal.first_added[mid(OLD)], T0 + 50)

    def test_a_replayed_row_with_the_same_stamp_is_one_stamp(self):
        self.store.keeper('x', journal=[commit_row(1, T0 + 10, [OLD]), commit_row(1, T0 + 10, [OLD])])
        self.assertEqual(self.store.state('x').journal.revision_times, {1: (T0 + 10,)})

    def test_rows_out_of_time_order_are_sorted_and_still_bound_the_time(self):
        self.store.keeper('x', journal=[commit_row(1, T0 + 300, effect='unchanged'), commit_row(1, T0 + 10, [OLD])])
        state = self.store.state('x')
        self.assertEqual(state.journal.revision_times, {1: (T0 + 10, T0 + 300)})
        self.assertEqual(state.settle_bounds(reach.Settled(1, mid(OLD), T0 + 5, False)), (5.0, 295.0))

    def test_journal_rows_without_a_revision_or_a_time_are_counted(self):
        self.store.keeper('r', journal=[commit_row(1, 10.0), {'outcome': 'committed', 'recorded_at': 5.0}, {'outcome': 'committed', 'revision': 2}])
        skipped = collections.Counter()
        state = reach.load_state(str(self.store.memory), 'r', skipped)
        self.assertEqual(sorted(state.journal.revision_times), [1])
        self.assertEqual(skipped['committed journal rows without a revision or a usable recorded_at'], 2)

    def test_a_committed_row_without_a_usable_time_or_revision_adds_nothing_and_removes_nothing(self):
        row = commit_row(2, T0 + 20, [OLD], [NEW], dropped=[(NEW, 'a reason')])
        broken = [{**row, 'recorded_at': T0 * 1000}, {**row, 'recorded_at': None}, {**row, 'revision': None}]
        self.store.keeper('broken', journal=broken)
        skipped = collections.Counter()
        journal = reach.load_state(str(self.store.memory), 'broken', skipped).journal
        self.assertEqual((journal.revision_times, journal.first_added, journal.removals), ({}, {}, {}))
        self.assertEqual(skipped['committed journal rows without a revision or a usable recorded_at'], 3)

    def test_a_first_seen_that_is_missing_or_past_the_calendar_is_read_as_no_write_time_and_counted(self):
        label = 'settled receipts whose source fact has no usable first_seen (read as having no write time)'
        skipped = collections.Counter()
        found = reach.settlement_of(bound('rid-ms', 's', OLD, 1, T0 * 1000), skipped)
        self.assertEqual(found, ('rid-ms', reach.Settled(1, mid(OLD), None, False)))
        no_time = bound('rid-none', 's', OLD, 1, T0)
        del no_time['admission_recall_binding']['source_fact']['first_seen']
        self.assertEqual(reach.settlement_of(no_time, skipped), ('rid-none', reach.Settled(1, mid(OLD), None, False)))
        self.assertEqual(dict(skipped), {label: 2})
        # A candidate closed without a target has no source fact, and nothing is wrong with that.
        reach.settlement_of(unbound('rid-plain', 1), skipped)
        self.assertEqual(dict(skipped), {label: 2})

    def test_every_queue_row_is_counted_whether_or_not_it_names_a_request_id(self):
        self.store.keeper('q', pending=['rid-1', 'rid-1', ''])
        state = self.store.state('q')
        self.assertEqual((state.waiting_rows, state.waiting), (3, frozenset({'rid-1'})))

    def test_the_oldest_waiting_row_is_the_earliest_usable_first_seen(self):
        # The last two stamps are past the calendar on the small side and on the large side; neither may be the oldest.
        self.store.keeper('w', pending=[('rid-1', T0 + 100), ('rid-2', T0 + 50), ('rid-3', T0 * 1000), ('rid-4', None), ('rid-5', -T0 * 1_000_000)])
        state = self.store.state('w')
        self.assertEqual((state.waiting_rows, state.oldest_waiting), (5, T0 + 50))
        self.store.keeper('x')
        self.assertIsNone(self.store.state('x').oldest_waiting)

    def test_queue_rows_without_a_usable_first_seen_are_counted_and_left_out_of_the_age(self):
        self.store.keeper('w', pending=[('rid-1', T0 + 100), ('rid-3', T0 * 1000), ('rid-4', None), ('rid-5', -T0 * 1_000_000)])
        skipped = collections.Counter()
        state = reach.load_state(str(self.store.memory), 'w', skipped)
        self.assertEqual((state.waiting_rows, state.oldest_waiting), (4, T0 + 100))
        self.assertEqual(dict(skipped), {'admission queue rows whose fact.first_seen is not a usable time (left out of the oldest age)': 3})

    def test_the_last_commit_is_the_latest_librarian_stamp_whatever_the_order_of_the_rows(self):
        # The latest stamp is not the last row of the file. A row of another source and a failed row do not count.
        self.store.keeper('lf', journal=[
            commit_row(1, T0 + 50, [OLD]), commit_row(2, T0 + 90, [NEW], source='explicit_write'), commit_row(2, T0 + 10),
            {'outcome': 'failed', 'recorded_at': T0 + 120},
        ])
        self.assertEqual(self.store.state('lf').last_commit(), T0 + 50)
        self.assertIsNone(self.store.state('empty-journal').last_commit())

    def test_a_quarantine_row_restarts_the_revisions_and_is_noted(self):
        quarantine = {'outcome': 'quarantined', 'recorded_at': T0 + 200, 'rejection': 'undecodable', 'rejected_path': 'rejected.json'}
        self.store.keeper(
            'qr',
            receipts=[bound('rid-q', 's', NEW, 1, T0 + 350)],
            journal=[commit_row(1, T0 + 100, [OLD]), quarantine, commit_row(1, T0 + 400, [NEW])],
        )
        state = self.store.state('qr')
        self.assertEqual(state.journal.revision_times, {1: (T0 + 400,)})
        self.assertEqual(state.journal.restarts, 1)
        self.assertEqual(state.journal.first_added[mid(OLD)], T0 + 100, 'a fact id is a hash of its claim and stays comparable')
        self.assertEqual(state.problems, ('qr.memory-journal.jsonl holds 1 revision restarts (a quarantine row, or a revision that went back); the stamps before each are dropped',))
        self.assertEqual(state.settle_bounds(state.settled['rid-q']), (50.0, 50.0))

    def test_a_journal_row_with_another_outcome_is_not_a_commit(self):
        other = commit_row(1, T0 + 100, [OLD])
        other['outcome'] = 'rolled_back'
        self.store.keeper('oo', journal=[other])
        state = self.store.state('oo')
        self.assertEqual((state.journal.revision_times, state.journal.first_added, state.last_commit()), ({}, {}, None))

    def test_the_last_commit_survives_a_quarantine_that_follows_it(self):
        quarantine = {'outcome': 'quarantined', 'recorded_at': T0 + 200, 'rejection': 'undecodable', 'rejected_path': 'rejected.json'}
        self.store.keeper('ql', journal=[commit_row(1, T0 + 100, [OLD]), quarantine])
        state = self.store.state('ql')
        self.assertEqual((state.journal.revision_times, state.last_commit()), ({}, T0 + 100))

    def test_a_revision_that_goes_back_restarts_the_stamps_without_a_quarantine_row(self):
        # With no snapshot to follow, the numbering begins at 1 again and the quarantine row may be missing.
        self.store.keeper(
            'back',
            receipts=[bound('rid-b', 's', NEW, 1, T0 + 350)],
            journal=[commit_row(1, T0 + 100, [OLD]), commit_row(2, T0 + 200), commit_row(1, T0 + 400, [NEW])],
        )
        state = self.store.state('back')
        self.assertEqual((state.journal.revision_times, state.journal.restarts), ({1: (T0 + 400,)}, 1))
        self.assertEqual(
            state.problems,
            ('back.memory-journal.jsonl holds 1 revision restarts (a quarantine row, or a revision that went back); the stamps before each are dropped',),
        )
        self.assertEqual(state.settle_bounds(state.settled['rid-b']), (50.0, 50.0))

    def test_restarts_are_counted_and_what_the_journal_learned_before_one_stays(self):
        quarantine = {'outcome': 'quarantined', 'recorded_at': T0 + 150}
        self.store.keeper('twice', journal=[
            commit_row(1, T0 + 100, [OLD]), commit_row(2, T0 + 120, [], [OLD]), quarantine,
            commit_row(1, T0 + 200, [NEW]), commit_row(2, T0 + 220), commit_row(1, T0 + 300, [OLD]),
        ])
        journal = self.store.state('twice').journal
        self.assertEqual(journal.restarts, 2)
        self.assertEqual(journal.revision_times, {1: (T0 + 300,)})
        self.assertEqual(journal.removals[mid(OLD)].recorded_at, T0 + 120, 'a fact id is a hash of its claim, so a removal before a restart still stands')
        self.assertEqual(journal.first_added[mid(OLD)], T0 + 100)

    def test_the_same_revision_twice_is_one_revision_with_two_stamps_not_a_restart(self):
        self.store.keeper('same', journal=[commit_row(1, T0 + 100, [OLD]), commit_row(1, T0 + 400)])
        journal = self.store.state('same').journal
        self.assertEqual((journal.revision_times, journal.restarts), ({1: (T0 + 100, T0 + 400)}, 0))

    def test_blank_lines_in_a_file_are_not_input_the_script_cannot_use(self):
        (self.store.memory / 'a.memory-events.jsonl').write_text('\n  \n\n', encoding='utf-8')
        skipped = collections.Counter()
        reach.load_state(str(self.store.memory), 'a', skipped)
        self.assertEqual(dict(skipped), {})

    def test_a_line_that_is_not_json_is_counted_in_the_file_it_came_from(self):
        (self.store.memory / 'a.memory-events.jsonl').write_text('{broken\n', encoding='utf-8')
        skipped = collections.Counter()
        reach.load_state(str(self.store.memory), 'a', skipped)
        self.assertEqual(dict(skipped), {'events lines that were not JSON': 1})

    def test_a_journal_that_cannot_be_opened_is_counted(self):
        (self.store.memory / 'dir.memory-journal.jsonl').mkdir()
        skipped = collections.Counter()
        state = reach.load_state(str(self.store.memory), 'dir', skipped)
        self.assertEqual(skipped['journal files that could not be opened'], 1)
        self.assertNotIn('missing dir.memory-journal.jsonl', state.problems)

    def test_missing_files_are_named_not_skipped(self):
        state = reach.load_state(str(self.store.memory), 'nobody', collections.Counter())
        self.assertEqual(
            state.problems,
            (
                'missing nobody.librarian-range-commit.json', 'missing nobody.memory-admission.json',
                'missing nobody.memory-journal.jsonl', 'missing nobody.memory-current.json',
            ),
        )
        (self.store.memory / 'broken.librarian-range-commit.json').write_text('{not json', encoding='utf-8')
        self.assertIn('unreadable broken.librarian-range-commit.json', reach.load_state(str(self.store.memory), 'broken', collections.Counter()).problems)


class OriginAndBoundsTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.state = self.store.state('a')

    def origin(self, request_id):
        return self.state.origin_of(self.state.settled[request_id])

    def test_a_target_added_after_the_write_even_when_an_unchanged_pass_follows_it(self):
        # NEW was added at 1000 and an unchanged pass wrote another row for revision 1 at 1200: the later row must not hide the addition.
        self.assertEqual(self.origin('rid-new'), reach.Origin.AFTER)
        self.assertEqual(self.origin('rid-own'), reach.Origin.AFTER)

    def test_a_target_added_before_the_write_and_a_target_no_commit_added(self):
        self.assertEqual(self.origin('rid-old'), reach.Origin.BEFORE)
        self.assertEqual(self.origin('rid-unknown'), reach.Origin.UNKNOWN)

    def test_a_target_with_no_usable_write_time_has_an_unknown_origin_whatever_a_trace_call_says(self):
        # The origin depends on the receipt alone, so the queued table and the settled table cannot disagree about it.
        settled = reach.Settled(2, mid(OLD), None, False)
        self.assertEqual(self.state.origin_of(settled), reach.Origin.UNKNOWN)

    def test_the_settlement_lies_between_the_first_pass_after_the_write_and_the_last_pass_of_the_revision(self):
        self.assertEqual(self.state.settle_bounds(self.state.settled['rid-new']), (100.0, 300.0))
        self.assertEqual(self.state.settle_bounds(self.state.settled['rid-old']), (500.0, 1000.0))
        # A write after the first pass of revision 2 is settled no earlier than the next pass.
        self.assertEqual(self.state.settle_bounds(reach.Settled(2, mid(OLD), T0 + 2200, False)), (300.0, 300.0))

    def test_an_explicit_write_row_at_the_revision_is_not_a_pass(self):
        # The explicit write row is stamped 2550, 50 s after the write; the only Librarian pass of revision 3 is at 3000.
        self.assertEqual(self.state.settle_bounds(self.state.settled['rid-own']), (500.0, 500.0))

    def test_no_bounds_without_a_source_fact_a_journal_row_or_a_pass_after_the_write(self):
        self.assertIsNone(self.state.settle_bounds(self.state.settled['rid-none']))
        self.assertIsNone(self.state.settle_bounds(self.state.settled['rid-undated']))
        self.assertIsNone(self.state.settle_bounds(reach.Settled(2, mid(OLD), T0 + 5000, False)))

    def test_a_target_added_in_the_very_second_of_the_write_counts_as_added_after(self):
        self.assertEqual(self.state.origin_of(reach.Settled(2, mid(OLD), T0 + 100, False)), reach.Origin.AFTER)

    def test_a_pass_in_the_very_second_of_the_write_can_be_the_settlement(self):
        self.assertEqual(self.state.settle_bounds(reach.Settled(1, mid(NEW), T0 + 1000, False)), (0.0, 200.0))


class FateTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.state = self.store.state('a')

    def fate(self, request_id, ts=T0 + 2000, state=None):
        call = reach.WriteCall('a', ts, reach.Kind.RECEIPT_OK, PENDING, '', request_id)
        return reach.fate_of(call, state or self.state)

    def test_a_target_added_after_the_write_before_it_or_by_no_commit_row(self):
        self.assertEqual(self.fate('rid-new'), reach.Fate.TARGET_AFTER)
        self.assertEqual(self.fate('rid-old'), reach.Fate.TARGET_BEFORE)
        self.assertEqual(self.fate('rid-unknown'), reach.Fate.TARGET_UNKNOWN)

    def test_a_candidate_settled_without_a_target(self):
        self.assertEqual(self.fate('rid-none'), reach.Fate.WITHOUT_TARGET)

    def test_a_row_in_the_queue_is_waiting(self):
        self.assertEqual(self.fate('rid-wait'), reach.Fate.WAITING)

    def test_a_receipt_wins_over_a_row_the_queue_still_holds(self):
        self.store.keeper('a', receipts=[unbound('rid-both', 1)], pending=['rid-both'], journal=[commit_row(1, T0 + 1000)])
        self.assertEqual(self.fate('rid-both', state=self.store.state('a')), reach.Fate.WITHOUT_TARGET)

    def test_no_record_is_split_by_the_oldest_receipt_of_the_keeper(self):
        # The oldest receipt names revision 1, whose first Librarian stamp is at 1000.
        self.assertEqual(self.fate('rid-lost', ts=T0 + 999), reach.Fate.NO_RECORD_OLDER)
        self.assertEqual(self.fate('rid-lost', ts=T0 + 1000), reach.Fate.NO_RECORD_NEWER)

    def test_a_keeper_without_a_dated_receipt_has_its_own_no_record_fate(self):
        self.store.keeper('empty')
        self.assertEqual(self.fate('rid-lost', state=self.store.state('empty')), reach.Fate.NO_RECEIPTS)
        # Receipts whose revision has no journal row are no better: nothing dates them.
        self.store.keeper('undated', receipts=[unbound('rid-u', 99)])
        self.assertEqual(self.fate('rid-lost', state=self.store.state('undated')), reach.Fate.NO_RECEIPTS)


class ReportTests(unittest.TestCase):
    """Keeper "a" has the store of keeper_a(); "empty" has files but no receipt; "ghost" has no files at all."""

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.store.keeper('empty')
        self.store.trace('a', [
            started(1, 'c1'), finished(T0 + 905.0, queued_text('rid-new'), 'c1'),
            finished(T0 + 1505.0, queued_text('rid-old'), 'c2'),
            finished(T0 + 1900.0, queued_text('rid-none'), 'c3'),
            finished(T0 + 2100.0, queued_text('rid-wait'), 'c4'),
            finished(T0 + 500.0, queued_text('rid-lost-old'), 'c5'),
            finished(T0 + 4000.0, queued_text('rid-lost-new'), 'c6'),
            finished(T0 + 4100.0, receipt_text(outcome='persisted_current_snapshot'), 'c7'),
            finished(T0 + 4200.0, rejected_text('supersedes_invalid'), 'c8'),
            finished(T0 + 4300.0, 'tool failed', 'c9', error=True),
            finished(T0 + 1970.0, queued_text('rid-unknown'), 'c10'),
        ])
        self.store.trace('empty', [finished(T0 + 4400.0, queued_text('rid-x'), 'c1')])
        self.store.trace('ghost', [finished(T0 + 4500.0, queued_text('rid-g'), 'c1')])
        self.code, self.out, self.err = self.store.run()

    def block(self, first_line):
        """The lines from the one that starts with ``first_line`` to the next blank line."""
        lines = self.out.split('\n')
        start = next(index for index, line in enumerate(lines) if line.startswith(first_line))
        end = next((index for index in range(start, len(lines)) if lines[index] == ''), len(lines))
        return lines[start:end]

    def line(self, block, prefix):
        found = [line.strip() for line in block if line.strip().startswith(prefix)]
        self.assertEqual(len(found), 1, f'{prefix!r}: {found}')
        return found[0]

    def count(self, block, prefix):
        return int(self.line(block, prefix).split(': ')[1].split(' ')[0])

    def test_the_call_table_adds_up_to_the_call_total(self):
        self.assertEqual((self.code, self.err), (0, ''))
        calls = self.block('write calls:')
        self.assertEqual(calls[0], 'write calls: 12 in 3 Keepers')
        self.assertEqual(calls[1], '  first 2026-10-27T00:08:20Z, last 2026-10-27T01:15:00Z; --since not set')
        kinds = [self.count(calls, kind.value + ':') for kind in reach.Kind]
        # Ten receipts that say ok (nine queued and one written directly), one rejection, one tool error.
        self.assertEqual((kinds, sum(kinds)), ([10, 1, 1, 0, 0], 12))
        self.assertEqual(self.line(calls, 'persisted_pending_admission:'), 'persisted_pending_admission: 9')
        self.assertEqual(self.line(calls, 'persisted_current_snapshot:'), 'persisted_current_snapshot: 1')
        self.assertEqual(self.line(calls, 'supersedes_invalid:'), 'supersedes_invalid: 1')
        self.assertEqual(self.line(calls, 'started calls without a finished record:'), 'started calls without a finished record: 0; finished records seen twice: 0')

    def test_the_queued_table_gives_every_queued_write_one_fate(self):
        queued = self.block('queued writes')
        self.assertEqual(queued[0], 'queued writes (persisted_pending_admission): 9')
        counts = {fate: self.count(queued, fate.value + ':') for fate in reach.Fate}
        self.assertEqual(
            counts,
            {
                reach.Fate.TARGET_AFTER: 1, reach.Fate.TARGET_BEFORE: 1, reach.Fate.TARGET_UNKNOWN: 1, reach.Fate.WITHOUT_TARGET: 1, reach.Fate.WAITING: 1,
                reach.Fate.NO_RECORD_OLDER: 1, reach.Fate.NO_RECORD_NEWER: 1, reach.Fate.NO_RECEIPTS: 2,
            },
        )
        self.assertEqual(sum(counts.values()), 9)
        # The queue of Keeper "a" holds one row, and the two other Keepers read have none.
        self.assertEqual(
            self.line(queued, 'rows in the admission queues'),
            'rows in the admission queues of the 3 Keepers read, whatever their age and whether or not the trace holds their call: 1',
        )
        # Keeper "a" has one pending row written at T0. Its last Librarian commit is revision 3 at 3000 s; a failed row and a row of
        # another source in its journal do not count. The read is a day after T0.
        self.assertEqual(
            self.line(queued, 'a:'),
            f'a: 1 rows; oldest written {T0_ISO} (86400 s before the read); last Librarian commit {reach.iso(T0 + 3000)} (83400 s before the read)',
        )

    def test_the_queue_total_adds_up_every_keeper_read_and_not_only_the_rows_a_call_names(self):
        store = Store()
        self.addCleanup(store.close)
        store.keeper('q1', pending=['rid-1', 'rid-2'])
        store.keeper('q2', pending=['rid-3', 'rid-4', 'rid-5'])
        store.trace('q1', [finished(T0 + 1, queued_text('rid-1'), 'c1')])
        lines = store.run()[1].split('\n')
        self.assertIn('  still waiting in the admission queue: 1 (100.0%)', lines)
        self.assertIn('  rows in the admission queues of the 2 Keepers read, whatever their age and whether or not the trace holds their call: 5', lines)

    def test_the_settled_table_counts_origin_and_the_receipts_that_are_not_candidates(self):
        settled = self.block('candidates the Librarian settled')
        # Twelve candidates: eleven with a target (rid-undated has no journal row at its revision but a source fact) and rid-none without one.
        self.assertEqual(settled[0], 'candidates the Librarian settled, in the --since window: 12 in 1 Keepers (read at 2026-10-28T00:00:00Z)')
        self.assertEqual(
            self.line(settled, 'receipts with a source fact were written from'),
            'receipts with a source fact were written from 2026-10-27T00:15:00Z to 2026-10-27T00:41:40Z',
        )
        self.assertEqual(self.line(settled, 'settled with a target first added by a row stamped at or after the write:'), 'settled with a target first added by a row stamped at or after the write: 2 (16.7%)')
        self.assertEqual(self.line(settled, 'settled with a target added by a row stamped before the write:'), 'settled with a target added by a row stamped before the write: 8 (66.7%)')
        self.assertEqual(
            self.line(settled, 'settled with a target that no commit row adds'),
            'settled with a target that no commit row adds, or whose receipt has no usable write time: 1 (8.3%)',
        )
        self.assertEqual(self.line(settled, 'settled without a target:'), 'settled without a target: 1 (8.3%)')
        # A target stamped before the write (8) or added by no row (1) may have existed before the Keeper wrote: 9 of the 11 with a target.
        self.assertEqual(
            self.line(settled, 'targets that may have existed before the write'),
            'targets that may have existed before the write (stamped before it, added by no row, or without a usable write time): 9 of 11 with a target (81.8%); the other 2 are exact',
        )
        self.assertEqual(self.line(settled, 'not counted:'), 'not counted: 0 that cannot be placed in the window, 0 written before --since')
        self.assertEqual(self.line(settled, 'receipts that are not a settled candidate'), 'receipts that are not a settled candidate (--since does not apply): 6')
        for reason in reach.Skip:
            self.assertEqual(self.count(settled, reason.value + ':'), 2 if reason is reach.Skip.OTHER_SHAPE else 1, reason)

    def test_the_settled_table_counts_standing_and_the_ends_without_a_current_fact(self):
        settled = self.block('candidates the Librarian settled')
        self.assertEqual(self.line(settled, 'settled with a target:'), 'settled with a target: 11')
        self.assertEqual(self.line(settled, "the target has the memory id of the Keeper's own sentence:"), "the target has the memory id of the Keeper's own sentence: 1 (9.1%)")
        # The eleven targets stand as: NEW, OWN and OLD (twice) are current; REV, ABS, DEAD, RET and TAKEN once each; GONE and STRANGER have no record.
        self.assertEqual(self.line(settled, 'target now, a current fact:'), 'target now, a current fact: 4 (36.4%)')
        self.assertEqual(self.line(settled, 'target now, not current and no file mentions it:'), 'target now, not current and no file mentions it: 2 (18.2%)')
        for standing in (reach.Standing.BY_REWRITE, reach.Standing.BY_ABSORPTION, reach.Standing.DEAD_END, reach.Standing.RETRACTED, reach.Standing.REMOVED):
            self.assertEqual(self.count(settled, f'target now, {standing.value}:'), 1, standing)
        self.assertEqual(
            self.line(settled, 'the target is a current fact now or the records lead to one:'),
            'the target is a current fact now or the records lead to one: 6 of 11 with a target (54.5%), 6 of 12 settled (50.0%)',
        )
        # Ends without a current fact or a retraction: TAKEN (removed with a reason, the commit also added facts), DEAD (ends at LOST, no row removed it),
        # GONE and STRANGER (no record).
        self.assertEqual(self.line(settled, 'targets whose records end without a current fact or a retraction:'), 'targets whose records end without a current fact or a retraction: 4')
        self.assertEqual(self.line(settled, 'the id where the records end was removed by a committed row with a written reason:'), 'the id where the records end was removed by a committed row with a written reason: 1 (25.0%)')
        self.assertEqual(self.line(settled, 'the id where the records end was removed by a committed row with no written reason:'), 'the id where the records end was removed by a committed row with no written reason: 0 (0.0%)')
        self.assertEqual(self.line(settled, 'the id where the records end was removed by no committed row:'), 'the id where the records end was removed by no committed row: 3 (75.0%)')
        self.assertEqual(self.line(settled, 'the removing commit also added a fact:'), 'the removing commit also added a fact: 1 of 1')
        # The ends are removed by Librarian passes. The comparison population is the ids of that kind removed since the first write of the
        # window (00:15:00Z): TAKEN alone, since nothing else is removed, not current and free of records.
        self.assertEqual(self.line(settled, 'the removing commit was a Librarian pass:'), 'the removing commit was a Librarian pass: 1 of 1')
        self.assertEqual(
            self.line(settled, 'for comparison, 1 ids that are not current'),
            'for comparison, 1 ids that are not current, that no revised, absorbed or retracted record leads out of and that a Librarian commit '
            'removed since 2026-10-27T00:15:00Z: a written reason 1 (100.0%), also added a fact 1 (100.0%)',
        )
        # Every current fact of the three Keepers has an adding row.
        self.assertEqual(
            self.line(settled, 'for comparison, current facts that no committed journal row added'),
            'for comparison, current facts that no committed journal row added: 0 of 5 (0.0%)',
        )

    def test_the_settled_table_counts_stamps_and_gives_the_time_as_a_range(self):
        settled = self.block('candidates the Librarian settled')
        # Revision 1 has two Librarian stamps and so has revision 2 (eight candidates); revision 3 has one (the explicit write row is no pass).
        self.assertEqual(
            self.line(settled, 'settled with a target whose revision has more than one Librarian stamp:'),
            'settled with a target whose revision has more than one Librarian stamp: 9 of 11',
        )
        self.assertEqual(
            self.line(settled, 'seconds from the write to the journal stamp of the settling pass'),
            'seconds from the write to the journal stamp of the settling pass (10 of 11 receipts have a source fact and a Librarian stamp at or after the write; '
            'the stamp is when the pass read the queue):',
        )
        # Earliest: 30 40 50 100 100 200 300 400 500 500. Latest: 300 500 530 540 550 600 700 800 900 1000.
        self.assertEqual(self.line(settled, 'earliest possible:'), 'earliest possible: p50 100, p90 500, max 500')
        self.assertEqual(self.line(settled, 'latest possible:'), 'latest possible: p50 550, p90 900, max 1000')

    def test_the_coverage_table_splits_candidates_by_call_and_trace_age(self):
        coverage = self.block('coverage of the call table')
        self.assertEqual(self.line(coverage, 'raw trace files per Keeper:'), 'raw trace files per Keeper: min 1, median 1, max 1 (3 Keepers)')
        self.assertEqual(self.line(coverage, 'candidates with a source fact:'), 'candidates with a source fact: 11')
        # Calls were found for rid-new, rid-old and rid-unknown; the other eight were written inside the trace that starts at the first second.
        self.assertEqual(self.line(coverage, 'with a matching write call:'), 'with a matching write call: 3 (27.3%)')
        self.assertEqual(self.line(coverage, 'without one:'), 'without one: 8 (72.7%)')
        self.assertEqual(self.line(coverage, 'written before the oldest raw trace of the Keeper:'), 'written before the oldest raw trace of the Keeper: 0')
        self.assertEqual(self.line(coverage, 'written inside the raw traces:'), 'written inside the raw traces: 8')
        self.assertEqual(self.line(coverage, 'the Keeper has no raw trace with a turn start:'), 'the Keeper has no raw trace with a turn start: 0')
        self.assertEqual(
            self.line(coverage, 'candidates without a source fact'),
            'candidates without a source fact (the write time is not known): 1, with a matching write call: 1',
        )

    def test_the_keeper_table_names_the_files_a_keeper_lacks_and_dates_its_traces(self):
        table = self.block('Keeper |')
        # Columns: calls, rejected, result not in the trace, queued, after, before or unknown, without a target, waiting, no record,
        # settled in the window, of those written inside the traces without a call, trace files, oldest trace, problems.
        self.assertIn(f'a | 10 | 1 | 0 | 7 | 1 | 2 | 1 | 1 | 2 | 12 | 8 | 1 | {T0_ISO} | -', table)
        self.assertIn(f'empty | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 1 | {T0_ISO} | -', table)
        self.assertIn(
            f'ghost | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 1 | {T0_ISO} | missing ghost.librarian-range-commit.json; missing ghost.memory-admission.json; '
            'missing ghost.memory-journal.jsonl; missing ghost.memory-current.json',
            table,
        )

    def test_every_row_of_the_keeper_table_has_a_cell_per_column(self):
        table = self.block('Keeper |')
        columns = len(table[0].split(' | '))
        self.assertEqual(columns, 15)
        self.assertEqual(len(table), 4)
        for row in table[1:]:
            self.assertEqual(len(row.split(' | ')), columns, row)

    def test_the_last_line_says_nothing_was_skipped(self):
        self.assertEqual(self.out.rstrip('\n').split('\n')[-1], 'skipped input: none')

    def test_since_moves_the_whole_fixture_to_the_not_counted_and_drops_the_calls(self):
        _, out, _ = self.store.run('--since', '2026-10-28')
        self.assertIn('write calls: 0 in 0 Keepers', out)
        self.assertIn('in the --since window: 0 in 0 Keepers', out)
        # Eleven receipts hold a write time before the date; rid-none is placed by its revision, whose last Librarian stamp is before it too.
        self.assertIn('not counted: 0 that cannot be placed in the window, 12 written before --since', out)

    def test_exclude_skips_the_keeper_in_the_call_table_and_the_settled_table(self):
        _, out, _ = self.store.run('--exclude', 'a')
        self.assertIn('write calls: 2 in 2 Keepers', out)
        self.assertIn('in the --since window: 0 in 0 Keepers', out)

    def test_only_reads_one_keeper_and_lists_only_that_keeper(self):
        _, out, _ = self.store.run('--only', 'a')
        self.assertIn('write calls: 10 in 1 Keepers', out)
        self.assertIn('in the --since window: 12 in 1 Keepers', out)
        self.assertNotIn('\nempty | ', out)
        self.assertNotIn('\nghost | ', out)

    def test_a_missing_directory_is_an_error_not_an_empty_report(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = reach.main([str(self.store.keepers / 'nope'), '--memory-dir', str(self.store.memory)])
        self.assertEqual((code, out.getvalue()), (2, ''))
        self.assertIn('not a directory', err.getvalue())

    def test_the_memory_directory_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            reach.main([str(self.store.keepers)])
        self.assertEqual(caught.exception.code, 2)

    def test_a_time_outside_the_calendar_is_a_usage_error_not_a_traceback(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
            reach.main([str(self.store.keepers), '--memory-dir', str(self.store.memory), '--now', '9999-12-31T23:59:59-05:00'])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn('--now is outside the calendar', err.getvalue())

    def test_a_date_or_time_that_does_not_parse_is_a_usage_error_not_a_traceback(self):
        base = [str(self.store.keepers), '--memory-dir', str(self.store.memory)]
        for flag, value in (('--since', '2026-10-28+09:00'), ('--now', 'yesterday')):
            err = io.StringIO()
            with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
                reach.main([*base, flag, value])
            self.assertEqual(caught.exception.code, 2, flag)
            self.assertIn('error:', err.getvalue(), flag)


class WindowTests(unittest.TestCase):
    """A candidate is in the --since window by the time it was written."""

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        self.since = T0 + DAY

    def test_a_receipt_without_a_source_fact_is_placed_by_the_stamp_of_a_revision_that_has_one(self):
        boundary = self.since
        self.store.keeper(
            'b',
            receipts=[unbound('rid-b1', 1), unbound('rid-b2', 2), unbound('rid-b3', 3)],
            journal=[commit_row(1, boundary - 1), commit_row(2, boundary), commit_row(3, boundary + 1)],
        )
        self.store.trace('b', [
            finished(boundary - 1, queued_text('rid-b1'), 'c1'), finished(boundary, queued_text('rid-b2'), 'c2'), finished(boundary + 1, queued_text('rid-b3'), 'c3'),
        ])
        _, out, _ = self.store.run('--since', '2026-10-28')
        self.assertIn('write calls: 2 in 1 Keepers', out)
        self.assertIn('in the --since window: 2 in 1 Keepers', out)
        self.assertIn('not counted: 0 that cannot be placed in the window, 1 written before --since', out)
        self.assertIn(f'b | 2 | 0 | 0 | 2 | 0 | 0 | 2 | 0 | 0 | 2 | 0 | 1 | {T0_ISO} | -', out)

    def test_a_candidate_written_after_the_date_is_in_every_table_even_when_its_revision_began_before_it(self):
        since = self.since
        # The revision began an hour before the date; an unchanged pass kept it after the candidate was written.
        self.store.keeper(
            'w',
            receipts=[bound('rid-w', 'src', OLD, 1, since + 400)],
            journal=[commit_row(1, since - 3600, [OLD]), commit_row(1, since + 500, effect='unchanged')],
        )
        self.store.trace('w', [finished(since + 450, queued_text('rid-w'), 'c1')])
        _, out, _ = self.store.run('--since', '2026-10-28')
        self.assertIn('write calls: 1 in 1 Keepers', out)
        self.assertIn('settled with a target added by a row stamped before the write: 1 (100.0%)', out)
        self.assertIn('in the --since window: 1 in 1 Keepers', out)
        self.assertIn('not counted: 0 that cannot be placed in the window, 0 written before --since', out)
        self.assertIn('earliest possible: p50 100, p90 100, max 100', out)

    def test_a_candidate_written_in_the_very_second_of_the_date_is_inside_and_one_second_earlier_is_older(self):
        since = self.since
        self.store.keeper(
            'e',
            receipts=[bound('rid-e1', 's', OLD, 1, since), bound('rid-e2', 's', OLD, 1, since - 1)],
            journal=[commit_row(1, since - 100, [OLD])],
        )
        _, out, _ = self.store.run('--since', '2026-10-28', '--only', 'e')
        self.assertIn('in the --since window: 1 in 1 Keepers', out)
        self.assertIn('not counted: 0 that cannot be placed in the window, 1 written before --since', out)

    def test_a_receipt_without_a_source_fact_is_older_unplaced_or_inside_by_all_the_stamps_of_its_revision(self):
        since = self.since
        # rid-u1: stamps on both sides of the date, so the pass that settled it is unknown. rid-u2: every stamp before it.
        # rid-u3: no stamp at its revision. rid-u4 and rid-u5: every stamp at or after it, the second from the very second.
        # rid-u6: the last stamp is in the very second of the date but the first is before it.
        self.store.keeper(
            'u',
            receipts=[unbound('rid-u1', 1), unbound('rid-u2', 2), unbound('rid-u3', 99), unbound('rid-u4', 4), unbound('rid-u5', 5), unbound('rid-u6', 6)],
            journal=[
                commit_row(1, since - 3600), commit_row(1, since + 500, effect='unchanged'),
                commit_row(2, since - 3600),
                commit_row(4, since + 100), commit_row(4, since + 200, effect='unchanged'),
                commit_row(5, since), commit_row(5, since + 10, effect='unchanged'),
                commit_row(6, since - 1), commit_row(6, since, effect='unchanged'),
            ],
        )
        _, out, _ = self.store.run('--since', '2026-10-28', '--only', 'u')
        self.assertIn('in the --since window: 2 in 1 Keepers', out)
        self.assertIn('not counted: 3 that cannot be placed in the window, 1 written before --since', out)

    def test_without_a_date_a_receipt_that_cannot_be_placed_is_still_counted(self):
        self.store.keeper('u', receipts=[unbound('rid-u3', 99)])
        _, out, _ = self.store.run('--only', 'u')
        self.assertIn('in the --since window: 1 in 1 Keepers', out)
        self.assertIn('not counted: 0 that cannot be placed in the window, 0 written before --since', out)


class RemovalTests(unittest.TestCase):
    """Targets whose records end without a current fact, by the committed row that removed the id where they end."""

    T1, T2, T3, T4, L3, L4, N1, N2 = ('target one', 'target two', 'target three', 'target four', 'lost three', 'lost four', 'new one', 'new two')

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        t1, t2, t3, t4, l3, l4, n1, n2 = self.T1, self.T2, self.T3, self.T4, self.L3, self.L4, self.N1, self.N2
        self.store.keeper(
            'rm',
            receipts=[bound('r1', 's1', t1, 1, T0 + 5), bound('r2', 's2', t2, 1, T0 + 5), bound('r3', 's3', t3, 1, T0 + 5), bound('r4', 's4', t4, 1, T0 + 5)],
            journal=[
                commit_row(1, T0 + 10, [t1, t2, t3, t4, l3, l4]),
                commit_row(2, T0 + 20, [n1], [t1], dropped=[(t1, 'a written reason')]),
                commit_row(3, T0 + 30, [], [t2], dropped=[(t2, '   ')]),
                commit_row(4, T0 + 40, [n2], [l3], dropped=[(l3, 'another written reason')]),
            ],
            current=[n1, n2],
            revised={t3: l3, t4: l4},
        )

    def test_a_removal_has_a_reason_when_its_row_names_the_fact_with_a_nonblank_reason(self):
        removals = self.store.state('rm').journal.removals
        self.assertEqual(
            removals,
            {
                mid(self.T1): reach.Removal(True, True, T0 + 20, True), mid(self.T2): reach.Removal(False, False, T0 + 30, True),
                mid(self.L3): reach.Removal(True, True, T0 + 40, True),
            },
        )

    def test_a_reason_written_for_another_id_is_no_reason_for_this_one(self):
        self.store.keeper('other', journal=[commit_row(2, T0 + 20, [self.N1], [self.T1], dropped=[(self.T2, 'a reason for another fact')])])
        self.assertEqual(self.store.state('other').journal.removals, {mid(self.T1): reach.Removal(False, True, T0 + 20, True)})

    def comparison(self, *args, keeper='base'):
        lines = [line.strip() for line in self.store.run('--only', keeper, *args)[1].split('\n')]
        found = [line for line in lines if line.startswith('for comparison, ') and ' ids that are not current' in line]
        self.assertEqual(len(found), 1, found)
        return found[0]

    def test_the_comparison_counts_only_ids_of_the_same_kind(self):
        n1, n2, t1, t2, t3, t4, l4 = self.N1, self.N2, self.T1, self.T2, self.T3, self.T4, self.L4
        self.store.keeper(
            'base',
            journal=[
                commit_row(1, T0 + 10, [n1, t4, l4]),
                commit_row(2, T0 + 20, [n2], [n1], dropped=[(n1, 'a written reason')]),  # counts: a reason, added a fact
                commit_row(3, T0 + 30, [], [n2]),  # counts: no reason, added nothing
                commit_row(4, T0 + 40, [], [t1], source='explicit_write'),  # not a Librarian pass
                commit_row(5, T0 + 50, [t3], [t2]),  # counts: no reason, added a fact
                commit_row(6, T0 + 60, [], [t4]),  # t4 has a revised record
                commit_row(7, T0 + 70, [], [l4]),  # l4 is a current fact
            ],
            current=[l4, t3],
            revised={t4: l4},
        )
        self.assertEqual(
            self.comparison(),
            'for comparison, 3 ids that are not current, that no revised, absorbed or retracted record leads out of and that a Librarian commit '
            'removed since the start of the journal: a written reason 1 (33.3%), also added a fact 2 (66.7%)',
        )

    def ends_of_that_kind(self, keeper):
        lines = [line.strip() for line in self.store.run('--only', keeper)[1].split('\n')]
        found = [line for line in lines if line.startswith('the ends above that are of that kind:')]
        self.assertEqual(len(found), 1, found)
        return found[0]

    def test_the_ends_of_the_same_kind_are_counted_against_all_the_ends(self):
        # t1, t2 and l3 end on a Librarian row; t4 ends on l4, which no row removed.
        self.assertEqual(self.ends_of_that_kind('rm'), 'the ends above that are of that kind: 3 of 4')

    def test_a_loop_of_revised_records_ends_on_an_id_outside_the_comparison(self):
        a, b = self.T1, self.T2
        self.store.keeper(
            'loop',
            receipts=[bound('rc', 's', a, 2, T0 + 60)],
            journal=[commit_row(1, T0 + 10, [a]), commit_row(2, T0 + 20, [b], [a]), commit_row(3, T0 + 30, [], [b])],
            revised={a: b, b: a},
        )
        self.assertEqual(self.ends_of_that_kind('loop'), 'the ends above that are of that kind: 0 of 1')
        self.assertIn('for comparison, 0 ids that are not current,', self.comparison(keeper='loop'))

    def test_an_end_removed_by_an_explicit_write_is_outside_the_comparison(self):
        self.store.keeper(
            'explicit',
            receipts=[bound('re', 's', self.T1, 1, T0 + 5)],
            journal=[commit_row(1, T0 + 10, [self.T1]), commit_row(2, T0 + 20, [], [self.T1], source='explicit_write')],
        )
        self.assertEqual(self.ends_of_that_kind('explicit'), 'the ends above that are of that kind: 0 of 1')

    def test_an_absorbed_or_retracted_id_is_not_of_the_same_kind(self):
        self.store.keeper(
            'base',
            journal=[commit_row(1, T0 + 10, [self.N1, self.N2, self.T1]), commit_row(2, T0 + 20, [], [self.N1, self.N2, self.T1])],
            absorbed={self.N1: self.T3},
            retracted=[self.N2],
        )
        self.assertIn('for comparison, 1 ids that are not current,', self.comparison())

    def test_the_comparison_starts_at_the_first_write_of_the_window(self):
        self.store.keeper(
            'win',
            receipts=[bound('rid-w', 'src', self.N1, 1, T0 + 500)],
            journal=[
                commit_row(1, T0 + 100, [self.N1, self.N2, self.T1]),
                commit_row(2, T0 + 200, [], [self.T1]),  # before the first write of the window
                commit_row(3, T0 + 500, [], [self.N2]),  # at the first write: counts
                commit_row(4, T0 + 600, [], [self.N1]),  # counts
            ],
        )
        self.assertIn(
            '2 ids that are not current, that no revised, absorbed or retracted record leads out of and that a Librarian commit '
            'removed since 2026-10-27T00:08:20Z: a written reason 0 (0.0%), also added a fact 0 (0.0%)',
            self.comparison('--since', '2026-10-27', keeper='win'),
        )

    def test_without_a_write_in_the_window_the_comparison_starts_at_the_date(self):
        self.store.keeper(
            'nr',
            journal=[commit_row(1, T0 - 100, [self.N1, self.N2]), commit_row(2, T0 - 50, [], [self.N1]), commit_row(3, T0 + 100, [], [self.N2])],
        )
        self.assertIn('1 ids that are not current,', self.comparison('--since', '2026-10-27', keeper='nr'))
        self.assertIn('removed since 2026-10-27T00:00:00Z:', self.comparison('--since', '2026-10-27', keeper='nr'))

    def test_the_comparison_of_a_store_without_removals_is_empty_not_an_error(self):
        self.assertIn('0 ids that are not current,', self.comparison(keeper='nobody'))
        self.assertIn('a written reason 0 (-), also added a fact 0 (-)', self.comparison(keeper='nobody'))

    def test_the_last_row_that_removed_a_fact_is_the_one_kept(self):
        self.store.keeper('again', journal=[
            commit_row(2, T0 + 20, [self.N1], [self.T1], dropped=[(self.T1, 'a written reason')]),
            commit_row(5, T0 + 50, [], [self.T1]),
        ])
        self.assertEqual(self.store.state('again').journal.removals, {mid(self.T1): reach.Removal(False, False, T0 + 50, True)})

    def test_a_row_of_another_source_is_a_removal_but_not_a_librarian_pass(self):
        self.store.keeper('src', journal=[commit_row(2, T0 + 20, [], [self.T1], source='explicit_write')])
        self.assertEqual(self.store.state('src').journal.removals, {mid(self.T1): reach.Removal(False, False, T0 + 20, False)})

    def test_the_report_looks_up_the_id_where_the_records_end(self):
        _, out, _ = self.store.run('--only', 'rm')
        lines = [line.strip() for line in out.split('\n')]
        self.assertIn('targets whose records end without a current fact or a retraction: 4', lines)
        self.assertIn('the id where the records end was removed by a committed row with a written reason: 2 (50.0%)', lines)
        self.assertIn('the id where the records end was removed by a committed row with no written reason: 1 (25.0%)', lines)
        self.assertIn('the id where the records end was removed by no committed row: 1 (25.0%)', lines)
        self.assertIn('the removing commit also added a fact: 2 of 3', lines)
        self.assertIn('the removing commit was a Librarian pass: 3 of 3', lines)

    def test_an_end_removed_by_another_source_is_not_counted_as_a_librarian_pass(self):
        self.store.keeper(
            'ex',
            receipts=[bound('r1', 's1', self.T1, 1, T0 + 5)],
            journal=[commit_row(1, T0 + 10, [self.T1]), commit_row(2, T0 + 20, [], [self.T1], source='explicit_write')],
        )
        lines = [line.strip() for line in self.store.run('--only', 'ex')[1].split('\n')]
        self.assertIn('the removing commit was a Librarian pass: 0 of 1', lines)


class CoverageTests(unittest.TestCase):
    """Raw traces keep only the latest turns, so older candidates have no call to match."""

    def test_candidates_are_split_by_call_and_by_the_age_of_the_oldest_trace(self):
        store = Store()
        self.addCleanup(store.close)
        # 'cov' has traces from T0+1000 on: c1 was written before them, c2 has a call, c3 was written inside them without a call,
        # and c6 was written in the very second the oldest trace starts.
        store.keeper(
            'cov',
            receipts=[
                bound('rid-c1', 's', OLD, 1, T0 + 500), bound('rid-c2', 's', OLD, 1, T0 + 1500), bound('rid-c3', 's', OLD, 1, T0 + 1600),
                bound('rid-c6', 's', OLD, 1, T0 + 1000), unbound('rid-c4', 1), unbound('rid-c5', 1),
            ],
            journal=[commit_row(1, T0 + 100, [OLD])],
        )
        store.trace('cov', [finished(T0 + 1550, queued_text('rid-c2'), 'c1'), finished(T0 + 1560, queued_text('rid-c4'), 'c2')], start=T0 + 1000)
        # 'bare' has no raw traces at all, 'odd' has two files that carry no turn start, 'big' has four turns and no receipts.
        store.keeper('bare', receipts=[bound('rid-b1', 's', OLD, 1, T0 + 10)], journal=[commit_row(1, T0 + 100, [OLD])])
        store.keeper('odd', receipts=[bound('rid-o1', 's', OLD, 1, T0 + 10)], journal=[commit_row(1, T0 + 100, [OLD])])
        store.trace('odd', [], name='notes.jsonl')
        store.trace('odd', [], name='more.jsonl')
        for index in range(4):
            store.trace('big', [], start=T0 + 5000 + index)
        _, out, _ = store.run()
        lines = [line.strip() for line in out.split('\n')]
        self.assertIn('raw trace files per Keeper: min 1, median 2, max 4 (3 Keepers)', lines)
        self.assertIn('candidates with a source fact: 6', lines)
        self.assertIn('with a matching write call: 1 (16.7%)', lines)
        self.assertIn('without one: 5 (83.3%)', lines)
        self.assertIn('written before the oldest raw trace of the Keeper: 1', lines)
        self.assertIn('written inside the raw traces: 2', lines)
        self.assertIn('the Keeper has no raw trace with a turn start: 2', lines)
        self.assertIn('candidates without a source fact (the write time is not known): 2, with a matching write call: 1', lines)
        self.assertIn('skipped input: raw trace files whose name has no turn start 2', lines)
        # Two calls, both queued: rid-c2 settled with a target that a row stamped before the write had added, rid-c4 without a target.
        # Of its six settled candidates, c3 and c6 were written inside the traces without a call.
        self.assertIn(f'cov | 2 | 0 | 0 | 2 | 0 | 1 | 1 | 0 | 0 | 6 | 2 | 1 | {reach.iso(T0 + 1000)} | -', out)
        self.assertIn('odd | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 2 | - | -', out)


class MedianTests(unittest.TestCase):
    def files_line(self, per_keeper):
        store = Store()
        self.addCleanup(store.close)
        for keeper, files in per_keeper.items():
            for index in range(files):
                store.trace(keeper, [], start=T0 + index)
        return next(line.strip() for line in store.run()[1].split('\n') if line.strip().startswith('raw trace files per Keeper'))

    def test_the_median_of_an_odd_number_of_keepers_is_the_middle_count(self):
        self.assertEqual(self.files_line({'m1': 1, 'm2': 2, 'm3': 9}), 'raw trace files per Keeper: min 1, median 2, max 9 (3 Keepers)')

    def test_the_median_of_an_even_number_of_keepers_is_the_mean_of_the_two_middle_counts(self):
        self.assertEqual(self.files_line({'m1': 1, 'm2': 2, 'm3': 4, 'm4': 8}), 'raw trace files per Keeper: min 1, median 3, max 8 (4 Keepers)')
        self.assertEqual(self.files_line({'m1': 1, 'm2': 2}), 'raw trace files per Keeper: min 1, median 1.5, max 2 (2 Keepers)')


class TimesPastTheCalendarTests(unittest.TestCase):
    def test_a_report_over_times_in_milliseconds_prints_and_counts_them_instead_of_stopping(self):
        store = Store()
        self.addCleanup(store.close)
        in_milliseconds = T0 * 1000
        store.trace('ms', [finished(in_milliseconds, queued_text('rid-ms'), 'c1'), finished(T0 + 1, queued_text('rid-ok'), 'c2')])
        store.keeper(
            'ms',
            receipts=[bound('rid-a', 's', OLD, 1, in_milliseconds), bound('rid-b', 's', OLD, 1, T0 + 5)],
            journal=[commit_row(1, in_milliseconds, [OLD]), commit_row(1, T0 + 100, [OLD])],
        )
        code, out, err = store.run()
        self.assertEqual((code, err), (0, ''))
        self.assertIn('write calls: 1 in 1 Keepers', out)
        self.assertEqual(
            out.rstrip('\n').split('\n')[-1],
            'skipped input: committed journal rows without a revision or a usable recorded_at 1; '
            'settled receipts whose source fact has no usable first_seen (read as having no write time) 1; '
            'write records whose ts is not a usable time 1',
        )


class EdgeInputTests(unittest.TestCase):
    """Inputs the live data does not hold today but the report must still read the same way in every table."""

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)

    def lines(self, *args):
        return self.store.run(*args)[1].split('\n')

    def test_each_keeper_that_holds_rows_names_its_oldest_row_and_the_busiest_comes_first(self):
        self.store.keeper('few', pending=[('rid-1', T0 + 100)])
        self.store.keeper('many', pending=[('rid-2', T0 + 300), ('rid-3', T0 + 50), ('rid-4', T0 * 1000)])
        self.store.keeper('none')
        lines = self.lines()
        total = '  rows in the admission queues of the 3 Keepers read, whatever their age and whether or not the trace holds their call: 4'
        start = lines.index(total)
        # The read is one day after T0, so the oldest rows are 86350 and 86300 seconds old.
        self.assertEqual(
            lines[start + 1:start + 4],
            [
                f'    many: 3 rows; oldest written {reach.iso(T0 + 50)} (86350 s before the read); last Librarian commit none in the journal',
                f'    few: 1 rows; oldest written {reach.iso(T0 + 100)} (86300 s before the read); last Librarian commit none in the journal',
                '',
            ],
        )

    def test_a_keeper_with_only_a_queue_file_is_read(self):
        rows = [{'sequence': number, 'request_id': f'rid-{number}', 'fact': {'first_seen': T0}} for number in range(5)]
        (self.store.memory / 'stuck.memory-admission.json').write_text(json.dumps({'generation': 'g', 'last_sequence': 5, 'pending': rows}), encoding='utf-8')
        lines = self.lines()
        self.assertIn('  rows in the admission queues of the 1 Keepers read, whatever their age and whether or not the trace holds their call: 5', lines)
        self.assertIn(f'    stuck: 5 rows; oldest written {T0_ISO} (86400 s before the read); last Librarian commit unknown, no journal file', lines)
        missing = 'missing stuck.librarian-range-commit.json; missing stuck.memory-journal.jsonl; missing stuck.memory-current.json'
        self.assertIn(f'stuck | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | - | {missing}', lines)

    def test_a_keeper_with_only_a_journal_and_current_facts_is_read(self):
        (self.store.memory / 'ghost.memory-journal.jsonl').write_text(json.dumps(commit_row(1, T0 + 10, [OLD])) + '\n', encoding='utf-8')
        (self.store.memory / 'ghost.memory-current.json').write_text(json.dumps({'facts': [{'claim': OLD}]}), encoding='utf-8')
        lines = self.lines()
        self.assertEqual(sum(line.startswith('ghost | ') for line in lines), 1)
        self.assertIn('  for comparison, current facts that no committed journal row added: 0 of 1 (0.0%)', lines)

    def test_a_queue_whose_rows_name_no_request_id_still_gets_its_line(self):
        self.store.keeper('anon', pending=[''])
        self.assertIn(f'    anon: 1 rows; oldest written {T0_ISO} (86400 s before the read); last Librarian commit none in the journal', self.lines())

    def test_a_journal_with_no_librarian_row_is_told_from_a_missing_journal(self):
        self.store.keeper('quiet', pending=['rid-1'], journal=[commit_row(1, T0 + 10, [OLD], source='explicit_write')])
        lines = self.lines()
        self.assertIn(f'    quiet: 1 rows; oldest written {T0_ISO} (86400 s before the read); last Librarian commit none in the journal', lines)

    def test_since_at_the_epoch_is_a_date_and_not_unset(self):
        self.store.trace('neg', [finished(-5, queued_text('rid-old'), 'c1'), finished(5, queued_text('rid-new'), 'c2')])
        self.store.keeper(
            'neg',
            # rid-plain has no source fact; its revision is stamped before 1970, so it was settled and written before --since.
            receipts=[bound('rid-old', 's', OLD, 1, -5), bound('rid-new', 's', OLD, 1, 5), unbound('rid-plain', 2)],
            journal=[commit_row(1, 10, [OLD]), commit_row(2, -50)],
        )
        lines = self.lines('--since', '1970-01-01')
        self.assertIn('write calls: 1 in 1 Keepers', lines)
        self.assertIn('  first 1970-01-01T00:00:05Z, last 1970-01-01T00:00:05Z; --since 1970-01-01T00:00:00Z', lines)
        self.assertIn('  not counted: 0 that cannot be placed in the window, 2 written before --since', lines)

    def test_current_facts_that_no_committed_row_added_are_counted(self):
        self.store.keeper('un', journal=[commit_row(1, T0 + 10, [OLD])], current=[OLD, NEW])
        self.assertIn('  for comparison, current facts that no committed journal row added: 1 of 2 (50.0%)', self.lines())

    def test_a_keeper_with_only_a_receipt_file_is_read(self):
        self.store.keeper('receipts-only', receipts=[unbound('rid-r', 1)], journal=[commit_row(1, T0 + 10)])
        for suffix in ('.memory-admission.json', '.memory-journal.jsonl', '.memory-current.json'):
            (self.store.memory / f'receipts-only{suffix}').unlink()
        lines = self.lines()
        self.assertIn('  rows in the admission queues of the 1 Keepers read, whatever their age and whether or not the trace holds their call: 0', lines)
        self.assertEqual(sum(line.startswith('receipts-only | ') for line in lines), 1)

    def test_a_receipt_with_a_write_time_past_the_calendar_is_read_the_same_in_both_tables(self):
        self.store.keeper('bad', receipts=[bound('rid-bad', 'src', OLD, 1, T0 * 1000)], journal=[commit_row(1, T0 + 1000, [OLD])])
        self.store.trace('bad', [finished(T0 + 900, queued_text('rid-bad'), 'c1')])
        lines = self.lines()
        unknown = '  settled with a target that no commit row adds, or whose receipt has no usable write time: 1 (100.0%)'
        self.assertEqual(lines.count(unknown), 2, 'once in the queued table and once in the settled table')
        self.assertIn(
            '  targets that may have existed before the write (stamped before it, added by no row, or without a usable write time): 1 of 1 with a target (100.0%); the other 0 are exact',
            lines,
        )

    def test_without_a_date_a_time_before_1970_is_counted_not_dropped(self):
        self.store.trace('neg', [finished(-5, queued_text('rid-neg'), 'c1')])
        self.store.keeper('neg', receipts=[bound('rid-neg', 'src', OLD, 1, -5)], journal=[commit_row(1, T0, [OLD])])
        lines = self.lines()
        self.assertIn('write calls: 1 in 1 Keepers', lines)
        self.assertIn('  first 1969-12-31T23:59:55Z, last 1969-12-31T23:59:55Z; --since not set', lines)
        self.assertIn('  not counted: 0 that cannot be placed in the window, 0 written before --since', lines)

    def test_a_quarantined_journal_does_not_mix_the_stamps_of_two_snapshots(self):
        quarantine = {'outcome': 'quarantined', 'recorded_at': T0 + 200, 'rejection': 'undecodable', 'rejected_path': 'rejected.json'}
        self.store.keeper(
            'qr',
            receipts=[bound('rid-q', 'src', NEW, 1, T0 + 350)],
            journal=[commit_row(1, T0 + 100, [OLD]), quarantine, commit_row(1, T0 + 400, [NEW])],
        )
        out = self.store.run()[1]
        self.assertIn('settled with a target whose revision has more than one Librarian stamp: 0 of 1', out)
        self.assertIn('qr.memory-journal.jsonl holds 1 revision restarts (a quarantine row, or a revision that went back); the stamps before each are dropped', out)

    def test_the_keeper_table_lists_the_most_calls_first_then_by_name(self):
        for keeper, count in (('x', 2), ('y', 5), ('b', 2)):
            self.store.trace(keeper, [finished(T0 + number, rejected_text('source_read_failed'), f'c{number}') for number in range(count)])
        self.store.keeper('z')
        lines = self.lines()
        header = next(index for index, line in enumerate(lines) if line.startswith('Keeper |'))
        self.assertEqual([line.split(' | ')[0] for line in lines[header + 1:] if ' | ' in line], ['y', 'b', 'x', 'z'])


class QuietKeeperTests(unittest.TestCase):
    """A Keeper that made no write call in the window still has its files read, so its problems show."""

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)

    def test_a_keeper_without_calls_is_in_the_keeper_table_with_its_missing_files(self):
        self.store.keeper('quiet', receipts=[unbound('rid-q', 1)], journal=[commit_row(1, T0 + 10)])
        (self.store.memory / 'quiet.memory-current.json').unlink()
        self.store.trace('loud', [finished(T0 + 1, rejected_text('source_read_failed'), 'c1')])
        _, out, _ = self.store.run()
        self.assertIn('quiet | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | - | missing quiet.memory-current.json', out)

    def test_a_claim_added_twice_is_dated_by_its_first_addition(self):
        journal = [commit_row(1, T0 + 100, [OLD]), commit_row(2, T0 + 200, [], [OLD]), commit_row(3, T0 + 2600, [OLD])]
        self.store.keeper('twice', receipts=[bound('rid-t', 'src', OLD, 3, T0 + 1500)], journal=journal, current=[OLD])
        state = self.store.state('twice')
        self.assertEqual(state.journal.first_added[mid(OLD)], T0 + 100)
        self.assertEqual(state.origin_of(state.settled['rid-t']), reach.Origin.BEFORE)


class CallsOnlyTests(unittest.TestCase):
    def test_a_keeper_with_calls_and_no_receipt_file_is_still_in_the_keeper_table(self):
        store = Store()
        self.addCleanup(store.close)
        store.trace('solo', [finished(T0 + 1, rejected_text('source_read_failed'), 'c1')])
        _, out, _ = store.run()
        self.assertIn(f'solo | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | {T0_ISO} | missing solo.librarian-range-commit.json', out)

    def test_a_native_call_of_an_official_client_has_its_own_column(self):
        store = Store()
        self.addCleanup(store.close)
        store.trace('nat', [native_finished(T0 + 1, ['Provider_step', {'step_index': 1}]), finished(T0 + 2, rejected_text('source_read_failed'), 'c1')])
        _, out, _ = store.run()
        self.assertIn(f'nat | 2 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | {T0_ISO} | missing nat.librarian-range-commit.json', out)


if __name__ == '__main__':
    unittest.main()
