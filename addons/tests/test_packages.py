"""Feature tests cross the same MCP subprocess boundary as the Add-on host.

The HTTP fixture supplies actual HTML bytes; browser identity in this fixture is
explicit test data, not a claim that a real browser or Keeper was qualified.
"""

from __future__ import annotations

import copy
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.request import urlopen


ADDONS = Path(__file__).resolve().parents[1]
ROW_FIELDS = {"id", "lane_id", "kind", "title", "observed_at", "subject_id", "clock",
              "actor", "fields", "evidence", "related_ids"}


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def reference(name: str, content: str = "fixture") -> dict:
    return {"uri": f"artifact://test/{name}", "sha256": digest(content)}


def document(revision: str, namespace: str = "site") -> str:
    return ('<!doctype html><html><head>'
            f'<meta name="masc-revision" content="{revision}">'
            f'<meta name="masc-revision-namespace" content="{namespace}">'
            '</head><body><button id="sign-in">Sign in</button></body></html>')


def source(observations: list[dict], *, source_id: str = "browser", incarnation: str = "session-1",
           complete: bool = True, detail: str | None = None) -> dict:
    return {"source_id": source_id, "incarnation": incarnation, "cursor": "offset:42",
            "complete": complete, "detail": detail, "observations": observations}


def web_binding(url: str = "https://service.test/app?version=1") -> dict:
    return {"target": {"id": "service", "environment": "production", "url": url},
            "request_id": "verification-1",
            "expected": {"namespace": "site", "revision": "A", "observed_at": 1000,
                         "manifest": reference("build-manifest", '{"revision":"A"}')}}


def web_observation(binding: dict, kind: str, *, revision: str = "B", actor=None) -> dict:
    result = {"id": f"event-{kind}", "kind": kind, "observed_at": 1001,
              "actor": actor, "evidence": [reference(kind)],
              "target": copy.deepcopy(binding["target"]), "request_id": binding["request_id"]}
    if kind == "deployment":
        result["revision"] = "A"
    else:
        result.update({"client_id": "client-1", "tab_id": "tab-1", "document_id": "doc-1"})
        if kind == "browser":
            result["html"] = document(revision)
        else:
            result["passed"] = False
    return result


class ProtocolCase(unittest.TestCase):
    def call(self, package: str, binding: dict, sources: list[dict], *, cwd=None):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "clientInfo": {"name": "test", "version": "1"},
                "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                "name": "lane_observe", "arguments": {"binding": binding, "sources": sources}}}]
        proc = subprocess.run([sys.executable, str(ADDONS / package / "server.py")],
                              input="".join(json.dumps(r) + "\n" for r in requests),
                              text=True, capture_output=True, check=True, timeout=10, cwd=cwd)
        self.assertEqual(proc.stderr, "")
        responses = [json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual([r["id"] for r in responses], [1, 2, 3])
        tool = responses[1]["result"]["tools"][0]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertEqual(set(tool["outputSchema"]["properties"]), {"rows", "coverage"})
        result = responses[2]["result"]
        if result["isError"]:
            return result
        output = result["structuredContent"]
        self.assertEqual(output, json.loads(result["content"][0]["text"]))
        self.assertEqual(set(output), {"rows", "coverage"})
        for row in output["rows"]:
            self.assertEqual(set(row), ROW_FIELDS)
            self.assertIn(row["kind"], {"event", "value", "relation"})
        return output


class WebLayer(ProtocolCase):
    def test_mismatch_uses_same_target_document_and_links_probe(self):
        binding = web_binding()
        events = [web_observation(binding, kind) for kind in ("deployment", "browser", "probe")]
        output = self.call("web-project", binding, [source(events)])
        relations = [row for row in output["rows"] if row["kind"] == "relation"]
        self.assertEqual(len(relations), 1)
        relation = relations[0]
        self.assertEqual(relation["fields"]["comparison"], "mismatch")
        self.assertEqual(relation["fields"]["observed_revision"], "B")
        self.assertEqual(len(relation["related_ids"]), 4)
        self.assertEqual(len(relation["fields"]["deployment_receipt_ids"]), 1)
        self.assertEqual(len(relation["fields"]["failed_probe_ids"]), 1)
        self.assertEqual({r["lane_id"] for r in output["rows"]}, {
            "web/expectation", "web/deployment", "web/browser", "web/probe", "web/revision"})

    def test_different_target_environment_url_or_request_never_join(self):
        for field, different in (("id", "another-service"), ("environment", "preview"),
                                 ("url", "https://service.test/app?version=2"),
                                 ("url", "https://service.test:8443/app?version=1"),
                                 ("request_id", "another-verification")):
            with self.subTest(field=field, different=different):
                binding = web_binding()
                browser = web_observation(binding, "browser")
                if field == "request_id":
                    browser[field] = different
                else:
                    browser["target"][field] = different
                output = self.call("web-project", binding, [source([browser])])
                self.assertFalse(any(r["kind"] == "relation" for r in output["rows"]))
                self.assertEqual(output["rows"][1]["fields"]["comparison"], "unrelated")

    def test_feature_failure_does_not_invent_revision_mismatch(self):
        binding = web_binding()
        events = [web_observation(binding, "browser", revision="A"), web_observation(binding, "probe")]
        output = self.call("web-project", binding, [source(events)])
        relation = output["rows"][-1]
        self.assertEqual(relation["fields"]["comparison"], "match")
        self.assertEqual(len(relation["fields"]["failed_probe_ids"]), 1)

    def test_unknown_revision_is_never_replaced_by_source_or_deploy_identity(self):
        for html in (None, "<html>no marker</html>", document("B", "another-site"),
                     document("B").replace('</head>', '<meta name="masc-revision" content="A"></head>')):
            with self.subTest(html=html):
                binding = web_binding()
                browser = web_observation(binding, "browser")
                browser.update({"html": html, "source_digest": "A", "version_endpoint": "A"})
                output = self.call("web-project", binding, [source([browser])])
                self.assertEqual(output["rows"][-1]["fields"]["comparison"], "unknown")

    def test_only_active_document_head_metadata_declares_revision(self):
        markers = ('<meta name="masc-revision" content="B">'
                   '<meta name="masc-revision-namespace" content="site">')
        for html in (f'<html><head></head><body>{markers}</body></html>',
                     f'<html><head><template>{markers}</template></head></html>',
                     f'<html><head><title>{markers}</title></head></html>',
                     f'<html><head><noscript>{markers}</noscript></head></html>',
                     f'<html><head><div>{markers}</div></head></html>'):
            with self.subTest(html=html):
                binding = web_binding()
                browser = web_observation(binding, "browser")
                browser["html"] = html
                output = self.call("web-project", binding, [source([browser])])
                self.assertEqual(output["rows"][-1]["fields"]["comparison"], "unknown")
        binding = web_binding()
        browser = web_observation(binding, "browser", revision="A")
        browser["html"] = document("A").replace("</body>", markers + "</body>")
        output = self.call("web-project", binding, [source([browser])])
        self.assertEqual(output["rows"][-1]["fields"]["comparison"], "match")

    def test_other_deployments_are_not_added_to_the_document_relation(self):
        binding = web_binding()
        receipt = web_observation(binding, "deployment")
        receipt["target"]["environment"] = "preview"
        output = self.call("web-project", binding,
                           [source([receipt, web_observation(binding, "browser")])])
        relation = output["rows"][-1]
        self.assertEqual(relation["fields"]["comparison"], "mismatch")
        self.assertEqual(relation["fields"]["deployment_receipt_ids"], [])

    def test_probe_document_identity_must_match_all_three_coordinates(self):
        binding = web_binding()
        for field in ("client_id", "tab_id", "document_id"):
            with self.subTest(field=field):
                probe = web_observation(binding, "probe")
                probe[field] = "another"
                output = self.call("web-project", binding,
                                   [source([web_observation(binding, "browser"), probe])])
                self.assertEqual(output["rows"][-1]["fields"]["failed_probe_ids"], [])

    def test_actual_actor_coverage_and_deterministic_replay(self):
        binding = web_binding()
        browser = web_observation(binding, "browser", actor="actual-provider/model")
        browser["assigned_runtime"] = "other-runtime"
        envelopes = [source([browser, {"kind": "keeper", "runtime_id": "assigned"}, {"tool": "read"}],
                            complete=False, detail="source rotated before offset 42")]
        output = self.call("web-project", binding, envelopes)
        self.assertEqual(output, self.call("web-project", binding, envelopes))
        self.assertEqual(output["rows"][1]["actor"], "actual-provider/model")
        self.assertIsNone(output["rows"][-1]["actor"])
        self.assertFalse(output["coverage"][0]["complete"])
        self.assertIn("rotated", output["coverage"][0]["detail"])
        self.assertIn("keeper", output["coverage"][0]["detail"])
        browser["actor"] = None
        output = self.call("web-project", binding, [source([browser])])
        self.assertIsNone(output["rows"][1]["actor"])

    def test_served_html_is_used_without_extra_network_access(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                body = (document("B") if self.path == "/app" else '{"revision":"A"}').encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/app"
            with urlopen(url) as response:
                html = response.read().decode()
                actual_url = response.url
            binding = web_binding(actual_url)
            observation = web_observation(binding, "browser")
            observation["html"] = html
            observation["evidence"] = [reference("captured-document", html)]
            output = self.call("web-project", binding, [source([observation])])
            self.assertEqual(output["rows"][-1]["fields"]["comparison"], "mismatch")
            self.assertEqual(output["rows"][1]["fields"]["html_sha256"], digest(html))
            self.assertEqual(requests, ["/app"])
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_malformed_known_observation_reports_error_instead_of_default_values(self):
        binding = web_binding()
        browser = web_observation(binding, "browser")
        browser["observed_at"] = False
        result = self.call("web-project", binding, [source([browser])])
        self.assertTrue(result["isError"])
        self.assertNotIn("structuredContent", result)


class MsxLayer(ProtocolCase):
    def test_optional_incarnation_follows_machine_without_merging_clocks(self):
        captures = [{"id": "capture", "kind": "capture", "observed_at": 1002,
                     "actor": None, "evidence": [], "machine_id": "workspace-msx",
                     "incarnation": run, "frame": frame, "screen": reference(run), "input_cursor": None,
                     "input_ledger": None}
                    for run, frame in (("history-A", 50), ("history-B", 0))]
        for binding in ({"machine_id": "workspace-msx"},
                        {"machine_id": "workspace-msx", "incarnation": None}):
            output = self.call("msx-observer", binding,
                [source([capture], incarnation=capture["incarnation"]) for capture in captures])
            self.assertTrue(all(row["fields"]["matches_binding"] for row in output["rows"]))
            self.assertNotEqual(output["rows"][0]["clock"]["domain"], output["rows"][1]["clock"]["domain"])
            self.assertEqual([row["clock"]["value"] for row in output["rows"]], ["50", "0"])

    def test_snapshots_preserve_machine_state_and_incarnation_clock(self):
        with tempfile.TemporaryDirectory() as path:
            screenshot = Path(path) / "frame.png"
            screenshot.write_bytes(b"captured pixels")
            before = screenshot.read_bytes()
            screen_ref = {"uri": screenshot.as_uri(), "sha256": hashlib.sha256(before).hexdigest()}
            captures = [{"id": "capture-1", "kind": "capture", "observed_at": 1002,
                         "actor": None, "evidence": [reference("capture-1")],
                         "machine_id": "game", "incarnation": run, "frame": frame,
                         "screen": screen_ref, "input_cursor": "input:4", "input_ledger": None}
                        for run, frame in (("load-1", 12345), ("load-2", 0))]
            sources = [source([capture], source_id="msx", incarnation=capture["incarnation"])
                       for capture in captures]
            output = self.call("msx-observer", {"machine_id": "game", "incarnation": "load-2"},
                               sources, cwd=path)
            self.assertEqual(screenshot.read_bytes(), before)
            self.assertEqual(sorted(p.name for p in Path(path).iterdir()), ["frame.png"])
            self.assertEqual([r["clock"]["value"] for r in output["rows"]], ["12345", "0"])
            self.assertEqual([r["clock"]["domain"] for r in output["rows"]],
                             ["msx/game/load-1/frame", "msx/game/load-2/frame"])
            self.assertEqual([r["fields"]["matches_binding"] for r in output["rows"]], [False, True])
            self.assertNotEqual(output["rows"][0]["id"], output["rows"][1]["id"])
            self.assertTrue(all(r["actor"] is None for r in output["rows"]))

    def test_input_history_reference_is_retained_without_inventing_inputs(self):
        input_bytes = ''.join(json.dumps({"who": "Alice", "key": "space", "edge": edge,
                                         "frame": frame}) + '\n'
                              for edge, frame in [("down", 10), ("up", 11)])
        capture = {"id": "capture-inputs", "kind": "capture", "observed_at": 1002,
                   "actor": None, "evidence": [], "machine_id": "game",
                   "incarnation": "machine-A", "frame": 20, "screen": reference("screen"),
                   "input_cursor": "2", "input_ledger": {"format": "msx-input-jsonl-sequence",
                   "entry_count": 2, "evidence": {"uri": "lane-sequence:" + digest(input_bytes), "sha256": digest(input_bytes)}}}
        binding = {"machine_id": "game"}
        result = self.call("msx-observer", binding, [source([capture])])
        row, = result["rows"]
        self.assertEqual(row["lane_id"], "msx/frame")
        self.assertIsNone(row["actor"])
        self.assertEqual(row["fields"]["input_ledger"], capture["input_ledger"])
        self.assertIn(capture["input_ledger"]["evidence"], row["evidence"])
        absent = {**capture, "input_ledger": None}
        empty = {**capture, "input_cursor": "0", "input_ledger": {
                 "format": "msx-input-jsonl-sequence", "entry_count": 0, "evidence": {"uri": "lane-sequence:" + digest("empty-node"), "sha256": digest("empty-node")}}}
        for observation in [absent, empty]:
            output = self.call("msx-observer", binding, [source([observation])])
            self.assertEqual(output["rows"][0]["fields"]["input_ledger"], observation["input_ledger"])
        for change in [{"entry_count": -1}, {"entry_count": True}, {"entry_count": 3},
                       {"format": "unknown"}, {"evidence": None},
                       {"evidence": reference("not-host-owned")}]:
            invalid = {**capture, "input_ledger": {**capture["input_ledger"], **change}}
            self.assertTrue(self.call("msx-observer", binding, [source([invalid])])["isError"])
        missing = {key: value for key, value in capture.items() if key != "input_ledger"}
        self.assertTrue(self.call("msx-observer", binding, [source([missing])])["isError"])

    def test_foreign_records_are_visible_as_coverage_not_fabricated_frames(self):
        output = self.call("msx-observer", {"machine_id": "game", "incarnation": "load-1"},
                           [source([{"kind": "keeper", "turn": 15}], complete=False,
                                   detail="snapshot unavailable")])
        self.assertEqual(output["rows"], [])
        self.assertFalse(output["coverage"][0]["complete"])
        self.assertIn("keeper", output["coverage"][0]["detail"])


if __name__ == "__main__":
    unittest.main()
