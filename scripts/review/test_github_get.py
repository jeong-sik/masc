"""HTTP quota recovery at a fake subprocess/clock boundary; no GitHub calls."""
from email.utils import formatdate
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest


SPEC = importlib.util.spec_from_file_location('github_get', Path(__file__).with_name('github-get.py'))
GET = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GET)


def response(status, data, headers=None):
    lines = [f'HTTP/2.0 {status} response', 'Content-Type: application/json']
    lines.extend(f'{key}: {value}' for key, value in (headers or {}).items())
    return subprocess.CompletedProcess([], int(status >= 400),
                                       '\r\n'.join(lines) + '\r\n\r\n' + json.dumps(data), '')


class Clock:
    def __init__(self):
        self.now, self.sleeps = 1000.0, []

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class GitHubGet(unittest.TestCase):
    def test_primary_and_secondary_quota_wait_for_the_server_time(self):
        for status, headers, deadline in [
                (403, {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1030'}, 1030),
                (429, {'Retry-After': '12'}, 1012),
                (403, {'Retry-After': formatdate(1020, usegmt=True)}, 1020),
                (429, {'Retry-After': '12', 'X-RateLimit-Remaining': '0',
                       'X-RateLimit-Reset': '1030'}, 1030)]:
            with self.subTest(headers=headers):
                clock, calls, failures = Clock(), [], []
                def run(command, **kwargs):
                    calls.append((clock.now, command))
                    return (response(status, {'message': 'limited'}, headers) if len(calls) == 1
                            else response(200, {'ok': True}))
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep,
                                    on_quota=failures.append)
                self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
                self.assertEqual([t for t, _ in calls], [1000, deadline])
                self.assertEqual(client.pauses, 1)
                self.assertIsInstance(failures[0], GET.QuotaLimited)
                self.assertEqual(failures[0].status, status)
                self.assertTrue(failures[0].details['headers'])
                self.assertTrue(all(c[2:4] == ['--method', 'GET'] for _, c in calls))

    def test_auth_missing_resource_server_error_and_unusable_quota_stay_failures(self):
        cases = [(403, {}), (404, {}), (500, {'Retry-After': '10'}), (429, {}),
                 (403, {'X-RateLimit-Remaining': '0'}),
                 (403, {'X-RateLimit-Remaining': '9', 'X-RateLimit-Reset': '1030'}),
                 (429, {'Retry-After': 'invalid'}), (429, {'Retry-After': '0'})]
        for status, headers in cases:
            with self.subTest(status=status, headers=headers):
                clock, calls = Clock(), []
                def run(command, **kwargs):
                    calls.append(command)
                    return response(status, {'message': 'refused'}, headers)
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
                with self.assertRaises(GET.ApiFailure) as raised:
                    client.read('repos/o/r/pulls/1')
                self.assertNotIsInstance(raised.exception, GET.QuotaLimited)
                self.assertEqual(raised.exception.status, status)
                self.assertEqual((len(calls), clock.sleeps, client.pauses), (1, [], 0))

    def test_headerless_and_malformed_responses_are_visible_failures(self):
        for raw in ('{"message":"limited"}', 'HTTP/2.0 403\nBad header\n\n{}'):
            with self.subTest(raw=raw):
                client = GET.Client(run=lambda *a, **k: subprocess.CompletedProcess([], 1, raw, ''))
                with self.assertRaises(GET.ApiFailure) as raised:
                    client.read('repos/o/r/pulls/1')
                self.assertIsNone(raised.exception.status)
                self.assertEqual(client.pauses, 0)

    def test_a_short_sleep_does_not_issue_a_request_before_the_deadline(self):
        clock, calls = Clock(), []
        def sleep(seconds):
            clock.sleeps.append(seconds)
            clock.now += seconds / 2 if len(clock.sleeps) == 1 else seconds
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(429, {}, {'Retry-After': '10'}) if len(calls) == 1
                    else response(200, []))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=sleep)
        self.assertEqual(client.read('repos/o/r/pulls'), [])
        self.assertEqual(calls, [1000, 1010])
        self.assertEqual(clock.sleeps, [10, 5])

    def test_review_pagination_reads_every_page_without_replaying_a_write(self):
        calls = []
        def run(command, **kwargs):
            calls.append(command[-1])
            return (response(200, [{'id': 1}], {'Link':
                    '<https://api.github.com/repos/o/r/pulls/1/reviews?page=2>; rel="next"'})
                    if len(calls) == 1 else response(200, [{'id': 2}]))
        client = GET.Client(run=run)
        self.assertEqual(client.pages('repos/o/r/pulls/1/reviews?page=1'), [{'id': 1}, {'id': 2}])
        self.assertEqual(calls, ['repos/o/r/pulls/1/reviews?page=1',
                                 'repos/o/r/pulls/1/reviews?page=2'])

    def test_an_endpoint_cannot_override_the_get_method(self):
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            return response(404, {'message': 'invalid endpoint'})
        with self.assertRaises(GET.ApiFailure):
            GET.Client(run=run).read('--method=POST')
        self.assertEqual(calls, [['gh', 'api', '--method', 'GET', '--include', '--', '--method=POST']])

    def test_separate_link_headers_preserve_the_next_page_and_its_change_request(self):
        calls = []
        first = ('HTTP/2.0 200 OK\n'
                 'Link: <https://api.github.com/repos/o/r/reviews?page=2>; rel="next"\n'
                 'Link: <https://api.github.com/repos/o/r/reviews?page=2>; rel="last"\n\n'
                 '[{"state":"APPROVED"}]')
        def run(command, **kwargs):
            calls.append(command[-1])
            return (subprocess.CompletedProcess([], 0, first, '') if len(calls) == 1
                    else response(200, [{'state': 'CHANGES_REQUESTED'}]))
        rows = GET.Client(run=run).pages('repos/o/r/reviews?page=1')
        self.assertEqual(rows, [{'state': 'APPROVED'}, {'state': 'CHANGES_REQUESTED'}])
        self.assertEqual(len(calls), 2)

    def test_conflicting_quota_headers_cannot_select_an_earlier_deadline(self):
        for name, values in [('Retry-After', ('120', '1')),
                             ('X-RateLimit-Remaining', ('0', '9')),
                             ('X-RateLimit-Reset', ('1120', '1001'))]:
            with self.subTest(name=name):
                clock, calls = Clock(), []
                raw = (f'HTTP/2.0 429 Too Many Requests\n{name}: {values[0]}\n'
                       f'{name.lower()}: {values[1]}\n\n{{"message":"limited"}}')
                def run(command, **kwargs):
                    calls.append(command)
                    return subprocess.CompletedProcess([], 1, raw, '')
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
                with self.assertRaises(GET.ApiFailure):
                    client.read('repos/o/r/pulls/1')
                self.assertEqual((len(calls), clock.sleeps), (1, []))

    def test_a_caller_deadline_cuts_a_quota_wait_short_without_an_early_retry(self):
        for deadline, sleeps in ((1010.0, [10.0]), (1000.0, [])):
            with self.subTest(deadline=deadline):
                clock, calls, failures = Clock(), [], []
                def run(command, **kwargs):
                    calls.append(clock.now)
                    return response(429, {'message': 'limited'}, {'Retry-After': '3600'})
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep,
                                    on_quota=failures.append)
                client.deadline = deadline
                with self.assertRaises(GET.QuotaWaitCutShort) as raised:
                    client.read('repos/o/r/pulls/1')
                self.assertIsInstance(raised.exception, GET.QuotaLimited)
                self.assertEqual(raised.exception.retry_at, 4600.0)
                self.assertEqual(calls, [1000.0])
                self.assertEqual(clock.sleeps, sleeps)
                self.assertEqual(client.pauses, 1)
                self.assertEqual(len(failures), 1)

    def test_a_deadline_past_the_server_time_waits_out_the_quota(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(429, {'message': 'limited'}, {'Retry-After': '12'})
                    if len(calls) == 1 else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        client.deadline = 5000.0
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(calls, [1000.0, 1012.0])
        self.assertEqual(clock.sleeps, [12])
        self.assertEqual(client.pauses, 1)


    def test_a_wait_that_ends_on_the_reset_second_retries_the_old_window_briefly(self):
        spent = {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1030'}
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            # The window has not rolled over yet at the reset second itself.
            return (response(403, {'message': 'limited'}, spent) if len(calls) <= 2
                    else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(calls, [1000.0, 1030.0, 1032.0])
        self.assertEqual(clock.sleeps, [30.0, GET.BOUNDARY_PAUSE_SECONDS])
        self.assertEqual((client.pauses, client.boundary_retries), (1, 1))

    def test_the_boundary_retry_is_bounded_and_then_a_visible_failure(self):
        spent = {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1030'}
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return response(403, {'message': 'limited'}, spent)
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        self.assertNotIsInstance(raised.exception, GET.QuotaLimited)
        # Its own type and state, so it is told apart from any other refusal.
        self.assertIsInstance(raised.exception, GET.QuotaBoundaryExhausted)
        self.assertEqual(raised.exception.status, 403)
        self.assertEqual(raised.exception.details['quota_state'], 'boundary_retries_exhausted')
        self.assertEqual(raised.exception.details['boundary_retries'], GET.BOUNDARY_RETRIES)
        self.assertIn('retries exhausted', str(raised.exception))
        # First request, the post-wait request, then the bounded retries.
        self.assertEqual(len(calls), 2 + GET.BOUNDARY_RETRIES)
        self.assertEqual(client.boundary_retries, GET.BOUNDARY_RETRIES)

    def test_other_refusals_do_not_carry_the_boundary_state(self):
        clock = Clock()
        client = GET.Client(run=lambda *a, **k: response(403, {'message': 'forbidden'}),
                            clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        self.assertNotIsInstance(raised.exception, GET.QuotaBoundaryExhausted)
        self.assertNotIn('quota_state', raised.exception.details)

    def test_an_elapsed_reset_without_a_prior_wait_stays_a_visible_failure(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return response(403, {'message': 'limited'},
                            {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '900'})
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure):
            client.read('repos/o/r/pulls/1')
        self.assertEqual((len(calls), clock.sleeps, client.boundary_retries), (1, [], 0))

    def test_a_refusal_after_a_wait_is_not_retried_when_quota_is_not_spent(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(429, {'message': 'limited'}, {'Retry-After': '10'})
                    if len(calls) == 1 else
                    response(403, {'message': 'forbidden'},
                             {'X-RateLimit-Remaining': '9', 'X-RateLimit-Reset': '900'}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        self.assertEqual(raised.exception.status, 403)
        self.assertEqual((len(calls), client.boundary_retries), (2, 0))

    def test_a_transient_503_waits_its_retry_after_and_then_reads(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(503, {'message': 'unavailable'}, {'Retry-After': '3'})
                    if len(calls) == 1 else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(calls, [1000.0, 1003.0])
        self.assertEqual(clock.sleeps, [3])
        self.assertEqual((client.pauses, client.transient_retries), (0, 1))

    def test_each_transient_retry_honors_its_own_retry_after(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            wait = {1: '1', 2: '3'}.get(len(calls))
            return (response(502, {'message': 'bad gateway'}, {'Retry-After': wait})
                    if wait else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(calls, [1000.0, 1001.0, 1004.0])
        self.assertEqual(client.transient_retries, 2)

    def test_a_transient_retry_after_date_waits_out_the_server_time(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(504, {'message': 'timeout'},
                             {'Retry-After': formatdate(1007, usegmt=True)})
                    if len(calls) == 1 else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(calls, [1000.0, 1007.0])

    def test_transient_retries_are_bounded_then_a_visible_failure(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return response(503, {'message': 'unavailable'}, {'Retry-After': '3'})
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        error = raised.exception
        self.assertNotIsInstance(error, GET.QuotaLimited)
        self.assertIsInstance(error, GET.TransientRetryExhausted)
        self.assertIsInstance(error, ValueError)  # the merge worker exits 1 on this
        self.assertEqual(error.status, 503)
        self.assertEqual(error.details['retry_state'], 'transient_retries_exhausted')
        self.assertEqual(error.details['transient_retries'], GET.TRANSIENT_RETRIES)
        self.assertEqual(len(calls), 1 + GET.TRANSIENT_RETRIES)
        self.assertEqual(clock.sleeps, [3] * GET.TRANSIENT_RETRIES)

    def test_a_5xx_without_a_usable_retry_after_stays_a_visible_failure(self):
        for status, headers in [(502, {}), (503, {}), (504, {}),
                                (503, {'Retry-After': 'invalid'}),
                                (500, {'Retry-After': '3'})]:
            with self.subTest(status=status, headers=headers):
                clock, calls = Clock(), []
                def run(command, **kwargs):
                    calls.append(command)
                    return response(status, {'message': 'refused'}, headers)
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
                with self.assertRaises(GET.ApiFailure) as raised:
                    client.read('repos/o/r/pulls/1')
                self.assertNotIsInstance(raised.exception, GET.TransientRetryExhausted)
                self.assertEqual((len(calls), clock.sleeps, client.transient_retries), (1, [], 0))

    def test_a_caller_deadline_cuts_a_transient_wait_without_an_early_retry(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return response(503, {'message': 'unavailable'}, {'Retry-After': '30'})
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        client.deadline = 1005.0
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        self.assertNotIsInstance(raised.exception, GET.TransientRetryExhausted)
        self.assertEqual((calls, clock.sleeps), ([1000.0], [5.0]))

    def test_a_retry_after_beyond_the_cap_is_not_waited_out(self):
        for value in (str(GET.TRANSIENT_MAX_PAUSE_SECONDS + 1), '3600',
                      formatdate(1000 + 3600, usegmt=True)):
            with self.subTest(retry_after=value):
                clock, calls = Clock(), []
                def run(command, **kwargs):
                    calls.append(clock.now)
                    return response(503, {'message': 'unavailable'}, {'Retry-After': value})
                client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
                with self.assertRaises(GET.ApiFailure) as raised:
                    client.read('repos/o/r/pulls/1')
                self.assertNotIsInstance(raised.exception, GET.TransientRetryExhausted)
                self.assertEqual((len(calls), clock.sleeps, client.pauses,
                                  client.transient_retries), (1, [], 0, 0))

    def test_a_retry_after_at_the_cap_is_waited_out(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(503, {'message': 'unavailable'},
                             {'Retry-After': str(GET.TRANSIENT_MAX_PAUSE_SECONDS)})
                    if len(calls) == 1 else response(200, {'ok': True}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        self.assertEqual(client.read('repos/o/r/pulls/1'), {'ok': True})
        self.assertEqual(clock.sleeps, [GET.TRANSIENT_MAX_PAUSE_SECONDS])

    def test_a_later_non_transient_refusal_carries_no_transient_state(self):
        clock, calls = Clock(), []
        def run(command, **kwargs):
            calls.append(clock.now)
            return (response(503, {'message': 'unavailable'}, {'Retry-After': '1'})
                    if len(calls) == 1 else response(404, {'message': 'not found'}))
        client = GET.Client(run=run, clock=lambda: clock.now, sleep=clock.sleep)
        with self.assertRaises(GET.ApiFailure) as raised:
            client.read('repos/o/r/pulls/1')
        self.assertEqual(raised.exception.status, 404)
        self.assertNotIn('retry_state', raised.exception.details)
        self.assertEqual((len(calls), client.transient_retries), (2, 1))


if __name__ == '__main__':
    unittest.main()
