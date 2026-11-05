"""HTTP/1.1 framing the TUI request relay relies on: body lengths, targets and Host."""
import importlib
from pathlib import Path
import sys
import unittest

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
sys.path[:0] = [str(PERF)]
http1 = importlib.import_module('tui_request_http')


class FramingTest(unittest.TestCase):
    def head(self, *fields):
        return http1.Head('', tuple(fields))

    def test_response_body_length_follows_rfc_9112(self):
        plain = self.head(('content-length', '5'))
        self.assertEqual(http1.response_framing(plain, method='HEAD', status=200), http1.Fixed(0))
        self.assertEqual(http1.response_framing(plain, method='GET', status=304), http1.Fixed(0))
        self.assertEqual(http1.response_framing(plain, method='GET', status=200), http1.Fixed(5))
        coded = self.head(('transfer-encoding', 'gzip'), ('content-length', '5'))
        self.assertEqual(http1.response_framing(coded, method='GET', status=200), http1.UntilClose())
        self.assertEqual(http1.response_framing(self.head(), method='GET', status=200),
                         http1.UntilClose())
        conflicting = self.head(('content-length', '5, 6'))
        self.assertIsInstance(http1.response_framing(conflicting, method='GET', status=200),
                              http1.Malformed)

    def test_request_body_length(self):
        self.assertEqual(http1.request_framing(self.head()), http1.Fixed(0))
        self.assertEqual(http1.request_framing(self.head(('transfer-encoding', 'gzip, chunked'))),
                         http1.Chunked())
        self.assertIsInstance(http1.request_framing(self.head(('transfer-encoding', 'gzip'))),
                              http1.Malformed)

    def test_only_upgrade_and_connect_requests_wait_for_their_answer(self):
        def switching(raw):
            return http1.parse_request(raw).switching
        self.assertTrue(switching(b'GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n'))
        self.assertTrue(switching(b'CONNECT host:1 HTTP/1.1\r\n\r\n'))
        self.assertFalse(switching(b'GET / HTTP/1.1\r\n\r\n'))

    def test_forwarded_host_names_the_server_and_nothing_else_changes(self):
        raw = b'GET /a:b HTTP/1.1\r\nHOST: 127.0.0.1:5\r\nX-Host: keep\r\n\r\n'
        self.assertEqual(http1.with_authority(raw, b'127.0.0.1:8935'),
                         b'GET /a:b HTTP/1.1\r\nHOST: 127.0.0.1:8935\r\nX-Host: keep\r\n\r\n')

    def test_targets_keep_the_origin_form_path_and_query_names_only(self):
        self.assertEqual(http1.split_target('/a/b?z=1&y=&z=2&x'), ('/a/b', ('x', 'y', 'z')))
        self.assertEqual(http1.split_target('//api/v1/keepers?x=1'), ('//api/v1/keepers', ('x',)))
        self.assertEqual(http1.split_target('//[?a'), ('//[', ('a',)))
        self.assertEqual(http1.split_target('*'), ('*', ()))
        self.assertEqual(http1.split_target('http://user:secret@host/a?b=1'), (http1.OTHER_FORM, ()))
        self.assertEqual(http1.split_target('host:443'), (http1.OTHER_FORM, ()))


if __name__ == '__main__':
    unittest.main()
