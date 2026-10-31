#!/usr/bin/env python3
"""Compare the recorded pure lookup code without reading or changing an outbox."""
import hashlib
from pathlib import Path
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
record = root / "docs/evidence/keeper-outbox-membership-20261030"
expected = {
    "old": "9d20563c33cb453448ccdc2043d48ba650ecb9ee28033f16242084e003230977",
    "new": "467aa76c9c97f3d21669d91f0159806228c0d853dadb312be94a3abd9b9b2b86",
}
lookup = {}
for role, commit, start in [
    ("old", base, "let receipt_ids snapshot ="),
    ("new", candidate, "let id_of_entry entry ="),
]:
    text = subprocess.check_output(
        ["git", "-C", str(root), "show", f"{commit}:lib/keeper/keeper_client_tool_outbox.ml"], text=True
    )
    first = text.index(start)
    section = text[first:text.index("\nlet developer_context snapshot =", first)]
    if hashlib.sha256(section.encode()).hexdigest() != expected[role]:
        raise SystemExit(f"unexpected {role} lookup source")
    header = "type entry = {path:string; json:unit}\ntype snapshot = {directory:string; entries:entry list}\n"
    helper = '\nlet make paths = {directory="";entries=List.map (fun path -> {path;json=()}) paths}\n'
    lookup[role] = header + section + helper

out.mkdir(parents=True)
for role, text in lookup.items():
    (out / f"{role}_lookup.ml").write_text(text)
for name in ("lookup_bench", "ids_bench"):
    (out / f"{name}.ml").write_bytes((record / f"{name}.ml.txt").read_bytes())
    subprocess.run(["ocamlopt", "-I", "+unix", "unix.cmxa", "old_lookup.ml", "new_lookup.ml",
                    f"{name}.ml", "-o", name], cwd=out, check=True)
    with (out / f"{name}.csv").open("w") as result, (out / f"{name}.stderr").open("w") as errors:
        subprocess.run([str(out / name)], cwd=out, stdout=result, stderr=errors, check=True)
print(f"Fresh results: {out}")
