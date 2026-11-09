"""Tests of transport_diff.py.

  python3 -m unittest discover -s scripts/auth-route-baseline
"""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path

from transport_diff import Finding, Problem, Row, Run, findings, main, parse_run, render

PLAIN = Row("GET", "/health", "/health", "plain", 200, 200, 200, 200)
WS = Row("GET", "/api/v1/ide/lsp", "/api/v1/ide/lsp", "ws", 200, 200, 426, 426)
DISCOVERY = Row("GET", "/ws", "/ws", "ws", 200, 200, 200, 200)


def row(**over: object) -> dict[str, object]:
    base: dict[str, object] = {
        "method": "GET",
        "route_path": "/health",
        "probed_path": "/health",
        "kind": "exact",
        "target": "plain",
        "http1_none": 200,
        "http1_bad": 200,
        "h2_none": 200,
        "h2_bad": 200,
    }
    return {**base, **over}


def results(rows: list[object], *, probes: int | None = None, stopped: list[str] | None = None) -> dict[str, object]:
    return {
        "probes": len(rows) if probes is None else probes,
        "answered": len(rows),
        "server_stopped_at": [] if stopped is None else stopped,
        "rows": rows,
    }


def write(out: Path, mode: str, doc: object) -> None:
    (out / mode).mkdir(parents=True, exist_ok=True)
    (out / mode / "results.json").write_text(json.dumps(doc), encoding="utf-8")


class FindingsTest(unittest.TestCase):
    def test_equal_statuses_on_a_plain_route_are_no_finding(self) -> None:
        self.assertEqual(findings(Run("default", (PLAIN,))), ())

    def test_a_differing_status_names_the_route_and_credential(self) -> None:
        run = Run("strict", (replace(PLAIN, h2_bad=404),))
        self.assertEqual(
            findings(run),
            (Finding("strict", "GET", "/health", "/health", "plain", "bad", 200, 404, "differs"),),
        )

    def test_both_credentials_can_differ_on_one_route(self) -> None:
        run = Run("default", (replace(PLAIN, h2_none=404, h2_bad=404),))
        self.assertEqual([f.credential for f in findings(run)], ["none", "bad"])

    def test_a_ws_route_answering_426_on_h2_is_no_finding(self) -> None:
        self.assertEqual(findings(Run("default", (WS, replace(WS, http1_none=401, http1_bad=401)))), ())

    def test_a_ws_route_not_answering_426_on_h2_is_a_finding(self) -> None:
        found = findings(Run("default", (replace(WS, h2_none=404),)))
        self.assertEqual([(f.credential, f.http1, f.h2, f.reason) for f in found], [("none", 200, 404, "h2_not_426")])

    def test_a_plain_get_on_ws_is_discovery_on_both_transports(self) -> None:
        self.assertEqual(findings(Run("default", (DISCOVERY,))), ())

    def test_a_transport_that_refuses_ws_discovery_is_a_finding(self) -> None:
        found = findings(Run("default", (replace(DISCOVERY, h2_bad=426),)))
        self.assertEqual([(f.route_path, f.credential, f.reason) for f in found], [("/ws", "bad", "differs")])

    def test_no_answer_on_either_side_is_a_finding(self) -> None:
        found = findings(Run("default", (replace(PLAIN, h2_none=0), replace(WS, http1_bad=0))))
        self.assertEqual([(f.route_path, f.credential, f.reason) for f in found], [("/health", "none", "no_answer"), ("/api/v1/ide/lsp", "bad", "no_answer")])


class ParseRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_a_complete_run_parses_every_row(self) -> None:
        write(self.out, "default", results([row(h2_none="200"), row(route_path="/api/v1/ide/lsp", probed_path="/api/v1/ide/lsp", target="ws", h2_none=426, h2_bad=426)]))
        self.assertEqual(parse_run(self.out, "default"), Run("default", (PLAIN, WS)))

    def test_a_missing_file_is_a_problem(self) -> None:
        run = parse_run(self.out, "strict")
        self.assertIsInstance(run, Problem)
        self.assertIn("is missing", run.message if isinstance(run, Problem) else "")

    def test_a_run_whose_server_stopped_is_a_problem(self) -> None:
        write(self.out, "default", results([row()], probes=5))
        write(self.out, "strict", results([row()], stopped=["GET /health"]))
        for mode in ("default", "strict"):
            run = parse_run(self.out, mode)
            self.assertIsInstance(run, Problem, mode)
            self.assertIn("stopped part-way", run.message if isinstance(run, Problem) else "")

    def test_a_status_that_is_not_a_number_is_a_problem(self) -> None:
        for bad in ("timeout", True, None):
            write(self.out, "default", results([row(h2_none=bad)]))
            run = parse_run(self.out, "default")
            self.assertIsInstance(run, Problem, repr(bad))
            self.assertIn("h2_none is not a status", run.message if isinstance(run, Problem) else "")

    def test_an_unknown_target_is_a_problem(self) -> None:
        write(self.out, "default", results([row(target="sse")]))
        run = parse_run(self.out, "default")
        self.assertIsInstance(run, Problem)
        self.assertIn("target is not plain or ws", run.message if isinstance(run, Problem) else "")

    def test_a_row_that_is_not_an_object_is_a_problem(self) -> None:
        write(self.out, "default", results([row(), "GET /health"]))
        run = parse_run(self.out, "default")
        self.assertIsInstance(run, Problem)
        self.assertIn("rows[1]: not an object", run.message if isinstance(run, Problem) else "")

    def test_rows_that_are_not_a_list_is_a_problem(self) -> None:
        write(self.out, "default", {"probes": 0, "answered": 0, "server_stopped_at": [], "rows": {}})
        run = parse_run(self.out, "default")
        self.assertIsInstance(run, Problem)
        self.assertIn("rows is not a list", run.message if isinstance(run, Problem) else "")


class RenderTest(unittest.TestCase):
    def test_the_header_counts_routes_by_target_and_the_tables_list_findings_and_ws_rows(self) -> None:
        run = Run("default", (PLAIN, replace(PLAIN, route_path="/x", probed_path="/x", h2_bad=500), WS))
        text = render(run, findings(run))
        self.assertIn("### default: 3 routes (2 plain, 1 ws), 1 findings", text)
        self.assertIn("| GET | `/x` | `/x` | plain | bad | 200 | 500 | differs |", text)
        self.assertIn("| GET | `/api/v1/ide/lsp` | 200 | 200 | 426 | 426 |", text)

    def test_without_findings_or_ws_rows_only_the_header_is_printed(self) -> None:
        run = Run("strict", (PLAIN,))
        self.assertEqual(render(run, ()), "### strict: 1 routes (1 plain, 0 ws), 0 findings\n")


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_main(self) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = main([str(self.out)])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_exit_0_when_both_modes_match_the_route_table(self) -> None:
        for mode in ("default", "strict"):
            write(self.out, mode, results([row(), row(route_path="/api/v1/ide/lsp", probed_path="/api/v1/ide/lsp", target="ws", h2_none=426, h2_bad=426)]))
        code, out, err = self.run_main()
        self.assertEqual((code, err), (0, ""))
        self.assertIn("### default: 2 routes (1 plain, 1 ws), 0 findings", out)
        self.assertIn("### strict: 2 routes (1 plain, 1 ws), 0 findings", out)

    def test_exit_1_when_a_mode_has_a_finding(self) -> None:
        write(self.out, "default", results([row()]))
        write(self.out, "strict", results([row(h2_bad=404)]))
        code, out, err = self.run_main()
        self.assertEqual((code, err), (1, ""))
        self.assertIn("### strict: 1 routes (1 plain, 0 ws), 1 findings", out)

    def test_exit_2_when_a_mode_cannot_be_used(self) -> None:
        write(self.out, "default", results([row()]))
        code, out, err = self.run_main()
        self.assertEqual((code, out), (2, ""))
        self.assertIn("strict/results.json is missing", err)


if __name__ == "__main__":
    unittest.main()
