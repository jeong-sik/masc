"""Prints every value that differs between two runs of console-frame.mjs.

usage: python3 frame-compare.py BEFORE.json AFTER.json
Rows are paired by their place; the label is not compared. Exits 1 when a
value differs or the rows are not the same measures in the same order."""
import json
import sys


def walk(path: str, a: object, b: object, out: list[str]) -> None:
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if path == "" and key == "label":
                continue
            walk(f"{path}.{key}", a.get(key, "<none>"), b.get(key, "<none>"), out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for index, (x, y) in enumerate(zip(a, b)):
            walk(f"{path}[{index}]", x, y, out)
    elif a != b:
        out.append(f"{path}: {json.dumps(a, ensure_ascii=False)} -> {json.dumps(b, ensure_ascii=False)}")


before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
differences: list[str] = []
if len(before) != len(after):
    differences.append(f"rows: {len(before)} -> {len(after)}")
for index, (x, y) in enumerate(zip(before, after)):
    name = f"[{index}] {x.get('measure')} {x.get('width', '')}{x.get('flow', '')}"
    found: list[str] = []
    walk("", x, y, found)
    print(f"{name}: {'same' if not found else 'differs'}")
    differences.extend(f"  {name}{line}" for line in found)
print("\n".join(differences) if differences else "every row is the same")
sys.exit(1 if differences else 0)
