"""Execute production HTTP/protocol source with explicit mock socket boundary."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
root = Path(sys.argv[1]).resolve(strict=True)
cohttp = Path(subprocess.check_output(["ocamlfind", "query", "cohttp-eio"], text=True).strip())
paths = {"__MCP_TRANSPORT_PROTOCOL__": "lib/mcp_transport_protocol/mcp_transport_protocol.ml", "__RUNTIME_OFFICIAL_CLIENT_TOOL__": "lib/runtime/runtime_official_client_tool.ml", "__RUNTIME_OFFICIAL_CLIENT_MCP__": "lib/runtime/runtime_official_client_mcp.ml", "__RUNTIME_OFFICIAL_CLIENT_MCP_HTTP__": "lib/runtime/runtime_official_client_mcp_http.ml"}
template = Path(__file__).with_name("repro.ml.in").read_text()
template = template.replace("__COHTTP_SERVER__", json.dumps(str(cohttp / "server.ml")))
for placeholder, relative in paths.items():
    template = template.replace(placeholder, json.dumps(str(root / relative)))
with tempfile.TemporaryDirectory(prefix="mcp-http-boundary-") as directory:
    harness = Path(directory) / "repro.ml"
    harness.write_text(template)
    started = time.perf_counter()
    result = subprocess.run(["ocaml", str(harness)], check=False)
    print(f"elapsed_seconds={time.perf_counter() - started:.6f}", flush=True)
sys.exit(result.returncode)
