import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "result_size_windows",
    Path(__file__).parents[1] / "harness" / "tool_calls" / "result_size_windows.py",
)
assert spec is not None and spec.loader is not None
rsw = importlib.util.module_from_spec(spec)
sys.modules["result_size_windows"] = rsw
spec.loader.exec_module(rsw)

T0 = rsw.utc("2026-09-28T05:24:00Z").timestamp()
T_EXEC = rsw.utc("2026-09-28T10:41:00Z").timestamp()
MARKER = '[masc:blob sha256=' + "a" * 64 + ' bytes=900 mime=text/plain preview="secret"]'
SECRET = "do-not-print-this-body"


def row(tool, ts, size, output, **extra):
    fields = {
        "record_kind": "tool_call",
        "ts": ts,
        "tool": tool,
        "lane": "claude_code",
        "runtime_profile": "claude_code.opus",
        "result_bytes": size,
        "output_text": output,
        "input": {"command": SECRET},
    }
    fields.update(extra)
    return fields


class ResultSizeWindowsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.masc = Path(self.tmp.name)
        self.day = self.masc / "tool_calls" / "2026-09" / "28.jsonl"
        self.day.parent.mkdir(parents=True)
        rows = [
            row("Read", T0 + 10, 16_384, SECRET),
            row("Read", T0 + 20, 16_385, SECRET),
            row("Read", T0 + 30, 32_768, SECRET),
            row("Read", T0 + 40, 40_000, MARKER),
            row("Read", T0 - 1, 50, SECRET),
            row("Grep", T0 + 50, None, SECRET),
            row("Execute", T_EXEC + 5, 700, MARKER),
            row("Execute", T_EXEC + 6, 900, SECRET),
            row("Execute", T_EXEC + 7, 800, MARKER,
                execution_evidence={"compared_output_bytes": 32_768, "handler_stored": False}),
            row("Execute", T_EXEC + 8, 900, MARKER,
                execution_evidence={"compared_output_bytes": 40_000, "handler_stored": True}),
            row("Execute", T_EXEC + 9, 800, SECRET,
                execution_evidence={"compared_output_bytes": 16_384, "handler_stored": False}),
            {"record_kind": "lifecycle_event", "ts": T0 + 70, "tool": "Read"},
            {"record_kind": "composition_run", "ts": T0 + 80, "tool": "Read"},
        ]
        self.day.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
        (self.day.parent / "29.jsonl").write_text("", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *windows):
        output = io.StringIO()
        args = ["--masc-dir", str(self.masc)]
        for window in windows:
            args.extend(["--window", window])
        with contextlib.redirect_stdout(output):
            status = rsw.main(args)
        self.assertEqual(status, 0)
        return output.getvalue()

    def cells(self, output):
        table = {}
        for line in output.splitlines()[2:]:
            columns = [cell.strip() for cell in line.strip("|").split("|")]
            table[(columns[0], columns[3])] = columns
        return table

    def test_boundaries_and_non_tool_rows(self):
        text = self.run_main(
            "others,2026-09-28T05:24:00Z,2026-09-29T05:24:00Z,except=Execute"
        )
        read = self.cells(text)[("others", "Read")]
        self.assertEqual(read[6:11], ["4", "1", "2", "1", "0"])
        self.assertEqual(read[11:17], ["3", "1", "0", "0", "1", "0"])
        self.assertEqual(self.cells(text)[("others", "Grep")][10], "1")

    def test_old_execute_sizes_and_path_are_unmeasured(self):
        text = self.run_main(
            "old,2026-09-28T10:41:00Z,2026-09-29T10:41:00Z,only=Execute"
        )
        execute = self.cells(text)[("old", "Execute")]
        self.assertEqual(execute[6], "5")
        self.assertEqual(execute[7:10], ["unmeasured"] * 3)
        self.assertEqual(execute[10:14], ["2", "2", "3", "0"])
        self.assertEqual(execute[14:17], ["unmeasured", "unmeasured", "2"])

    def test_fresh_execute_counts_actual_compared_size_and_paths(self):
        text = self.run_main(
            "fresh,2026-09-28T10:41:07Z,2026-09-29T10:41:00Z,only=Execute"
        )
        execute = self.cells(text)[("fresh", "Execute")]
        self.assertEqual(execute[6:17],
                         ["3", "1", "1", "1", "0", "1", "2", "0", "1", "1", "0"])

    def test_output_is_one_table_and_never_contains_body(self):
        text = self.run_main(
            "others,2026-09-28T05:24:00Z,2026-09-29T05:24:00Z,except=Execute",
            "execute,2026-09-28T10:41:00Z,2026-09-29T10:41:00Z,only=Execute",
        )
        self.assertTrue(all(line.startswith("|") for line in text.splitlines()))
        self.assertNotIn(SECRET, text)
        self.assertNotIn("sha256=", text)
        self.assertIn("claude_code.opus", text)

    def test_missing_day_or_bad_row_fails_closed(self):
        (self.day.parent / "29.jsonl").unlink()
        with self.assertRaises(rsw.InputError):
            rsw.count(self.masc / "tool_calls", [
                rsw.parse_window("x,2026-09-28T05:24:00Z,2026-09-29T05:24:00Z")
            ])
        (self.day.parent / "29.jsonl").write_text("", encoding="utf-8")
        with self.day.open("a", encoding="utf-8") as stream:
            stream.write("not json\n")
        with self.assertRaises(rsw.InputError):
            rsw.count(self.masc / "tool_calls", [
                rsw.parse_window("x,2026-09-28T05:24:00Z,2026-09-29T05:24:00Z")
            ])

    def test_invalid_windows(self):
        for spec_text in (
            "x,2026-09-28T05:24:00Z",
            "x,2026-09-28T05:24:00,2026-09-29T05:24:00Z",
            "x,2026-09-29T05:24:00Z,2026-09-28T05:24:00Z",
            "x,2026-09-28T05:24:00Z,2026-09-29T05:24:00Z,maybe=Execute",
        ):
            with self.assertRaises(rsw.InputError):
                rsw.parse_window(spec_text)


if __name__ == "__main__":
    unittest.main()
