import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "audit-keeper-fleet-readiness.py"
)


def load_audit_module():
    spec = importlib.util.spec_from_file_location(
        "audit_keeper_fleet_readiness", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


audit = load_audit_module()


class AuditKeeperFleetReadinessPathDefaultsTest(unittest.TestCase):
    def test_default_base_path_uses_explicit_masc_base_path_only(self):
        with (
            tempfile.TemporaryDirectory() as masc_base,
            tempfile.TemporaryDirectory() as me_root,
        ):
            with patch.dict(
                os.environ,
                {"MASC_BASE_PATH": masc_base, "ME_ROOT": me_root},
                clear=True,
            ):
                self.assertEqual(audit.default_base_path(), masc_base)
            with patch.dict(os.environ, {"ME_ROOT": me_root}, clear=True):
                self.assertIsNone(audit.default_base_path())
            with patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(audit.default_base_path())


def audit_args(base_path: Path, expected_keepers: int):
    return SimpleNamespace(
        base_path=str(base_path),
        expected_keepers=expected_keepers,
        max_silence_hours=2400.0,
        require_board_evidence=True,
        require_web_search_evidence=False,
        require_product_evidence=False,
        require_design_evidence=False,
        require_pr_created_evidence=False,
        require_provider_turn_evidence=False,
        require_checkpoint_evidence=False,
        require_history_evidence=False,
        tool_call_log_evidence_required=False,
        require_persistent_work_evidence=False,
    )


def write_ready_keeper(root: Path, name: str) -> None:
    config_dir = root / ".masc" / "config" / "keepers"
    runtime_dir = root / ".masc" / "keepers"
    config_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / f"{name}.toml").write_text(
        "\n".join(
            [
                "[keeper]",
                'sandbox_profile = "docker"',
                'network_mode = "inherit"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (runtime_dir / f"{name}.json").write_text(
        json.dumps(
            {
                "sandbox_profile": "docker",
                "network_mode": "inherit",
                "last_turn_ts": time.time(),
            }
        ),
        encoding="utf-8",
    )
    (runtime_dir / f"{name}.decisions.jsonl").write_text(
        json.dumps(
            {
                "ts_unix": time.time(),
                "event": "tool_exec",
                "tool": "keeper_board_post",
                "ok": True,
            }
        )
        + "\n",
        encoding="utf-8",
    )


def write_board_post(
    root: Path,
    author: str,
    post_id: str,
    *,
    hearth: str | None = None,
    meta: dict | None = None,
    body: str = "body",
    ts: float | None = None,
) -> None:
    row = {
        "id": post_id,
        "author": author,
        "body": body,
        "content": body,
        "created_at": time.time() if ts is None else ts,
        "updated_at": time.time() if ts is None else ts,
    }
    if hearth is not None:
        row["hearth"] = hearth
    if meta is not None:
        row["meta"] = meta
    board_path = root / ".masc" / "board_posts.jsonl"
    board_path.parent.mkdir(parents=True, exist_ok=True)
    with board_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row) + "\n")


def append_decision(root: Path, keeper: str, row: dict) -> None:
    decisions_path = root / ".masc" / "keepers" / f"{keeper}.decisions.jsonl"
    decisions_path.parent.mkdir(parents=True, exist_ok=True)
    with decisions_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row) + "\n")


def write_persistent_work_evidence(
    root: Path,
    keeper: str,
    *,
    tool: str = "tool_execute",
    top_level_generation: bool = True,
) -> None:
    trace = f"trace-{keeper}"
    manifest_dir = root / ".masc" / "keepers" / keeper / "runtime-manifests"
    checkpoint_path = (
        root / ".masc" / "keepers" / keeper / "checkpoints" / "turn-1.json"
    )
    tool_log_path = root / ".masc" / "tool_calls" / "2026-05" / "15.jsonl"
    history_path = root / ".masc" / "traces" / trace / "history.jsonl"
    for path in (
        manifest_dir,
        checkpoint_path.parent,
        tool_log_path.parent,
        history_path.parent,
    ):
        path.mkdir(parents=True, exist_ok=True)

    checkpoint_path.write_text('{"ok": true}\n', encoding="utf-8")
    history_path.write_text(
        json.dumps({"role": "assistant", "content": "persisted"}) + "\n",
        encoding="utf-8",
    )
    tool_row = {
        "keeper": keeper,
        "trace_id": trace,
        "keeper_turn_id": 1,
        "tool": tool,
        "success": True,
        "runtime_contract": {
            "keeper_name": keeper,
            "trace_id": trace,
            "generation": 1,
            "keeper_turn_id": 1,
        },
    }
    if top_level_generation:
        tool_row["generation"] = 1
    tool_log_path.write_text(
        json.dumps(tool_row) + "\n",
        encoding="utf-8",
    )
    rows = [
        {
            "ts": "2026-05-15T00:00:00Z",
            "keeper_name": keeper,
            "trace_id": trace,
            "generation": 1,
            "keeper_turn_id": 1,
            "event": "provider_attempt_started",
            "status": "started",
            "links": {},
        },
        {
            "ts": "2026-05-15T00:00:01Z",
            "keeper_name": keeper,
            "trace_id": trace,
            "generation": 1,
            "keeper_turn_id": 1,
            "event": "provider_attempt_finished",
            "status": "provider_returned",
            "links": {},
        },
        {
            "ts": "2026-05-15T00:00:02Z",
            "keeper_name": keeper,
            "trace_id": trace,
            "generation": 1,
            "keeper_turn_id": 1,
            "event": "checkpoint_saved",
            "status": "ok",
            "links": {"checkpoint_path": str(checkpoint_path)},
        },
        {
            "ts": "2026-05-15T00:00:03Z",
            "keeper_name": keeper,
            "trace_id": trace,
            "generation": 1,
            "keeper_turn_id": 1,
            "event": "turn_finished",
            "status": "success",
            "links": {"tool_call_log_path": str(tool_log_path)},
        },
    ]
    (manifest_dir / f"{trace}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


class AuditKeeperFleetReadinessTest(unittest.TestCase):
    def test_parse_args_defaults_to_18_keepers(self):
        args = audit.parse_args([])

        self.assertEqual(args.expected_keepers, 18)

    def test_iter_jsonl_streams_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_path = root / "events.jsonl"
            log_path.write_text(
                json.dumps({"a": 1}) + "\n\n" + json.dumps({"b": 2}) + "\n",
                encoding="utf-8",
            )

            rows = audit.iter_jsonl(log_path)

            self.assertNotIsInstance(rows, list)
            self.assertEqual(next(rows), {"a": 1})
            self.assertEqual(next(rows), {"b": 2})
            with self.assertRaises(StopIteration):
                next(rows)
            self.assertEqual(list(audit.iter_jsonl(root / "missing.jsonl")), [])

    def test_pr_creation_evidence_ignores_free_text_claims(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "message": "created PR #123",
                "response_preview": "https://github.com/acme/repo/pull/123",
            }
        )

        self.assertEqual(refs, set())
        self.assertEqual(sources, set())

    def test_pr_creation_evidence_counts_successful_tool_execute_output(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "tool_execute",
                "ok": True,
                "output": {
                    "url": "https://github.com/acme/repo/pull/123",
                    "number": 123,
                },
            }
        )

        self.assertEqual(
            refs,
            {
                "https://github.com/acme/repo/pull/123",
                "PR#123",
            },
        )
        self.assertEqual(sources, {"events.jsonl"})

    def test_pr_creation_evidence_rejects_failed_tool_execute_output(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "tool_execute",
                "ok": False,
                "output": {"url": "https://github.com/acme/repo/pull/123"},
            }
        )

        self.assertEqual(refs, set())
        self.assertEqual(sources, set())

    def test_pr_creation_evidence_rejects_generic_tool_execute_success(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "tool_execute",
                "ok": True,
                "output": {"ok": True, "stdout": "hello"},
            }
        )

        self.assertEqual(refs, set())
        self.assertEqual(sources, set())

    def test_pr_creation_evidence_reads_structured_ref_url(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "tool_execute",
                "ok": True,
                "output": {"url": "https://github.com/acme/repo/pull/124"},
            }
        )

        self.assertEqual(refs, {"https://github.com/acme/repo/pull/124"})
        self.assertEqual(sources, {"events.jsonl"})

    def test_pr_creation_evidence_ignores_freeform_review_ref_mentions(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "tool_execute",
                "ok": True,
                "message": "created https://github.com/acme/repo/pull/124",
            }
        )

        self.assertEqual(refs, set())
        self.assertEqual(sources, set())

    def test_scan_pr_creation_evidence_reads_keeper_scoped_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keepers_dir = root / ".masc" / "keepers"
            keepers_dir.mkdir(parents=True)
            (keepers_dir / "alpha.decisions.jsonl").write_text(
                json.dumps(
                    {
                        "tool": "tool_execute",
                        "ok": True,
                        "output": {
                            "url": "https://github.com/acme/repo/pull/125",
                            "number": 125,
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            evidence = audit.scan_pr_creation_evidence(root, "alpha")

        self.assertEqual(
            evidence.refs,
            {
                "https://github.com/acme/repo/pull/125",
                "PR#125",
            },
        )
        self.assertEqual(
            evidence.sources,
            {str(keepers_dir / "alpha.decisions.jsonl")},
        )

    def test_pr_creation_evidence_reads_route_evidence_ref_url(self):
        row = {
            "_source_path": "tool_calls.jsonl",
            "tool": "tool_execute",
            "success": True,
            "route_evidence": {
                "url": "https://github.com/acme/repo/pull/42\n",
                "via": "docker",
            },
        }

        refs, sources = audit.pr_evidence_from_row(row)

        self.assertEqual(refs, {"https://github.com/acme/repo/pull/42"})
        self.assertEqual(sources, {"tool_calls.jsonl"})

    def test_scan_keeper_evidence_reads_rotated_decision_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keepers_dir = root / ".masc" / "keepers"
            keepers_dir.mkdir(parents=True)
            base_row = {
                "ts_unix": 10.0,
                "event": "tool_exec",
                "tool": "tool_execute",
                "ok": True,
            }
            rotated_row = {
                "ts_unix": 20.0,
                "event": "tool_exec",
                "tool": "tool_execute",
                "ok": True,
                "result_markers": ["event=APPROVE"],
            }
            (keepers_dir / "alpha.decisions.jsonl").write_text(
                json.dumps(base_row) + "\n",
                encoding="utf-8",
            )
            (keepers_dir / "alpha.decisions.jsonl.1").write_text(
                json.dumps(rotated_row) + "\n",
                encoding="utf-8",
            )

            latest_ts, tools = audit.scan_keeper_evidence(root, "alpha")

        self.assertEqual(latest_ts, 20.0)
        self.assertEqual(tools, {"tool_execute"})

    def test_product_and_design_evidence_use_explicit_board_domains(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_board_post(root, "alpha", "p-product", hearth="product")
            write_board_post(
                root,
                "alpha",
                "p-design",
                meta={"tags": ["design"], "source": "keeper_board_post"},
            )
            args = audit_args(root, expected_keepers=1)
            args.require_product_evidence = True
            args.require_design_evidence = True

            report = audit.build_report(args)

        self.assertTrue(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["product_action"])
        self.assertTrue(keeper["design_action"])
        self.assertEqual(
            keeper["product_evidence"],
            ["product:board_post:p-product:hearth=product"],
        )
        self.assertEqual(
            keeper["design_evidence"],
            ["design:board_post:p-design:meta.tags_0_=design"],
        )

    def test_product_and_design_evidence_ignore_freeform_body_mentions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_board_post(
                root,
                "alpha",
                "p-freeform",
                body="This mentions product and design, but has no domain marker.",
            )
            args = audit_args(root, expected_keepers=1)
            args.require_product_evidence = True
            args.require_design_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        keeper = report["keepers"][0]
        self.assertFalse(keeper["product_action"])
        self.assertFalse(keeper["design_action"])
        self.assertIn("product_action_evidence_missing", keeper["failures"])
        self.assertIn("design_action_evidence_missing", keeper["failures"])

    def test_expected_keepers_is_minimum_not_exact_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_ready_keeper(root, "bravo")

            report = audit.build_report(audit_args(root, expected_keepers=1))

        self.assertTrue(report["ok"])
        self.assertEqual(report["configured_keepers"], 2)
        self.assertEqual(report["fleet_failures"], [])

    def test_expected_keepers_fails_below_minimum(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")

            report = audit.build_report(audit_args(root, expected_keepers=2))

        self.assertFalse(report["ok"])
        self.assertEqual(
            report["fleet_failures"], ["minimum_2_configured_keepers_got_1"]
        )

    def test_require_persistent_work_evidence_fails_without_runtime_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            args = audit_args(root, expected_keepers=1)
            args.require_persistent_work_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        keeper = report["keepers"][0]
        self.assertFalse(keeper["provider_turn_evidence"])
        self.assertFalse(keeper["checkpoint_evidence"])
        self.assertFalse(keeper["history_evidence"])
        self.assertFalse(keeper["tool_call_log_evidence"])
        self.assertEqual(
            keeper["failures"],
            [
                "provider_turn_evidence_missing",
                "checkpoint_evidence_missing",
                "history_evidence_missing",
                "tool_call_log_evidence_missing",
            ],
        )

    def test_require_persistent_work_evidence_passes_without_code_surface(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_persistent_work_evidence(root, "alpha", tool="keeper_board_get")
            args = audit_args(root, expected_keepers=1)
            args.require_persistent_work_evidence = True

            report = audit.build_report(args)

        self.assertTrue(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["provider_turn_evidence"])
        self.assertTrue(keeper["checkpoint_evidence"])
        self.assertTrue(keeper["history_evidence"])
        self.assertTrue(keeper["tool_call_log_evidence"])
        self.assertEqual(keeper["failures"], [])

    def test_require_persistent_work_evidence_rejects_uncorrelated_tool_log_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_persistent_work_evidence(root, "alpha")
            tool_log_path = root / ".masc" / "tool_calls" / "2026-05" / "15.jsonl"
            tool_log_path.write_text(
                json.dumps(
                    {
                        "keeper": "alpha",
                        "tool": "tool_execute",
                        "success": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            args = audit_args(root, expected_keepers=1)
            args.require_persistent_work_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["provider_turn_evidence"])
        self.assertTrue(keeper["checkpoint_evidence"])
        self.assertTrue(keeper["history_evidence"])
        self.assertFalse(keeper["tool_call_log_evidence"])
        self.assertEqual(keeper["failures"], ["tool_call_log_evidence_missing"])

    def test_require_persistent_work_evidence_accepts_runtime_contract_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_persistent_work_evidence(
                root,
                "alpha",
                top_level_generation=False,
            )
            args = audit_args(root, expected_keepers=1)
            args.require_persistent_work_evidence = True

            report = audit.build_report(args)

        self.assertTrue(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["tool_call_log_evidence"])
        self.assertEqual(len(keeper["tool_call_log_evidence_refs"]), 1)

    def test_require_persistent_work_evidence_passes_with_manifest_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_persistent_work_evidence(root, "alpha")
            args = audit_args(root, expected_keepers=1)
            args.require_persistent_work_evidence = True

            report = audit.build_report(args)

        self.assertTrue(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["provider_turn_evidence"])
        self.assertTrue(keeper["checkpoint_evidence"])
        self.assertTrue(keeper["history_evidence"])
        self.assertTrue(keeper["tool_call_log_evidence"])
        self.assertEqual(
            keeper["provider_turn_evidence_refs"],
            ["provider_turn:trace=trace-alpha:generation=1:turn=1"],
        )
        self.assertEqual(len(keeper["checkpoint_evidence_refs"]), 1)
        self.assertEqual(len(keeper["history_evidence_refs"]), 1)
        self.assertEqual(len(keeper["tool_call_log_evidence_refs"]), 1)

    def test_scan_keeper_evidence_reads_tool_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls_dir = root / ".masc" / "tool_calls" / "2026-05"
            calls_dir.mkdir(parents=True)
            rows = [
                {
                    "ts": 50.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {
                        "argv": ["git", "push", "-u", "origin", "keeper/proof"],
                    },
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 60.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {"pr_number": 123, "event": "APPROVE"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "event": "APPROVE",
                            "via": "docker",
                        }
                    ),
                    "success": True,
                },
                {
                    "ts": 70.0,
                    "keeper": "beta",
                    "tool": "tool_execute",
                    "input": {"title": "wrong keeper"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
            ]
            (calls_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            latest_ts, tools = audit.scan_keeper_evidence(root, "alpha")

        self.assertEqual(latest_ts, 60.0)
        self.assertEqual(tools, {"tool_execute"})

    def test_scan_keeper_evidence_reads_newest_tool_calls_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_calls_dir = root / ".masc" / "tool_calls" / "2026-05"
            new_calls_dir = root / ".masc" / "tool_calls" / "2026-06"
            old_calls_dir.mkdir(parents=True)
            new_calls_dir.mkdir(parents=True)

            old_rows = [
                {
                    "ts": 10.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {"label": "old"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 20.0,
                    "keeper": "alpha",
                    "tool": "tool_search_files",
                    "input": {"query": "old"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
            ]
            new_rows = [
                {
                    "ts": 70.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {"label": "new"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 80.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {"title": "new"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "url": "https://github.com/acme/repo/pull/2",
                            "via": "docker",
                        }
                    ),
                    "success": True,
                },
                {
                    "ts": 90.0,
                    "keeper": "alpha",
                    "tool": "tool_execute",
                    "input": {"pr_number": 2, "event": "APPROVE"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "event": "APPROVE",
                            "via": "docker",
                        }
                    ),
                    "success": True,
                },
            ]
            (old_calls_dir / "31.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in old_rows),
                encoding="utf-8",
            )
            (new_calls_dir / "01.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in new_rows),
                encoding="utf-8",
            )

            latest_ts, tools = audit.scan_keeper_evidence(root, "alpha")

        self.assertEqual(latest_ts, 90.0)
        self.assertEqual(tools, {"tool_execute", "tool_search_files"})

    def test_web_search_evidence_counts_successful_decision_tool(self):
        row = {
            "ts_unix": 100.0,
            "event": "tool_exec",
            "tool": "masc_web_search",
            "ok": True,
            "args": {"query": "MASC keeper web search proof"},
        }

        evidence = audit.web_search_evidence_from_decision(row, "alpha.decisions.jsonl")

        self.assertEqual(
            evidence,
            {
                "web_search:masc_web_search:"
                "query=MASC keeper web search proof:"
                "ts=100:"
                "source=alpha.decisions.jsonl"
            },
        )

    def test_web_search_evidence_rejects_failed_decision_tool(self):
        row = {
            "ts_unix": 100.0,
            "event": "tool_exec",
            "tool": "masc_web_search",
            "ok": False,
            "args": {"query": "MASC keeper web search proof"},
        }

        evidence = audit.web_search_evidence_from_decision(row, "alpha.decisions.jsonl")

        self.assertEqual(evidence, set())

    def test_web_search_evidence_counts_successful_global_tool_call(self):
        row = {
            "ts": 110.0,
            "keeper": "alpha",
            "tool": "WebSearch",
            "input": {"query": "latest MASC MCP keeper proof"},
            "output": json.dumps({"ok": True}),
            "success": True,
        }

        evidence = audit.web_search_evidence_from_tool_call(row, "06.jsonl")

        self.assertEqual(
            evidence,
            {
                "web_search:WebSearch:"
                "query=latest MASC MCP keeper proof:"
                "ts=110:"
                "source=06.jsonl"
            },
        )

    def test_scan_keeper_web_search_evidence_filters_keeper_not_run_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls_dir = root / ".masc" / "tool_calls" / "2026-05"
            calls_dir.mkdir(parents=True)
            rows = [
                {
                    "ts": 80.0,
                    "keeper": "alpha",
                    "tool": "masc_web_search",
                    "input": {"query": "keeper proof old-run"},
                    "output": json.dumps({"ok": True}),
                    "success": True,
                },
                {
                    "ts": 90.0,
                    "keeper": "alpha",
                    "tool": "masc_web_search",
                    "input": {"query": "keeper proof current-run"},
                    "output": json.dumps({"ok": True}),
                    "success": True,
                },
                {
                    "ts": 95.0,
                    "keeper": "beta",
                    "tool": "masc_web_search",
                    "input": {"query": "keeper proof current-run"},
                    "output": json.dumps({"ok": True}),
                    "success": True,
                },
            ]
            (calls_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            latest_ts, evidence = audit.scan_keeper_web_search_evidence(root, "alpha")

        self.assertEqual(latest_ts, 90.0)
        self.assertEqual(
            evidence,
            {
                "web_search:masc_web_search:"
                "query=keeper proof old-run:"
                "ts=80:"
                "source=06.jsonl",
                "web_search:masc_web_search:"
                "query=keeper proof current-run:"
                "ts=90:"
                "source=06.jsonl",
            },
        )

    def test_require_web_search_evidence_fails_without_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            args = audit_args(root, expected_keepers=1)
            args.require_web_search_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        keeper = report["keepers"][0]
        self.assertFalse(keeper["web_search_action"])
        self.assertIn("web_search_evidence_missing", keeper["failures"])

    def test_require_web_search_evidence_passes_with_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            append_decision(
                root,
                "alpha",
                {
                    "ts_unix": time.time(),
                    "event": "tool_exec",
                    "tool": "masc_web_search",
                    "ok": True,
                    "args": {"query": "MASC keeper web search proof"},
                },
            )
            args = audit_args(root, expected_keepers=1)
            args.require_web_search_evidence = True

            report = audit.build_report(args)

        self.assertTrue(report["ok"])
        keeper = report["keepers"][0]
        self.assertTrue(keeper["web_search_action"])
        self.assertEqual(len(keeper["web_search_evidence"]), 1)


if __name__ == "__main__":
    unittest.main()
