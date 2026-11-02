"""Credential echo checks for the synthetic Goal confirmation receipt."""
import importlib.util
import json
from pathlib import Path
import threading
import traceback
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-goal-confirmation-runtime.py'
spec = importlib.util.spec_from_file_location('goal_confirmation_runtime_fixture', SCRIPT)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ReceiptCredentialTest(unittest.TestCase):
    def test_escaped_echo_in_any_sse_frame_is_detected(self):
        token = 'ab12cd34'
        raw = 'data: {"id":1,"result":"ok"}\n\ndata: {"detail":"ab\\u0031\\u0032cd34"}\n\n'
        self.assertTrue(fixture.contains_encoded_credential(raw, token))
        self.assertTrue(fixture.contains_encoded_credential(r'ab\\u0031\\u0032cd34', token))
        self.assertFalse(fixture.contains_encoded_credential('data: {"id":1,"result":"ok"}', token))

    def test_nested_values_and_keys_are_checked_after_decoding(self):
        token = 'ab12cd34'
        self.assertTrue(fixture.contains_credential({'content': [{'text': r'{"value":"ab\\u0031\\u0032cd34"}'}]}, token))
        self.assertTrue(fixture.contains_credential({token: 'value'}, token))
        self.assertFalse(fixture.contains_credential({'content': ['other']}, token))

    def test_sse_with_split_credential_is_not_saved(self):
        token = 'ab12cd34'
        frames = [
            {'id': 1, 'result': {'delta': 'prefix ab12'}},
            {'id': 2, 'metadata': 'unrelated', 'result': {'delta': 'cd34 suffix'}},
        ]
        raw = ''.join('data: ' + json.dumps(frame) + '\n\n' for frame in frames)
        self.assertFalse(fixture.contains_encoded_credential(raw, token))
        self.assertEqual(fixture.decode_response_payload(raw, token), frames[0])
        evidence = fixture.http_evidence('/mcp', {'method': 'initialize'}, True, 200, raw, 'text/event-stream')
        saved = json.dumps(evidence)
        self.assertNotIn('raw', evidence)
        self.assertEqual(evidence['response_body']['state'], 'not_retained')
        self.assertNotIn('prefix ab12', saved)
        self.assertNotIn('cd34 suffix', saved)

    def test_nested_split_escape_is_not_saved(self):
        token = 'ab12cd34'
        streams = [r'ab\u005cu0031\u0032cd34',
                   r'ab\u005c\u0075\u0030\u0030\u0033\u0031\u0032cd34']
        for stream in streams:
            for boundary in range(1, len(stream)):
                with self.subTest(stream=stream, boundary=boundary):
                    frames = [{'id': 1, 'delta': stream[:boundary]},
                              {'id': 2, 'delta': stream[boundary:]}]
                    raw = ''.join('data: ' + json.dumps(frame) + '\n\n' for frame in frames)
                    evidence = fixture.http_evidence('/mcp', None, True, 200, raw, 'text/event-stream')
                    self.assertNotIn('raw', evidence)
                    self.assertEqual(evidence['response_body']['state'], 'not_retained')
                    self.assertNotIn(token, json.dumps(evidence))

    def test_event_stream_is_omitted_by_header_or_body_shape(self):
        raw = 'data: {"id":1,"result":"ok"}\n\n'
        for content_type in ('', 'text/event-stream; charset=utf-8'):
            with self.subTest(content_type=content_type):
                evidence = fixture.http_evidence('/mcp', None, True, 200, raw, content_type)
                self.assertNotIn('raw', evidence)
        header_only = fixture.http_evidence('/mcp', None, True, 200, '{"id":1}', 'text/event-stream')
        self.assertNotIn('raw', header_only)
        no_space = fixture.http_evidence('/mcp', None, True, 200, 'data:{"id":1}\n\n', '')
        self.assertNotIn('raw', no_space)

    def test_json_response_evidence_retains_raw_body(self):
        raw = '{"id":1,"result":"ok"}'
        evidence = fixture.http_evidence('/mcp', None, True, 200, raw, 'application/json')
        self.assertEqual(evidence['raw'], raw)

    def test_raw_token_match_is_checked_before_unicode_normalization(self):
        self.assertTrue(fixture.contains_encoded_credential(r'\u0031abc', '0031abc'))


class ProviderFailureTest(unittest.TestCase):
    def test_provider_failure_during_read_prevents_a_false_success(self):
        failure = fixture.ProviderFailure()
        read_started = threading.Event()
        provider_finished = threading.Event()
        outcomes = []
        token = 'secret-verifier-token'

        def provider_operation():
            raise fixture.CredentialEchoWithheld(f'private value: {token}')

        def provider_thread():
            if read_started.wait(2):
                outcomes.append(fixture.run_provider_handler(failure, provider_operation))
            provider_finished.set()

        thread = threading.Thread(target=provider_thread)
        thread.start()
        try:
            def read():
                read_started.set()
                self.assertTrue(provider_finished.wait(2))
                return {'goal': {'phase': 'awaiting_confirmation'}}

            with self.assertRaisesRegex(RuntimeError, '^Credential echo withheld$') as raised:
                fixture.wait_for_confirmation(read, failure, lambda _: self.fail('unexpected read error'))
        finally:
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcomes, [False])
        self.assertNotIn(token, str(raised.exception))

    def test_provider_failure_wakes_wait_and_does_not_reveal_exception_details(self):
        failure = fixture.ProviderFailure()
        waiting = threading.Event()
        finished = threading.Event()
        observed = []
        token = 'secret-verifier-token'

        def observe():
            waiting.set()
            try:
                failure.wait(2)
            except RuntimeError as error:
                observed.append(str(error))
            finally:
                finished.set()

        thread = threading.Thread(target=observe)
        thread.start()
        try:
            self.assertTrue(waiting.wait(2))

            def provider_operation():
                raise RuntimeError(f'sensitive provider diagnostic: {token}')

            self.assertFalse(fixture.run_provider_handler(failure, provider_operation))
            self.assertTrue(finished.wait(1))
        finally:
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(observed, ['Synthetic verifier provider handler failed; details withheld'])
        self.assertNotIn(token, observed[0])

    def test_successful_observation_is_preserved(self):
        failure = fixture.ProviderFailure()
        expected = {'goal': {'phase': 'awaiting_confirmation'}}
        self.assertEqual(fixture.wait_for_confirmation(lambda: expected, failure,
                                                       lambda _: self.fail('unexpected read error')), expected)
        self.assertTrue(fixture.run_provider_handler(failure, lambda: None))

    def test_provider_failure_takes_precedence_over_a_read_error_without_exposing_it(self):
        failure = fixture.ProviderFailure()
        token = 'secret-verifier-token'
        observed = []

        def read():
            failure.record(RuntimeError(f'provider detail {token}'))
            raise fixture.URLError(f'read detail {token}')

        with self.assertRaises(RuntimeError) as raised:
            fixture.wait_for_confirmation(read, failure, observed.append)
        self.assertEqual(observed, [])
        self.assertNotIn(token, ''.join(traceback.format_exception(raised.exception)))

    def test_transient_read_error_still_retries_without_provider_failure(self):
        failure = fixture.ProviderFailure()
        expected = {'goal': {'phase': 'awaiting_confirmation'}}
        attempts = iter([fixture.URLError('temporarily offline'), expected])
        observed = []

        def read():
            result = next(attempts)
            if isinstance(result, Exception):
                raise result
            return result

        self.assertEqual(fixture.wait_for_confirmation(read, failure, observed.append, interval=0), expected)
        self.assertEqual(len(observed), 1)
        self.assertIsInstance(observed[0], fixture.URLError)


if __name__ == '__main__':
    unittest.main()
