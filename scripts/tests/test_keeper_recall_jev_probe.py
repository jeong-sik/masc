"""Pure logic of the Jev recall probe; no request is sent and no key is read."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'keeper-recall-jev-probe.py'
spec = importlib.util.spec_from_file_location('keeper_recall_jev_probe', SCRIPT)
assert spec is not None and spec.loader is not None
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

CAPACITY = {'detail': {'error_type': 'max_tokens_exceeded'}}
WORDS = {'N': 'needed', 'm': 'maybe_needed', 'n': 'not_needed'}
# The seven candidates whose label changed in the ten identical runs on won-chik
# (docs/evidence/keeper-recall-jev-probe-2026-10-28/won-chik-repeat10.txt).
CHANGED = {
    '7a3943d7fe03': ('n m m m n m n n n n', [0.27, 0.25, 0.19, 0.20, 0.23, 0.16, 0.20, 0.25, 0.27, 0.19]),
    'c5849f1b038e': ('N N m m n m m m m m', [0.04, 0.04, 0.10, 0.09, 0.02, 0.14, 0.10, 0.13, 0.14, 0.12]),
    '96223d39f66d': ('m m m m m m n n m m', [0.06, 0.09, 0.03, 0.09, 0.09, 0.09, 0.16, 0.21, 0.10, 0.07]),
    '15f034b878d2': ('n n n n n n n n m n', [0.14, 0.25, 0.28, 0.34, 0.20, 0.31, 0.27, 0.30, 0.19, 0.18]),
    '3c06d24af014': ('m n m n n n n n n n', [0.09, 0.14, 0.09, 0.16, 0.22, 0.13, 0.13, 0.18, 0.11, 0.10]),
    '8cb86b5f3496': ('n n n n n n n n n m', [0.14, 0.09, 0.06, 0.16, 0.14, 0.18, 0.09, 0.30, 0.16, 0.10]),
    'e8f99f665358': ('m m m m m m m m n m', [0.23, 0.23, 0.28, 0.22, 0.22, 0.31, 0.19, 0.16, 0.16, 0.19]),
}
# The other 49 candidates kept one label in every run: 6 needed, 5 maybe_needed, 38 not_needed.
UNCHANGED = ['needed'] * 6 + ['maybe_needed'] * 5 + ['not_needed'] * 38


def candidate(question_id, claim='a claim'):
    return {'question_id': question_id, 'claim': claim}


def runs_of(rows, count):
    """rows: question id -> (labels per run, confidence per run)."""
    return [
        {question_id: {'choice': labels[index], 'confidence': confidence[index]} for question_id, (labels, confidence) in rows.items()}
        for index in range(count)
    ]


class SplitBySizeTests(unittest.TestCase):
    def test_pieces_keep_order_and_respect_the_limit(self):
        items = [candidate(f'q{index}', 'x' * 100) for index in range(3)]
        weight = len(json.dumps(items[0], ensure_ascii=False).encode('utf-8'))
        pieces = probe.split_by_size(items, 2 * weight)
        self.assertEqual([[c['question_id'] for c in piece] for piece in pieces], [['q0', 'q1'], ['q2']])

    def test_a_candidate_over_the_limit_goes_alone(self):
        items = [candidate('big', 'x' * 500), candidate('small', 'y')]
        pieces = probe.split_by_size(items, 100)
        self.assertEqual([[c['question_id'] for c in piece] for piece in pieces], [['big'], ['small']])

    def test_no_candidates_make_no_pieces(self):
        self.assertEqual(probe.split_by_size([], 1000), [])


class BuildRequestTests(unittest.TestCase):
    def test_rule_sits_in_the_question_and_state_holds_purpose_and_candidates(self):
        items = [candidate('aaa'), candidate('bbb')]
        request = probe.build_request('jev-test', 'turn text', items)
        self.assertEqual(set(request['state']), {'purpose', 'candidates'})
        self.assertEqual(set(request['questions']), {'aaa', 'bbb'})
        question = request['questions']['aaa']
        self.assertIn('aaa', question['instructions'])
        self.assertEqual(question['criteria'], probe.LABEL_MEANINGS)
        self.assertNotIn('not_needed only when', json.dumps(request['state']))


class LoadCandidatesTests(unittest.TestCase):
    def test_candidate_fields_and_id(self):
        snapshot = {'facts': [{'claim': 'the claim', 'category': 'lesson', 'first_seen': 0, 'last_seen': 86400, 'origin': {'kind': 'injected'}}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'alpha.memory-current.json'
            path.write_text(json.dumps(snapshot), encoding='utf-8')
            loaded = probe.load_candidates(str(path))
        self.assertEqual(
            loaded,
            [{
                'question_id': hashlib.sha256('the claim'.encode('utf-8')).hexdigest()[:12],
                'category': 'lesson',
                'claim': 'the claim',
                'first_seen': '1970-01-01',
                'last_seen': '1970-01-02',
                'origin': 'injected',
            }],
        )


class CapacityTests(unittest.TestCase):
    def test_only_a_400_with_the_capacity_error_type_is_a_capacity_refusal(self):
        self.assertTrue(probe.is_capacity(400, CAPACITY))
        self.assertFalse(probe.is_capacity(400, {'detail': {'error_type': 'invalid_request'}}))
        self.assertFalse(probe.is_capacity(400, {}))
        self.assertFalse(probe.is_capacity(429, CAPACITY))
        self.assertFalse(probe.is_capacity(200, CAPACITY))


class JudgeTests(unittest.TestCase):
    def fake_post(self, limit):
        calls = []

        def post(request, timeout):
            self.assertEqual(timeout, 10.0)
            ids = list(request['questions'])
            calls.append(len(ids))
            if len(ids) > limit:
                return 400, CAPACITY, 0.01
            answers = {question_id: {'choice': 'needed', 'confidence': 0.5} for question_id in ids}
            return 200, {'model': 'jev-test', 'usage': {'input_tokens': 10 * len(ids)}, 'answers': answers}, 0.01

        return post, calls

    def test_a_capacity_refusal_halves_the_candidates_front_half_first(self):
        post, calls = self.fake_post(limit=2)
        items = [candidate(f'q{index}') for index in range(5)]
        with patch.object(probe, 'post', post):
            answers = probe.judge('jev-test', 'turn', items, 10.0, [])
        self.assertEqual(calls, [5, 2, 3, 1, 2])
        self.assertEqual(set(answers), {f'q{index}' for index in range(5)})

    def test_a_refused_single_candidate_is_reported_and_the_run_goes_on(self):
        post, calls = self.fake_post(limit=0)
        trace = []
        with patch.object(probe, 'post', post):
            answers = probe.judge('jev-test', 'turn', [candidate('only', 'abc')], 10.0, trace)
        self.assertEqual((answers, calls), ({}, [1]))
        self.assertTrue(any('too large alone: question_id only, claim 3 bytes' in line for line in trace))

    def test_another_refusal_stops_the_run(self):
        for status, body in ((400, {'detail': {'error_type': 'invalid_request'}}), (429, {})):
            with self.subTest(status=status):
                with patch.object(probe, 'post', lambda _request, _timeout: (status, body, 0.01)):
                    with self.assertRaises(probe.Refusal) as caught:
                        probe.judge('jev-test', 'turn', [candidate('q0'), candidate('q1')], 10.0, [])
                self.assertIn(f'HTTP {status}', str(caught.exception))


class SendGuardTests(unittest.TestCase):
    def test_name_must_match_the_file_and_an_excluded_keeper_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            toml = Path(directory) / 'runtime.toml'
            toml.write_text('[typesafeai]\nexcluded_keepers = ["alpha"]\n', encoding='utf-8')
            path = str(Path(directory) / 'alpha.memory-current.json')
            self.assertIn('alpha', probe.refuse_unless_allowed(path, 'beta', ''))
            self.assertIn('excluded_keepers', probe.refuse_unless_allowed(path, 'alpha', str(toml)))
            self.assertIsNone(probe.refuse_unless_allowed(path, 'alpha', ''))
            other = str(Path(directory) / 'beta.memory-current.json')
            self.assertIsNone(probe.refuse_unless_allowed(other, 'beta', str(toml)))


class RepeatReportTests(unittest.TestCase):
    def won_chik_ten_runs(self):
        rows = {question_id: ([WORDS[code] for code in labels.split()], confidence) for question_id, (labels, confidence) in CHANGED.items()}
        for index, label in enumerate(UNCHANGED):
            rows[f'stable{index:02d}'] = ([label] * 10, [0.5] * 10)
        return [candidate(question_id) for question_id in rows], runs_of(rows, 10)

    def test_ten_runs_on_won_chik_reproduce_the_printed_counts(self):
        items, runs = self.won_chik_ten_runs()
        lines = probe.repeat_report(items, runs)
        self.assertEqual(lines[0], "label counts over 10 runs: {'needed': 62, 'maybe_needed': 82, 'not_needed': 416}")
        self.assertIn('of 56 candidates judged in every run, the label changed between runs for 7 (12.5%)', lines)
        self.assertIn(
            'mean reported confidence of the changed candidates 0.16, of the others 0.50',
            lines,
        )
        self.assertIn(
            'unchanged candidates with a mean confidence at or below 0.25, the highest mean among the changed: 0 of 49',
            lines,
        )
        self.assertIn('selected (needed or maybe_needed) in every run: 11, in at least one run: 18', lines)
        self.assertIn('selected sets: 7 distinct over 10 runs, identical in 4 of 45 run pairs (8.9%)', lines)
        self.assertEqual(sum(1 for line in lines if line.startswith('  changed: ')), 7)

    def test_unchanged_candidates_as_unsure_as_the_changed_ones_are_counted(self):
        rows = {
            'flip': (['needed', 'not_needed'], [0.10, 0.20]),
            'low': (['not_needed', 'not_needed'], [0.12, 0.12]),
            'high': (['not_needed', 'not_needed'], [0.90, 0.90]),
        }
        lines = probe.repeat_report([candidate(question_id) for question_id in rows], runs_of(rows, 2))
        self.assertIn(
            'unchanged candidates with a mean confidence at or below 0.15, the highest mean among the changed: 1 of 2',
            lines,
        )

    def test_changed_lines_show_the_probability_of_each_label(self):
        runs = [
            {'flip': {'choice': 'maybe_needed', 'confidence': 0.04, 'probabilities': {'needed': 0.31, 'maybe_needed': 0.37, 'not_needed': 0.32}}},
            {'flip': {'choice': 'not_needed', 'confidence': 0.03, 'probabilities': {'needed': 0.30, 'maybe_needed': 0.34, 'not_needed': 0.36}}},
        ]
        changed = [line for line in probe.repeat_report([candidate('flip')], runs) if line.startswith('  changed: ')]
        self.assertEqual(len(changed), 1)
        self.assertIn("probabilities (needed/maybe_needed/not_needed) ['0.31/0.37/0.32', '0.30/0.34/0.36']", changed[0])
        self.assertEqual(probe.probability_text({}), '-/-/-')

    def test_identical_runs_have_one_selected_set(self):
        rows = {'a': (['needed'] * 3, [0.9] * 3), 'b': (['not_needed'] * 3, [0.5] * 3)}
        lines = probe.repeat_report([candidate('a'), candidate('b')], runs_of(rows, 3))
        self.assertIn('of 2 candidates judged in every run, the label changed between runs for 0 (0.0%)', lines)
        self.assertIn('mean reported confidence of the changed candidates -, of the others 0.70', lines)
        self.assertIn('selected sets: 1 distinct over 3 runs, identical in 3 of 3 run pairs (100.0%)', lines)

    def test_an_answer_outside_the_three_labels_is_reported_and_left_out(self):
        rows = {'a': (['needed', ''], [0.9, 0.9]), 'b': (['not_needed', 'not_needed'], [0.5, 0.5])}
        lines = probe.repeat_report([candidate('a'), candidate('b')], runs_of(rows, 2))
        self.assertIn('1 candidates had an answer outside the three labels in some run and are left out below', lines)
        self.assertIn('selected (needed or maybe_needed) in every run: 0, in at least one run: 0', lines)

    def test_a_candidate_missing_from_a_run_is_not_counted(self):
        rows = {'a': (['needed', 'needed'], [0.9, 0.9]), 'b': (['needed', 'needed'], [0.9, 0.9])}
        runs = runs_of(rows, 2)
        del runs[1]['b']
        lines = probe.repeat_report([candidate('a'), candidate('b')], runs)
        self.assertIn('of 1 candidates judged in every run, the label changed between runs for 0 (0.0%)', lines)


if __name__ == '__main__':
    unittest.main()
