import contextlib
import email.message
import importlib.util
import inspect
import io
import json
import re
import sys
import tempfile
import tomllib
import unittest
import unittest.mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "keeper_multi_collaboration_acceptance.py"
)
CATALOG_PATH = (
    REPO_ROOT
    / "scripts"
    / "fixtures"
    / "keeper-multi-collaboration"
    / "missions.json"
)
# Spelled out whole: PR CI picks the suites that name a changed file as an
# exact string literal, so an edit to one fixture runs this suite.
COMPOSITION_FIXTURE_SOURCES = {
    "acceptance-inline-probe": "scripts/fixtures/keeper-multi-collaboration/skills/acceptance-inline-probe/SKILL.md",
    "acceptance-async-probe": "scripts/fixtures/keeper-multi-collaboration/skills/acceptance-async-probe/SKILL.md",
}


def load_acceptance_module():
    spec = importlib.util.spec_from_file_location(
        "keeper_multi_collaboration_acceptance",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


acceptance = load_acceptance_module()


def skill_identity(name, *, source_id="fixture", package_id=None):
    return {
        "source_id": source_id,
        "package_id": package_id or name,
        "name": name,
    }


def skill_reference(name, revision, *, source_id="fixture", package_id=None):
    return {
        "identity": skill_identity(
            name,
            source_id=source_id,
            package_id=package_id,
        ),
        "content_revision": revision,
    }


def published_skill(name, revision, *, source_id="fixture", package_id=None):
    return skill_reference(
        name,
        revision,
        source_id=source_id,
        package_id=package_id,
    )


class KeeperMultiCollaborationAcceptanceTest(unittest.TestCase):
    def test_runtime_by_role_requires_exact_five_role_object(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }

        parsed = acceptance.parse_runtime_by_role(json.dumps(mapping))

        self.assertEqual(parsed, mapping)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "exact five roles"):
            acceptance.parse_runtime_by_role(
                json.dumps({"coordinator": "runtime-a"})
            )

    def test_heterogeneous_runtime_mode_refuses_duplicates_and_fallback_mix(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        acceptance.validate_runtime_strategy(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        duplicate = dict(mapping)
        duplicate["researcher"] = "runtime-a"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "five distinct"):
            acceptance.validate_runtime_strategy(
                runtime_id=None,
                runtime_by_role=duplicate,
                require_heterogeneous=True,
            )
        with self.assertRaisesRegex(acceptance.AcceptanceError, "mutually exclusive"):
            acceptance.validate_runtime_strategy(
                runtime_id="fallback",
                runtime_by_role=mapping,
                require_heterogeneous=False,
            )

    def test_runtime_strategy_receipt_is_exact_and_fail_closed(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        receipt = acceptance.runtime_strategy_receipt(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        self.assertEqual(receipt["runtime_strategy"], "heterogeneous_required")
        self.assertEqual(receipt["runtime_by_role"], mapping)
        self.assertEqual(receipt["distinct_runtime_count"], 5)

        with self.assertRaisesRegex(
            acceptance.AcceptanceError, "exact runtime selection"
        ):
            acceptance.runtime_strategy_receipt(
                runtime_id=None,
                runtime_by_role={},
                require_heterogeneous=False,
            )

    def test_sandbox_profiles_pin_the_keeper_up_tool_enum(self):
        toml_text = (REPO_ROOT / "config" / "tools" / "masc_keeper_up.toml").read_text()
        match = re.search(
            r'name = "sandbox_profile"\n(?:.*\n){0,3}?enum = \[([^\]]*)\]', toml_text
        )
        self.assertIsNotNone(match, "masc_keeper_up.toml declares no sandbox_profile enum")
        server_profiles = tuple(re.findall(r'"([^"]+)"', match.group(1)))
        self.assertEqual(acceptance.SANDBOX_PROFILES, server_profiles)

    def test_every_keeper_up_call_uses_the_configured_profile_and_never_local(self):
        module_source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"sandbox_profile": "local"', module_source)
        self.assertNotIn("ALLOW_LOCAL_PLAYGROUND", module_source)
        keeper_up_calls = module_source.count('"masc_keeper_up"')
        self.assertEqual(keeper_up_calls, 2)
        self.assertEqual(
            module_source.count('"sandbox_profile": self.sandbox_profile'), keeper_up_calls
        )
        for method in (
            acceptance.MissionRun.create_fleet,
            acceptance.MissionRun.restart_and_recall,
        ):
            source = inspect.getsource(method)
            self.assertIn('"sandbox_profile": self.sandbox_profile', source)
            self.assertNotIn('"local"', source)

    def test_every_keeper_up_is_followed_by_the_unattended_stance(self):
        module_source = SCRIPT_PATH.read_text(encoding="utf-8")
        keeper_up_calls = module_source.count('"masc_keeper_up"')
        self.assertEqual(keeper_up_calls, 2)
        self.assertEqual(module_source.count("self.declare_unattended("), keeper_up_calls)
        for method, declare in (
            (acceptance.MissionRun.create_fleet, "self.declare_unattended(role)"),
            (
                acceptance.MissionRun.restart_and_recall,
                'self.declare_unattended("coordinator")',
            ),
        ):
            source = inspect.getsource(method)
            self.assertLess(source.index('"masc_keeper_up"'), source.index(declare))

    def test_unattended_stance_pins_the_server_route_and_mode(self):
        dashboard = (
            REPO_ROOT / "lib" / "server" / "server_routes_http_routes_dashboard.ml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            f'Http.Router.post "{acceptance.TOOL_APPROVAL_MODE_ROUTE}"', dashboard
        )
        mode_source = (
            REPO_ROOT / "lib" / "keeper" / "keeper_tool_approval_mode.ml"
        ).read_text(encoding="utf-8")
        self.assertIn(f'| "{acceptance.TOOL_APPROVAL_MODE_UNATTENDED}" ->', mode_source)
        self.assertEqual(
            acceptance.default_tool_approval_mode_url("http://127.0.0.1:9418/mcp"),
            "http://127.0.0.1:9418/api/v1/keepers/tool-approval-mode",
        )

    def test_set_tool_approval_mode_posts_the_stance_and_fails_closed(self):
        seen = {}
        url = "http://h/api/v1/keepers/tool-approval-mode"

        class Response:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return self.body

        def fake_urlopen(request, timeout):
            seen["method"] = request.get_method()
            seen["auth"] = request.get_header("Authorization")
            seen["body"] = json.loads(request.data.decode("utf-8"))
            return Response(seen["reply"])

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", fake_urlopen):
            seen["reply"] = b'{"keeper":"rw-x-build-a","mode":"yolo"}'
            echo = acceptance.set_tool_approval_mode(
                url, "tok", 5.0, keeper="rw-x-build-a", mode="yolo"
            )
            self.assertEqual(echo, {"keeper": "rw-x-build-a", "mode": "yolo"})
            self.assertEqual(seen["method"], "POST")
            self.assertEqual(seen["auth"], "Bearer tok")
            self.assertEqual(seen["body"], {"name": "rw-x-build-a", "mode": "yolo"})
            seen["reply"] = b'{"keeper":"rw-x-build-a","mode":"auto"}'
            with self.assertRaisesRegex(acceptance.AcceptanceError, "echo mismatch"):
                acceptance.set_tool_approval_mode(
                    url, "tok", 5.0, keeper="rw-x-build-a", mode="yolo"
                )

        def forbidden(request, timeout):
            raise acceptance.urllib.error.HTTPError(
                request.full_url, 403, "Forbidden", {}, io.BytesIO(b"admin tier required")
            )

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", forbidden):
            with self.assertRaisesRegex(acceptance.AcceptanceError, "HTTP 403"):
                acceptance.set_tool_approval_mode(
                    url, "tok", 5.0, keeper="rw-x-build-a", mode="yolo"
                )

    def test_declare_unattended_records_the_echo_per_role(self):
        written = {}

        class Writer:
            def write_json(self, name, payload):
                written[name] = payload

        class Stub:
            roles = {"builder-a": "rw-x-build-a"}
            endpoint = "http://127.0.0.1:9418/mcp"
            token = "tok"
            timeout = 5.0
            writer = Writer()
            tool_approval_modes = {}

        calls = []

        def fake_set(url, token, timeout, *, keeper, mode):
            calls.append((url, token, timeout, keeper, mode))
            return {"keeper": keeper, "mode": mode}

        with unittest.mock.patch.object(acceptance, "set_tool_approval_mode", fake_set):
            acceptance.MissionRun.declare_unattended(Stub(), "builder-a")
        self.assertEqual(
            calls,
            [
                (
                    "http://127.0.0.1:9418/api/v1/keepers/tool-approval-mode",
                    "tok",
                    5.0,
                    "rw-x-build-a",
                    "yolo",
                )
            ],
        )
        self.assertEqual(Stub.tool_approval_modes, {"builder-a": "yolo"})
        self.assertEqual(
            written["observations/tool-approval-mode-builder-a.json"],
            {"keeper": "rw-x-build-a", "mode": "yolo"},
        )

    @staticmethod
    def board_page_response(offset, next_offset, text):
        return {
            "result": {
                "content": [{"type": "text", "text": text}],
                "_meta": {
                    acceptance.MASC_CALL_META_KEY: {
                        "metadata": {
                            acceptance.COMMENT_PAGE_METADATA_KEY: {
                                "offset": offset,
                                "returned": 1,
                                "total": 3,
                                "has_more": next_offset is not None,
                                "next_offset": next_offset,
                            }
                        }
                    }
                },
            }
        }

    def test_board_thread_read_follows_the_page_position_to_the_last_page(self):
        pages = {
            0: (2, "first COORDINATOR_READY"),
            2: (3, "second"),
            3: (None, "last REVIEWER_OBSERVED"),
        }
        calls = []
        outer = self

        class Stub:
            def call(self, label, tool, arguments):
                calls.append((label, tool, dict(arguments)))
                next_offset, text = pages[arguments["comment_offset"]]
                response = outer.board_page_response(
                    arguments["comment_offset"], next_offset, text
                )
                return acceptance.ToolObservation(tool, arguments, response, text, text)

        thread = acceptance.MissionRun.read_board_thread(Stub(), "p-1")
        self.assertEqual(
            [arguments["comment_offset"] for _, _, arguments in calls], [0, 2, 3]
        )
        self.assertTrue(
            all(
                arguments["comment_limit"] == acceptance.BOARD_COMMENT_PAGE_LIMIT
                for _, _, arguments in calls
            )
        )
        self.assertTrue(acceptance.text_contains(thread.data, "REVIEWER_OBSERVED"))
        self.assertTrue(acceptance.text_contains(thread.data, "COORDINATOR_READY"))
        self.assertIn("REVIEWER_OBSERVED", thread.text)

    def test_board_thread_read_refuses_a_page_that_does_not_move_forward(self):
        outer = self

        class Stub:
            def call(self, label, tool, arguments):
                response = outer.board_page_response(0, 0, "loop")
                return acceptance.ToolObservation(tool, arguments, response, "loop", "loop")

        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.MissionRun.read_board_thread(Stub(), "p-1")

    def test_board_thread_read_refuses_a_page_without_a_position(self):
        class Stub:
            def call(self, label, tool, arguments):
                return acceptance.ToolObservation(tool, arguments, {"result": {}}, "text", "text")

        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.MissionRun.read_board_thread(Stub(), "p-1")

    def test_run_refuses_to_start_without_a_turn_settle_budget(self):
        argv = ["acceptance", "--run", "--sandbox-profile", "microvm"]
        with unittest.mock.patch.object(sys, "argv", argv):
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                code = acceptance.main()
        self.assertEqual(code, 2)
        self.assertIn("--turn-settle-budget", stderr.getvalue())

    def test_turn_wait_uses_the_settle_budget_not_the_http_timeout(self):
        module_source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn("time.monotonic() + self.timeout", module_source)
        self.assertIn("time.monotonic() + self.turn_settle_budget_sec", module_source)
        self.assertIn(
            '"turn_settle_budget_sec": run.turn_settle_budget_sec', module_source
        )
        wrapper = (SCRIPT_PATH.parent / "keeper_multi_collaboration_acceptance.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('"--turn-settle-budget" "$KEEPER_COLLAB_TURN_SETTLE_BUDGET_SEC"', wrapper)

    @staticmethod
    def _http_429(url, body=b'{"error":"Too Many Requests","message":"Rate limit exceeded"}', retry_after="0"):
        headers = email.message.Message()
        headers["Retry-After"] = retry_after
        headers["X-RateLimit-Limit"] = "150"
        headers["X-RateLimit-Remaining"] = "0"
        return acceptance.urllib.error.HTTPError(url, 429, "Too Many Requests", headers, io.BytesIO(body))

    def test_mcp_client_retries_429_and_records_each_rejection(self):
        calls = []
        sleeps = []

        class Response:
            headers = email.message.Message()

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'

        def fake_urlopen(request, timeout):
            calls.append(request.full_url)
            if len(calls) <= 2:
                raise self._http_429(request.full_url)
            return Response()

        records = []
        client = acceptance.McpClient("http://h/mcp", "tok", 5.0)
        client.on_rate_limited = records.append
        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", fake_urlopen):
            with unittest.mock.patch.object(acceptance.time, "sleep", sleeps.append):
                value = client.request("tools/call", {"name": "masc_x", "arguments": {}})
        self.assertEqual(value["result"], {"ok": True})
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [0.0, 0.0])
        self.assertEqual([r["attempt"] for r in records], [1, 2])
        self.assertEqual(records[0]["tool"], "masc_x")
        self.assertEqual(records[0]["status"], 429)
        self.assertEqual(records[0]["headers"]["X-RateLimit-Remaining"], "0")
        self.assertIn("Rate limit exceeded", records[0]["body"])

    def test_mcp_client_gives_up_on_429_after_the_retry_budget(self):
        sleeps = []

        def always_429(request, timeout):
            raise self._http_429(request.full_url, retry_after="not-a-number")

        client = acceptance.McpClient("http://h/mcp", "tok", 5.0)
        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", always_429):
            with unittest.mock.patch.object(acceptance.time, "sleep", sleeps.append):
                with self.assertRaisesRegex(acceptance.AcceptanceError, "MCP HTTP 429"):
                    client.request("tools/call", {"name": "masc_x", "arguments": {}})
        self.assertEqual(len(sleeps), acceptance.RATE_LIMIT_RETRY_ATTEMPTS)
        self.assertEqual(set(sleeps), {acceptance.RATE_LIMIT_RETRY_FALLBACK_SEC})

    def test_dashboard_get_retries_429_then_returns_the_payload(self):
        calls = []
        recorded = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{"entries":[1]}'

        def fake_urlopen(request, timeout):
            calls.append(request.full_url)
            if len(calls) == 1:
                raise self._http_429(request.full_url)
            return Response()

        class Stub:
            endpoint = "http://127.0.0.1:9418/mcp"
            token = "tok"
            timeout = 5.0

            def record_rate_limited(self, record):
                recorded.append(record)

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", fake_urlopen):
            with unittest.mock.patch.object(acceptance.time, "sleep", lambda s: None):
                value = acceptance.MissionRun.dashboard_get(Stub(), "/api/v1/keepers/k/tool-calls")
        self.assertEqual(value, {"entries": [1]})
        self.assertEqual(calls, ["http://127.0.0.1:9418/api/v1/keepers/k/tool-calls"] * 2)
        self.assertEqual([r["method"] for r in recorded], ["GET"])

    def test_every_client_reports_429s_and_the_bundle_counts_them(self):
        module_source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertEqual(module_source.count("client.on_rate_limited = self.record_rate_limited"), 2)
        self.assertIn(
            '"transport_rate_limited_count": len(run.rate_limited_responses)', module_source
        )

    def test_run_refuses_to_start_without_a_sandbox_profile(self):
        with unittest.mock.patch.object(sys, "argv", ["acceptance", "--run"]):
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                code = acceptance.main()
        self.assertEqual(code, 2)
        self.assertIn("--sandbox-profile", stderr.getvalue())

    def test_goal_verifier_phase_failure_is_recorded_not_fatal(self):
        written = {}

        class Writer:
            def write_json(self, name, payload):
                written[name] = payload

        class Stub:
            verifier_goal_id = "goal-x"
            verifier_task_id = "task-9"
            writer = Writer()
            goal_verifier_evidence = {}

            def run_goal_verifier_refute_reenter_prove(self):
                raise acceptance.AcceptanceError("verifier Task has no completion verdict")

        stub = Stub()
        acceptance.MissionRun.run_goal_verifier_guarded(stub)
        self.assertEqual(stub.goal_verifier_evidence["failure"], acceptance.GOAL_VERIFIER_PHASE_FAILED)
        self.assertEqual(stub.goal_verifier_evidence["task_id"], "task-9")
        self.assertIn("no completion verdict", stub.goal_verifier_evidence["detail"])
        self.assertIn("observations/goal-verifier-failure.json", written)

    def test_run_sequence_guards_the_goal_verifier_phase(self):
        run_source = inspect.getsource(acceptance.MissionRun.run)
        self.assertIn("self.run_goal_verifier_guarded()", run_source)
        self.assertNotIn("self.run_goal_verifier_refute_reenter_prove()", run_source)
        self.assertIn("self.run_continuity_chain(post_id)", run_source)

    def test_catalog_has_exact_mission_and_assertion_counts(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        self.assertEqual(len(catalog["missions"]), 23)
        self.assertEqual(
            len(
                {
                    assertion
                    for mission in catalog["missions"]
                    for assertion in mission["assertions"]
                }
            ),
            49,
        )
        self.assertEqual(
            catalog["keeper_required_skill_identities"],
            [
                skill_identity(
                    acceptance.INLINE_FIXTURE,
                    source_id="project-masc",
                ),
                skill_identity(
                    acceptance.ASYNC_FIXTURE,
                    source_id="project-masc",
                ),
            ],
        )

    def test_required_exact_reference_resolves_from_snapshot(self):
        required_identity = skill_identity(acceptance.INLINE_FIXTURE)
        required_reference = skill_reference(acceptance.INLINE_FIXTURE, "a" * 64)
        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill(acceptance.INLINE_FIXTURE, "a" * 64)]},
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "composition",
                        "tool_name": "display-name-is-not-acceptance-authority",
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["required_skill_references"], [required_reference])
        self.assertEqual(report["missing_skill_references"], [])

    def test_composition_preflight_fails_on_unavailable_surface(self):
        required_identity = skill_identity("broken")
        required_reference = skill_reference("broken", "b" * 64)
        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill("broken", "b" * 64)]},
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "unavailable",
                        "error": "composition rejected",
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "surface_unavailable")
        self.assertEqual(report["missing_skill_references"], [required_reference])
        self.assertEqual(
            report["required_unavailable_surfaces"],
            [{"reference": required_reference, "error": "composition rejected"}],
        )

    def test_composition_preflight_rejects_same_name_at_another_revision(self):
        required_identity = skill_identity(acceptance.INLINE_FIXTURE)
        required_reference = skill_reference(acceptance.INLINE_FIXTURE, "a" * 64)
        other_revision = skill_reference(acceptance.INLINE_FIXTURE, "b" * 64)

        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill(acceptance.INLINE_FIXTURE, "a" * 64)]},
                "surfaces": [
                    {
                        "reference": other_revision,
                        "kind": "composition",
                        "tool_name": acceptance.INLINE_FIXTURE_TOOL,
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "missing_surfaces")
        self.assertEqual(report["required_skill_references"], [required_reference])
        self.assertEqual(report["missing_skill_references"], [required_reference])
        self.assertEqual(report["installed_skill_references"], [other_revision])

    def test_unrelated_unavailable_is_observed_without_blocking(self):
        required_identity = skill_identity(acceptance.INLINE_FIXTURE)
        required_reference = skill_reference(acceptance.INLINE_FIXTURE, "a" * 64)
        unrelated_reference = skill_reference("unrelated", "c" * 64)

        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {
                    "skills": [
                        published_skill(acceptance.INLINE_FIXTURE, "a" * 64),
                        published_skill("unrelated", "c" * 64),
                    ]
                },
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "composition",
                        "tool_name": acceptance.INLINE_FIXTURE_TOOL,
                    },
                    {
                        "reference": unrelated_reference,
                        "kind": "unavailable",
                        "error": "unrelated composition rejected",
                    },
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["required_unavailable_surfaces"], [])
        self.assertEqual(
            report["unavailable_surfaces"],
            [
                {
                    "reference": unrelated_reference,
                    "error": "unrelated composition rejected",
                }
            ],
        )

    @staticmethod
    def fixture_document(name):
        path = REPO_ROOT / COMPOSITION_FIXTURE_SOURCES[name]
        text = path.read_text(encoding="utf-8")
        opening = "```toml composition\n"
        start = text.index(opening) + len(opening)
        end = text.index("\n```", start)
        (composition,) = tomllib.loads(text[start:end])["compositions"]
        frontmatter = text.split("---\n", 2)[1]
        return text, frontmatter, composition

    def test_fixtures_declare_the_shape_the_assertions_judge(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)
        self.assertEqual(
            [
                identity["package_id"]
                for identity in catalog["keeper_required_skill_identities"]
            ],
            [acceptance.INLINE_FIXTURE, acceptance.ASYNC_FIXTURE],
        )
        self.assertIn(acceptance.INLINE_FIXTURE_TOOL, catalog["keeper_required_tools"])
        self.assertIn(acceptance.ASYNC_FIXTURE_TOOL, catalog["keeper_required_tools"])
        self.assertEqual(
            {
                identity["package_id"]: acceptance.composition_fixture_path(
                    catalog_path=CATALOG_PATH,
                    identity_key=acceptance.canonical_skill_identity_key(
                        identity, context="catalog"
                    ),
                )
                for identity in catalog["keeper_required_skill_identities"]
            },
            {
                name: REPO_ROOT / source
                for name, source in COMPOSITION_FIXTURE_SOURCES.items()
            },
        )

        for name in (acceptance.INLINE_FIXTURE, acceptance.ASYNC_FIXTURE):
            text, frontmatter, composition = self.fixture_document(name)
            self.assertEqual(text.count("```toml composition"), 1, name)
            self.assertEqual(composition["name"], name)
            self.assertIn(f"name: {name}\n", frontmatter)
            # The model reads the TOML description; the frontmatter carries the
            # same sentence so the catalog and the tool never disagree.
            self.assertIn(
                "description: " + json.dumps(composition["description"]) + "\n",
                frontmatter,
            )
            self.assertNotIn("params", composition)

        _, _, inline = self.fixture_document(acceptance.INLINE_FIXTURE)
        self.assertEqual(inline["execution"], "inline")
        nodes = {node["id"]: node for node in inline["nodes"]}
        self.assertEqual(
            [node["id"] for node in inline["nodes"]],
            list(acceptance.INLINE_FIXTURE_NODES),
        )
        for node_id in acceptance.INLINE_FIXTURE_PARALLEL_NODES:
            self.assertEqual(nodes[node_id]["input"]["kind"], "literal")
            self.assertNotIn("after", nodes[node_id])
        dataflow = nodes[acceptance.INLINE_FIXTURE_DATAFLOW_NODE]
        self.assertNotIn("after", dataflow)
        self.assertEqual(
            [
                field
                for field in dataflow["input"]["fields"]
                if field["value"]["kind"] == "output"
            ],
            [
                {
                    "name": acceptance.INLINE_FIXTURE_DATAFLOW_INPUT_FIELD,
                    "value": {
                        "kind": "output",
                        "node": acceptance.INLINE_FIXTURE_DATAFLOW_SOURCE_NODE,
                        "pointer": "/" + acceptance.INLINE_FIXTURE_DATAFLOW_SOURCE_FIELD,
                    },
                }
            ],
        )

        _, _, background = self.fixture_document(acceptance.ASYNC_FIXTURE)
        self.assertEqual(background["execution"], "async")
        self.assertEqual(
            [node["id"] for node in background["nodes"]],
            list(acceptance.ASYNC_FIXTURE_NODES),
        )

    def test_fixture_install_uses_the_skill_editor_routes_and_outcomes(self):
        dashboard = (
            REPO_ROOT / "lib" / "server" / "server_routes_http_routes_dashboard.ml"
        ).read_text(encoding="utf-8")
        for route in (
            acceptance.SKILL_EDITOR_CREATE_ROUTE,
            acceptance.SKILL_EDITOR_SAVE_ROUTE,
        ):
            self.assertIn(f'Http.Router.post "{route}"', dashboard)
        editor = (REPO_ROOT / "lib" / "server" / "server_skill_editor.ml").read_text(
            encoding="utf-8"
        )
        for outcomes in acceptance.SKILL_EDITOR_PUBLISHED_OUTCOMES.values():
            for outcome in outcomes:
                self.assertIn(f'"status", `String "{outcome}"', editor)

    @staticmethod
    def editor_outcome(status, identity_key, revision, batches=None):
        # The flow the server reports for a fixture, shaped as
        # Keeper_skill_observability.to_yojson writes it.
        planned = (
            acceptance.COMPOSITION_FIXTURE_BATCHES[identity_key[1]]
            if batches is None
            else batches
        )
        return {
            "status": status,
            "preview": {
                "profile": {
                    "reference": acceptance.skill_reference_json(
                        (*identity_key, revision)
                    ),
                    "flow": {
                        "nodes": [],
                        "batches": [
                            {"index": index, "execution_mode": mode, "node_ids": nodes}
                            for index, (mode, nodes) in enumerate(planned)
                        ],
                    },
                },
                "diagnostics": [],
            },
            "snapshot_revision": "snapshot-1",
        }

    def test_run_creates_unpublished_fixtures_and_saves_published_ones(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)
        inline_key = ("project-masc", acceptance.INLINE_FIXTURE, acceptance.INLINE_FIXTURE)
        async_key = ("project-masc", acceptance.ASYNC_FIXTURE, acceptance.ASYNC_FIXTURE)
        stale_async = acceptance.skill_reference_json((*async_key, "d" * 64))
        calls = []

        class Response:
            def __init__(self, value):
                self.value = value

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps(self.value).encode("utf-8")

        def fake_urlopen(request, timeout):
            body = json.loads(request.data.decode("utf-8"))
            calls.append((request.full_url, request.get_header("Authorization"), body))
            if request.full_url.endswith(acceptance.SKILL_EDITOR_CREATE_ROUTE):
                return Response(
                    self.editor_outcome("created_and_published", inline_key, "e" * 64)
                )
            return Response(
                self.editor_outcome("saved_and_published", async_key, "f" * 64)
            )

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", fake_urlopen):
            receipts = acceptance.install_composition_fixtures(
                catalog=catalog,
                catalog_path=CATALOG_PATH,
                skills={"state": "ready", "snapshot": {"skills": [stale_async]}},
                mcp_url="http://127.0.0.1:9418/mcp",
                token="tok",
                timeout=5.0,
            )

        inline_text, _, _ = self.fixture_document(acceptance.INLINE_FIXTURE)
        async_text, _, _ = self.fixture_document(acceptance.ASYNC_FIXTURE)
        self.assertEqual(
            calls,
            [
                (
                    "http://127.0.0.1:9418" + acceptance.SKILL_EDITOR_CREATE_ROUTE,
                    "Bearer tok",
                    {
                        "source_id": "project-masc",
                        "package_id": acceptance.INLINE_FIXTURE,
                        "source_text": inline_text,
                    },
                ),
                (
                    "http://127.0.0.1:9418" + acceptance.SKILL_EDITOR_SAVE_ROUTE,
                    "Bearer tok",
                    {"reference": stale_async, "source_text": async_text},
                ),
            ],
        )
        self.assertEqual(
            [(receipt["status"], receipt["reference"]) for receipt in receipts],
            [
                (
                    "created_and_published",
                    acceptance.skill_reference_json((*inline_key, "e" * 64)),
                ),
                (
                    "saved_and_published",
                    acceptance.skill_reference_json((*async_key, "f" * 64)),
                ),
            ],
        )

    def test_fixture_install_fails_when_the_editor_did_not_publish(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)
        inline_key = ("project-masc", acceptance.INLINE_FIXTURE, acceptance.INLINE_FIXTURE)

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                outcome = KeeperMultiCollaborationAcceptanceTest.editor_outcome(
                    "created_but_unpublished", inline_key, "e" * 64
                )
                outcome["reason"] = "snapshot refresh failed"
                return json.dumps(outcome).encode("utf-8")

        with unittest.mock.patch.object(
            acceptance.urllib.request, "urlopen", lambda request, timeout: Response()
        ):
            with self.assertRaisesRegex(
                acceptance.AcceptanceError, "not published.*snapshot refresh failed"
            ):
                acceptance.install_composition_fixtures(
                    catalog=catalog,
                    catalog_path=CATALOG_PATH,
                    skills={"state": "ready", "snapshot": {"skills": []}},
                    mcp_url="http://127.0.0.1:9418/mcp",
                    token="tok",
                    timeout=5.0,
                )

        def conflict(request, timeout):
            raise acceptance.urllib.error.HTTPError(
                request.full_url,
                409,
                "Conflict",
                {},
                io.BytesIO(b'{"ok":false,"code":"package_already_exists"}'),
            )

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", conflict):
            with self.assertRaisesRegex(
                acceptance.AcceptanceError, "HTTP 409.*package_already_exists"
            ):
                acceptance.install_composition_fixtures(
                    catalog=catalog,
                    catalog_path=CATALOG_PATH,
                    skills={"state": "ready", "snapshot": {"skills": []}},
                    mcp_url="http://127.0.0.1:9418/mcp",
                    token="tok",
                    timeout=5.0,
                )

    def test_fixture_install_fails_when_the_server_plans_another_shape(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)
        inline_key = ("project-masc", acceptance.INLINE_FIXTURE, acceptance.INLINE_FIXTURE)
        # The dataflow node promoted into the first concurrent batch: every
        # node would still run, and the dataflow assertion would fail at the end.
        flattened = [
            (
                "concurrent",
                sorted(
                    [
                        *acceptance.INLINE_FIXTURE_PARALLEL_NODES,
                        acceptance.INLINE_FIXTURE_DATAFLOW_NODE,
                    ]
                ),
            )
        ]

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps(
                    KeeperMultiCollaborationAcceptanceTest.editor_outcome(
                        "created_and_published", inline_key, "e" * 64, flattened
                    )
                ).encode("utf-8")

        with unittest.mock.patch.object(
            acceptance.urllib.request, "urlopen", lambda request, timeout: Response()
        ):
            with self.assertRaisesRegex(acceptance.AcceptanceError, "is planned as"):
                acceptance.install_composition_fixtures(
                    catalog=catalog,
                    catalog_path=CATALOG_PATH,
                    skills={"state": "ready", "snapshot": {"skills": []}},
                    mcp_url="http://127.0.0.1:9418/mcp",
                    token="tok",
                    timeout=5.0,
                )

    def test_read_only_preflight_lists_pending_fixtures_and_needs_a_writable_source(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)
        operator_tools = set(catalog["operator_required_tools"])
        inline_key = ("project-masc", acceptance.INLINE_FIXTURE, acceptance.INLINE_FIXTURE)
        inline_reference = acceptance.skill_reference_json((*inline_key, "a" * 64))

        class Client:
            def __init__(self, url, token, timeout):
                pass

            def initialize(self):
                return None

            def list_tools(self):
                return operator_tools

        def no_request(request, timeout):
            raise AssertionError(f"read-only preflight sent: {request.full_url}")

        def run_preflight(skills, writable):
            with contextlib.ExitStack() as stack:
                stack.enter_context(
                    unittest.mock.patch.object(
                        acceptance,
                        "read_health",
                        lambda url, token, timeout: {
                            "paths": {"effective_base_path": "/campaign"}
                        },
                    )
                )
                stack.enter_context(unittest.mock.patch.object(acceptance, "McpClient", Client))
                stack.enter_context(
                    unittest.mock.patch.object(
                        acceptance, "read_skills", lambda url, token, timeout: skills
                    )
                )
                stack.enter_context(
                    unittest.mock.patch.object(
                        acceptance,
                        "read_writable_skill_source_ids",
                        lambda url, token, timeout: writable,
                    )
                )
                stack.enter_context(
                    unittest.mock.patch.object(
                        acceptance.urllib.request, "urlopen", no_request
                    )
                )
                return acceptance.preflight(
                    catalog=catalog,
                    catalog_path=CATALOG_PATH,
                    mcp_url="http://127.0.0.1:9418/mcp",
                    health_url="http://127.0.0.1:9418/health?full=1",
                    token="tok",
                    timeout=5.0,
                    expected_base_path="/campaign",
                    expected_source_sha=None,
                    install_fixtures=False,
                )

        empty = {"state": "ready", "snapshot": {"skills": []}, "surfaces": []}
        _, _, result = run_preflight(empty, ["project-masc"])
        self.assertEqual(result["status"], "passed")
        self.assertEqual(
            result["composition_surfaces"]["status"], "required_identity_not_published"
        )
        self.assertEqual(
            result["composition_fixture_installation"],
            {
                "requested": False,
                "receipts": [],
                "pending": sorted(
                    catalog["keeper_required_skill_identities"],
                    key=lambda identity: identity["package_id"],
                ),
                "published_more_than_once": [],
                "writable_source_ids": ["project-masc"],
            },
        )
        with self.assertRaisesRegex(acceptance.AcceptanceError, "not writable and ready"):
            run_preflight(empty, ["project-agents"])

        # One fixture pending does not excuse the other one being published
        # and refused as a composition.
        inline_refused = {
            "state": "ready",
            "snapshot": {"skills": [inline_reference]},
            "surfaces": [
                {"reference": inline_reference, "kind": "unavailable", "error": "rejected"}
            ],
        }
        with self.assertRaisesRegex(acceptance.AcceptanceError, "surface_unavailable|not ready"):
            run_preflight(inline_refused, ["project-masc"])

        published_twice = {
            "state": "ready",
            "snapshot": {
                "skills": [
                    inline_reference,
                    acceptance.skill_reference_json((*inline_key, "b" * 64)),
                ]
            },
            "surfaces": [],
        }
        with self.assertRaisesRegex(acceptance.AcceptanceError, "published more than once"):
            run_preflight(published_twice, ["project-masc"])

    def test_writable_sources_are_read_from_the_editor_sources_body(self):
        class Response:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return self.body

        seen = []

        def answer(body):
            def fake_urlopen(request, timeout):
                seen.append((request.get_method(), request.full_url, request.get_header("Authorization")))
                return Response(body)

            return fake_urlopen

        url = "http://127.0.0.1:9418" + acceptance.SKILL_EDITOR_SOURCES_ROUTE
        body = b'{"status":"ready","sources":[{"source_id":"project-masc"},{"source_id":"project-agents"}]}'
        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", answer(body)):
            self.assertEqual(
                acceptance.read_writable_skill_source_ids(url, "tok", 5.0),
                ["project-agents", "project-masc"],
            )
        self.assertEqual(seen, [("GET", url, "Bearer tok")])
        with unittest.mock.patch.object(
            acceptance.urllib.request, "urlopen", answer(b'{"status":"ready"}')
        ):
            with self.assertRaisesRegex(acceptance.AcceptanceError, "no source list"):
                acceptance.read_writable_skill_source_ids(url, "tok", 5.0)
        dashboard = (
            REPO_ROOT / "lib" / "server" / "server_routes_http_routes_dashboard.ml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            f'Http.Router.get "{acceptance.SKILL_EDITOR_SOURCES_ROUTE}"', dashboard
        )

    def test_fixture_install_never_writes_to_an_unpinned_workspace(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        def forbidden(request, timeout):
            raise AssertionError(f"request left before the workspace was pinned: {request.full_url}")

        with unittest.mock.patch.object(acceptance.urllib.request, "urlopen", forbidden):
            for base_path, source_sha in ((None, "a" * 40), ("", "a" * 40), ("/campaign", None)):
                with self.assertRaisesRegex(
                    acceptance.AcceptanceError, "--expected-base-path and --expected-source-sha"
                ):
                    acceptance.preflight(
                        catalog=catalog,
                        catalog_path=CATALOG_PATH,
                        mcp_url="http://127.0.0.1:9418/mcp",
                        health_url="http://127.0.0.1:9418/health?full=1",
                        token="tok",
                        timeout=5.0,
                        expected_base_path=base_path,
                        expected_source_sha=source_sha,
                        install_fixtures=True,
                    )

    def test_run_settles_every_precondition_before_preflight_writes(self):
        preflight_calls = []

        def recording_preflight(**kwargs):
            preflight_calls.append(kwargs)
            raise AssertionError("preflight ran before the run's preconditions settled")

        def forbidden(request, timeout):
            raise AssertionError(f"request left before preconditions settled: {request.full_url}")

        with tempfile.TemporaryDirectory() as tmp_name:
            tmp = Path(tmp_name)
            token_file = tmp / "token"
            token_file.write_text("tok", encoding="utf-8")
            full = [
                "acceptance",
                "--run",
                "--allow-mutation",
                "--sandbox-profile",
                "docker",
                "--turn-settle-budget",
                "300",
                "--expected-base-path",
                "/campaign",
                "--expected-source-sha",
                "a" * 40,
                "--token-file",
                str(token_file),
                "--browser-proof-script",
                str(tmp / "proof.mjs"),
                "--runtime-id",
                "runtime-a",
            ]

            def without(flag, has_value=True):
                index = full.index(flag)
                return full[:index] + full[index + (2 if has_value else 1):]

            occupied = tmp / "occupied"
            occupied.mkdir()
            (occupied / "left-over.json").write_text("{}", encoding="utf-8")
            cases = [
                (without("--expected-base-path") + ["--output-dir", str(tmp / "a")],
                 "--run requires exact --expected-base-path"),
                (without("--runtime-id") + ["--output-dir", str(tmp / "b")],
                 "exact runtime selection"),
                (full + ["--output-dir", str(occupied)], "output directory must be empty"),
                ([*full[:6], "0", *full[7:], "--output-dir", str(tmp / "c")],
                 "--turn-settle-budget must be positive"),
            ]
            for argv, message in cases:
                with unittest.mock.patch.object(sys, "argv", argv):
                    with unittest.mock.patch.object(acceptance, "preflight", recording_preflight):
                        with unittest.mock.patch.object(
                            acceptance.urllib.request, "urlopen", forbidden
                        ):
                            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                                code = acceptance.main()
                self.assertEqual(code, 2, message)
                self.assertIn(message, stderr.getvalue())
        self.assertEqual(preflight_calls, [])

    def test_catalog_has_exact_rw20_rw21_delivery_and_debate_missions(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        poc = catalog["missions"][18]
        self.assertEqual(poc["id"], "RW20")
        self.assertEqual(
            poc["assertions"],
            ["poc_execution_proof_observed", "poc_review_cites_execution"],
        )
        debate = catalog["missions"][19]
        self.assertEqual(debate["id"], "RW21")
        self.assertEqual(
            debate["assertions"],
            ["debate_restatement_faithful", "debate_verdict_cites_rebuttal"],
        )
        self.assertIn("tool_execute", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw22_coverage_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        coverage = catalog["missions"][20]
        self.assertEqual(coverage["id"], "RW22")
        self.assertEqual(
            coverage["assertions"],
            [
                "qa_coverage_execution_observed",
                "qa_coverage_passes_verification",
                "qa_coverage_review_matches_spec",
            ],
        )
        # The row exists to reject partial runs, so the tester must be able to
        # execute rather than only claim, and the work has to enter the typed
        # verification flow and actually pass it — submitting is not completing.
        self.assertIn("tool_execute", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_claim", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_done", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw23_goal_verifier_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        goal_verifier = catalog["missions"][21]
        self.assertEqual(goal_verifier["id"], "RW23")
        self.assertEqual(
            goal_verifier["assertions"],
            [
                "goal_verifier_refutation_observed",
                "goal_verifier_reentry_proven",
                "goal_verifier_dashboard_browser_observed",
            ],
        )
        self.assertIn("Goal", goal_verifier["capabilities"])
        self.assertIn("Browser", goal_verifier["capabilities"])
        self.assertIn("masc_goal_transition", catalog["operator_required_tools"])
        self.assertTrue(catalog["approaches_apply_to_each_mission"])
        self.assertEqual(
            [approach["id"] for approach in catalog["execution_approaches"]],
            ["A", "B", "C"],
        )

    def test_goal_verifier_convergence_budget_covers_one_retry_cycle(self):
        # The live worker re-arms retryable deferred reviews on the default
        # 60-second maintenance pulse. A 300-second evaluator request that
        # fails near its boundary still needs a complete second attempt.
        self.assertEqual(
            acceptance.goal_verifier_convergence_timeout(300.0),
            720.0,
        )
        wait_source = inspect.getsource(acceptance.MissionRun.wait_for_goal_state)
        self.assertIn("goal_verifier_convergence_timeout(self.timeout)", wait_source)

    def test_browser_proof_parent_outlives_inner_readiness_and_capture(self):
        self.assertEqual(acceptance.browser_proof_subprocess_timeout(300.0), 600.0)
        self.assertEqual(acceptance.browser_proof_subprocess_timeout(400.0), 800.0)
        capture_source = inspect.getsource(acceptance.MissionRun.capture_browser_proof)
        self.assertIn("browser_proof_subprocess_timeout(self.timeout)", capture_source)
        self.assertNotIn("timeout=120", capture_source)

    def test_runtime_serving_evidence_requires_exact_completed_receipt_per_role(self):
        keepers = {"coordinator": "keeper-c", "reviewer": "keeper-r"}
        expected = {"coordinator": "runtime-c", "reviewer": "runtime-r"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(failed["served_role_count"], 1)
            self.assertEqual(
                failed["roles"]["reviewer"]["fallback_receipt_count"], 1
            )

            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    ),
                    self.runtime_receipt(
                        "runtime-r", keeper_name="keeper-r", fallback=False
                    ),
                ],
            )
            passed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(passed["status"], "passed")
            self.assertEqual(passed["served_role_count"], 2)
            self.assertEqual(passed["distinct_served_runtime_count"], 2)

    def test_campaign_identity_slug_keeps_seconds_in_identity(self):
        first = acceptance.campaign_identity_slug("rw-20260821-090001", 16)
        second = acceptance.campaign_identity_slug("rw-20260821-090059", 16)

        self.assertNotEqual(first, second)
        self.assertLessEqual(len(first), 16)
        self.assertLessEqual(len(second), 16)

    def test_runtime_serving_evidence_rejects_stale_exact_receipt(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.append_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-c", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            role = failed["roles"]["coordinator"]
            self.assertEqual(role["baseline_manifest_line_count"], 1)
            self.assertEqual(role["current_run_receipt_row_count"], 1)
            self.assertEqual(role["exact_success_count"], 0)
            self.assertEqual(role["fallback_receipt_count"], 1)

    def test_runtime_serving_evidence_rejects_malformed_receipt_identity(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            malformed = self.runtime_receipt(
                "runtime-c", keeper_name="wrong-keeper", fallback=False
            )
            malformed["runtime_id"] = "different-top-level-runtime"
            self.write_runtime_receipts(base_path, "keeper-c", [malformed])

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            self.assertEqual(
                failed["roles"]["coordinator"]["exact_success_count"], 0
            )
            self.assertTrue(
                any("keeper_name mismatch" in error for error in failed["parse_errors"])
            )
            self.assertTrue(
                any(
                    "top-level runtime_id does not match decision" in error
                    for error in failed["parse_errors"]
                )
            )

    def test_rw23_task_is_not_exposed_to_autonomous_work_before_refutation(self):
        setup_source = inspect.getsource(acceptance.MissionRun.setup_product_state)
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # The success-token Task and verifier Goal both used to be visible
        # during fleet setup. The autonomous fleet completed them before RW23
        # could write the failing artifact. Create the Goal only inside the
        # directed RW23 phase. Goals are now an ownerless shared open set, so
        # no removed assignment/scope compatibility call may return.
        # Since RFC-0387 a created Goal is executing/idle at once; the runner
        # waits for that state (no criterion_state="viable" step remains)
        # before it creates the proof Task.
        self.assertNotIn("goal-verifier-task-create", setup_source)
        self.assertNotIn("goal-verifier-upsert", setup_source)
        self.assertNotIn("goal-verifier-assign", setup_source)
        self.assertNotIn("masc_goal_assign", setup_source)
        self.assertNotIn("active_goal_ids", setup_source)
        self.assertIn("goal-verifier-task-create", rw23_source)
        self.assertIn("goal-verifier-upsert", rw23_source)
        self.assertNotIn("goal-verifier-assign", rw23_source)
        self.assertNotIn("masc_goal_assign", rw23_source)
        self.assertLess(
            rw23_source.index("goal-verifier-upsert"),
            rw23_source.index('completion_state="idle"'),
        )
        self.assertLess(
            rw23_source.index('completion_state="idle"'),
            rw23_source.index("goal-verifier-task-create"),
        )
        self.assertLess(
            rw23_source.index("goal-verifier-task-create"),
            rw23_source.index("goal-verifier-refute-artifact"),
        )

    def test_rw23_uses_durable_verdict_without_parsing_board_text(self):
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # masc_tasks is a human-facing Board rendering in the live server. The
        # verifier history event is the typed durable authority for both the
        # rejected and approved transitions.
        self.assertNotIn("wait_for_verifier_task_status", rw23_source)
        self.assertEqual(rw23_source.count("wait_for_verifier_task_verdict"), 2)
        self.assertIn('wait_for_verifier_task_verdict("in_progress")', rw23_source)
        self.assertIn('wait_for_verifier_task_verdict("done")', rw23_source)

    def test_rw23_prompts_pin_canonical_artifact_path_and_original_task(self):
        run = object.__new__(acceptance.MissionRun)
        run.marker = "keeper-collab-contract"
        run.verifier_task_id = "task-009"
        run.verifier_artifact = "artifacts/keeper-collab-contract-goal-proof.txt"
        run.verifier_success_token = "GOAL_PROOF_PASS=keeper-collab-contract"

        refute = run._goal_verifier_refute_prompt(
            "GOAL_PROOF_FAIL=keeper-collab-contract"
        )
        proven = run._goal_verifier_proven_prompt()

        canonical_write = (
            "path='artifacts/keeper-collab-contract-goal-proof.txt'"
        )
        canonical_evidence = (
            "evidence_refs=['artifact:artifacts/"
            "keeper-collab-contract-goal-proof.txt']"
        )
        self.assertIn(canonical_write, refute)
        self.assertIn(canonical_write, proven)
        self.assertIn(canonical_evidence, refute)
        self.assertIn(canonical_evidence, proven)
        self.assertIn("path에 'playground/' 접두사", refute)
        self.assertIn("path에 'playground/' 접두사", proven)
        self.assertNotIn("playground의 artifacts/", refute)
        self.assertNotIn("playground의 artifacts/", proven)
        self.assertIn("task_id='task-009'", refute)
        self.assertIn("task_id='task-009'", proven)
        for forbidden_tool in (
            "keeper_task_release",
            "masc_add_task",
            "keeper_task_claim",
        ):
            self.assertIn(forbidden_tool, proven)
        self.assertIn("대체 Task를 만들거나 claim하지 마세요", proven)

    @staticmethod
    def runtime_receipt(runtime_id, *, keeper_name, fallback):
        return {
            "schema_version": 1,
            "ts": "2026-08-21T09:00:00Z",
            "keeper_name": keeper_name,
            "trace_id": f"trace-{runtime_id}",
            "keeper_turn_id": 1,
            "event": "receipt_appended",
            "runtime_id": runtime_id,
            "status": "ok",
            "decision": {
                "outcome": "ok",
                "runtime_id": runtime_id,
                "runtime_attempt_count": 1,
                "runtime_fallback_applied": fallback,
                "runtime_outcome": "completed",
            },
        }

    @staticmethod
    def write_runtime_receipts(base_path, keeper, rows):
        manifest_root = (
            base_path / ".masc" / "keepers" / keeper / "runtime-manifests"
        )
        manifest_root.mkdir(parents=True, exist_ok=True)
        (manifest_root / "trace.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows),
            encoding="utf-8",
        )

    @staticmethod
    def append_runtime_receipts(base_path, keeper, rows):
        manifest_path = (
            base_path
            / ".masc"
            / "keepers"
            / keeper
            / "runtime-manifests"
            / "trace.jsonl"
        )
        with manifest_path.open("a", encoding="utf-8") as handle:
            handle.write("".join(json.dumps(row) + "\n" for row in rows))


if __name__ == "__main__":
    unittest.main()
