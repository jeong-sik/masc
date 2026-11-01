#!/usr/bin/env python3
"""Recompile the real stream modules and write a fresh isolated comparison."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: reproduce.py NEW_OUTPUT_DIRECTORY BASE_COMMIT CANDIDATE_COMMIT")
root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
out = Path(sys.argv[1])
if not out.is_absolute():
    out = root / out
if out.exists():
    raise SystemExit("output directory already exists")
base, candidate = sys.argv[2:]
record = root / "docs/evidence/tui-fleet-observation-20261030"

def source(commit, path):
    return subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{path}"])

paths = [
    "lib/keeper/keeper_fleet_grade.mli", "lib/keeper/keeper_fleet_grade.ml",
    "lib/keeper/keeper_fleet_blocker.mli", "lib/keeper/keeper_fleet_blocker.ml",
    "lib/fleet_stream/fleet_stream.mli", "lib/fleet_stream/fleet_stream.ml",
    "lib/sse_wire/sse_wire.mli", "lib/sse_wire/sse_wire.ml",
    "bin/masc_tui_fleet_stream.mli", "test/test_tui_fleet_stream.ml",
]
shared = {}
for path in paths:
    shared[path] = source(base, path)
    if shared[path] != source(candidate, path):
        raise SystemExit(f"shared source changed: {path}")
old = source(base, "bin/masc_tui_fleet_stream.ml")
new = source(candidate, "bin/masc_tui_fleet_stream.ml")
expected_old = "62475ac439e603c9b6157defa0e41d03f04e390e07d347dcde1735a76d4692fc"
expected_new = "5e564835d6ef831731850bffbf1a73fb0f9e8235093b5e20db253ad28c3e2f27"
if hashlib.sha256(old).hexdigest() != expected_old or hashlib.sha256(new).hexdigest() != expected_new:
    raise SystemExit("stream source does not match the recorded bytes")

tests = shared["test/test_tui_fleet_stream.ml"].decode()
a = tests.index("let test_the_screen_draws_only_what_a_following_job_posted () =")
b = tests.index("let test_first_scan_failure_is_visible_until_a_real_reading () =")
c = tests.index("(* Whatever the hub does and however the bytes are cut")
selected = (tests[:a] + tests[b:c]).replace("module Hub = Masc.Fleet_stream_hub\n", "")
names = re.findall(r"^let (test_[a-z0-9_]+) \(\) =", selected, re.M)
if len(names) != 23:
    raise SystemExit("unexpected selected lifecycle test count")
selected += '\nlet () = run "isolated fleet stream" [ "lifecycle", [\n'
selected += ''.join(f'  test_case "{name}" `Quick {name};\n' for name in names)
selected += '] ]\n'

out.mkdir(parents=True)
wrapper = b"module Fleet_stream = Fleet_stream\nmodule Keeper_fleet_grade = Keeper_fleet_grade\n"
common = [
    "keeper_fleet_grade.mli", "keeper_fleet_grade.ml",
    "keeper_fleet_blocker.mli", "keeper_fleet_blocker.ml",
    "fleet_stream.mli", "fleet_stream.ml", "sse_wire.mli", "sse_wire.ml", "masc.ml",
]
for role, stream in [("old", old), ("new", new)]:
    directory = out / role
    directory.mkdir()
    for path, raw in shared.items():
        if path != "test/test_tui_fleet_stream.ml":
            (directory / Path(path).name).write_bytes(raw)
    (directory / "masc.ml").write_bytes(wrapper)
    (directory / "masc_tui_fleet_stream.ml").write_bytes(stream)
    (directory / "selected_tests.ml").write_text(selected)
    subprocess.run(["ocamlfind", "ocamlopt", "-package", "yojson,alcotest", "-linkpkg",
                    *common, "masc_tui_fleet_stream.mli", "masc_tui_fleet_stream.ml",
                    "selected_tests.ml", "-o", "selected_tests"], cwd=directory, check=True)
    with (directory / "tests.txt").open("w") as result:
        subprocess.run([str(directory / "selected_tests"), "--compact"], cwd=directory, stdout=result, check=True)

directory = out / "diff"
directory.mkdir()
for path, raw in shared.items():
    if path not in ("test/test_tui_fleet_stream.ml", "bin/masc_tui_fleet_stream.mli"):
        (directory / Path(path).name).write_bytes(raw)
(directory / "masc.ml").write_bytes(wrapper)
(directory / "old_client.ml").write_bytes(old)
(directory / "new_client.ml").write_bytes(new)
for name in ("equivalence", "bench"):
    (directory / f"{name}.ml").write_bytes((record / f"{name}.ml.txt").read_bytes())
    packages = "yojson" if name == "equivalence" else "yojson,unix"
    subprocess.run(["ocamlfind", "ocamlopt", "-package", packages, "-linkpkg", *common,
                    "old_client.ml", "new_client.ml", f"{name}.ml", "-o", name], cwd=directory, check=True)
    with (directory / ("equivalence.txt" if name == "equivalence" else "bench.csv")).open("w") as result:
        subprocess.run([str(directory / name)], cwd=directory, stdout=result, check=True)
print(f"Fresh results: {out}")
