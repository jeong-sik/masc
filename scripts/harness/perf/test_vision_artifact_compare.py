"""Failure-path evidence from real child processes, without an OCaml build."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

import vision_artifact_compare as compare


class FailureEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "output"

    def executable(self, name, body):
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o700)
        return path

    def run_window(self, binary):
        return compare.run_window(
            label="before", sha="test-source", binary=binary,
            fixtures=self.root, output=self.output, tracer_dir=self.root,
            count=1, seconds=1, index=1)

    def assert_reaped(self, count):
        cleanup = json.loads((self.output / "cleanup.json").read_text())
        self.assertFalse(cleanup["completed"])
        self.assertEqual(len(cleanup["children"]), count)
        self.assertTrue(all(c["reaped"] for c in cleanup["children"].values()))

    def test_trace_header_reads_one_real_fibers_summary(self):
        trace = (b"ready pid=123 started_at_unix=100.000000\n"
                 b"window started_at_unix=100.000000 ended_at_unix=101.000000\n"
                 b"pid=123 window_s=1.0 events=10 lost=0\n")
        self.assertEqual(compare.trace_header("rtev_fibers", trace),
                         {"events": 10, "lost": 0})

    def test_trace_header_reads_one_real_watch_summary(self):
        trace = (b"ready pid=123 started_at_unix=100.000000\n"
                 b"window started_at_unix=100.000000 ended_at_unix=101.000000\n"
                 b"pid=123 dir=/tmp/events window_s=1.0 backlog_drained=2 events=10 lost=0\n")
        self.assertEqual(compare.trace_header("rtev_watch", trace),
                         {"events": 10, "lost": 0})

    def test_trace_header_rejects_missing_duplicate_and_bad_counts(self):
        cases = (
            b"ready pid=123 started_at_unix=100.000000\n",
            b"pid=123 window_s=1.0 events=10 lost=0\n"
            b"pid=123 window_s=1.0 events=10 lost=0\n",
            b"pid=123 window_s=1.0 events=0 lost=0\n",
            b"pid=123 window_s=1.0 events=10 lost=1\n",
        )
        for trace in cases:
            with self.subTest(trace=trace), self.assertRaises(RuntimeError):
                compare.trace_header("rtev_fibers", trace)

    def test_workload_exit_preserves_both_streams(self):
        binary = self.executable("measure", """
import sys
print('partial measurement', flush=True)
print('measurement failure', file=sys.stderr, flush=True)
sys.exit(7)
""")
        with self.assertRaisesRegex(RuntimeError, "exited before window-ready"):
            self.run_window(binary)
        self.assertEqual((self.output / "stdout.jsonl").read_text(), "partial measurement\n")
        self.assertEqual((self.output / "stderr.txt").read_text(), "measurement failure\n")
        self.assert_reaped(1)

    def test_watcher_failure_keeps_completed_and_pending_child_logs(self):
        binary = self.executable("measure", """
from pathlib import Path
import sys, time
state = Path(sys.argv[1])
print('partial measurement', flush=True)
print('pending workload', file=sys.stderr, flush=True)
(state / 'window-ready').touch()
while not (state / 'window-go').exists(): time.sleep(.01)
(state / 'window-complete').touch()
while True: time.sleep(.01)
""")
        for name, code in (("rtev_fibers", 0), ("rtev_watch", 9)):
            self.executable(name + ".exe", f"""
from pathlib import Path
import os, sys, time
control = Path(os.environ['MASC_RTEV_CONTROL_DIR'])
(control / 'ready').write_text(str(time.time()))
print('ready pid=123 started_at_unix=100.000000', flush=True)
print('window started_at_unix=100.000000 ended_at_unix=101.000000', flush=True)
print('pid=123 window_s=1.0 events=5 lost=0', flush=True)
print('{name} diagnostic', file=sys.stderr, flush=True)
while not (control / 'stop').exists(): time.sleep(.01)
(control / 'ended').write_text(str(time.time()))
sys.exit({code})
""")
        with self.assertRaisesRegex(RuntimeError, "rtev_watch exited 9"):
            self.run_window(binary)
        self.assertEqual((self.output / "stdout.jsonl").read_text(), "partial measurement\n")
        self.assertEqual((self.output / "stderr.txt").read_text(), "pending workload\n")
        for name in ("rtev_fibers", "rtev_watch"):
            self.assertEqual(
                (self.output / f"{name}.txt").read_text(),
                "ready pid=123 started_at_unix=100.000000\n"
                "window started_at_unix=100.000000 ended_at_unix=101.000000\n"
                "pid=123 window_s=1.0 events=5 lost=0\n",
            )
            self.assertEqual((self.output / f"{name}.stderr.txt").read_text(), f"{name} diagnostic\n")
        self.assert_reaped(3)


if __name__ == "__main__":
    unittest.main()
