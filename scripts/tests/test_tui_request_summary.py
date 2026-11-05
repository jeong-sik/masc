"""Per-window summaries the TUI request probe builds from the relay's log."""
import importlib
from pathlib import Path
import sys
import unittest

PERF = Path(__file__).resolve().parent.parent / 'harness' / 'perf'
sys.path[:0] = [str(PERF)]
http1 = importlib.import_module('tui_request_http')
record = importlib.import_module('tui_request_log')
summary = importlib.import_module('tui_request_summary')


class SummaryTest(unittest.TestCase):
    def test_requests_and_events_land_in_the_window_they_started_in(self):
        entries = [
            record.Sent(1, 0.5, 'GET', '/stream', ()),
            record.Answered(1, 0.6, 200, True),
            record.Arrived(1, 1.5, 'tick', 8),
            record.Sent(2, 1.2, 'GET', '/json', ('q',)),
            record.Answered(2, 1.3, 200, False),
            record.Ended(2, 1.4, record.Ending.COMPLETE, 40, 120, ''),
            record.Sent(3, 1.8, 'GET', '/json', ('q',)),
            record.Fault(1.9, http1.Side.CLIENT, 'malformed header field line'),
            record.Ended(3, 1.9, record.Ending.MALFORMED, 30, 0, 'client: malformed header field line'),
            record.Failed(1.95, 'RuntimeError: boom'),
            record.Ended(1, 3.0, record.Ending.CLIENT_CLOSED, 30, 999, ''),
        ]
        index = summary.index_entries(entries)
        first = summary.summarize_window(index, summary.Window('startup', '', 0.0, 1.0, True), 0.0)
        second = summary.summarize_window(index, summary.Window('rest', '', 1.0, 2.0, True), 0.0)
        self.assertEqual((first.requests, first.response_bytes, first.events), (1, 0, 0))
        self.assertEqual(first.by_request[0].endings, {'client_closed': 1})
        self.assertEqual((second.requests, second.response_bytes, second.faults), (2, 120, 2))
        self.assertEqual(second.by_request[0].statuses, {'200': 1, summary.NO_ANSWER: 1})
        self.assertEqual(second.by_request[0].endings, {'complete': 1, 'malformed': 1})
        self.assertEqual([(row.event, row.count, row.bytes) for row in second.by_event],
                         [('/stream tick', 1, 8)])
        self.assertEqual(second.requests_per_s, 2.0)
        self.assertEqual([detail for _, detail in index.faults],
                         ['client: malformed header field line', 'relay: RuntimeError: boom'])


if __name__ == '__main__':
    unittest.main()
