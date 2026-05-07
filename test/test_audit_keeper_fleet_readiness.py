import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace


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


def audit_args(base_path: Path, expected_keepers: int):
    return SimpleNamespace(
        base_path=str(base_path),
        expected_keepers=expected_keepers,
        max_silence_hours=2400.0,
        require_board_evidence=True,
        require_product_evidence=False,
        require_design_evidence=False,
        require_pr_surface_evidence=False,
        require_pr_review_evidence=False,
        require_pr_create_evidence=False,
        require_pr_created_evidence=False,
        require_pr_url_evidence=False,
        require_git_push_evidence=False,
        require_pr_approve_evidence=False,
        require_pr_lifecycle_evidence=False,
        require_docker_pr_create_evidence=False,
        require_docker_git_push_evidence=False,
        require_docker_pr_approve_evidence=False,
        require_docker_pr_lifecycle_evidence=False,
        evidence_run_id=None,
        forbid_github_identity=[],
    )


def write_ready_keeper(
    root: Path,
    name: str,
    *,
    github_identity: str = "anyang-keepers",
    github_account_login: str | None = None,
) -> None:
    config_dir = root / ".masc" / "config" / "keepers"
    runtime_dir = root / ".masc" / "keepers"
    credential_dir = root / ".masc" / "github-identities" / github_identity / "gh"
    config_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    credential_dir.mkdir(parents=True, exist_ok=True)
    account_login = github_account_login or github_identity
    (credential_dir / "hosts.yml").write_text(
        "\n".join(
            [
                "github.com:",
                "    git_protocol: https",
                f"    user: {account_login}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (config_dir / f"{name}.toml").write_text(
        "\n".join(
            [
                "[keeper]",
                'sandbox_profile = "docker"',
                'network_mode = "inherit"',
                'tool_preset = "coding"',
                f'github_identity = "{github_identity}"',
                'git_identity_mode = "github_identity"',
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
                "tool_preset": "coding",
                "github_identity": github_identity,
                "git_identity_mode": "github_identity",
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


class AuditKeeperFleetReadinessTest(unittest.TestCase):
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

    def test_pr_creation_evidence_counts_successful_keeper_pr_create_output(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "keeper_pr_create",
                "ok": True,
                "output": {
                    "pr_url": "https://github.com/acme/repo/pull/123",
                    "number": 123,
                },
            }
        )

        self.assertEqual(
            refs,
            {
                "keeper_pr_create",
                "https://github.com/acme/repo/pull/123",
                "PR#123",
            },
        )
        self.assertEqual(sources, {"events.jsonl"})

    def test_pr_creation_evidence_rejects_failed_keeper_pr_create_output(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "keeper_pr_create",
                "ok": False,
                "output": {"pr_url": "https://github.com/acme/repo/pull/123"},
            }
        )

        self.assertEqual(refs, set())
        self.assertEqual(sources, set())

    def test_pr_creation_evidence_uses_structured_shell_command_and_output(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "keeper_shell",
                "ok": True,
                "args": {"command": "gh pr create --draft --title t --body b"},
                "output": {"url": "https://github.com/acme/repo/pull/124"},
            }
        )

        self.assertEqual(
            refs,
            {"gh pr create", "https://github.com/acme/repo/pull/124"},
        )
        self.assertEqual(sources, {"events.jsonl"})

    def test_pr_creation_evidence_ignores_freeform_shell_mentions(self):
        refs, sources = audit.pr_evidence_from_row(
            {
                "_source_path": "events.jsonl",
                "tool": "keeper_shell",
                "ok": True,
                "message": "gh pr create returned https://github.com/acme/repo/pull/124",
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
                        "tool": "keeper_pr_create",
                        "ok": True,
                        "output": {
                            "pr_url": "https://github.com/acme/repo/pull/125",
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
                "keeper_pr_create",
                "https://github.com/acme/repo/pull/125",
                "PR#125",
            },
        )
        self.assertEqual(
            evidence.sources,
            {str(keepers_dir / "alpha.decisions.jsonl")},
        )

    def test_pr_action_metric_paths_returns_newest_date_split_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_root = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            for relative_path in (
                "2026-04/30.jsonl",
                "2026-05/05.jsonl",
                "2026-05/06.jsonl",
            ):
                path = metrics_root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}\n", encoding="utf-8")

            paths = audit.pr_action_metric_paths(root, "alpha")

        self.assertEqual(
            [path.relative_to(metrics_root).as_posix() for path in paths],
            ["2026-05/06.jsonl", "2026-05/05.jsonl", "2026-04/30.jsonl"],
        )

    def test_decision_lifecycle_evidence_ignores_git_push_markers(self):
        row = {
            "event": "tool_exec",
            "tool": "masc_code_git",
            "ok": True,
            "action": "push",
            "via": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_decision_lifecycle_evidence_handles_non_string_tool(self):
        row = {
            "event": "tool_exec",
            "tool": {"name": "keeper_shell"},
            "ok": True,
            "result_markers": ["gh pr create"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_ignores_freeform_command_mentions(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_shell",
            "ok": True,
            "cmd": "echo gh pr create && echo git push && echo via=docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_uses_structured_markers(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_shell",
            "ok": True,
            "result_markers": ["gh pr create", "via=brokered"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_shell:gh_pr_create"})
        self.assertEqual(docker_evidence, {"pr_create:keeper_shell:gh_pr_create"})

    def test_lifecycle_evidence_does_not_treat_sandbox_as_docker_route(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_pr_create",
            "ok": True,
            "sandbox_profile": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_does_not_treat_plain_docker_marker_as_route(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_pr_create",
            "ok": True,
            "result_markers": ["docker"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, set())

    def test_action_metric_git_push_drives_lifecycle_evidence(self):
        row = {
            "ts_unix": 30.0,
            "metric_event": "keeper_pr_work_action",
            "tool_name": "masc_code_git",
            "pr_work_action": "GIT_PUSH",
            "pr_work_action_source": "masc_code_git",
            "pr_work_action_success": True,
            "route": {"via": "docker"},
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"git_push:masc_code_git"})
        self.assertEqual(docker_evidence, {"git_push:masc_code_git"})

    def test_action_metric_brokered_route_counts_as_docker_backed(self):
        row = {
            "metric_event": "keeper_pr_work_action",
            "tool_name": "keeper_pr_create",
            "pr_work_action": "PR_CREATE",
            "pr_work_action_source": "keeper_pr_create",
            "pr_work_action_success": True,
            "route_via": "brokered",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, {"pr_create:keeper_pr_create"})

    def test_action_metric_does_not_treat_sandbox_as_docker_route(self):
        row = {
            "metric_event": "keeper_pr_work_action",
            "tool_name": "masc_code_git",
            "pr_work_action": "GIT_PUSH",
            "pr_work_action_source": "masc_code_git",
            "pr_work_action_success": True,
            "sandbox_profile": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"git_push:masc_code_git"})
        self.assertEqual(docker_evidence, set())

    def test_tool_call_log_drives_shell_lifecycle_evidence(self):
        row = {
            "ts": 50.0,
            "keeper": "alpha",
            "tool": "keeper_shell",
            "input": {"op": "gh", "cmd": "pr create --draft --title t"},
            "output": json.dumps(
                {
                    "ok": True,
                    "command": "gh 'pr' 'create' '--draft' '--title' 't'",
                    "via": "docker",
                }
            ),
            "success": True,
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_tool_call(row)

        self.assertEqual(evidence, {"pr_create:keeper_shell"})
        self.assertEqual(docker_evidence, {"pr_create:keeper_shell"})

    def test_tool_call_log_does_not_count_failed_approve(self):
        row = {
            "ts": 55.0,
            "keeper": "alpha",
            "tool": "keeper_shell",
            "input": {"op": "gh", "cmd": "pr review 123 --approve"},
            "output": json.dumps(
                {
                    "ok": False,
                    "command": "gh 'pr' 'review' '123' '--approve'",
                    "via": "docker",
                }
            ),
            "success": False,
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_tool_call(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_scan_keeper_evidence_reads_rotated_decision_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keepers_dir = root / ".masc" / "keepers"
            keepers_dir.mkdir(parents=True)
            base_row = {
                "ts_unix": 10.0,
                "event": "tool_exec",
                "tool": "keeper_pr_create",
                "ok": True,
            }
            rotated_row = {
                "ts_unix": 20.0,
                "event": "tool_exec",
                "tool": "keeper_pr_review_comment",
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

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 20.0)
        self.assertEqual(tools, {"keeper_pr_create", "keeper_pr_review_comment"})
        self.assertEqual(
            evidence,
            {"pr_create:keeper_pr_create", "pr_approve:keeper_pr_review_comment"},
        )
        self.assertEqual(docker_evidence, set())

    def test_scan_keeper_evidence_reads_pr_action_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = (
                root / ".masc" / "keepers" / "alpha" / "pr-action-metrics" / "2026-05"
            )
            metrics_dir.mkdir(parents=True)
            rows = [
                {
                    "ts_unix": 25.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "keeper_shell",
                    "pr_work_action": "PR_CREATE",
                    "pr_work_action_source": "keeper_shell",
                    "pr_work_action_success": True,
                    "route_via": "brokered",
                },
                {
                    "ts_unix": 30.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "masc_code_git",
                    "pr_work_action": "GIT_PUSH",
                    "pr_work_action_source": "masc_code_git",
                    "pr_work_action_success": True,
                    "route": {"via": "docker"},
                },
                {
                    "ts_unix": 35.0,
                    "metric_event": "keeper_pr_review_action",
                    "tool_name": "keeper_pr_review_comment",
                    "pr_review_action": "APPROVE",
                    "pr_review_action_success": True,
                    "execution_via": "docker",
                },
                {
                    "ts_unix": 40.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "masc_code_git",
                    "pr_work_action": "GIT_PUSH",
                    "pr_work_action_source": "masc_code_git",
                    "pr_work_action_success": False,
                    "via": "docker",
                },
            ]
            (metrics_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 40.0)
        self.assertEqual(
            tools, {"keeper_shell", "masc_code_git", "keeper_pr_review_comment"}
        )
        self.assertEqual(
            evidence,
            {
                "pr_create:keeper_shell",
                "git_push:masc_code_git",
                "pr_approve:keeper_pr_review_comment",
            },
        )
        self.assertEqual(docker_evidence, evidence)

    def test_pr_action_metric_paths_are_newest_first_and_cutoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            old_path = metrics_dir / "2026-04" / "30.jsonl"
            new_path = metrics_dir / "2026-05" / "06.jsonl"
            mid_path = metrics_dir / "2026-05" / "05.jsonl"
            for path in (old_path, new_path, mid_path):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}\n", encoding="utf-8")

            paths = audit.pr_action_metric_paths(root, "alpha", min_day_key=20260501)

        self.assertEqual(paths, [new_path, mid_path])

    def test_scan_keeper_evidence_skips_old_pr_action_metric_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            old_dir = metrics_dir / "2026-05"
            old_dir.mkdir(parents=True)
            now = 1_778_064_000.0
            old_ts = now - (48 * 3600.0)
            recent_ts = now - 60.0
            (old_dir / "04.jsonl").write_text(
                json.dumps(
                    {
                        "ts_unix": old_ts,
                        "metric_event": "keeper_pr_work_action",
                        "tool_name": "masc_code_git",
                        "pr_work_action": "GIT_PUSH",
                        "pr_work_action_source": "masc_code_git",
                        "pr_work_action_success": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            (old_dir / "06.jsonl").write_text(
                json.dumps(
                    {
                        "ts_unix": recent_ts,
                        "metric_event": "keeper_pr_work_action",
                        "tool_name": "keeper_shell",
                        "pr_work_action": "PR_CREATE",
                        "pr_work_action_source": "keeper_shell",
                        "pr_work_action_success": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root,
                "alpha",
                max_silence_hours=24.0,
                now=now,
            )

        self.assertEqual(latest_ts, recent_ts)
        self.assertEqual(tools, {"keeper_shell"})
        self.assertEqual(evidence, {"pr_create:keeper_shell"})
        self.assertEqual(docker_evidence, set())

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

    def test_forbid_github_identity_fails_matching_keeper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha", github_identity="operator")
            args = audit_args(root, expected_keepers=1)
            args.forbid_github_identity = ["operator"]

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        self.assertEqual(
            report["keepers"][0]["failures"],
            ["github_identity_forbidden_operator"],
        )

    def test_forbid_github_identity_fails_matching_account_login(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(
                root,
                "alpha",
                github_identity="reviewer-keepers",
                github_account_login="operator",
            )
            args = audit_args(root, expected_keepers=1)
            args.forbid_github_identity = ["operator"]

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        self.assertEqual(
            report["keepers"][0]["failures"],
            ["github_account_forbidden_operator"],
        )

    def test_docker_pr_approve_requirement_fails_with_single_identity_pool(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_ready_keeper(root, "bravo")
            args = audit_args(root, expected_keepers=2)
            args.require_docker_pr_lifecycle_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        self.assertEqual(report["github_identity_counts"], {"anyang-keepers": 2})
        self.assertEqual(report["github_account_counts"], {"anyang-keepers": 2})
        self.assertIn(
            "docker_pr_approve_identity_pool_insufficient_unique_github_identities_1",
            report["fleet_failures"],
        )
        self.assertIn(
            "docker_pr_approve_account_pool_insufficient_unique_accounts_1",
            report["fleet_failures"],
        )

    def test_docker_pr_approve_requirement_fails_aliases_to_same_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(
                root,
                "alpha",
                github_identity="anyang-keepers",
                github_account_login="anyang-keepers",
            )
            write_ready_keeper(
                root,
                "bravo",
                github_identity="reviewer-keepers",
                github_account_login="anyang-keepers",
            )
            args = audit_args(root, expected_keepers=2)
            args.require_docker_pr_approve_evidence = True

            report = audit.build_report(args)

        self.assertFalse(report["ok"])
        self.assertEqual(
            report["github_identity_counts"],
            {"anyang-keepers": 1, "reviewer-keepers": 1},
        )
        self.assertEqual(report["github_account_counts"], {"anyang-keepers": 2})
        self.assertIn(
            "docker_pr_approve_account_pool_insufficient_unique_accounts_1",
            report["fleet_failures"],
        )

    def test_docker_pr_approve_requirement_accepts_multiple_identity_pool(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha", github_identity="anyang-keepers")
            write_ready_keeper(root, "bravo", github_identity="reviewer-keepers")
            args = audit_args(root, expected_keepers=2)
            args.require_docker_pr_approve_evidence = True

            report = audit.build_report(args)

        self.assertEqual(
            report["github_identity_counts"],
            {"anyang-keepers": 1, "reviewer-keepers": 1},
        )
        self.assertEqual(
            report["github_account_counts"],
            {"anyang-keepers": 1, "reviewer-keepers": 1},
        )
        self.assertNotIn(
            "docker_pr_approve_identity_pool_insufficient_unique_github_identities_1",
            report["fleet_failures"],
        )
        self.assertNotIn(
            "docker_pr_approve_account_pool_insufficient_unique_accounts_1",
            report["fleet_failures"],
        )

    def test_scan_keeper_evidence_reads_tool_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls_dir = root / ".masc" / "tool_calls" / "2026-05"
            calls_dir.mkdir(parents=True)
            rows = [
                {
                    "ts": 50.0,
                    "keeper": "alpha",
                    "tool": "keeper_bash",
                    "input": {"cmd": "git push -u origin keeper/proof"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 60.0,
                    "keeper": "alpha",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr review 123 --approve"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "command": "gh 'pr' 'review' '123' '--approve'",
                            "via": "docker",
                        }
                    ),
                    "success": True,
                },
                {
                    "ts": 70.0,
                    "keeper": "beta",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr create --draft"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
            ]
            (calls_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 60.0)
        self.assertEqual(tools, {"keeper_bash", "keeper_shell"})
        self.assertEqual(
            evidence,
            {"git_push:keeper_bash", "pr_approve:keeper_shell"},
        )
        self.assertEqual(docker_evidence, evidence)

    def test_scan_keeper_evidence_filters_pr_lifecycle_by_run_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls_dir = root / ".masc" / "tool_calls" / "2026-05"
            calls_dir.mkdir(parents=True)
            metrics_dir = (
                root / ".masc" / "keepers" / "alpha" / "pr-action-metrics" / "2026-05"
            )
            metrics_dir.mkdir(parents=True)
            rows = [
                {
                    "ts": 50.0,
                    "keeper": "alpha",
                    "tool": "keeper_bash",
                    "input": {"cmd": "git push -u origin keeper/old-run"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 60.0,
                    "keeper": "alpha",
                    "tool": "keeper_bash",
                    "input": {
                        "cmd": (
                            "git push -u origin "
                            "keeper/alpha-docker-pr-proof-current-run"
                        )
                    },
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
            ]
            (calls_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            metric_rows = [
                {
                    "ts_unix": 55.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "keeper_pr_create",
                    "pr_work_action": "PR_CREATE",
                    "pr_work_action_source": "keeper_pr_create",
                    "pr_work_action_success": True,
                    "pr_work_ref": "keeper/alpha-docker-pr-proof-old-run",
                    "route_via": "docker",
                },
                {
                    "ts_unix": 65.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "keeper_pr_create",
                    "pr_work_action": "PR_CREATE",
                    "pr_work_action_source": "keeper_pr_create",
                    "pr_work_action_success": True,
                    "pr_work_ref": "keeper/alpha-docker-pr-proof-current-run",
                    "pr_url": "https://github.com/acme/repo/pull/42",
                    "route_via": "docker",
                },
            ]
            (metrics_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in metric_rows),
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha", evidence_run_id="current-run"
            )

        self.assertEqual(latest_ts, 65.0)
        self.assertEqual(tools, {"keeper_bash", "keeper_pr_create"})
        self.assertEqual(
            evidence, {"git_push:keeper_bash", "pr_create:keeper_pr_create"}
        )
        self.assertEqual(docker_evidence, evidence)

    def test_run_id_filter_counts_redacted_approval_by_correlated_pr_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            alpha_metrics_dir = (
                root / ".masc" / "keepers" / "alpha" / "pr-action-metrics" / "2026-05"
            )
            bravo_metrics_dir = (
                root / ".masc" / "keepers" / "bravo" / "pr-action-metrics" / "2026-05"
            )
            alpha_metrics_dir.mkdir(parents=True)
            bravo_metrics_dir.mkdir(parents=True)
            current_run = "current-run"
            (alpha_metrics_dir / "06.jsonl").write_text(
                "".join(
                    json.dumps(row) + "\n"
                    for row in [
                        {
                            "ts_unix": 10.0,
                            "metric_event": "keeper_pr_work_action",
                            "tool_name": "keeper_bash",
                            "pr_work_action": "GIT_PUSH",
                            "pr_work_action_source": "keeper_bash",
                            "pr_work_action_success": True,
                            "pr_work_command": "git push origin alpha-old-run",
                            "route_via": "docker",
                        },
                        {
                            "ts_unix": 20.0,
                            "metric_event": "keeper_pr_work_action",
                            "tool_name": "keeper_bash",
                            "pr_work_action": "GIT_PUSH",
                            "pr_work_action_source": "keeper_bash",
                            "pr_work_action_success": True,
                            "pr_work_command": f"git push origin alpha-{current_run}",
                            "route_via": "docker",
                        },
                        {
                            "ts_unix": 30.0,
                            "metric_event": "keeper_pr_work_action",
                            "tool_name": "keeper_pr_create",
                            "pr_work_action": "PR_CREATE",
                            "pr_work_action_source": "keeper_pr_create",
                            "pr_work_action_success": True,
                            "pr_work_ref": f"keeper-alpha/{current_run}",
                            "pr_url": "https://github.com/acme/repo/pull/100",
                            "route_via": "docker",
                        },
                        {
                            "ts_unix": 40.0,
                            "metric_event": "keeper_pr_review_action",
                            "tool_name": "keeper_pr_review_comment",
                            "pr_review_action": "APPROVE",
                            "pr_review_action_success": True,
                            "pr_number": 999,
                            "route_via": "docker",
                        },
                        {
                            "ts_unix": 50.0,
                            "metric_event": "keeper_pr_review_action",
                            "tool_name": "keeper_pr_review_comment",
                            "pr_review_action": "APPROVE",
                            "pr_review_action_success": True,
                            "pr_number": 101,
                            "route_via": "docker",
                        },
                    ]
                ),
                encoding="utf-8",
            )
            (bravo_metrics_dir / "06.jsonl").write_text(
                json.dumps(
                    {
                        "ts_unix": 25.0,
                        "metric_event": "keeper_pr_work_action",
                        "tool_name": "keeper_pr_create",
                        "pr_work_action": "PR_CREATE",
                        "pr_work_action_source": "keeper_pr_create",
                        "pr_work_action_success": True,
                        "pr_work_ref": f"keeper-bravo/{current_run}",
                        "pr_url": "https://github.com/acme/repo/pull/101",
                        "route_via": "docker",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            run_pr_numbers = audit.collect_evidence_run_pr_numbers(root, current_run)
            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root,
                "alpha",
                evidence_run_id=current_run,
                evidence_run_pr_numbers=run_pr_numbers,
            )

        self.assertEqual(run_pr_numbers, {100, 101})
        self.assertEqual(latest_ts, 50.0)
        self.assertEqual(
            tools,
            {"keeper_bash", "keeper_pr_create", "keeper_pr_review_comment"},
        )
        self.assertEqual(
            evidence,
            {
                "git_push:keeper_bash",
                "pr_approve:keeper_pr_review_comment",
                "pr_create:keeper_pr_create",
            },
        )
        self.assertEqual(docker_evidence, evidence)

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
                    "tool": "keeper_bash",
                    "input": {"cmd": "git push -u origin keeper/old"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 20.0,
                    "keeper": "alpha",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr create --draft"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 30.0,
                    "keeper": "alpha",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr review 1 --approve"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "command": "gh pr review 1 --approve",
                            "via": "docker",
                        }
                    ),
                    "success": True,
                },
            ]
            new_rows = [
                {
                    "ts": 70.0,
                    "keeper": "alpha",
                    "tool": "keeper_bash",
                    "input": {"cmd": "git push -u origin keeper/new"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 80.0,
                    "keeper": "alpha",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr create --draft"},
                    "output": json.dumps({"ok": True, "via": "docker"}),
                    "success": True,
                },
                {
                    "ts": 90.0,
                    "keeper": "alpha",
                    "tool": "keeper_shell",
                    "input": {"op": "gh", "cmd": "pr review 2 --approve"},
                    "output": json.dumps(
                        {
                            "ok": True,
                            "command": "gh pr review 2 --approve",
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

            latest_ts, _tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 90.0)
        self.assertEqual(
            evidence,
            {
                "git_push:keeper_bash",
                "pr_create:keeper_shell",
                "pr_approve:keeper_shell",
            },
        )
        self.assertEqual(docker_evidence, evidence)


if __name__ == "__main__":
    unittest.main()
