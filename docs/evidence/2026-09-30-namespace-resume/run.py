"""Capture a check's command, UTC times, exit code and complete output."""

import datetime
import json
import pathlib
import subprocess
import sys

target = pathlib.Path(sys.argv[1])
command = sys.argv[2:]
target.parent.mkdir(parents=True, exist_ok=True)
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
result = subprocess.run(
    command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False
)
target.with_suffix(".log").write_bytes(result.stdout)
target.with_suffix(".json").write_text(
    json.dumps(
        {
            "command": command,
            "cwd": str(pathlib.Path.cwd()),
            "started_at": started,
            "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "exit_code": result.returncode,
        },
        indent=2,
    )
    + "\n"
)
sys.stdout.buffer.write(result.stdout)
sys.exit(result.returncode)
