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
    'models': {'glm-flash': {'api-name': 'glm-5.3-flash', 'temperature': 1}},
    'zai': {'glm-flash': {'max-concurrent': 3}},
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


class AskRuleTest(unittest.TestCase):
    def test_a_question_without_choices_needs_free_text(self):
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(choices=[])]}),
                         ['questions[0]: neither choices nor free_text'])
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(choices=[], free_text=True)]}), [])

    def test_omitted_ids_are_numbered_by_position_and_never_collide(self):
        self.assertEqual(fcv.masc_ask_rule_errors({'questions': [question(), question()]}), [])

    def test_supplied_ids_must_be_unique_and_not_blank(self):
        args = {'questions': [question(question_id='x'), question(question_id='x'), question(question_id=' ')]}
        errors = fcv.masc_ask_rule_errors(args)
        self.assertIn('questions: duplicate question_id', errors)
        self.assertIn('questions[2].question_id: blank', errors)

    def test_a_supplied_id_can_collide_with_a_position_number(self):
        args = {'questions': [question(question_id='q2'), question()]}
        self.assertIn('questions: duplicate question_id', fcv.masc_ask_rule_errors(args))


class JudgeTest(unittest.TestCase):
    def test_outcomes(self):
        self.assertEqual(fcv.judge(ASK, None, True).outcome, 'no_call')
        self.assertEqual(fcv.judge(ASK, '{"questions": [', False).outcome, 'unparseable')
        self.assertEqual(fcv.judge(ASK, {'questions': [question()]}, True), fcv.Verdict('valid', ()))
        verdict = fcv.judge(ASK, {'questions': [question(choices=[])]}, True)
        self.assertEqual(verdict.outcome, 'invalid')

    def test_tools_without_rules_are_judged_by_schema_alone(self):
        other = fcv.ToolDefinition('masc_other', 'x', {'type': 'object', 'properties': {}})
        self.assertEqual(fcv.judge(other, {}, True).outcome, 'valid')


class SummaryTest(unittest.TestCase):
    def test_transport_errors_stay_out_of_the_rate(self):
        rows = [{'variant': 'A', 'lane': 'zai.glm-flash', 'outcome': o}
                for o in ['valid', 'valid', 'invalid', 'transport_error', 'transport_error']]
        [line] = fcv.summarize(rows)
        self.assertIn('2/3', line)
        self.assertIn('66.7%', line)


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
