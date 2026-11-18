#!/usr/bin/env python3
"""List the code that names a module the Librarian cut deletes.

usage: list_callers.py <repository root> > callers.tsv

The deleted set is the one the RFC's section 19.2 names in items a to e:
every `lib/keeper/keeper_librarian*.ml` except the five that stay, and the
modules listed by name below. A file outside that set that names one of the
modules has to change at the cut. The output has one row per such file: the
file, how many deleted modules it names, and their names.

A module is found by its capitalised name on a word boundary in `.ml` and
`.mli` files under `lib/` and `bin/`. A call hidden behind `open` or
`include` of another module is not found, and a name inside a comment is.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

STAYS = {
    "keeper_librarian",
    "keeper_librarian_context",
    "keeper_librarian_context_io",
    "keeper_librarian_context_recall",
    "keeper_librarian_context_review",
    "keeper_librarian_runtime",
}
NAMED = """
keeper_memory_os_current_update keeper_memory_os_current_read_anchor
keeper_memory_os_current_range_codec keeper_memory_os_current_receipt_store
keeper_memory_os_current_publication keeper_memory_os_current_revision_evidence
keeper_memory_os_current_journal keeper_memory_os_current_program_apply
keeper_memory_os_current_retraction_plan keeper_memory_os_program
keeper_memory_os_program_publication keeper_memory_os_program_types
keeper_memory_os_journal_codec keeper_memory_os_receipt_selection
keeper_memory_absorbed keeper_memory_admission_queue
keeper_memory_admission_judgment keeper_memory_admission_worker
keeper_memory_cleanup librarian_continuity_snapshot librarian_continuity_report
keeper_continuity_request keeper_continuity_evidence
keeper_continuity_observation keeper_external_read_cursor
keeper_turn_boundaries typesafeai_librarian_preflight
librarian_working_state_evaluation librarian_production_evaluation
""".split()

sources = sorted(
    path
    for top in ("lib", "bin")
    for path in (root / top).rglob("*.ml*")
    if path.suffix in (".ml", ".mli")
)
stems = {path.stem for path in sources}
deleted = {
    stem for stem in stems if stem.startswith("keeper_librarian") and stem not in STAYS
} | {stem for stem in NAMED if stem in stems}
missing = sorted(stem for stem in NAMED if stem not in stems)
if missing:
    sys.exit("named in the RFC but not in the tree: " + " ".join(missing))

pattern = re.compile(
    r"\b(" + "|".join(sorted((s[0].upper() + s[1:] for s in deleted), key=len, reverse=True)) + r")\b"
)
rows: dict[str, set[str]] = {}
for path in sources:
    if path.stem in deleted:
        continue
    found = set(pattern.findall(path.read_text(encoding="utf-8", errors="replace")))
    if found:
        unit = str(path.relative_to(root).with_suffix(""))
        rows.setdefault(unit, set()).update(found)

print("unit\tdeleted modules named\tnames")
for unit in sorted(rows):
    names = sorted(rows[unit])
    print(f"{unit}\t{len(names)}\t{' '.join(names)}")
print(f"# deleted modules {len(deleted)}, units that name one {len(rows)}", file=sys.stderr)
