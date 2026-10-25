"""Actual Worker/Connector/store receipts; fake provider and owned temp store.

No HTTP, account, browser process, Native manager or installed runtime is used.
The generated packet is replayed through the actual Dashboard and page script.
"""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "addons/onepassword"))
sys.path.insert(0, str(ROOT / "addons/tests"))
from onepassword_store_fixture import MemoryRecords
import oauth
import server


with tempfile.TemporaryDirectory() as directory:
    calls = []

    def provider(path, fields, configuration):
        calls.append({"path": path, "fields": sorted(fields)})
        return {"access_token": "FIXTURE_ACCESS", "refresh_token": "FIXTURE_REFRESH",
                "token_type": "Bearer", "expires_in": 900}

    connector = oauth.Connector(oauth.Configuration("fixture-client", "FIXTURE_SECRET",
        "https://masc.example/addons/oauth/callback"),
        oauth.PrivateStore(Path(directory) / "store", records=MemoryRecords(directory), provision=True), transport=provider)
    worker = server.Worker(Path(directory) / "configuration.json")
    with patch.object(server, "load_settings", return_value=server.Settings(connector, "fixture", None)):
        pending = worker.operator({"action": "connect", "arguments": {}})
        identity = pending["callback"]["arguments"]
        returned = connector.configuration.redirect_uri + "?" + urlencode({"state": identity["state"],
            "code": "FIXTURE_CODE"}) + "#integration_key=FIXTURE_KEY"
        command = {"action": "complete", "arguments": {**identity, "callback_url": returned}}
        write = connector.store.write

        def before_capture(root, record):
            if record["phase"] == "exchanging":
                raise OSError("FIXTURE_PRE_CAPTURE_FAILURE")
            return write(root, record)

        with patch.object(connector.store, "write", side_effect=before_capture):
            not_captured = worker.operator(command)
        assert "callback_receipt" not in not_captured and not calls
        captured = worker.operator(command)
        replayed = worker.operator(command)
        assert len(calls) == 1
        assert captured["callback_receipt"] == replayed["callback_receipt"]
        packet = {"scope": "actual Python producer/protected store with explicit MemoryRecords; fake provider; no OS credential backend/HTTP/Native/browser",
                  "source_sha256": {str(path): hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                    for path in ["addons/onepassword/oauth.py", "addons/onepassword/server.py"]},
                  "pending": pending, "callback_url": returned, "not_captured": not_captured,
                  "captured": captured, "replayed": replayed, "provider_calls": calls}
        Path(__file__).with_name("backend-receipts.json").write_text(json.dumps(packet, indent=2) + "\n")
