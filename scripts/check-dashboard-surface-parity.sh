#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-dashboard-surface-parity.sh [--check|--print-nav-json|--print-readiness-json]

Checks that dashboard/src/config/navigation.ts and
lib/dashboard/dashboard_surface_readiness.ml describe the same canonical
Dashboard v1 surface contract.
EOF
}

mode="${1:---check}"
case "$mode" in
  --check|--print-nav-json|--print-readiness-json)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" "$mode" <<'PY'
import json
import re
import sys
from pathlib import Path


repo_root = Path(sys.argv[1])
mode = sys.argv[2]


def fail(message: str) -> None:
    raise SystemExit(message)


def extract_balanced_block(text: str, anchor: str, open_char: str, close_char: str) -> str:
    anchor_idx = text.find(anchor)
    if anchor_idx < 0:
        fail(f"parse error: missing anchor {anchor!r}")
    assign_idx = text.find("=", anchor_idx)
    search_start = assign_idx if assign_idx >= 0 else anchor_idx
    start = text.find(open_char, search_start)
    if start < 0:
        fail(f"parse error: missing {open_char!r} after {anchor!r}")
    depth = 0
    for idx in range(start, len(text)):
        ch = text[idx]
        if ch == open_char:
            depth += 1
        elif ch == close_char:
            depth -= 1
            if depth == 0:
                return text[start + 1:idx]
    fail(f"parse error: unbalanced {open_char}{close_char} after {anchor!r}")


def split_top_level_objects(block: str) -> list[str]:
    objects: list[str] = []
    depth = 0
    start: int | None = None
    for idx, ch in enumerate(block):
        if ch == "{":
            if depth == 0:
                start = idx
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                objects.append(block[start:idx + 1])
                start = None
    return objects


def extract_string(pattern: str, text: str, *, label: str) -> str:
    match = re.search(pattern, text, re.S)
    if not match:
        fail(f"parse error: missing {label}")
    return match.group(1)


def extract_optional_string(pattern: str, text: str) -> str | None:
    match = re.search(pattern, text, re.S)
    return match.group(1) if match else None


def extract_key_array(block: str, key: str) -> str:
    anchor = f"{key}:"
    anchor_idx = block.find(anchor)
    if anchor_idx < 0:
        fail(f"parse error: missing key {key!r}")
    start = block.find("[", anchor_idx)
    if start < 0:
        fail(f"parse error: missing array for key {key!r}")
    depth = 0
    for idx in range(start, len(block)):
        ch = block[idx]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return block[start + 1:idx]
    fail(f"parse error: unbalanced array for key {key!r}")


def parse_navigation_contract() -> list[dict[str, object]]:
    nav_text = (repo_root / "dashboard/src/config/navigation.ts").read_text()
    surfaces_block = extract_balanced_block(
        nav_text,
        "export const DASHBOARD_SURFACES",
        "[",
        "]",
    )
    section_items_block = extract_balanced_block(
        nav_text,
        "export const DASHBOARD_SECTION_ITEMS",
        "{",
        "}",
    )

    def exposure_for(tab: str, hidden: bool) -> str:
        if hidden:
            return "diagnostic"
        if tab == "lab":
            return "lab"
        return "main"

    def meets_main_gate_for(tab: str, hidden: bool) -> bool:
        return (not hidden) and tab != "lab"

    sections_by_tab: dict[str, list[dict[str, object]]] = {}
    for tab in ["monitoring", "command", "connectors", "workspace", "lab", "code"]:
        tab_block = extract_key_array(section_items_block, tab)
        tab_entries: list[dict[str, object]] = []
        for obj in split_top_level_objects(tab_block):
            hidden = re.search(r"hidden:\s*true", obj) is not None
            section_id = extract_string(r"id:\s*'([^']+)'", obj, label=f"{tab} id")
            label = extract_string(r"label:\s*'([^']+)'", obj, label=f"{tab}.{section_id} label")
            tab_entries.append(
                {
                    "id": f"{tab}.{section_id}",
                    "label": label,
                    "route_hash": f"#{tab}?section={section_id}",
                    "exposure_status": exposure_for(tab, hidden),
                    "hidden_from_nav": hidden,
                    "meets_main_gate": meets_main_gate_for(tab, hidden),
                }
            )
        sections_by_tab[tab] = tab_entries

    contract: list[dict[str, object]] = []
    for obj in split_top_level_objects(surfaces_block):
        hidden = re.search(r"hidden:\s*true", obj) is not None
        surface_id = extract_string(r"id:\s*'([^']+)'", obj, label="surface id")
        label = extract_string(r"label:\s*'([^']+)'", obj, label=f"{surface_id} label")
        has_default_params = re.search(r"defaultParams\s*:", obj) is not None
        if has_default_params:
            entries = sections_by_tab.get(surface_id, [])
            if hidden:
                entries = [
                    {
                        **entry,
                        "exposure_status": "diagnostic",
                        "hidden_from_nav": True,
                        "meets_main_gate": False,
                    }
                    for entry in entries
                ]
            contract.extend(entries)
            continue
        contract.append(
            {
                "id": surface_id,
                "label": label,
                "route_hash": f"#{surface_id}",
                "exposure_status": "diagnostic" if hidden else "main",
                "hidden_from_nav": hidden,
                "meets_main_gate": not hidden,
            }
        )
    return contract


def parse_readiness_source() -> list[dict[str, object]]:
    readiness_text = (repo_root / "lib/dashboard/dashboard_surface_readiness.ml").read_text()
    entries_block = extract_balanced_block(readiness_text, "let all_entries =", "[", "]")
    contract: list[dict[str, object]] = []
    for obj in split_top_level_objects(entries_block):
        contract.append(
            {
                "id": extract_string(r'id = "([^"]+)"', obj, label="readiness id"),
                "label": extract_string(r'label = "([^"]+)"', obj, label="readiness label"),
                "route_hash": extract_optional_string(r'route_hash = Some "([^"]+)"', obj),
                "exposure_status": extract_string(
                    r'exposure_status = "([^"]+)"',
                    obj,
                    label="readiness exposure_status",
                ),
                "hidden_from_nav": extract_string(
                    r"hidden_from_nav = (true|false)",
                    obj,
                    label="readiness hidden_from_nav",
                )
                == "true",
                "meets_main_gate": extract_string(
                    r"meets_main_gate = (true|false)",
                    obj,
                    label="readiness meets_main_gate",
                )
                == "true",
            }
        )
    return contract


def emit(payload: list[dict[str, object]]) -> None:
    print(json.dumps({"surfaces": payload}, ensure_ascii=False, indent=2))


nav_contract = parse_navigation_contract()
readiness_contract = parse_readiness_source()

if mode == "--print-nav-json":
    emit(nav_contract)
    raise SystemExit(0)

if mode == "--print-readiness-json":
    emit(readiness_contract)
    raise SystemExit(0)

nav_ids = [entry["id"] for entry in nav_contract]
readiness_ids = [entry["id"] for entry in readiness_contract]

errors: list[str] = []

if nav_ids != readiness_ids:
    missing = [surface_id for surface_id in nav_ids if surface_id not in readiness_ids]
    extra = [surface_id for surface_id in readiness_ids if surface_id not in nav_ids]
    if missing:
        errors.append(f"missing readiness surfaces: {', '.join(missing)}")
    if extra:
        errors.append(f"unexpected readiness surfaces: {', '.join(extra)}")
    if not missing and not extra:
        errors.append("surface order drifted between navigation.ts and dashboard_surface_readiness.ml")

nav_by_id = {entry["id"]: entry for entry in nav_contract}
readiness_by_id = {entry["id"]: entry for entry in readiness_contract}

for surface_id in nav_ids:
    if surface_id not in readiness_by_id:
        continue
    expected = nav_by_id[surface_id]
    actual = readiness_by_id[surface_id]
    for key in [
        "label",
        "route_hash",
        "exposure_status",
        "hidden_from_nav",
        "meets_main_gate",
    ]:
        if expected[key] != actual[key]:
            errors.append(
                f"{surface_id}: {key} expected {expected[key]!r} but got {actual[key]!r}"
            )

if errors:
    for error in errors:
        print(f"dashboard surface parity failed: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"Dashboard surface parity OK: {len(nav_contract)} canonical surfaces aligned "
    "between navigation.ts and dashboard_surface_readiness.ml"
)
PY
