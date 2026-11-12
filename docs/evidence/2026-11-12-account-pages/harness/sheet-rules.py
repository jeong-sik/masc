"""Checks that a split of a style sheet moved its rules and changed none.
usage: sheet-rules.py OLD_SHEET NEW_SHEET [NEW_SHEET...]
The new sheets are read in the order given, which is the order a page sends
them. Two things are compared:
  - the lines that are not comments or blank, as a multiset: each such line of
    OLD_SHEET is in the new sheets as often, and nothing else is;
  - the order of the rules that weigh nothing (they start with ":where(" or
    "*"). Between two of them the later one wins, so their order is part of
    what the sheet means.
Exits 1 when either differs.
Not looked for: two rules of equal weight that set one property on one
element and changed places. Whether a page has such an element is read in a
browser, from the computed style of every element (ux-measure3.mjs)."""
import collections
import pathlib
import sys


def rule_lines(text):
    out, in_comment = [], False
    for line in text.split("\n"):
        stripped = line.strip()
        if in_comment:
            in_comment = "*/" not in stripped
            continue
        if stripped.startswith("/*"):
            in_comment = "*/" not in stripped
            continue
        if stripped:
            out.append(line)
    return out


old = rule_lines(pathlib.Path(sys.argv[1]).read_text())
new = [line for path in sys.argv[2:] for line in rule_lines(pathlib.Path(path).read_text())]
missing = collections.Counter(old) - collections.Counter(new)
added = collections.Counter(new) - collections.Counter(old)
weightless = lambda lines: [line for line in lines if line.startswith((":where(", "*"))]
print(f"rule lines: {len(old)} before, {len(new)} after")
print(f"missing after the split: {sum(missing.values())}, added: {sum(added.values())}")
for line in list(missing) + list(added):
    print("  " + line)
same_order = weightless(old) == weightless(new)
print(f"rules that weigh nothing: {len(weightless(old))}, in the same order: {same_order}")
for line in weightless(new):
    print("  " + line)
sys.exit(0 if not missing and not added and same_order else 1)
