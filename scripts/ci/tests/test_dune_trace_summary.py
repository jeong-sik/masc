"""The trace summary sorts dune's processes by kind and never repeats the environment."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CI = Path(__file__).resolve().parents[1]
SCRIPT = CI / "dune-trace-summary.py"
spec = importlib.util.spec_from_file_location("dune_trace_summary", SCRIPT)
assert spec is not None and spec.loader is not None
summary = importlib.util.module_from_spec(spec)
sys.modules["dune_trace_summary"] = summary
spec.loader.exec_module(summary)

SECOND = 1_000_000_000


def csexp(value) -> bytes:
    if isinstance(value, list):
        return b"(" + b"".join(csexp(item) for item in value) + b")"
    data = str(value).encode()
    return str(len(data)).encode() + b":" + data


def finish(start_s, seconds, prog, args, targets=()):
    return ["process", "finish", [start_s * SECOND, int(seconds * SECOND)],
            ["process_args", list(args)], ["pid", "1"], ["categories", []],
            ["prog", prog], ["dir", "."], ["exit", "0"],
            ["target_files", list(targets)], ["rusage", []]]


RECORDS = [
    ["config", "init", "0", ["version", "3.24.1"],
     ["env", ["GITHUB_TOKEN=fixture-secret-value", "HOME=/home/runner"]]],
    ["process", "start", "0", ["prog", "/opam/bin/ocamlopt.opt"]],
    finish(0, 4.0, "/opam/bin/ocamlopt.opt", ["-c", "lib/a.ml"], ["_build/default/lib/a.cmx"]),
    finish(1, 6.5, "/opam/bin/ocamlopt.opt", ["-o", "test/test_alpha.exe", "a.cmx"],
           ["_build/default/test/test_alpha.exe"]),
    finish(2, 1.5, "/opam/bin/ocamlopt.opt", ["-a", "-o", "lib/masc.cmxa"],
           ["_build/default/lib/masc.cmxa"]),
    finish(8, 12.0, "/w/_build/default/test/test_alpha.exe", []),
    finish(9, 30.0, "/usr/bin/python3", ["./test_tui_x_pty.py", "../bin/masc_tui.exe"]),
    finish(3, 0.5, "/opam/bin/ocamldep.opt", ["-modules", "lib/a.ml"]),
]


class DuneTraceSummary(unittest.TestCase):
    def kinds(self, data: bytes):
        return summary.summarise(summary.parse_stream(data))["kinds"]

    def test_processes_are_sorted_by_kind_with_their_time(self):
        kinds = self.kinds(b"".join(csexp(record) for record in RECORDS))
        self.assertEqual(
            {kind: (row["processes"], row["seconds"]) for kind, row in kinds.items()},
            {"compile": (1, 4.0), "link": (1, 6.5), "library archive": (1, 1.5),
             "test run": (2, 42.0), "dependency scan": (1, 0.5)})
        self.assertEqual(kinds["link"]["slowest"], [["test_alpha.exe", 6.5]])
        self.assertEqual(kinds["test run"]["slowest"],
                         [["test_tui_x_pty.py", 30.0], ["test_alpha.exe", 12.0]])

    def test_wall_time_spans_first_start_to_last_finish(self):
        result = summary.summarise(summary.parse_stream(b"".join(csexp(r) for r in RECORDS)))
        self.assertEqual(result["wall_seconds"], 39.0)

    def test_a_trace_cut_mid_record_keeps_the_complete_records(self):
        data = b"".join(csexp(record) for record in RECORDS)
        cut = data + csexp(finish(50, 9.0, "/opam/bin/ocamlopt.opt", ["-c", "b.ml"]))[:-20]
        self.assertEqual(self.kinds(cut), self.kinds(data))

    def test_the_written_summary_never_repeats_the_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace"
            out = Path(directory) / "timing.json"
            trace.write_bytes(b"".join(csexp(record) for record in RECORDS))
            done = subprocess.run([sys.executable, str(SCRIPT), str(trace), "--out", str(out)],
                                  capture_output=True, text=True, check=True)
            written = out.read_text(encoding="utf-8")
            json.loads(written)
            for text in (written, done.stdout, done.stderr):
                self.assertNotIn("fixture-secret-value", text)
                self.assertNotIn("GITHUB_TOKEN", text)


if __name__ == "__main__":
    unittest.main()
