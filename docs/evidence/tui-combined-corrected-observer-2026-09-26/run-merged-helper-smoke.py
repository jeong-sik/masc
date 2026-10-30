"""Run the separate merged-helper smoke; never compare its timings with CI."""
from pathlib import Path
import contextlib
import hashlib
import json
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
binary = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(exist_ok=False)
for key in list(os.environ):
    if key.startswith("MASC_"):
        del os.environ[key]
sys.path.insert(0, str(root / "test"))
import test_tui_input_frame_pty as scenario


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


helper = Path(scenario.h.__file__).resolve()
assert helper == root / "test/test_tui_keyboard_input.py"
assert digest(helper) == "cdd6271f169c806f6ba19fd2506daad4a52b33d7daddbb0ef0a7df8f884abe66"
assert digest(Path(scenario.__file__)) == "2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55"
assert digest(binary) == "c96d72f1a3ba9379c47f8dc777c67e12edb2141b4da28770f40f7471593e4383"
identity = {
    "source_head": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "helper": str(helper), "helper_sha256": digest(helper),
    "scenario_sha256": digest(Path(scenario.__file__)),
    "runner_sha256": digest(Path(__file__)),
    "binary": str(binary), "binary_sha256": digest(binary),
    "scope": "separate merged-helper smoke; no before/after latency claim",
}
(out / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
with (out / "stdout.txt").open("w") as stdout, (out / "stderr.txt").open("w") as stderr:
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        scenario.run(str(binary), cycles=10, retained_channels=250)
assert digest(helper) == identity["helper_sha256"]
assert digest(binary) == identity["binary_sha256"]
print("merged helper: 100 transitions and draft PASS")
