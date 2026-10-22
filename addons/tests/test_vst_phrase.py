"""Exercise the real MCP stdio boundary, with explicit native snapshot fixtures."""
import copy
import json
from pathlib import Path
import sys
import unittest
from stdio_fixture import run_stdio

PACKAGE = Path(__file__).resolve().parents[1] / "vst-phrase"


def snapshot(state="rendered"):
    return {"source_id": "vst-phrase", "incarnation": "native-session", "cursor": "7",
        "complete": True, "detail": "Latest local phrase state",
        "observations": [{"id": "native-session:7", "kind": "vst_phrase", "observed_at": 1234,
            "actor": None, "evidence": [{"uri": "file:///audio.wav", "sha256": "a" * 64}],
            "fields": {"state": state, "selection": {"name": "Retrologue", "plugin_path": "/synth.vst3",
                "plugin_name": None, "preset_path": "/sound.vstpreset"},
                "render": {"midi_sha256": "b" * 64, "wav_sha256": "a" * 64, "duration_ms": 2000}}}]}


class VstPhrase(unittest.TestCase):
    def exchange(self, sources):
        requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                "name": "lane_observe", "arguments": {"binding": {}, "sources": sources}}}]
        result = run_stdio([sys.executable, str(PACKAGE / "server.py")],
            input="".join(json.dumps(item) + "\n" for item in requests))
        self.assertEqual(result.stderr, "")
        replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
        self.assertEqual([tool["name"] for tool in replies[1]["tools"]], ["lane_observe"])
        return replies[2]

    def test_state_preserves_identity_selection_and_audio_evidence(self):
        original = snapshot()
        for state in ("rendered", "player_started", "pause_requested", "resume_requested", "stop_requested"):
            original["observations"][0]["fields"]["state"] = state
            reply = self.exchange([original])
            self.assertFalse(reply["isError"])
            output = reply["structuredContent"]
            reading = output["rows"][0]
            self.assertEqual(reading["fields"]["state"], state)
            self.assertEqual(reading["fields"]["selection"], original["observations"][0]["fields"]["selection"])
            self.assertEqual(reading["evidence"], original["observations"][0]["evidence"])
            self.assertEqual(reading["fields"]["source_event_id"], "native-session:7")
            self.assertEqual(output["coverage"][0]["cursor"], "7")
            self.assertFalse(reading["fields"]["action_receipt"])

    def test_known_render_failure_is_distinct_from_unavailable_source(self):
        failed = snapshot("failed")
        failed["observations"][0]["fields"].update({"render": None, "error": "License unavailable"})
        failure = self.exchange([failed])["structuredContent"]
        self.assertEqual(failure["rows"][0]["fields"]["error"], "License unavailable")
        self.assertTrue(failure["coverage"][0]["complete"])
        missing = copy.deepcopy(failed)
        missing.update({"observations": [], "complete": False, "detail": "Companion unavailable"})
        for sources in ([missing], []):
            unavailable = self.exchange(sources)["structuredContent"]
            self.assertEqual(unavailable["rows"], [])
            self.assertFalse(unavailable["coverage"][0]["complete"])

    def test_unknown_observations_preserve_incomplete_coverage(self):
        mixed = snapshot()
        mixed["observations"].append({"kind": "other"})
        output = self.exchange([mixed])["structuredContent"]
        self.assertEqual(len(output["rows"]), 1)
        self.assertFalse(output["coverage"][0]["complete"])

    def test_invalid_render_or_state_is_refused(self):
        for fault in ("state", "hash", "render", "error"):
            broken = snapshot()
            fields = broken["observations"][0]["fields"]
            if fault == "state": fields["state"] = "audible"
            elif fault == "hash": fields["render"]["midi_sha256"] = "invented"
            elif fault == "render": fields["render"] = None
            else: fields["state"] = "failed"
            self.assertTrue(self.exchange([broken])["isError"])

    def test_missing_event_identity_returns_protocol_error_without_crashing(self):
        broken = snapshot("rendering")
        broken["observations"][0]["fields"]["render"] = None
        del broken["observations"][0]["id"]
        reply = self.exchange([broken])
        self.assertTrue(reply["isError"])
        self.assertIn("observation.id", reply["content"][0]["text"])

    def test_export_destination_and_hashes_survive_the_lane_boundary(self):
        exported = snapshot("exported")
        fields = exported["observations"][0]["fields"]
        fields["export_path"] = "/audio.wav"
        fields["render"]["output_path"] = "/audio.wav"
        reply = self.exchange([exported])
        self.assertFalse(reply["isError"])
        reading = reply["structuredContent"]["rows"][0]
        self.assertEqual(reading["fields"]["state"], "exported")
        self.assertEqual(reading["fields"]["export_path"], "/audio.wav")
        self.assertEqual(reading["evidence"], exported["observations"][0]["evidence"])
        self.assertFalse(reading["fields"]["action_receipt"])
        fields["render"]["output_path"] = "/different.wav"
        self.assertTrue(self.exchange([exported])["isError"])
        fields["render"] = None
        self.assertTrue(self.exchange([exported])["isError"])

    def test_export_failure_keeps_error_without_published_audio(self):
        failed = snapshot("export_failed")
        observation = failed["observations"][0]
        observation["evidence"] = []
        observation["fields"].update({"render": None, "export_path": "/existing.wav", "error": "EEXIST"})
        reply = self.exchange([failed])
        self.assertFalse(reply["isError"])
        reading = reply["structuredContent"]["rows"][0]
        self.assertEqual(reading["fields"]["error"], "EEXIST")
        self.assertEqual(reading["evidence"], [])
        self.assertTrue(reply["structuredContent"]["coverage"][0]["complete"])
        observation["evidence"] = snapshot()["observations"][0]["evidence"]
        self.assertTrue(self.exchange([failed])["isError"])
        observation["evidence"] = []
        del observation["fields"]["error"]
        self.assertTrue(self.exchange([failed])["isError"])


if __name__ == "__main__":
    unittest.main()
