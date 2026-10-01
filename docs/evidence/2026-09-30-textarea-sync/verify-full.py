"""Run the full Dashboard suite and bind its result to measured working bytes."""

import datetime
import gzip
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path.cwd()
output = root / sys.argv[1]
output.mkdir(parents=True, exist_ok=False)


def snapshot() -> list[dict[str, str | int]]:
    files = (
        subprocess.check_output(
            [
                "git",
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
                "dashboard",
            ]
        )
        .decode()
        .split("\0")
    )
    rows: list[dict[str, str | int]] = []
    for name in sorted(set(files) - {""}):
        data = (root / name).read_bytes()
        rows.append(
            {
                "path": name,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "blob": hashlib.sha1(
                    b"blob " + str(len(data)).encode() + b"\0" + data
                ).hexdigest(),
            }
        )
    return rows


before = snapshot()
(output / "sources.json.gz").write_bytes(
    gzip.compress(json.dumps(before, indent=2).encode(), mtime=0)
)
env = os.environ.copy()
env.pop("MASC_CONFIG_DIR", None)
env.pop("MASC_BASE_PATH", None)
command = [
    "pnpm",
    "exec",
    "vitest",
    "run",
    "--config",
    "vitest.config.ts",
    "--no-file-parallelism",
    "--maxWorkers=1",
]
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
result = subprocess.run(
    command,
    cwd=root / "dashboard",
    env=env,
    capture_output=True,
    timeout=560,
    check=False,
)
finished = datetime.datetime.now(datetime.timezone.utc).isoformat()
log = result.stdout + result.stderr
(output / "vitest.log.gz").write_bytes(gzip.compress(log, mtime=0))
receipt = {
    "command": command,
    "cwd": "dashboard",
    "started": started,
    "finished": finished,
    "exit": result.returncode,
    "base_head": subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip(),
    "source_files": len(before),
    "source_unchanged": snapshot() == before,
    "log_sha256": hashlib.sha256(log).hexdigest(),
}
(output / "execution.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(log.decode(errors="replace")[-8000:])
print(json.dumps(receipt))
sys.exit(result.returncode if receipt["source_unchanged"] else 1)
