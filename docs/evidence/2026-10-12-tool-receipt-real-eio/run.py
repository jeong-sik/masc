"""Interpret production receipt, context and guard source with installed Eio."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve(strict=True)
receipts = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) > 2 else root / "lib/keeper/keeper_official_client_tool_receipts.ml"
paths = {"__EXECUTION_CONTEXT__": root / "lib/fs_compat/execution_context.ml", "__EIO_GUARD__": root / "lib/core/eio_guard.ml", "__RECEIPTS__": receipts}
template = Path(__file__).with_name("repro.ml.in").read_text()
for placeholder, path in paths.items():
    template = template.replace(placeholder, json.dumps(str(path)))
with tempfile.TemporaryDirectory(prefix="receipt-real-eio-") as directory:
    harness = Path(directory) / "repro.ml"
    harness.write_text(template)
    started = time.perf_counter()
    result = subprocess.run(["ocaml", str(harness)], check=False)
    print(f"elapsed_seconds={time.perf_counter() - started:.6f}", flush=True)
sys.exit(result.returncode)
