from contextlib import redirect_stderr
import importlib.util
import io
import sys
import tempfile
from types import SimpleNamespace
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "produce_natural_keeper_skill_proof.py"
)
sys.path.insert(0, str(SCRIPT_PATH.parent))


def load_module():
    spec = importlib.util.spec_from_file_location(
        "produce_natural_keeper_skill_proof", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


producer = load_module()
HEAD = "a" * 40
TREE = "b" * 40
SOURCE_FINGERPRINT = "c" * 64
EXECUTABLE_SHA256 = "d" * 64
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"


def source():
    return {"head": HEAD, "tree": TREE, "tracked_changes": []}


def status():
    return {
        "name": "keeper-one",
        "model_observability": {"runtime_id": "runtime-one"},
    }


def acceptance():
    return {
        "operation_id": "kmsg-exact-one",
        "state": "queued",
        "queued_count": 1,
        "existing": False,
    }


MESSAGE = "Please investigate this naturally.\n"


def operation_source(submitted_by="proof-operator"):
    return {
        "schema": "masc.keeper_chat_operation.source.v1",
        "submitted_by": submitted_by,
        "thread_id": "keeper:keeper-one",
        "continuation_channel": {
            "kind": "dashboard",
            "thread_id": "keeper:keeper-one",
        },
        "surface": {"kind": "agent"},
        "channel": "agent",
        "channel_user_id": "",
        "channel_user_name": "",
        "channel_workspace_id": "",
        "conversation_id": None,
        "external_message_id": None,
        "workspace_id": None,
        "extra_mentions": [],
        "user_row_origin": "needs_append",
    }


def operation(state, **fields):
    operation_input = producer.direct_message_input(MESSAGE)
    value = {
        "schema": "masc.keeper_chat_operation.v1",
        "operation_id": "kmsg-exact-one",
        "sequence": "7",
        "created_at": 1.0,
        "execution_digest": producer.canonical_json_digest(operation_input),
        "source": operation_source(),
        "input": operation_input if state in ("Queued", "Running") else None,
        "state": state,
    }
    value.update(fields)
    return value


class FakeTransport:
    def __init__(
        self,
        operations,
        *,
        producer_error=None,
        caller_agent_id: str | None = "proof-operator",
    ):
        self.operations = list(operations)
        self.producer_error = producer_error
        self.caller_agent_id = caller_agent_id
        self.calls = []

    def call_tool(self, name, arguments):
        self.calls.append((name, arguments))
        if name == "masc_keeper_status":
            return status()
        if name == "masc_keeper_msg":
            if self.producer_error is not None:
                raise self.producer_error
            return acceptance()
        if name == "masc_keeper_delegate_status":
            if not self.operations:
                raise AssertionError("unexpected status poll")
            return self.operations.pop(0)
        raise AssertionError(f"unexpected tool {name}")


def run(transport, **overrides):
    arguments = {
        "transport": transport,
        "keeper": "keeper-one",
        "runtime_id": "runtime-one",
        "message": MESSAGE,
        "message_raw": MESSAGE.encode(),
        "source_before": source(),
        "source_snapshot_fn": source,
        "observation_timeout": 10.0,
        "poll_interval": 1.0,
        "monotonic": lambda: 0.0,
        "sleep": lambda _seconds: None,
    }
    arguments.update(overrides)
    return producer.run_producer(**arguments)


class NaturalKeeperSkillProofProducerTest(unittest.TestCase):
    def test_health_binds_dune_inputs_and_executable_bytes(self):
        health = {
            "health_detail": "full",
            "build": {
                "binary_commit": HEAD,
                "binary_commit_source": "embedded",
                "source_fingerprint": SOURCE_FINGERPRINT,
                "executable_sha256": EXECUTABLE_SHA256,
                "executable_provenance_path": "/private/provenance.json",
                "executable_provenance_sha256": "e" * 64,
                "runtime_instance_id": INSTANCE,
                "started_at": "2026-08-27T00:00:00Z",
            },
            "paths": {
                "effective_base_path": "/workspace",
                "effective_masc_root": "/workspace/.masc",
            },
        }

        identity = producer.validate_health(
            health, source=source(), expected_base_path="/workspace"
        )

        self.assertEqual(identity["source_fingerprint"], SOURCE_FINGERPRINT)
        self.assertEqual(identity["executable_sha256"], EXECUTABLE_SHA256)
        del health["build"]["source_fingerprint"]
        with self.assertRaisesRegex(producer.ProducerError, "source_fingerprint"):
            producer.validate_health(
                health, source=source(), expected_base_path="/workspace"
            )

    def test_mcp_initialize_sends_initialized_notification(self):
        client = producer.McpClient(
            "http://127.0.0.1:8935/mcp", "secret", 1.0, "test-version"
        )

        def initialize_request(method, params):
            self.assertEqual(method, "initialize")
            self.assertEqual(params["protocolVersion"], "test-version")
            client.session_id = "session-one"
            return {"jsonrpc": "2.0", "id": 1, "result": {}}

        with (
            mock.patch.object(client, "request", side_effect=initialize_request),
            mock.patch.object(client, "notify") as notify,
        ):
            client.initialize()

        notify.assert_called_once_with("notifications/initialized", {})

    def test_mcp_tool_result_binds_caller_agent_identity(self):
        client = producer.McpClient(
            "http://127.0.0.1:8935/mcp", "secret", 1.0, "test-version"
        )
        response = {
            "result": {
                "isError": False,
                "_meta": {
                    "com.github.yousleepwhen.masc/call": {
                        "agent_id": "proof-operator"
                    }
                },
                "structuredContent": {"name": "keeper-one"},
            }
        }
        with mock.patch.object(client, "request", return_value=response):
            self.assertEqual(
                client.call_tool("masc_keeper_status", {}), {"name": "keeper-one"}
            )
        self.assertEqual(client.caller_agent_id, "proof-operator")

    def test_expected_source_sha_is_explicit(self):
        producer.validate_expected_source(source(), HEAD)
        with self.assertRaisesRegex(producer.ProducerError, "differs from expected"):
            producer.validate_expected_source(source(), "0" * 40)

    def test_server_restart_during_production_is_rejected(self):
        before = {
            "binary_commit": HEAD,
            "runtime_instance_id": "instance-one",
            "started_at": "2026-08-27T00:00:00Z",
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        }
        after = {**before, "started_at": "2026-08-27T00:01:00Z"}
        with self.assertRaisesRegex(producer.ProducerError, "server identity changed"):
            producer.require_same_server(before, after)
        same_second_restart = {**before, "runtime_instance_id": "instance-two"}
        with self.assertRaisesRegex(producer.ProducerError, "server identity changed"):
            producer.require_same_server(before, same_second_restart)

    def test_success_submits_exactly_once_and_preserves_exact_turn_reference(self):
        transport = FakeTransport(
            [
                operation("Queued"),
                operation("Running", started_at=2.0),
                operation("Succeeded", completed_at=3.0, outcome_ref="trace-one#9"),
            ]
        )

        receipt = run(transport)

        producer_calls = [
            call for call in transport.calls if call[0] == "masc_keeper_msg"
        ]
        self.assertEqual(len(producer_calls), 1)
        self.assertEqual(
            producer_calls[0][1],
            {
                "name": "keeper-one",
                "message": MESSAGE,
            },
        )
        self.assertEqual(receipt["operation"]["turn_ref"], "trace-one#9")
        self.assertEqual(
            receipt["operation"]["expected_operation_input_digest"],
            producer.canonical_json_digest(producer.direct_message_input(MESSAGE)),
        )
        self.assertIsNone(receipt["skill_tool_use_id"])
        self.assertIsNone(receipt["actual_invocation_runtime_id"])
        self.assertEqual(receipt["producer_calls"], {"masc_keeper_msg": 1})
        self.assertEqual(receipt["submitted_by"], "proof-operator")

    def test_transport_ambiguity_does_not_resubmit_producer_call(self):
        transport = FakeTransport(
            [], producer_error=producer.ProducerError("ambiguous")
        )

        with self.assertRaisesRegex(producer.ProducerError, "ambiguous"):
            run(transport)

        self.assertEqual(
            len([call for call in transport.calls if call[0] == "masc_keeper_msg"]),
            1,
        )

    def test_failed_terminal_is_not_success(self):
        transport = FakeTransport(
            [
                operation(
                    "Failed",
                    completed_at=3.0,
                    failure_kind="Turn_exception",
                    failure_detail="provider failed",
                    outcome_ref=None,
                )
            ]
        )

        with self.assertRaisesRegex(producer.ProducerError, "terminated as Failed"):
            run(transport)

    def test_cancelled_terminal_is_not_success(self):
        transport = FakeTransport([operation("Cancelled", completed_at=3.0)])

        with self.assertRaisesRegex(producer.ProducerError, "terminated as Cancelled"):
            run(transport)

    def test_unknown_operation_state_is_rejected(self):
        transport = FakeTransport([operation("Finished")])

        with self.assertRaisesRegex(producer.ProducerError, "state is unknown"):
            run(transport)

    def test_observation_timeout_is_not_success(self):
        transport = FakeTransport([operation("Queued")])

        with self.assertRaisesRegex(producer.ProducerError, "observation boundary"):
            run(transport, monotonic=iter([0.0, 10.0]).__next__)

        self.assertEqual(
            len([call for call in transport.calls if call[0] == "masc_keeper_msg"]),
            1,
        )

    def test_source_drift_after_terminal_is_rejected(self):
        transport = FakeTransport(
            [operation("Succeeded", completed_at=3.0, outcome_ref="trace-one#9")]
        )
        changed = {"head": "d" * 40, "tree": TREE, "tracked_changes": []}

        with self.assertRaisesRegex(producer.ProducerError, "source checkout changed"):
            run(transport, source_snapshot_fn=lambda: changed)

    def test_runtime_mismatch_is_rejected_before_producer_call(self):
        transport = FakeTransport([])
        original = status

        def mismatched_status():
            value = original()
            value["model_observability"]["runtime_id"] = "runtime-two"
            return value

        transport.call_tool = lambda name, arguments: (
            transport.calls.append((name, arguments))
            or (mismatched_status() if name == "masc_keeper_status" else acceptance())
        )

        with self.assertRaisesRegex(producer.ProducerError, "runtime differs"):
            run(transport)

        self.assertEqual(
            len([call for call in transport.calls if call[0] == "masc_keeper_msg"]),
            0,
        )

    def test_missing_mcp_caller_identity_is_rejected_before_producer_call(self):
        transport = FakeTransport([], caller_agent_id=None)
        with self.assertRaisesRegex(producer.ProducerError, "submitting agent"):
            run(transport)
        self.assertEqual(
            len([call for call in transport.calls if call[0] == "masc_keeper_msg"]),
            0,
        )

    def test_rejects_url_credentials(self):
        with self.assertRaisesRegex(
            producer.ProducerError, "must not contain credentials"
        ):
            producer.canonical_base_url("http://user:secret@127.0.0.1:8935")

    def test_operation_fields_are_closed(self):
        malformed = operation(
            "Succeeded",
            completed_at=3.0,
            outcome_ref="trace-one#9",
            guessed_skill_tool_use_id="call-1",
        )
        transport = FakeTransport([malformed])

        with self.assertRaisesRegex(producer.ProducerError, "fields differ"):
            run(transport)

    def test_foreign_operation_owner_is_rejected(self):
        terminal = operation("Succeeded", completed_at=3.0, outcome_ref="trace-one#9")
        terminal["source"] = operation_source("foreign-owner")
        with self.assertRaisesRegex(producer.ProducerError, "direct-message source"):
            run(FakeTransport([terminal]))

    def test_operation_execution_digest_must_match_message(self):
        terminal = operation("Succeeded", completed_at=3.0, outcome_ref="trace-one#9")
        terminal["execution_digest"] = "0" * 64
        with self.assertRaisesRegex(producer.ProducerError, "execution digest differs"):
            run(FakeTransport([terminal]))

    def test_success_turn_ref_must_be_canonical(self):
        terminal = operation(
            "Succeeded", completed_at=3.0, outcome_ref="not-a-turn-ref"
        )
        with self.assertRaisesRegex(
            producer.ProducerError, "turn_ref is not canonical"
        ):
            run(FakeTransport([terminal]))

    def test_failed_run_leaves_incomplete_marker_and_no_receipt(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source_repo = root / "repo"
            base_path = root / "base"
            source_repo.mkdir()
            base_path.mkdir()
            output = root / "evidence"
            args = SimpleNamespace(
                base_url="http://127.0.0.1:8935",
                request_timeout_seconds=1.0,
                source_repo=source_repo,
                expected_source_sha=HEAD,
                expected_base_path=str(base_path),
                token_file=root / "token",
                message_file=root / "message",
                out=output,
                mcp_protocol_version="test-version",
                keeper="keeper-one",
                runtime_id="runtime-one",
                observation_timeout_seconds=1.0,
                poll_interval_seconds=0.1,
            )
            client = mock.Mock()
            with (
                mock.patch.object(producer, "parse_args", return_value=args),
                mock.patch.object(producer, "read_secret", return_value="secret"),
                mock.patch.object(
                    producer,
                    "read_message",
                    return_value=("natural message", b"natural message"),
                ),
                mock.patch.object(producer, "source_snapshot", return_value=source()),
                mock.patch.object(producer, "read_health", return_value={}),
                mock.patch.object(
                    producer,
                    "validate_health",
                    return_value={
                        "binary_commit": HEAD,
                        "runtime_instance_id": "instance-one",
                        "started_at": "now",
                        "effective_base_path": str(base_path),
                        "effective_masc_root": str(base_path / ".masc"),
                    },
                ),
                mock.patch.object(producer, "McpClient", return_value=client),
                mock.patch.object(
                    producer,
                    "run_producer",
                    side_effect=producer.ProducerError("terminal failure"),
                ),
            ):
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(producer.main(), 1)

            self.assertTrue((output / "INCOMPLETE").is_file())
            self.assertFalse((output / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
