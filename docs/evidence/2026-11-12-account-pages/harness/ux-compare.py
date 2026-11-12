"""Compares two measurements of ux-measure3.mjs.
usage: ux-compare.py [--added=NAME,...] BEFORE.json AFTER.json [STATE_BEFORE=STATE_AFTER ...]
With no pairs, every state of BEFORE is compared with the state of the same
name in AFTER. A pair compares two states of different names; BEFORE and AFTER
may be one file.

Prints one line per pair: how many values were compared, the two digests of
the computed styles, and "same" or the values that differ. The label, the
state name and the number of attempts are not compared. When a digest differs and the values behind it were filed
(OUT/styles/*.json.gz next to each JSON), the properties that differ are
printed, twenty at most per window size.
--added names properties that only AFTER has, such as custom properties a
sheet starts to define. Every element inherits them, so they change every
digest. A window whose filed values differ only by them, absent before, is
the same, and the line says how many such values it set aside.
Exits 1 when a pair differs or a state is missing."""
import gzip
import json
import pathlib
import sys

SKIP = {"label", "state", "attempts"}
LIMIT = 20
ADDED = "--added="

added: set[str] = set()
arguments: list[str] = []
for argument in sys.argv[1:]:
    if argument.startswith(ADDED):
        added |= {name for name in argument[len(ADDED):].split(",") if name}
    else:
        arguments.append(argument)


def load(path):
    rows = json.load(open(path))
    return {row["state"]: row for row in rows}, pathlib.Path(path).parent / "styles"


def filed(folder, row, width):
    path = folder / f"{row['label']}-{row['state']}-{width}.json.gz"
    return json.loads(gzip.decompress(path.read_bytes())) if path.is_file() else None


def properties(old, new):
    """The values that differ, and how many differ only because AFTER sets a
    property of --added that BEFORE did not have."""
    out = []
    set_aside = 0
    for element in sorted(old.keys() | new.keys()):
        a, b = old.get(element), new.get(element)
        if a is None or b is None:
            out.append(f"{element}: in one reading only")
            continue
        for name in sorted(a.keys() | b.keys()):
            if a.get(name) == b.get(name):
                continue
            if name in added and name not in a:
                set_aside += 1
                continue
            out.append(f"{element} {name}: {a.get(name)} -> {b.get(name)}")
    return out, set_aside


before, before_styles = load(arguments[0])
after, after_styles = load(arguments[1])
pairs = [tuple(arg.split("=", 1)) for arg in arguments[2:]] or [(state, state) for state in before]
differs = False
for left, right in pairs:
    if left not in before or right not in after:
        differs = True
        print(f"{left} = {right}\tmissing")
        continue
    old, new = before[left], after[right]
    keys = sorted((old.keys() | new.keys()) - SKIP)
    changed = [key for key in keys if old.get(key) != new.get(key)]
    notes = []
    for key in list(changed):
        if key not in ("styles320", "styles1280"):
            notes.append(f"    {key}: {old.get(key)!r} -> {new.get(key)!r}")
            continue
        width = key[len("styles"):]
        facts = {k: (old[key].get(k), new[key].get(k)) for k in old[key] if k != "sha256" and old[key].get(k) != new[key].get(k)}
        if facts:
            notes.append(f"    {key} window: {facts}")
        a, b = filed(before_styles, old, width), filed(after_styles, new, width)
        if a is None or b is None:
            notes.append(f"    {key}: the values behind the digest were not filed")
            continue
        lines, set_aside = properties(a, b)
        if not lines and not facts:
            changed.remove(key)
            notes.append(f"    {key}: same but for {set_aside} values of the added properties")
            continue
        aside = f", besides {set_aside} values of the added properties" if set_aside else ""
        notes.append(f"    {key}: {len(lines)} properties differ{aside}")
        notes.extend(f"      {line}" for line in lines[:LIMIT])
    differs = differs or bool(changed)
    name = left if left == right else f"{left} = {right}"
    digests = " ".join(f"{old[k]['sha256']}/{new[k]['sha256']}" for k in ("styles320", "styles1280"))
    print(f"{name}\t{len(keys)} values\t{old['styles320']['elements']} elements\t{digests}\t{'same' if not changed else 'DIFFERS in ' + ', '.join(changed)}")
    for note in notes:
        print(note)
sys.exit(1 if differs else 0)
