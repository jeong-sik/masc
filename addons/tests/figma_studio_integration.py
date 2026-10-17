"""Exercise a distributed Figma service with the real MASC adapter and worker.

Only authenticated MASC routing and the Figma native editor are fixtures.
The service and Plugin come exclusively from an extracted release ZIP.
"""

from __future__ import annotations

import argparse
import base64
import zipfile
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "addons/figma-studio/host"))
from mcp_client import McpClient, encode  # noqa: E402
from adapter import Adapter, FigmaApi  # noqa: E402


class Worker:
    image = None
    volume = None
    invocations = []

    def __init__(self, path: Path, state: str):
        command = [sys.executable, str(path / "server.py"), "--state-dir", state]
        if self.image is not None:
            command = ["container", "run", "--rm", "--name", "figma-contract-" + uuid.uuid4().hex,
                       "--interactive", "--network", "none", "--cap-drop", "ALL", "--read-only",
                       "--cpus", "1", "--memory", "256M", "--workdir", "/addon",
                       "--mount", f"type=bind,source={path.resolve()},target=/addon,readonly",
                       "--mount", f"type=volume,source={self.volume},target=/state",
                       self.image, "python3", "server.py", "--state-dir", "/state"]
        self.invocations.append(command)
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        stdin, stdout = self.process.stdin, self.process.stdout
        assert stdin is not None and stdout is not None
        self.stdin, self.stdout = stdin, stdout
        self.lock = threading.Lock()
        self.sequence = 0

    def request(self, method, params):
        with self.lock:
            self.sequence += 1
            self.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": self.sequence,
                        "method": method,
                        "params": params,
                    }
                )
                + "\n"
            )
            self.stdin.flush()
            response = json.loads(self.stdout.readline())
            assert response["id"] == self.sequence
            return response["result"]

    def close(self):
        self.stdin.close()
        self.process.wait()
        self.stdout.close()
        assert self.process.returncode == 0


def running(stack, server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def close():
        server.shutdown()
        server.server_close()
        thread.join()

    stack.callback(close)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, default=ROOT / "addons/figma-studio")
    parser.add_argument("--figma-package", required=True, type=Path)
    parser.add_argument("--microvm-image", help="Use an existing Apple container image instead of a local worker process")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    with ExitStack() as stack:
        if args.microvm_image:
            Worker.image = args.microvm_image
            Worker.volume = "figma-contract-" + uuid.uuid4().hex
            subprocess.run(["container", "volume", "create", Worker.volume], check=True, capture_output=True)
            stack.callback(lambda: subprocess.run(["container", "volume", "delete", Worker.volume], check=True, capture_output=True))
        installation = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="figma-distribution-")))
        with zipfile.ZipFile(args.figma_package) as archive:
            archive.extractall(installation)
        service_script = installation / "studio/service.py"
        config = installation / "service.toml"
        subprocess.run([sys.executable, str(service_script), "init", "--config", str(config)], check=True, capture_output=True)
        config.write_text(config.read_text().replace("port = 8941", "port = 0"))
        import tomllib
        service_config = tomllib.loads(config.read_text())["service"]
        service = subprocess.Popen([sys.executable, str(service_script), "serve", "--config", str(config)], stdout=subprocess.PIPE, text=True)
        assert service.stdout is not None
        def stop_service():
            service.terminate()
            service.wait(timeout=5)
            service.stdout.close()
        stack.callback(stop_service)
        service_url = service.stdout.readline().strip().split(" listening on ")[-1]
        assert service_url.startswith("http://127.0.0.1:")
        api = FigmaApi(service_url, service_config["client_token"])
        state = stack.enter_context(tempfile.TemporaryDirectory())
        worker = Worker(args.worker, state)
        stack.callback(lambda: worker.close())
        worker.request("initialize", {})
        binding = {
            "installation": "contract-fixture",
            "keeper": "leader",
            "relay_agent": "studio-relay",
            "sources": [],
        }
        observed = worker.request(
            "tools/call",
            {
                "name": "lane_observe",
                "arguments": {
                    "sources": [],
                    "binding": binding,
                },
            },
        )
        assert not observed.get("isError")

        class HostFixture(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                pass

            def do_POST(self):
                request = json.loads(
                    self.rfile.read(int(self.headers["Content-Length"]))
                )
                token = self.headers.get("Authorization")
                assert token in ("Bearer fixture-keeper", "Bearer fixture-relay")
                if "id" not in request:
                    self.send_response(202)
                    self.end_headers()
                    return
                params = request["params"]
                if request["method"] == "tools/call":
                    params = {
                        "name": "lane_call",
                        "arguments": {
                            "tool": params["name"],
                            "arguments": params["arguments"],
                            # Mirrors MASC Full-profile registered Worker
                            # credentials; an HTTP Admin is not an operator.
                            "caller": {"kind": "keeper", "name": "leader"}
                            if token == "Bearer fixture-keeper"
                            else {"kind": "agent", "name": "studio-relay"},
                        },
                    }
                result = worker.request(request["method"], params)
                response = encode(
                    {"jsonrpc": "2.0", "id": request["id"], "result": result}
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        host = running(stack, ThreadingHTTPServer(("127.0.0.1", 0), HostFixture))
        url = f"http://127.0.0.1:{host.server_port}/mcp"
        relay_client, keeper = (
            McpClient(url, "fixture-relay"),
            McpClient(url, "fixture-keeper"),
        )
        relay_client.initialize()
        keeper.initialize()
        adapter_state = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        adapter = Adapter(relay_client, api, adapter_state)
        stack.callback(adapter.close)
        plugin = subprocess.Popen(
            ["node", str(Path(__file__).with_name("figma_plugin_driver.cjs")), str(installation / "plugin/studio/code.js")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        plugin_in, plugin_out = plugin.stdin, plugin.stdout
        assert plugin_in is not None and plugin_out is not None

        def close_plugin():
            plugin_in.close()
            plugin.wait()
            plugin_out.close()
            assert plugin.returncode == 0

        stack.callback(close_plugin)
        context = json.loads(plugin_out.readline())
        session, root = context["session_id"], context["root_id"]

        def post(path, values):
            request = urllib.request.Request(
                service_url + path,
                data=encode({"session_id": session, **values}),
                headers={
                    "Authorization": "Bearer " + service_config["plugin_token"],
                    "Origin": "null",
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(request) as response:
                return json.load(response)

        paired = post("/v1/plugin/session", {"protocol": "figma-studio/1", "document": context["document"]})
        service_id = paired["service_id"]
        adapter.step()
        keeper.call("masc_figma_bind", {"session_id": session})

        def execute(identity, kind, **values):
            keeper.call(
                "masc_figma_submit",
                {
                    "operation_id": identity,
                    "session_id": session,
                    "root_id": root,
                    "kind": kind,
                    **values,
                },
            )
            adapter.step()
            command = post("/v1/plugin/poll", {"service_id": service_id})["command"]
            assert command["id"] == identity
            plugin_in.write(json.dumps(command) + "\n")
            plugin_in.flush()
            reply = json.loads(plugin_out.readline())
            result = post(
                "/v1/plugin/result",
                {
                    "service_id": service_id,
                    "operation_id": identity,
                    "ok": reply["ok"],
                    "payload": reply["payload"],
                },
            )
            repeated = post(
                "/v1/plugin/result",
                {
                    "service_id": service_id,
                    "operation_id": identity,
                    "ok": reply["ok"],
                    "payload": reply["payload"],
                },
            )
            assert result == repeated
            adapter.step()
            return keeper.call("masc_figma_operation", {"operation_id": identity})

        before = execute("capture-1", "capture")["result"]["snapshot_id"]
        edited = execute(
            "edit-1",
            "apply",
            snapshot_id=before,
            ops=[
                {
                    "op": "create_frame",
                    "params": {
                        "ref": "@card",
                        "parent_id": root,
                        "name": "Card",
                        "width": 320,
                        "height": 240,
                    },
                },
                {
                    "op": "set_auto_layout",
                    "params": {
                        "node_id": "@card",
                        "direction": "VERTICAL",
                        "spacing": 12,
                        "padding": 24,
                    },
                },
                {
                    "op": "create_text",
                    "params": {
                        "ref": "@title",
                        "parent_id": "@card",
                        "text": "Hello Studio",
                        "font": {"family": "Inter", "style": "Regular"},
                        "font_size": 20,
                    },
                },
            ],
        )
        assert edited["state"] == "applied"
        snapshot = edited["result"]["snapshot_id"]
        # The host CLI downloads using the relay agent, never a forged owner.
        result = relay_client.call_result(
            "masc_figma_snapshot", {"snapshot_id": snapshot}
        )
        png = base64.b64decode(next(item["data"] for item in result["content"] if item["type"] == "image"), validate=True)
        metadata = json.loads(result["content"][0]["text"])
        title = json.loads(metadata["tree_json"])["document"]["children"][0][
            "children"
        ][0]["id"]
        report = keeper.call(
            "masc_figma_validate",
            {
                "snapshot_id": snapshot,
                "checks": [
                    {"node_id": title, "path": ["characters"], "equals": "Hello Studio"}
                ],
            },
        )
        assert (
            report["verdict"] == "pass" and report["visual_verdict"] == "not_evaluated"
        )
        retained = worker.request(
            "tools/call",
            {
                "name": "lane_observe",
                "arguments": {
                    "binding": binding,
                    "sources": [],
                },
            },
        )
        assert len(retained["structuredContent"]["artifacts"]) == 3

        # A completed Plugin command can outlive the worker that dispatched it.
        # Re-pairing must not relabel its receipt with the replacement boot.
        keeper.call(
            "masc_figma_submit",
            {
                "operation_id": "capture-before-restart",
                "session_id": session,
                "root_id": root,
                "kind": "capture",
            },
        )
        adapter.step()
        old_command = post("/v1/plugin/poll", {"service_id": service_id})["command"]
        plugin_in.write(json.dumps(old_command) + "\n")
        plugin_in.flush()
        old_reply = json.loads(plugin_out.readline())
        old_boot = relay_client.call("masc_figma_relay", {"kind": "status"})["worker_boot_id"]
        worker.close()
        worker = Worker(args.worker, state)
        worker.request("initialize", {})
        worker.request(
            "tools/call",
            {
                "name": "lane_observe",
                "arguments": {"binding": binding, "sources": []},
            },
        )
        adapter.step()
        new_boot = relay_client.call("masc_figma_relay", {"kind": "status"})["worker_boot_id"]
        assert new_boot != old_boot
        post("/v1/plugin/result", {
            "service_id": service_id, "operation_id": old_command["id"],
            "ok": old_reply["ok"], "payload": old_reply["payload"],
        })
        adapter.step()
        delivery = adapter.db.execute("SELECT state,boot FROM deliveries WHERE id=?", (old_command["id"],)).fetchone()
        assert delivery["state"] == "obsolete" and delivery["boot"] == old_boot
        uncertain = keeper.call(
            "masc_figma_operation", {"operation_id": old_command["id"]}
        )
        assert uncertain["state"] == "outcome_unknown"
        keeper.call("masc_figma_bind", {"session_id": session})
        continued = execute("capture-after-restart", "capture")
        assert continued["state"] == "captured"

        result_path = args.output / "snapshot-result.json"
        result_path.write_bytes(encode(result))
        (args.output / "preview.png").write_bytes(png)
        (args.output / "validation.json").write_bytes(encode(report))
        kitty = subprocess.run(
            [
                sys.executable,
                str(installation / "studio/preview.py"),
                str(result_path),
                "--kitty",
                "--size",
                "80",
                "24",
            ],
            check=True,
            capture_output=True,
        )
        assert b"\x1b_G" in kitty.stdout
        (args.output / "kitty.bin").write_bytes(kitty.stdout)
        receipt = {
            "scope": "distributed service and Plugin, real worker and host adapter; native editor and authenticated routing fixtures",
            "packaged_service_without_source_checkout": True,
            "service_protocol": api.info()["protocol"],
            "real_worker": True,
            "real_adapter": True,
            "real_microvm": args.microvm_image is not None,
            "worker_runtime": "apple_container" if args.microvm_image else "local_process",
            "real_figma": False,
            "installed_masc": False,
            "snapshot_id": snapshot,
            "structural_verdict": report["verdict"],
            "visual_verdict": report["visual_verdict"],
            "kitty_protocol_emitted": True,
            "duplicate_result_retained": True,
            "worker_restart_refusal_and_next_capture": True,
        }
        (args.output / "receipt.json").write_bytes(encode(receipt))
        (args.output / "worker-invocations.json").write_bytes(encode(Worker.invocations))
        print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
