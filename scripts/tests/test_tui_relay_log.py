# pyright: strict
"""Reading the relay's decision log: a cut last line names the relay's exit.

    python3 -m unittest scripts.tests.test_tui_relay_log

The relay ends every log line with a newline, so a last line without one was
cut while it was written, as when the relay is killed. idle.py and summary.py
then report the cut with the relay's exit instead of a bare "not a JSON
object", and the run still counts as unreadable evidence. No relay, TUI or
MASC server runs here.
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'harness' / 'tui'))
import idle  # noqa: E402
from relay_files import read_log  # noqa: E402
import summary  # noqa: E402

SIGKILL_EXIT = -9
REFUSED: dict[str, object] = {'decision': 'refused', 'verb': 'POST', 'path': '/api/v1/tui/preferences',
                              'why': 'rest-write'}
# A path with Hangul, so a cut can fall inside a three-byte character.
DONE: dict[str, object] = {'decision': 'done', 'verb': 'GET', 'path': '/api/v1/keepers/키퍼', 'status': 200}


def line(entry: dict[str, object]) -> bytes:
    return (json.dumps(entry, ensure_ascii=False) + '\n').encode()


class RelayLogTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.dir = Path(scratch.name)
        self.log = self.dir / 'relay.jsonl'

    def test_a_whole_log_is_read(self) -> None:
        self.log.write_bytes(line(REFUSED) + line(DONE))
        self.assertEqual(read_log(self.log, 0), [REFUSED, DONE])

    def test_a_last_line_cut_inside_a_character_names_the_signal(self) -> None:
        # The last character of the path is three bytes; keep one of them.
        cut = line(DONE)[:-len('퍼"}\n'.encode()) + 1]
        self.log.write_bytes(line(REFUSED) + cut)
        error = read_log(self.log, SIGKILL_EXIT)
        assert isinstance(error, str)
        self.assertIn(':2: the last line is cut off', error)
        self.assertIn('SIGKILL', error)

    def test_a_cut_line_with_an_unknown_exit_says_so(self) -> None:
        self.log.write_bytes(line(REFUSED) + line(DONE)[:20])
        error = read_log(self.log, None)
        assert isinstance(error, str)
        self.assertIn('cut off', error)
        self.assertIn('is not known', error)

    def test_a_bad_line_with_a_newline_is_not_called_cut(self) -> None:
        self.log.write_bytes(line(REFUSED) + b'{"decision": \n' + line(DONE))
        self.assertEqual(read_log(self.log, SIGKILL_EXIT), f'{self.log}:2: not a JSON object')

    def test_a_whole_last_line_without_its_newline_is_read(self) -> None:
        self.log.write_bytes(line(REFUSED) + line(DONE)[:-1])
        self.assertEqual(read_log(self.log, SIGKILL_EXIT), [REFUSED, DONE])

    def test_idle_counts_refusals_and_reports_a_cut_log(self) -> None:
        self.log.write_bytes(line(REFUSED) + line(DONE))
        refused = idle.refused_requests(self.log, 0)
        assert isinstance(refused, list)
        self.assertEqual([entry['why'] for entry in refused], ['rest-write'])
        self.log.write_bytes(line(REFUSED) + line(DONE)[:-3])
        error = idle.refused_requests(self.log, SIGKILL_EXIT)
        assert isinstance(error, str)
        self.assertIn('SIGKILL', error)

    def test_summary_takes_the_relay_exit_from_idle_json(self) -> None:
        (self.dir / 'idle.json').write_text(json.dumps({'relay': {'exit': SIGKILL_EXIT}, 'screens': []}),
                                            encoding='utf-8')
        self.log.write_bytes(line(REFUSED) + line(DONE)[:-3])
        lines = summary.summarize(self.dir, reads=True)
        problem = [text for text in lines if 'no relay log' in text]
        self.assertEqual(len(problem), 1)
        self.assertIn('SIGKILL', problem[0])


if __name__ == '__main__':
    unittest.main()
