#!/usr/bin/env bash
# RFC-0049 — Dashboard nav-event allowlist parity gate.
#
# Verifies that the OCaml backend allowlist used by
# `lib/dashboard/dashboard_nav_event.ml` (the POST /api/v1/dashboard/nav-event
# validator) matches the TypeScript client's surface + section inventory in:
#   - dashboard/src/types/sse.ts          (VALID_TABS — 9 surfaces)
#   - dashboard/src/config/navigation.ts  (DASHBOARD_SECTION_ITEMS and
#     SETTINGS_ROUTE_SECTION_IDS)
#
# When the two drift, the server silently returns 400 for the unknown
# (surface, section) pair, the client drops the event in its catch(), and
# the corresponding counter never increments. Operators see the new
# section missing from Grafana with no obvious cause.
#
# Run from repo root:
#   scripts/check-dashboard-nav-event-parity.sh
#
# Exit codes:
#   0  matched
#   1  drift detected
#   2  parse error
#
# Pattern follows scripts/check-dashboard-surface-parity.sh.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-dashboard-nav-event-parity.sh [--check|--print-client-json|--print-server-json]

  --check                Default. Compare and exit 1 on drift.
  --print-client-json    Print the client-side inventory as JSON, no compare.
  --print-server-json    Print the server-side inventory as JSON, no compare.
EOF
}

mode="${1:---check}"
case "$mode" in
  --check|--print-client-json|--print-server-json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
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
    print(f"check-dashboard-nav-event-parity: {message}", file=sys.stderr)
    raise SystemExit(2)


def read(path: str) -> str:
    p = repo_root / path
    if not p.exists():
        fail(f"missing source: {path}")
    return p.read_text()


# --- Client side -----------------------------------------------------------

def parse_valid_tabs() -> list[str]:
    """Extract `export const VALID_TABS = [ ... ]` (with or without a
    `: TabId[]` annotation — #24409 dropped it for an `as const` array)
    from sse.ts."""
    text = read("dashboard/src/types/sse.ts")
    m = re.search(
        r"export\s+const\s+VALID_TABS\s*(?::\s*TabId\[\]\s*)?=\s*\[([^\]]*)\]",
        text,
    )
    if not m:
        fail("could not find VALID_TABS in dashboard/src/types/sse.ts")
    raw = m.group(1)
    return re.findall(r"'([^']+)'", raw)


def parse_section_items() -> dict[str, list[str]]:
    """Extract `DASHBOARD_SECTION_ITEMS` per-tab section IDs from navigation.ts."""
    text = read("dashboard/src/config/navigation.ts")
    anchor_idx = text.find("DASHBOARD_SECTION_ITEMS")
    if anchor_idx < 0:
        fail("DASHBOARD_SECTION_ITEMS not found in navigation.ts")
    open_idx = text.find("{", anchor_idx)
    if open_idx < 0:
        fail("DASHBOARD_SECTION_ITEMS '{' not found")
    depth = 0
    end = -1
    for i in range(open_idx, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        fail("DASHBOARD_SECTION_ITEMS unbalanced braces")
    block = text[open_idx:end]
    redirect_only_sections = parse_section_redirect_keys(text)

    # Match top-level `<tab>: [` followed by a balanced `[ ... ]`.
    out: dict[str, list[str]] = {}
    pos = 0
    while True:
        m = re.search(r"^\s*([a-zA-Z_][a-zA-Z0-9_-]*)\s*:\s*\[", block[pos:], re.MULTILINE)
        if not m:
            break
        tab = m.group(1)
        arr_start = pos + m.end() - 1
        depth_b = 0
        arr_end = -1
        for i in range(arr_start, len(block)):
            ch = block[i]
            if ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b -= 1
                if depth_b == 0:
                    arr_end = i + 1
                    break
        if arr_end < 0:
            fail(f"unbalanced section array for tab {tab}")
        arr_text = block[arr_start:arr_end]
        # section IDs appear as `id: '<value>'`
        ids = [
            section_id
            for section_id in re.findall(r"\bid\s*:\s*'([^']+)'", arr_text)
            if (tab, section_id) not in redirect_only_sections
        ]
        out[tab] = ids
        pos = arr_end
    settings_ids = parse_settings_route_section_ids(text)
    if settings_ids:
        out["settings"] = settings_ids
    return out


def parse_settings_route_section_ids(text: str) -> list[str]:
    """Extract routeable settings section IDs.

    Settings is intentionally a sectionless sidebar surface, but the router
    preserves non-default settings hashes such as `#settings?section=runtimes`.
    The default account section normalizes to no `section` param, so it is not
    a resolved nav-event target.
    """
    m = re.search(
        r"export\s+const\s+SETTINGS_ROUTE_SECTION_IDS\s*=\s*\[([^\]]*)\]\s+as\s+const",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not m:
        return []
    return [section_id for section_id in re.findall(r"'([^']+)'", m.group(1)) if section_id != "account"]


def parse_section_redirect_keys(text: str) -> set[tuple[str, str]]:
    """Extract same-surface section redirects from SECTION_REDIRECTS.

    Redirects are applied before section validation in navigation.ts, so a
    section item with a direct redirect entry is a legacy compatibility target,
    not a resolved nav-event target.
    """
    anchor_idx = text.find("SECTION_REDIRECTS")
    if anchor_idx < 0:
        return set()
    open_idx = text.find("{", anchor_idx)
    if open_idx < 0:
        fail("SECTION_REDIRECTS '{' not found")
    depth = 0
    end = -1
    for i in range(open_idx, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        fail("SECTION_REDIRECTS unbalanced braces")
    block = text[open_idx:end]
    return {
        (surface, section)
        for surface, section in re.findall(r"'([^']+):([^']+)'\s*:", block)
    }


def client_inventory() -> dict[str, object]:
    tabs = parse_valid_tabs()
    section_map = parse_section_items()
    # Tabs with empty arrays still must appear with [].
    for t in tabs:
        section_map.setdefault(t, [])
    return {
        "valid_surfaces": sorted(tabs),
        "valid_sections": {t: sorted(set(sections)) for t, sections in section_map.items()},
    }


# --- Server side -----------------------------------------------------------

def parse_ocaml_string_list_block(text: str, anchor: str) -> list[str]:
    """Extract `let <anchor> = [ "a"; "b"; ... ]` strings."""
    m = re.search(rf"\b{anchor}\b\s*=\s*\[", text)
    if not m:
        fail(f"could not find OCaml binding {anchor}")
    start = m.end() - 1
    depth = 0
    end = -1
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        fail(f"{anchor}: unbalanced bracket")
    return re.findall(r'"([^"]+)"', text[start:end])


def parse_valid_sections_ocaml(text: str) -> dict[str, list[str]]:
    """Extract `let valid_sections = [ "tab", [ "a"; "b" ]; ... ]`."""
    m = re.search(r"\bvalid_sections\b\s*=\s*\[", text)
    if not m:
        fail("could not find OCaml binding valid_sections")
    start = m.end() - 1
    depth = 0
    end = -1
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        fail("valid_sections: unbalanced outer bracket")
    block = text[start + 1 : end - 1]
    out: dict[str, list[str]] = {}
    # Pattern: `"surface", [ "section1"; "section2"; ... ]`
    for m in re.finditer(r'"([^"]+)"\s*,\s*\[([^\]]*)\]', block):
        surface = m.group(1)
        sections = re.findall(r'"([^"]+)"', m.group(2))
        out[surface] = sections
    return out


def server_inventory() -> dict[str, object]:
    text = read("lib/dashboard/dashboard_nav_event.ml")
    return {
        "valid_surfaces": sorted(parse_ocaml_string_list_block(text, "valid_surfaces")),
        "valid_sections": {s: sorted(set(secs)) for s, secs in parse_valid_sections_ocaml(text).items()},
    }


# --- Compare ---------------------------------------------------------------

def compare(client: dict[str, object], server: dict[str, object]) -> list[str]:
    errors: list[str] = []
    cs = set(client["valid_surfaces"])
    ss = set(server["valid_surfaces"])
    if cs != ss:
        only_client = sorted(cs - ss)
        only_server = sorted(ss - cs)
        if only_client:
            errors.append(f"surfaces in navigation.ts but not in dashboard_nav_event.ml: {only_client}")
        if only_server:
            errors.append(f"surfaces in dashboard_nav_event.ml but not in navigation.ts: {only_server}")

    client_secs = client["valid_sections"]
    server_secs = server["valid_sections"]

    # Server is allowed to include a surface with no sections (e.g.
    # cockpit, overview, logs are absent from server's valid_sections —
    # they emit only a surface event, no section event).
    surfaces_with_client_sections = {s for s, secs in client_secs.items() if secs}
    for surface in sorted(surfaces_with_client_sections):
        client_set = set(client_secs[surface])
        server_set = set(server_secs.get(surface, []))
        only_client = sorted(client_set - server_set)
        only_server = sorted(server_set - client_set)
        if only_client:
            errors.append(
                f"surface {surface!r}: sections in navigation.ts not in dashboard_nav_event.ml: {only_client}"
            )
        if only_server:
            errors.append(
                f"surface {surface!r}: sections in dashboard_nav_event.ml not in navigation.ts: {only_server}"
            )

    # Server should not list sections under a surface that has none on the client.
    for surface in sorted(set(server_secs) - surfaces_with_client_sections):
        if server_secs[surface]:
            errors.append(
                f"surface {surface!r}: dashboard_nav_event.ml lists sections {server_secs[surface]} but navigation.ts has none"
            )

    return errors


# --- Main ------------------------------------------------------------------

if mode == "--print-client-json":
    print(json.dumps(client_inventory(), indent=2, sort_keys=True))
    raise SystemExit(0)
if mode == "--print-server-json":
    print(json.dumps(server_inventory(), indent=2, sort_keys=True))
    raise SystemExit(0)

# --check
client = client_inventory()
server = server_inventory()
errs = compare(client, server)
if not errs:
    print("dashboard nav-event allowlist parity: OK")
    raise SystemExit(0)

print("dashboard nav-event allowlist parity: DRIFT", file=sys.stderr)
for e in errs:
    print(f"  - {e}", file=sys.stderr)
print(
    "\nFix: update lib/dashboard/dashboard_nav_event.ml `valid_sections` to match "
    "dashboard/src/config/navigation.ts `DASHBOARD_SECTION_ITEMS`. "
    "Drift causes silent counter loss (server 400 → client drop → no Grafana data).",
    file=sys.stderr,
)
raise SystemExit(1)
PY
