"""The navigation trace report (RFC-0485): what it counts, what it leaves out."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "tui-nav-trace-report.py"
spec = importlib.util.spec_from_file_location("tui_nav_trace_report", MODULE_PATH)
assert spec is not None and spec.loader is not None
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def surface(to: str, origin: str | None = None) -> str:
    return json.dumps({"t": 1.0, "kind": "surface", "from": origin, "to": to})


def unchanged(on: str, key: str, advertised: bool) -> str:
    return json.dumps(
        {"t": 1.0, "kind": "key_unchanged", "surface": on, "key": key, "advertised": advertised}
    )


def capped(limit: int) -> str:
    return json.dumps({"t": 1.0, "kind": "capped", "limit": limit})


class ParseLine(unittest.TestCase):
    def test_each_kind_the_tui_writes(self) -> None:
        self.assertEqual(report.parse_line(surface("work")), report.Opened(None, "work"))
        self.assertEqual(
            report.parse_line(surface("changes", "work")), report.Opened("work", "changes")
        )
        self.assertEqual(
            report.parse_line(unchanged("changes", "left", True)),
            report.Unchanged("changes", "left", True),
        )
        self.assertEqual(report.parse_line(capped(4096)), report.Capped(4096))

    def test_a_line_that_is_not_an_event_is_none(self) -> None:
        for line in [
            "not json",
            "[]",
            "3",
            json.dumps({"kind": "other"}),
            json.dumps({"kind": "surface"}),
            json.dumps({"kind": "surface", "to": 3}),
            json.dumps({"kind": "key_unchanged", "surface": "a", "key": "b", "advertised": "yes"}),
            json.dumps({"kind": "key_unchanged", "surface": "a", "key": "b"}),
            json.dumps({"kind": "capped", "limit": "many"}),
            json.dumps({"kind": "capped", "limit": True}),
        ]:
            with self.subTest(line=line):
                self.assertIsNone(report.parse_line(line))


class Summarize(unittest.TestCase):
    def test_visits_are_counted_most_opened_first_and_ties_by_name(self) -> None:
        lines = [surface("work"), surface("keepers"), surface("work"), surface("board")]
        self.assertEqual(
            report.summarize(lines).opened, (("work", 2), ("board", 1), ("keepers", 1))
        )

    def test_a_key_the_footer_announced_is_kept_apart_from_one_it_did_not(self) -> None:
        lines = [
            unchanged("changes", "left", True),
            unchanged("changes", "left", True),
            unchanged("changes", "end", False),
            unchanged("work", "left", True),
        ]
        summary = report.summarize(lines)
        self.assertEqual(summary.announced, (("changes", "left", 2), ("work", "left", 1)))
        self.assertEqual(summary.not_announced, (("changes", "end", 1),))

    def test_the_cap_blank_lines_and_unreadable_lines(self) -> None:
        summary = report.summarize([surface("work"), "", "   ", "garbage", capped(3)])
        self.assertEqual(summary.capped, 3)
        self.assertEqual(summary.unreadable, 1)
        self.assertEqual(summary.opened, (("work", 1),))

    def test_an_empty_trace_has_nothing(self) -> None:
        summary = report.summarize([])
        self.assertEqual(
            (summary.opened, summary.announced, summary.not_announced, summary.capped, summary.unreadable),
            ((), (), (), None, 0),
        )


class Render(unittest.TestCase):
    def test_sections_and_the_surfaces_that_never_opened(self) -> None:
        summary = report.summarize(
            [surface("work"), surface("work"), unchanged("work", "left", True), unchanged("work", "end", False)]
        )
        text = report.render(summary, ("work", "schedules", "memory"))
        self.assertIn("Screens opened (2 visits, 1 screens)", text)
        self.assertIn("Announced, unchanged", text)
        self.assertIn("Not announced, unchanged", text)
        not_opened = text.split("Not opened (from --expect)\n")[1]
        self.assertIn("  schedules\n", not_opened)
        self.assertIn("  memory\n", not_opened)
        self.assertNotIn("  work\n", not_opened)

    def test_every_expected_surface_opened(self) -> None:
        text = report.render(report.summarize([surface("work")]), ("work",))
        self.assertTrue(text.split("Not opened (from --expect)\n")[1].startswith("  (none)"))

    def test_no_expect_means_no_section(self) -> None:
        self.assertNotIn("Not opened", report.render(report.summarize([surface("work")]), ()))

    def test_the_cap_and_unreadable_lines_are_said(self) -> None:
        text = report.render(report.summarize([capped(4096), "garbage"]), ())
        self.assertIn("stopped at its cap of 4096 lines", text)
        self.assertIn("1 line(s) were not trace events", text)


class Main(unittest.TestCase):
    def test_a_file_is_read_and_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace.jsonl"
            trace.write_text(surface("work") + "\n" + unchanged("work", "left", True) + "\n", encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = report.main([str(trace)])
        self.assertEqual(code, 0)
        self.assertIn("work", out.getvalue())

    def test_a_file_that_cannot_be_read_is_exit_two(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = report.main(["/nonexistent/nav-trace.jsonl"])
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err.getvalue())


if __name__ == "__main__":
    unittest.main()
