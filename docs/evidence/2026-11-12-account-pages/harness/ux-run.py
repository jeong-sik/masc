"""Fills the placeholders of ux-measure3.mjs and prints the script, for
`ego-browser nodejs`. usage: python3 ux-run.py SPACE LABEL OUT_DIR STATES_JSON
SPACE is a task space name; STATES_JSON is a JSON array of
[name, base, scenario or null, path]."""
import json
import pathlib
import sys

space, label, out, states = sys.argv[1:5]
script = (pathlib.Path(__file__).parent / "ux-measure3.mjs").read_text()
json.loads(states)
axe = pathlib.Path(__file__).resolve().parent / "axe.min.js"
assert axe.is_file(), f"put axe.min.js of axe-core next to this script: {axe}"
for key, value in (
    ('const AXE = "__AXE__";', f"const AXE = {json.dumps(str(axe))};"),
    ("const SPACE = __SPACE__;", f"const SPACE = {json.dumps(space)};"),
    ('const LABEL = "__LABEL__";', f"const LABEL = {json.dumps(label)};"),
    ('const OUT = "__OUT__";', f"const OUT = {json.dumps(out)};"),
    ("const STATES = __STATES__;", f"const STATES = {states};"),
):
    assert script.count(key) == 1, key
    script = script.replace(key, value)
sys.stdout.write(script)
