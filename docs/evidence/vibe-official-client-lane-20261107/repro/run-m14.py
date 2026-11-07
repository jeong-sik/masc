"""m14: one vibe call with --prompt-file and only the lane's allowlisted env.

Usage: python3 -I run-m14.py <base>; <base> holds wd/ (empty), out-b/ (empty)
and prompt.txt. Writes b.stdout and b.stderr into <base>. Makes one model call.
The name list copies child_environment_key_allowed in lib/runtime/runtime_vibe_cli.ml
as it was before the proxy names joined it.
"""

import os
import shutil
import subprocess
import sys
import time

ALLOWED = (
    "COLORTERM HOME LANG LC_ALL LC_CTYPE LOGNAME PATH SHELL SSL_CERT_DIR "
    "SSL_CERT_FILE TEMP TERM TMP TMPDIR TZ USER XDG_CACHE_HOME XDG_CONFIG_HOME "
    "XDG_DATA_HOME XDG_RUNTIME_DIR"
).split()


def main() -> None:
    base = os.path.abspath(sys.argv[1])
    vibe = shutil.which("vibe")
    assert vibe is not None
    env = {k: os.environ[k] for k in ALLOWED if k in os.environ}
    argv = [vibe, "--workdir", f"{base}/wd", "--output-dir", f"{base}/out-b",
            "--agent", "ask", "--output", "json", "--prompt-file", f"{base}/prompt.txt"]
    started = time.monotonic()
    done = subprocess.run(argv, env=env, cwd=base, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=300)
    with open(f"{base}/b.stdout", "w") as f:
        f.write(done.stdout)
    with open(f"{base}/b.stderr", "w") as f:
        f.write(done.stderr)
    print("exit:", done.returncode, "seconds:", round(time.monotonic() - started, 1))
    print("env names:", sorted(env))


if __name__ == "__main__":
    main()
