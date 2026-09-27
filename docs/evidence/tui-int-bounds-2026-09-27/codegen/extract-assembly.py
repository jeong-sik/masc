"""Extract complete selected symbol bodies from a verified macOS artifact."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("artifact", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--source", required=True)
args = parser.parse_args()
manifest = json.loads((args.artifact / "manifest.json").read_text())
assert manifest["commit"] == args.source
binary = args.artifact / "masc_tui.exe"
assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest["sha256"][binary.name]
args.output.mkdir(exist_ok=False, parents=True)
selectors = (
    "camlMasc_tui_message_layout$", "camlMasc_tui_scroll$",
    "camlStdlib__Int$min_", "camlStdlib__Int$max_",
)
selected = []
calls = []
function = None
active = False
process = subprocess.Popen(["otool", "-tvV", str(binary)], stdout=subprocess.PIPE, text=True)
for line in process.stdout:
    if line.startswith("_") and line.rstrip().endswith(":"):
        function = line.strip()
        active = any(selector in function for selector in selectors)
    if active:
        selected.append(line)
        if re.search(r"\tb(?:l)?\t_camlStdlib\$(min|max)_\d+\s*$", line):
            calls.append({"function": function, "instruction": line.strip()})
assert process.wait() == 0
assert any(selectors[0] in line for line in selected)
assert any(selectors[1] in line for line in selected)
decoded = "".join(selected).encode()
(args.output / "selected-assembly.txt.gz").write_bytes(gzip.compress(decoded, mtime=0))
(args.output / "bound-call-sites.json").write_text(json.dumps(calls, indent=2) + "\n")
(args.output / "extraction.json").write_text(json.dumps({
    "source": args.source,
    "binary_sha256": manifest["sha256"][binary.name],
    "command": ["otool", "-tvV", "<ARTIFACT>/masc_tui.exe"],
    "selectors": list(selectors),
    "selected_lines": len(selected),
    "decoded_sha256": hashlib.sha256(decoded).hexdigest(),
    "static_generic_bound_branches": len(calls),
}, indent=2) + "\n")
