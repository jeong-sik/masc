"""Fills the placeholders of console-frame.mjs and prints the script, for
`ego-browser nodejs`. usage: python3 console-frame-run.py SPACE LABEL OUT_DIR MOCK
SPACE is a task space name; MOCK is the address of console-mock.mjs."""
import json
import pathlib
import sys

space, label, out, mock = sys.argv[1:5]
script = (pathlib.Path(__file__).parent / "console-frame.mjs").read_text()
for key, value in (
    ("const SPACE = __SPACE__;", f"const SPACE = {json.dumps(space)};"),
    ('const LABEL = "__LABEL__";', f"const LABEL = {json.dumps(label)};"),
    ('const OUT = "__OUT__";', f"const OUT = {json.dumps(out)};"),
    ('const MOCK = "__MOCK__";', f"const MOCK = {json.dumps(mock)};"),
):
    assert script.count(key) == 1, key
    script = script.replace(key, value)
sys.stdout.write(script)
