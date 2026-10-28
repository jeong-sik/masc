"""Logic of the write-reach measurement on small synthetic Keeper stores; nothing is read from a live base path."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'keeper-recall-write-reach.py'
spec = importlib.util.spec_from_file_location('keeper_recall_write_reach', SCRIPT)
assert spec is not None and spec.loader is not None
reach = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = reach  # the script's dataclasses read their own module while they are defined
spec.loader.exec_module(reach)

PENDING = 'persisted_pending_admission'


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


def range_receipt(revision):
    return {'state': 'committed', 'range_id': 'range-1', 'snapshot_revision': revision, 'snapshot_sha256': 'h'}


def commit_row(revision, recorded_at, added=()):
    return {'outcome': 'committed', 'revision': revision, 'recorded_at': recorded_at, 'change': {'added': [{'claim': claim} for claim in added]}}


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

    def trace(self, keeper, records, name='turn-1.jsonl'):
        folder = self.keepers / keeper / 'raw-traces'
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(''.join(json.dumps(record) + '\n' for record in records), encoding='utf-8')

    def keeper(self, keeper, receipts=(), pending=(), journal=(), current=(), revised=(), retracted=(), absorbed=()):
        def put(suffix, value):
            (self.memory / f'{keeper}{suffix}').write_text(value, encoding='utf-8')

        put('.librarian-range-commit.json', json.dumps({'receipts': list(receipts)}))
        put('.memory-admission.json', json.dumps({'generation': 'g', 'last_sequence': 9, 'pending': [{'sequence': 9, 'request_id': rid, 'fact': {}} for rid in pending]}))
        put('.memory-journal.jsonl', ''.join(json.dumps(row) + '\n' for row in journal))
        put('.memory-current.json', json.dumps({'facts': [{'claim': claim} for claim in current]}))
        events = [{'kind': 'revised', 'memory_id': mid(claim)} for claim in revised] + [{'kind': 'retracted', 'memory_id': mid(claim)} for claim in retracted]
        put('.memory-events.jsonl', ''.join(json.dumps(row) + '\n' for row in events))
        put('.memory-absorbed.jsonl', ''.join(json.dumps({'memory_id': mid(claim)}) + '\n' for claim in absorbed))

    def run(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = reach.main([str(self.keepers), '--memory-dir', str(self.memory), '--now', '2026-10-28T00:00:00Z', *extra])
        return code, out.getvalue(), err.getvalue()


class CallKindTests(unittest.TestCase):
    def call(self, record):
        return reach.call_of('k', record)

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


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)

    def scan(self, only=(), excluded=(), since=0.0):
        return reach.scan_traces(str(self.store.keepers), set(only), set(excluded), since)

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

    def test_since_only_and_exclude_bound_the_read(self):
        for keeper in ('a', 'b'):
            self.store.trace(keeper, [finished(10, queued_text(f'memory-admission-{keeper}1'), 'c1'), finished(20, queued_text(f'memory-admission-{keeper}2'), 'c2')])
        self.assertEqual(len(self.scan().calls), 4)
        self.assertEqual({call.request_id for call in self.scan(since=15.0).calls}, {'memory-admission-a2', 'memory-admission-b2'})
        self.assertEqual({call.keeper for call in self.scan(only=['a']).calls}, {'a'})
        self.assertEqual({call.keeper for call in self.scan(excluded=['a']).calls}, {'b'})


# One Keeper whose queue had every ending. Commit times: revision 1 at 1000, 2 at 2000 (adds nothing), 3 at 3000.
OWN = 'own sentence'
ADDED = 'claim written by the Librarian'
RESIDENT = 'claim that was already there'
REVISED, RETRACTED, ABSORBED, GONE = 'was revised', 'was retracted', 'was absorbed', 'left without a record'


def keeper_a(store):
    store.keeper(
        'a',
        receipts=[
            bound('rid-added', 'a reworded sentence', ADDED, 1, 900.0),
            bound('rid-own', OWN, OWN, 3, 2500.0),
            bound('rid-resident', 'x1', RESIDENT, 2, 1500.0),
            bound('rid-revised', 'x2', REVISED, 2, 1600.0),
            bound('rid-retracted', 'x3', RETRACTED, 2, 1700.0),
            bound('rid-absorbed', 'x4', ABSORBED, 2, 1800.0),
            bound('rid-gone', 'x5', GONE, 2, 1900.0),
            unbound('rid-none', 2),
            bound('rid-undated', 'x6', RESIDENT, 99, 1900.0),
            bound('rid-prepared', 'x7', RESIDENT, 2, 1900.0, state='prepared'),
            range_receipt(2),
        ],
        pending=['rid-wait'],
        journal=[
            commit_row(1, 1000.0, [ADDED]), commit_row(2, 2000.0), commit_row(3, 3000.0, [OWN]),
            {'outcome': 'failed', 'kind': 'lane_cancelled', 'recorded_at': 3500.0},
            # A row that is not a commit but names revision 2: it must not replace the commit of revision 2.
            {'outcome': 'failed', 'revision': 2, 'recorded_at': 9999.0, 'change': {'added': [{'claim': RESIDENT}]}},
        ],
        current=[ADDED, OWN, RESIDENT],
        revised=[REVISED],
        retracted=[RETRACTED],
        absorbed=[ABSORBED],
    )


class StateTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.state = reach.load_state(str(self.store.memory), 'a')

    def test_candidates_are_read_from_both_receipt_shapes_and_the_rest_is_counted_apart(self):
        self.assertEqual(len(self.state.settled), 9)
        self.assertEqual(self.state.settled['rid-none'].target, '')
        self.assertEqual(self.state.settled['rid-added'].target, mid(ADDED))
        self.assertEqual(self.state.not_candidates, 2)  # the range receipt and the prepared one
        self.assertEqual(self.state.waiting, frozenset({'rid-wait'}))
        self.assertEqual(self.state.problems, ())

    def test_a_target_equal_to_the_keepers_own_claim_is_flagged(self):
        self.assertTrue(self.state.settled['rid-own'].own_sentence)
        self.assertFalse(self.state.settled['rid-added'].own_sentence)

    def test_only_committed_journal_rows_are_commits(self):
        self.assertEqual(sorted(self.state.commits), [1, 2, 3])
        self.assertEqual(self.state.commits[1].added, frozenset({mid(ADDED)}))

    def test_a_target_has_one_standing(self):
        standings = self.state.standings
        self.assertEqual(
            [standings.of(mid(claim)) for claim in (ADDED, REVISED, RETRACTED, ABSORBED, GONE)],
            [reach.Standing.CURRENT, reach.Standing.REVISED, reach.Standing.RETRACTED, reach.Standing.ABSORBED, reach.Standing.GONE],
        )

    def test_a_repeated_request_id_is_not_counted_twice(self):
        self.store.keeper('r', receipts=[unbound('same', 1), unbound('same', 2)], journal=[commit_row(1, 10.0), commit_row(2, 20.0)])
        state = reach.load_state(str(self.store.memory), 'r')
        self.assertEqual((len(state.settled), state.not_candidates, state.settled['same'].revision), (1, 1, 1))

    def test_missing_files_are_named_not_skipped(self):
        state = reach.load_state(str(self.store.memory), 'nobody')
        self.assertEqual(
            state.problems,
            ('missing nobody.librarian-range-commit.json', 'missing nobody.memory-admission.json', 'missing nobody.memory-current.json'),
        )
        (self.store.memory / 'broken.librarian-range-commit.json').write_text('{not json', encoding='utf-8')
        self.assertIn('unreadable broken.librarian-range-commit.json', reach.load_state(str(self.store.memory), 'broken').problems)


class FateTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.state = reach.load_state(str(self.store.memory), 'a')

    def fate(self, request_id, ts=2000.0, state=None):
        call = reach.WriteCall('a', ts, reach.Kind.RECEIPT_OK, PENDING, '', request_id)
        return reach.fate_of(call, state or self.state)

    def test_a_target_the_commit_added_and_one_that_was_already_there(self):
        self.assertEqual(self.fate('rid-added'), reach.Fate.ADDED)
        self.assertEqual(self.fate('rid-resident'), reach.Fate.EXISTING)

    def test_a_commit_row_that_the_journal_lost_is_its_own_fate(self):
        self.assertEqual(self.fate('rid-undated'), reach.Fate.UNDATED)

    def test_a_candidate_settled_without_a_target(self):
        self.assertEqual(self.fate('rid-none'), reach.Fate.WITHOUT_TARGET)

    def test_a_row_in_the_queue_is_waiting(self):
        self.assertEqual(self.fate('rid-wait'), reach.Fate.WAITING)

    def test_a_receipt_wins_over_a_row_the_queue_still_holds(self):
        self.store.keeper('a', receipts=[unbound('rid-both', 1)], pending=['rid-both'], journal=[commit_row(1, 1000.0)])
        self.assertEqual(self.fate('rid-both', state=reach.load_state(str(self.store.memory), 'a')), reach.Fate.WITHOUT_TARGET)

    def test_no_record_is_split_by_the_oldest_receipt_of_the_keeper(self):
        # The oldest receipt commit is revision 1 at 1000.
        self.assertEqual(self.fate('rid-lost', ts=999.0), reach.Fate.NO_RECORD_OLDER)
        self.assertEqual(self.fate('rid-lost', ts=1000.0), reach.Fate.NO_RECORD_NEWER)

    def test_a_keeper_without_any_receipt_has_its_own_no_record_fate(self):
        self.store.keeper('empty')
        self.assertEqual(self.fate('rid-lost', state=reach.load_state(str(self.store.memory), 'empty')), reach.Fate.NO_RECEIPTS)


class ReportTests(unittest.TestCase):
    """Keeper "a" has the store of keeper_a(); "empty" has files but no receipt; "ghost" has no files at all."""

    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.close)
        keeper_a(self.store)
        self.store.keeper('empty')
        self.store.trace('a', [
            started(1, 'c1'), finished(905.0, queued_text('rid-added'), 'c1'),
            finished(1505.0, queued_text('rid-resident'), 'c2'),
            finished(1900.0, queued_text('rid-none'), 'c3'),
            finished(2100.0, queued_text('rid-wait'), 'c4'),
            finished(500.0, queued_text('rid-lost-old'), 'c5'),
            finished(4000.0, queued_text('rid-lost-new'), 'c6'),
            finished(4100.0, receipt_text(outcome='persisted_current_snapshot'), 'c7'),
            finished(4200.0, rejected_text('supersedes_invalid'), 'c8'),
            finished(4300.0, 'tool failed', 'c9', error=True),
        ])
        self.store.trace('empty', [finished(4400.0, queued_text('rid-x'), 'c1')])
        self.store.trace('ghost', [finished(4500.0, queued_text('rid-g'), 'c1')])
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
        self.assertEqual(calls[0], 'write calls: 11 in 3 Keepers')
        kinds = [self.count(calls, kind.value + ':') for kind in reach.Kind]
        # Nine receipts that say ok (eight queued and one written directly), one rejection, one tool error.
        self.assertEqual((kinds, sum(kinds)), ([9, 1, 1, 0, 0], 11))
        self.assertEqual(self.line(calls, 'persisted_pending_admission:'), 'persisted_pending_admission: 8')
        self.assertEqual(self.line(calls, 'persisted_current_snapshot:'), 'persisted_current_snapshot: 1')
        self.assertEqual(self.line(calls, 'supersedes_invalid:'), 'supersedes_invalid: 1')
        self.assertEqual(self.line(calls, 'started calls without a finished record:'), 'started calls without a finished record: 0; finished records seen twice: 0')

    def test_the_queued_table_gives_every_queued_write_one_fate(self):
        queued = self.block('queued writes')
        self.assertEqual(queued[0], 'queued writes (persisted_pending_admission): 8')
        counts = {fate: self.count(queued, fate.value + ':') for fate in reach.Fate}
        self.assertEqual(
            counts,
            {
                reach.Fate.ADDED: 1, reach.Fate.EXISTING: 1, reach.Fate.UNDATED: 0, reach.Fate.WITHOUT_TARGET: 1, reach.Fate.WAITING: 1,
                reach.Fate.NO_RECORD_OLDER: 1, reach.Fate.NO_RECORD_NEWER: 1, reach.Fate.NO_RECEIPTS: 2,
            },
        )
        self.assertEqual(sum(counts.values()), 8)

    def test_the_settled_table_counts_classes_standing_and_time(self):
        settled = self.block('candidates the Librarian settled')
        # Dated candidates: two targets the commit added (rid-added, rid-own), five that were already there
        # (rid-resident, rid-revised, rid-retracted, rid-absorbed, rid-gone) and rid-none, which has no target.
        self.assertIn('commit at or after --since: 8 in 3 Keepers', settled[0])
        self.assertEqual(self.line(settled, 'settled with a target the commit added:'), 'settled with a target the commit added: 2 (25.0%)')
        self.assertEqual(self.line(settled, 'settled with a target that already existed:'), 'settled with a target that already existed: 5 (62.5%)')
        self.assertEqual(self.line(settled, 'settled without a target:'), 'settled without a target: 1 (12.5%)')
        self.assertEqual(
            self.line(settled, 'not counted:'),
            'not counted: 1 settled with a target whose commit row is not in the journal, 2 receipts that are not a committed candidate',
        )
        self.assertEqual(self.line(settled, 'settled with a target:'), 'settled with a target: 7')
        self.assertEqual(self.line(settled, "the target has the memory id of the Keeper's own sentence:"), "the target has the memory id of the Keeper's own sentence: 1 (14.3%)")
        # The seven targets stand as: ADDED, OWN and RESIDENT current; REVISED, RETRACTED, ABSORBED and GONE once each.
        self.assertEqual(self.line(settled, 'target now, a current fact:'), 'target now, a current fact: 3 (42.9%)')
        for standing in (reach.Standing.REVISED, reach.Standing.RETRACTED, reach.Standing.ABSORBED, reach.Standing.GONE):
            self.assertEqual(self.count(settled, f'target now, {standing.value}:'), 1, standing)
        self.assertEqual(self.line(settled, 'settled and the target is a current fact now:'), 'settled and the target is a current fact now: 3 of 8 (37.5%)')
        # first_seen to the commit: 100 (added), 500 (own), 500, 400, 300, 200 and 100 for the five targets that were already there.
        self.assertEqual(
            self.line(settled, 'seconds from the write to the commit'),
            'seconds from the write to the commit (7 receipts with a source fact): p50 300, p90 500, max 500',
        )

    def test_the_keeper_table_names_the_files_a_keeper_lacks(self):
        table = self.block('Keeper |')
        self.assertIn('a | 9 | 1 | 6 | 2 | 1 | 1 | 2 | -', table)
        self.assertIn('empty | 1 | 0 | 1 | 0 | 0 | 0 | 1 | -', table)
        self.assertIn(
            'ghost | 1 | 0 | 1 | 0 | 0 | 0 | 1 | missing ghost.librarian-range-commit.json; missing ghost.memory-admission.json; missing ghost.memory-current.json',
            table,
        )

    def test_since_drops_older_calls_and_older_commits(self):
        # Every timestamp in the store is a few thousand seconds after the epoch; "ghost" has only calls, so it drops out with them.
        _, out, _ = self.store.run('--since', '1970-01-02')
        self.assertIn('write calls: 0 in 0 Keepers', out)
        self.assertIn('commit at or after --since: 0 in 2 Keepers', out)

    def test_exclude_skips_the_keeper_in_the_call_table_and_the_settled_table(self):
        _, out, _ = self.store.run('--exclude', 'a')
        self.assertIn('write calls: 2 in 2 Keepers', out)
        self.assertIn('commit at or after --since: 0 in 2 Keepers', out)

    def test_only_reads_one_keeper(self):
        _, out, _ = self.store.run('--only', 'a')
        self.assertIn('write calls: 9 in 1 Keepers', out)
        self.assertIn('commit at or after --since: 8 in 1 Keepers', out)

    def test_a_missing_directory_is_an_error_not_an_empty_report(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = reach.main([str(self.store.keepers / 'nope'), '--memory-dir', str(self.store.memory)])
        self.assertEqual((code, out.getvalue()), (2, ''))
        self.assertIn('not a directory', err.getvalue())


if __name__ == '__main__':
    unittest.main()
