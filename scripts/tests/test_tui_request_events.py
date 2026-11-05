"""Server-sent event naming in the TUI request relay (HTML, "Parsing an event stream")."""
import importlib
import json
from pathlib import Path
import sys
import unittest

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
sys.path[:0] = [str(PERF)]
events = importlib.import_module('tui_request_events')

DEEPER_THAN_THE_STACK = 10**6


class EventTest(unittest.TestCase):
    PAYLOAD = (b'event: snapshot\ndata: {"type":"ignored"}\n\n'
               b': keep-alive\r\n\r\n'
               b'id: 7\n\n'
               b'event: message\ndata: {"type":"changed"}\n\n'
               b'data: not json\n\n')
    NAMES = ['snapshot', events.COMMENT_EVENT, events.NO_DATA_EVENT, 'changed', events.MESSAGE_EVENT]
    MIXED = b'data: {"type":"a"}\n\r\nevent: b\rdata: 1\r\r: c\r\n\n'

    def split(self, pieces):
        heard = []
        parser = events.EventParser(lambda name, size: heard.append((name, size)))
        for piece in pieces:
            parser.feed(piece)
        return heard

    def names(self, pieces):
        return [name for name, _ in self.split(pieces)]

    def test_names_follow_the_event_field_then_json_data(self):
        self.assertEqual(self.names([self.PAYLOAD]), self.NAMES)

    def test_arrival_in_single_bytes_cuts_the_same_events(self):
        for payload in (self.PAYLOAD, self.MIXED):
            whole = self.split([payload])
            self.assertEqual(self.split([bytes([byte]) for byte in payload]), whole)
            self.assertEqual(sum(size for _, size in whole), len(payload))

    def test_crlf_lf_and_cr_each_end_a_line(self):
        self.assertEqual(self.names([self.MIXED]), ['a', 'b', events.COMMENT_EVENT])

    def test_blank_lines_alone_end_no_block_and_an_unfinished_block_is_not_counted(self):
        self.assertEqual(self.split([b'\n\n\r\n', b'data: 1\n\n', b'data: cut']),
                         [(events.MESSAGE_EVENT, len(b'\n\n\r\ndata: 1\n\n'))])

    def test_a_leading_bom_is_dropped_even_when_cut(self):
        self.assertEqual(self.names([b'\xef\xbb', b'\xbfevent: x\ndata: 1\n\n']), ['x'])

    def test_data_nested_deeper_than_the_stack_names_no_json_event(self):
        deep = b'[' * DEEPER_THAN_THE_STACK
        with self.assertRaises(RecursionError):
            json.loads(deep)
        self.assertEqual(self.names([b'data: ' + deep + b'\n\n']), [events.MESSAGE_EVENT])


if __name__ == '__main__':
    unittest.main()
