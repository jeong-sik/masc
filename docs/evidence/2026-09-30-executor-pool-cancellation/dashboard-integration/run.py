import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path("masc/.worktrees/36496-pool-cancel")
out = Path("evidence/36496-focused-20260930")
label = sys.argv[1]
cmd = sys.argv[2:]
receipt_path = out / (label + ".json")
if receipt_path.exists():
    raise SystemExit("Refusing to overwrite a receipt")
env = os.environ.copy()
for key in ("MASC_CONFIG_DIR", "MASC_BASE_PATH"):
    env.pop(key, None)
env["MASC_SKIP_DEPS_CHECK"] = "1"
sources = ["lib/core/executor_pool_ref.ml", "test/test_dashboard_cache_cancellation.ml", "test/dune"]
receipt = {
    "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "command": cmd,
    "source_sha256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources},
    "limitation": "Focused local validation; installed dependency pins differ. Dependency guard skipped; no shared switch changes.",
}
with (out / (label + ".log")).open("xb") as log:
    try:
        process = subprocess.Popen(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = process.wait(timeout=110)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            rc = 124
    except OSError as error:
        log.write(str(error).encode())
        rc = 127
receipt.update(exit_code=rc, finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
receipt["log_sha256"] = hashlib.sha256((out / (label + ".log")).read_bytes()).hexdigest()
receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt))
print((out / (label + ".log")).read_text(errors="replace")[-9000:])
raise SystemExit(rc)
