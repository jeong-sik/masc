import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "capture-tui-keeper-chat.py"


def load_module():
    try:
        import playwright.sync_api  # noqa: F401
    except ModuleNotFoundError:
        playwright = types.ModuleType("playwright")
        sync_api = types.ModuleType("playwright.sync_api")
        sync_api.Browser = object
        sync_api.Frame = object
        sync_api.Page = object
        sync_api.TimeoutError = TimeoutError
        sync_api.sync_playwright = None
        playwright.sync_api = sync_api
        sys.modules["playwright"] = playwright
        sys.modules["playwright.sync_api"] = sync_api

    spec = importlib.util.spec_from_file_location(
        "capture_tui_keeper_chat", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


capture = load_module()


class CaptureTuiKeeperChatTest(unittest.TestCase):
    def test_request_label_matches_the_tui_twenty_cell_projection(self):
        request = {
            "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
            "name": "alpha",
            "message": "first",
        }
        label = capture.compact_request_label(request)
        self.assertEqual(label, "tui-01..0123456789ab")
        self.assertEqual(len(label), 20)

    def test_fixture_serves_current_workspace_and_keeper_roster(self):
        state = capture.Fixture("causal")
        state.workspace_base_path = "/tmp/masc-capture-contract"
        health = capture.fixture_static_response(state, "/health?full=1")
        roster = capture.fixture_static_response(
            state, "/api/v1/gate/keepers?detailed=true"
        )
        history = capture.fixture_static_response(state, capture.CHAT_HISTORY_GET)
        memory = capture.fixture_static_response(state, capture.MEMORY_JOURNAL_GET)
        self.assertIsInstance(health, dict)
        self.assertIsInstance(roster, dict)
        assert isinstance(health, dict)
        assert isinstance(roster, dict)
        self.assertEqual(
            health["paths"]["effective_base_path"],
            state.workspace_base_path,
        )
        self.assertEqual(health["keeper_fleet_safety"]["status"], "ok")
        self.assertEqual(roster["total"], 1)
        self.assertEqual(roster["keepers"][0]["name"], "alpha")
        self.assertEqual(roster["keepers"][0]["meta"]["sandbox_profile"], "docker")
        self.assertEqual(history, [])
        self.assertEqual(
            memory,
            {
                "keeper": "alpha",
                "returned": 0,
                "undecodable_lines": 0,
                "entries": [],
            },
        )
        state.record("GET", capture.CHAT_HISTORY_GET)
        self.assertEqual(state.summary()["unexpected_chat_route_count"], 0)

    def test_mcp_initialize_is_a_handshake_not_another_post(self):
        state = capture.Fixture("causal")
        handshake = state.record("POST", capture.MCP_POST)
        handshake["mcp_method"] = "initialize"
        tool_call = state.record("POST", capture.MCP_POST)
        tool_call["mcp_method"] = "tools/call"
        summary = state.summary()
        self.assertEqual(summary["mcp_initialize_count"], 1)
        self.assertEqual(summary["other_post_count"], 1)

    def test_keeper_meta_matches_current_strict_schema(self):
        meta = capture.current_keeper_meta()
        self.assertEqual(
            set(meta),
            {
                "schema",
                "name",
                "instructions",
                "trace_id",
                "trace_history",
                "created_at",
                "updated_at",
                "last_proactive_outcome",
                "last_proactive_reason",
                "last_proactive_preview",
                "message_scope_ack_id",
                "last_runtime_attempt",
                "paused",
                "latched_reason",
                "current_task_id",
                "keeper_id",
                "agent_core_env",
                "usage_cursor",
                "last_usage_resolution",
                "last_handoff_ts",
                "total_turns",
                "total_input_tokens",
                "total_output_tokens",
                "total_tokens",
                "total_cost_usd",
                "last_turn_ts",
                "last_input_tokens",
                "last_output_tokens",
                "last_total_tokens",
                "last_latency_ms",
                "proactive_count_total",
                "last_proactive_ts",
                "proactive_visible_count_total",
                "last_visible_proactive_ts",
            },
        )
        self.assertNotIn("agent_name", meta)
        self.assertNotIn("generation", meta)

    def test_unique_screen_line_requires_one_structural_row(self):
        text = "\n".join(
            [
                "ACTIVE TURN",
                "  NEXT 1 · 20:01:02 · queued-message",
                "Enter:queue(1)",
            ]
        )
        self.assertEqual(
            capture.unique_screen_line(text, "NEXT 1", "queued-message"),
            (1, "  NEXT 1 · 20:01:02 · queued-message"),
        )
        with self.assertRaises(AssertionError):
            capture.unique_screen_line(text, "missing")

    def test_causal_fixture_records_multiple_request_identities_in_order(self):
        state = capture.Fixture("causal")
        first = {
            "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
            "name": "alpha",
            "message": "first",
        }
        second = {
            "request_id": "tui-0198f0df-5678-7abc-9def-0123456789ab",
            "name": "alpha",
            "message": "second",
        }
        self.assertEqual(
            state.parse_request(json.dumps(first).encode()),
            first,
        )
        self.assertEqual(
            state.parse_request(json.dumps(second).encode()),
            second,
        )
        self.assertEqual(state.summary()["requests"], [first, second])
        self.assertEqual(capture.request_identity(state, "second"), second)

    def test_history_reloads_only_completed_causal_turns_in_typed_order(self):
        state = capture.Fixture("causal")
        first = {
            "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
            "name": "alpha",
            "message": "first",
        }
        second = {
            "request_id": "tui-0198f0df-5678-7abc-9def-0123456789ab",
            "name": "alpha",
            "message": "second",
        }
        state.note_submission("first", 10.0)
        state.note_submission("second", 20.0)
        state.parse_request(json.dumps(first).encode())
        state.parse_request(json.dumps(second).encode())
        state.complete_request(first["request_id"])

        first_history = state.chat_history()
        self.assertEqual(
            [row["role"] for row in first_history],
            ["user", "tool", "assistant"],
        )
        self.assertTrue(
            all(
                row["delivery_key"]["operation_id"] == first["request_id"]
                for row in first_history
            )
        )
        self.assertTrue(all(row["ts"] == 10.0 for row in first_history))

        state.complete_request(second["request_id"])
        history = state.chat_history()
        self.assertEqual(
            [row["role"] for row in history],
            ["user", "tool", "assistant", "user", "assistant"],
        )
        self.assertEqual(history[3]["ts"], 20.0)
        self.assertEqual(history[4]["content"], "reply-second")

    def test_stream_payload_carries_reply_and_structural_turn_sequence(self):
        request = {
            "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
            "name": "alpha",
            "message": "queued",
        }
        payload = capture.stream_payload(
            request,
            True,
            reply="reply-queued",
            turn_sequence=2,
        ).decode()
        self.assertIn('"delta":"reply-queued"', payload)
        self.assertIn('"turn_ref":"trace-chat#2"', payload)
        self.assertIn('"timestamp":1.0', payload)

    def test_first_stream_payload_places_tool_before_reply_at_one_timestamp(self):
        request = {
            "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
            "name": "alpha",
            "message": "first",
        }
        payload = capture.stream_payload(
            request,
            True,
            reply="reply-first",
            turn_sequence=1,
        ).decode()
        self.assertLess(payload.index("TOOL_CALL_START"), payload.index("reply-first"))
        self.assertIn("KEEPER_TOOL_RESULT_READY", payload)
        self.assertEqual(payload.count('"timestamp":1.0'), 11)


if __name__ == "__main__":
    unittest.main()
