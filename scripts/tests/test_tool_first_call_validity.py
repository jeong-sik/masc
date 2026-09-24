import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'first_call_validity',
    Path(__file__).parents[1] / 'harness' / 'tool_calls' / 'first_call_validity.py',
)
assert spec is not None and spec.loader is not None
fcv = importlib.util.module_from_spec(spec)
sys.modules['first_call_validity'] = fcv
spec.loader.exec_module(fcv)

RUNTIME = {
    'providers': {
        'zai': {'protocol': 'openai-compatible-http', 'endpoint': 'https://example.test/v4/',
                'credentials': {'type': 'env', 'key': 'ZAI_KEY'}},
        'cli': {'protocol': 'claude-code', 'command': 'claude'},
        'filed': {'protocol': 'openai-compatible-http', 'endpoint': 'https://example.test',
                  'credentials': {'type': 'file', 'path': '/tmp/token'}},
    },
    'models': {'glm-flash': {'api-name': 'glm-5.3-flash', 'temperature': 1}, 'uncapped': {'api-name': 'u'}},
    'zai': {'glm-flash': {'max-concurrent': 3}, 'uncapped': {'max-tokens': 2048}},
    'cli': {'glm-flash': {'max-concurrent': 1}},
    'filed': {'glm-flash': {'max-concurrent': 1}},
}

ASK_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['questions'],
    'properties': {
        'context': {'type': 'string'},
        'questions': {
            'type': 'array',
            'items': {
                'type': 'object',
                'additionalProperties': False,
                'required': ['header', 'prompt', 'mode'],
                'properties': {
                    'header': {'type': 'string'},
                    'prompt': {'type': 'string'},
                    'mode': {'type': 'string', 'enum': ['single', 'multi']},
                    'free_text': {'type': 'boolean'},
                    'choices': {
                        'type': 'array',
                        'items': {
                            'type': 'object',
                            'additionalProperties': False,
                            'required': ['label'],
                            'properties': {'label': {'type': 'string'}},
                        },
                    },
                },
            },
        },
    },
}
ASK = fcv.ToolDefinition('masc_ask', 'Ask the operator.', ASK_SCHEMA)


def question(**fields):
    base = {'header': 'Which PR', 'prompt': 'Which one stays?', 'mode': 'single',
            'choices': [{'label': 'A'}, {'label': 'B'}]}
    base.update(fields)
    return base


class LaneTest(unittest.TestCase):
    def test_lane_reads_endpoint_model_key_and_concurrency_from_runtime(self):
        lane = fcv.resolve_lane(RUNTIME, 'zai.glm-flash')
        self.assertEqual(lane.endpoint, 'https://example.test/v4')
        self.assertEqual(lane.api_model, 'glm-5.3-flash')
        self.assertEqual(lane.credential_env, 'ZAI_KEY')
        self.assertEqual(lane.max_concurrent, 3)
        self.assertEqual(lane.temperature, 1.0)
        self.assertIsNone(lane.max_tokens)

    def test_a_lane_without_max_concurrent_runs_one_at_a_time_and_sends_its_max_tokens(self):
        lane = fcv.resolve_lane(RUNTIME, 'zai.uncapped')
        self.assertEqual(lane.max_concurrent, fcv.DEFAULT_LANE_CONCURRENCY)
        self.assertEqual(lane.max_tokens, 2048)

    def test_lanes_this_harness_cannot_call_are_refused_by_name(self):
        for name, fragment in [('cli.glm-flash', 'not callable'), ('filed.glm-flash', 'only env credentials'),
                               ('zai.missing', 'no [zai.missing] lane'), ('nodot', 'is not <provider>.<model>')]:
            with self.subTest(name=name), self.assertRaisesRegex(fcv.HarnessError, fragment.replace('[', r'\[').replace(']', r'\]')):
                fcv.resolve_lane(RUNTIME, name)


class SchemaTest(unittest.TestCase):
    def test_every_error_is_reported_not_only_the_first(self):
        errors = fcv.schema_errors(ASK_SCHEMA, {'questions': [{'mode': 'both', 'extra': 1}], 'stray': True})
        self.assertIn('$.stray: not in the schema', errors)
        self.assertIn('$.questions[0].header: missing', errors)
        self.assertIn('$.questions[0].prompt: missing', errors)
        self.assertIn('$.questions[0].extra: not in the schema', errors)
        self.assertTrue(any(e.startswith("$.questions[0].mode: 'both' is not one of") for e in errors))

    def test_a_string_where_an_object_belongs_is_one_type_error(self):
        self.assertEqual(fcv.schema_errors(ASK_SCHEMA, {'questions': ['Which PR stays?']}),
                         ['$.questions[0]: expected object, got str'])

    def test_booleans_are_not_integers(self):
        self.assertEqual(fcv.schema_errors({'type': 'integer'}, True), ['$: expected integer, got bool'])

    def test_a_type_outside_the_subset_is_the_harness_error(self):
        with self.assertRaises(fcv.HarnessError):
            fcv.schema_errors({'type': 'null'}, None)

    def test_a_keyword_the_judge_does_not_check_stops_the_run(self):
        for schema in [{'anyOf': [{'type': 'string'}]}, {'type': ['string', 'null']},
                       {'type': 'object', 'additionalProperties': {'type': 'string'}}]:
            with self.subTest(schema=schema), self.assertRaises(fcv.HarnessError):
                fcv.schema_errors(schema, 'x')

    def test_bounds_are_checked(self):
        self.assertEqual(fcv.schema_errors({'type': 'integer', 'minimum': 1, 'maximum': 3}, 4), ['$: 4 is above 3'])
        self.assertEqual(fcv.schema_errors({'type': 'string', 'minLength': 2}, 'a'), ['$: length 1 is below 2'])
        self.assertEqual(fcv.schema_errors({'type': 'array', 'maxItems': 1}, [1, 2]), ['$: length 2 is above 1'])
        self.assertEqual(fcv.schema_errors({'type': 'string', 'description': 'd', 'maxLength': 5}, 'abc'), [])


class AskRuleTest(unittest.TestCase):
    def test_a_question_without_choices_needs_free_text(self):
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(choices=[])]}),
                         ['questions[0]: neither choices nor free_text'])
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(choices=[], free_text=True)]}), [])

    def test_ids_are_left_to_the_schema(self):
        args = {'questions': [question(question_id='x'), question(question_id='x'), question()]}
        self.assertEqual(fcv.masc_ask_rule_errors(args), [])

    def test_blank_means_what_ocaml_trim_removes(self):
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(header=' \t')]}),
                         ['questions[0].header: blank'])
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(header='\u3000')]}), [])


class JudgeTest(unittest.TestCase):
    def call(self, arguments, parsed=True, name='masc_ask'):
        return fcv.FirstCall(name, arguments, parsed)

    def test_outcomes(self):
        self.assertEqual(fcv.judge(ASK, None).outcome, 'no_call')
        self.assertEqual(fcv.judge(ASK, self.call('{"questions": [', parsed=False)).outcome, 'unparseable')
        self.assertEqual(fcv.judge(ASK, self.call(None, parsed=False)).outcome, 'unparseable')
        self.assertEqual(fcv.judge(ASK, self.call({'questions': [question()]})), fcv.Verdict('valid', ()))
        self.assertEqual(fcv.judge(ASK, self.call({'questions': [question(choices=[])]})).outcome, 'invalid')

    def test_a_call_to_another_name_is_invalid(self):
        verdict = fcv.judge(ASK, self.call({'questions': [question()]}, name='masc_ask_status'))
        self.assertEqual(verdict.outcome, 'invalid')

    def test_tools_without_rules_are_judged_by_schema_alone(self):
        other = fcv.ToolDefinition('masc_other', 'x', {'type': 'object', 'properties': {}})
        self.assertEqual(fcv.judge(other, self.call({}, name='masc_other')).outcome, 'valid')


class SummaryTest(unittest.TestCase):
    def test_transport_errors_and_provider_rejections_stay_out_of_the_rate(self):
        rows = [{'variant': 'A', 'lane': 'zai.glm-flash', 'outcome': o}
                for o in ['valid', 'valid', 'invalid', 'transport_error', 'provider_rejected']]
        [line] = fcv.summarize(rows)
        self.assertIn('2/3', line)
        self.assertIn('66.7%', line)

    def test_runs_with_a_prior_call_are_summarized_apart(self):
        rows = [{'variant': 'A', 'lane': 'l', 'outcome': 'valid', 'prior_call': False},
                {'variant': 'A', 'lane': 'l', 'outcome': 'invalid', 'prior_call': True}]
        lines = fcv.summarize(rows)
        self.assertEqual(len(lines), 2)
        self.assertTrue(any(line.startswith('A+prior') for line in lines))


class TrialTest(unittest.TestCase):
    LANE = fcv.Lane('zai.glm-flash', 'https://example.test', 'm', 'KEY', 1, None, None)
    SCENARIO = fcv.Scenario('s', 'ask')

    def run_with(self, failure):
        calls = []
        def fake(*_args):
            calls.append(1)
            raise failure
        original, sleep = fcv.first_tool_call, fcv.time.sleep
        fcv.first_tool_call, fcv.time.sleep = fake, (lambda _s: None)
        try:
            return fcv.trial(self.LANE, ASK, self.SCENARIO, None, 0), len(calls)
        finally:
            fcv.first_tool_call, fcv.time.sleep = original, sleep

    def test_a_malformed_response_is_retried_then_recorded_not_raised(self):
        row, attempts = self.run_with(IndexError('list index out of range'))
        self.assertEqual(row['outcome'], 'transport_error')
        self.assertEqual(attempts, fcv.MAX_ATTEMPTS)

    def test_a_400_is_a_provider_rejection_and_is_not_resampled(self):
        error = fcv.urllib.error.HTTPError('u', 400, 'bad', {}, None)
        error.read = lambda *_: b'error parsing tool call'
        row, attempts = self.run_with(error)
        self.assertEqual((row['outcome'], attempts), ('provider_rejected', 1))


class WireCaptureTest(unittest.TestCase):
    def test_the_newest_capture_that_carried_the_tool_wins(self):
        with tempfile.TemporaryDirectory() as root:
            masc = Path(root)
            day = masc / 'wire-capture' / '2026-09'
            day.mkdir(parents=True)
            def blob(tools):
                raw = json.dumps(tools)
                digest = f'{abs(hash(raw)):064x}'[-64:]
                path = masc / 'tool_blobs' / digest[:2] / digest
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(raw)
                return digest
            old = blob([{'name': 'masc_ask', 'description': 'old', 'input_schema': {'type': 'object'}}])
            new = blob([{'name': 'masc_ask', 'description': 'new', 'input_schema': {'type': 'object'}}])
            other = blob([{'name': 'Execute', 'description': 'x', 'input_schema': {'type': 'object'}}])
            lines = [json.dumps({'ts': t, 'kind': 'request', 'tools_ref': {'_blob': {'sha256': d}}})
                     for t, d in [('1', old), ('2', new), ('3', other)]]
            (day / '24.jsonl').write_text('\n'.join(lines) + '\n')
            self.assertEqual(fcv.tool_from_wire_capture(masc, 'masc_ask').description, 'new')
            with self.assertRaises(fcv.HarnessError):
                fcv.tool_from_wire_capture(masc, 'masc_missing')


if __name__ == '__main__':
    unittest.main()
