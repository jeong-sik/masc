"""HITL's shared Exact store keeps terminals without their input body."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
SERVER = ADDONS / "hitl-auto-judge" / "server.py"


def call(tool, arguments):
    return {"method": "tools/call", "params": {"name": tool, "arguments": arguments}}


def admitted(arguments):
    return call("lane_call", {"tool": "judge", "caller": {"kind": "operator"}, "arguments": arguments})


class HitlTerminalStore(unittest.TestCase):
    def transcript(self, state, operations):
        operations = [{"method": "initialize", "params": {}}, *operations]
        lines = [json.dumps({"jsonrpc": "2.0", "id": index, **operation})
                 for index, operation in enumerate(operations, 1)]
        result = run_stdio([sys.executable, str(SERVER), "--state", str(state)],
                           input="\n".join(lines) + "\n")
        self.assertEqual(result.stderr, "")
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(1, len(operations) + 1)))
        return [reply["result"] for reply in replies[1:]]

    def test_terminal_drops_body_and_replays_the_same_judgment_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            original = {"kind": "exact_output", "request_id": "original-hitl", "output": "judgment",
                        "system": "original input " * 8192,
                        "messages": [{"role": "user", "text": "Judge the captured request"}],
                        "schema": {"type": "object"}}
            terminal = {"status": "outcome_unknown"}
            submit = lambda request: admitted({"kind": "submit", "request": request})
            replies = self.transcript(state, [submit(original), call("lane_host_result", {
                "request_id": original["request_id"], "result": terminal})])
            self.assertTrue(all(not reply["isError"] for reply in replies))
            path, = (state / "hitl-auto-judge").glob("*.json")
            retained = json.loads(path.read_text())
            self.assertEqual(set(retained), {"version", "request_id", "digest", "result"})
            self.assertEqual(retained["version"], 2)
            self.assertEqual(retained["result"], terminal)
            replies = self.transcript(state, [admitted({"kind": "read", "request_id": original["request_id"]}),
                                               submit(original), submit({**original, "system": "changed"}),
                                               call("lane_host_requests", {})])
            self.assertEqual([reply["structuredContent"]["result"] for reply in replies[:2]], [terminal] * 2)
            self.assertTrue(replies[2]["isError"])
            self.assertEqual(replies[3]["structuredContent"], {"requests": []})
            self.assertEqual(json.loads(path.read_text()), retained)


if __name__ == "__main__":
    unittest.main()
