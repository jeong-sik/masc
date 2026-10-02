"""Bind focused local executions to the published PR source, without live APIs."""

import datetime
import gzip
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

root = Path.cwd()
expected_head, destination = sys.argv[1:]
output = Path(destination).resolve()
output.mkdir(parents=True, exist_ok=False)
runner = Path(__file__).resolve()
browser = root / "docs/evidence/2026-09-30-keeper-config-save/browser.mjs"
env = os.environ.copy()
for key in ("MASC_CONFIG_DIR", "MASC_BASE_PATH"):
    env.pop(key, None)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=root).decode().strip()


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def snapshot():
    head = git("rev-parse", "HEAD")
    if head != expected_head:
        raise RuntimeError(f"unexpected HEAD: {head}")
    rows = []
    for entry in git("ls-tree", "-r", head, "--", "dashboard").splitlines():
        metadata, path = entry.split("\t", 1)
        mode, object_type, blob = metadata.split()
        if object_type != "blob":
            raise RuntimeError(f"unexpected source object: {path}")
        file = root / path
        data = os.readlink(file).encode() if mode == "120000" else file.read_bytes()
        observed_blob = hashlib.sha1(
            b"blob " + str(len(data)).encode() + b"\0" + data
        ).hexdigest()
        if observed_blob != blob:
            raise RuntimeError(f"working source differs from Git: {path}")
        rows.append(
            {"path": path, "git_blob": blob, "sha256": hashlib.sha256(data).hexdigest()}
        )
    for file in (browser, runner):
        rows.append(
            {
                "path": str(file.relative_to(root)),
                "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
            }
        )
    return {
        "head": head,
        "dashboard_tree": git("rev-parse", "HEAD:dashboard"),
        "files": rows,
    }


receipt = {
    "scope": "Published source; local focused tests and Chromium synthetic API only",
    "started_utc": utc(),
    "playwright_browsers_path": env.get("PLAYWRIGHT_BROWSERS_PATH"),
    "ld_library_path": env.get("LD_LIBRARY_PATH"),
    "runs": [],
}
before = snapshot()
receipt["source_before"] = {
    key: value for key, value in before.items() if key != "files"
}
(output / "sources.json.gz").write_bytes(
    gzip.compress((json.dumps(before, indent=2) + "\n").encode(), mtime=0)
)
commands = [
    (
        "focused-vitest",
        root / "dashboard",
        [
            "pnpm",
            "exec",
            "vitest",
            "run",
            "src/components/keeper-config-panel.test.ts",
            "src/api/dashboard-keeper-config.test.ts",
            "--config",
            "vitest.config.ts",
            "--no-file-parallelism",
            "--maxWorkers=1",
        ],
    ),
    (
        "typescript",
        root / "dashboard",
        ["pnpm", "exec", "tsc", "--noEmit", "--pretty", "false"],
    ),
    (
        "chromium",
        root,
        ["node", str(browser.relative_to(root)), "dashboard", str(output / "browser")],
    ),
]
for name, cwd, command in commands:
    start = utc()
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log = output / (name + ".log.gz")
    log.write_bytes(gzip.compress(result.stdout, mtime=0))
    run = {
        "name": name,
        "command": command,
        "cwd": str(cwd.relative_to(root)),
        "started_utc": start,
        "finished_utc": utc(),
        "exit": result.returncode,
        "raw_log_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "compressed_log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
    }
    receipt["runs"].append(run)
    print(json.dumps(run), flush=True)
    if result.returncode != 0:
        break
after = snapshot()
receipt["source_after"] = {key: value for key, value in after.items() if key != "files"}
receipt["source_unchanged"] = before == after
receipt["finished_utc"] = utc()
receipt["passed"] = (
    len(receipt["runs"]) == len(commands)
    and all(run["exit"] == 0 for run in receipt["runs"])
    and receipt["source_unchanged"]
)
(output / "execution.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(
    json.dumps({key: value for key, value in receipt.items() if key != "runs"}),
    flush=True,
)
sys.exit(0 if receipt["passed"] else 1)
