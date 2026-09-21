#!/usr/bin/env python3
"""Every JSONL turn-record fixture satisfies the decoder's contract.

The decoder in lib/types/turn_record.ml is the SSOT: `require "..."` names
the fields a record cannot miss, and the `fields_are_unique_known` list
names the fields it accepts at all -- a key outside the list fails with
"turn_record: fields are not exact". Three fixtures merged that the decoder
rejects (#37396): one missing `response_observed_model_input`, one missing
`usage_scope`, both written by hand against a remembered shape rather than
the decoder's own calls. This reads those calls instead of a hand-copied
list, so a key the decoder gains or drops moves the gate with it.

Checks, over dashboard/src/api/fixtures/*.jsonl, per line:
  1. every top-level key is within the decoder's known list
  2. every line carries the decoder's required keys

Exits 1 naming file, line and key. A repository with no JSONL fixture has
nothing to check and exits 0. The self-test (test_check_fixture_decoder_
contract.py) builds a synthetic decoder and fixtures in a temporary
directory and runs the same functions.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DECODER = REPO_ROOT / "lib" / "types" / "turn_record.ml"
FIXTURE_GLOB = "dashboard/src/api/fixtures/*.jsonl"

# The top-level decoder's own words: `require "name"` inside of_json, and
# the list literal handed to fields_are_unique_known. Slicing of_json by the
# next top-level `let ` keeps nested decoders (prompt_block, input_component,
# raw_trace_run_ref) out of the required set -- their keys are their own
# contracts.
KNOWN_RE = re.compile(r"fields_are_unique_known\s*\[(.*?)\]\s*fields", re.DOTALL)
REQUIRE_RE = re.compile(r'require\s+"([^"]+)"')


def _of_json_slice(decoder_text: str) -> str:
    start = decoder_text.index("let of_json")
    tail = decoder_text[start + len("let of_json") :]
    nxt = re.search(r"\nlet ", tail)
    return tail if nxt is None else tail[: nxt.start()]


def extract_required_keys(decoder_text: str) -> list[str]:
    return REQUIRE_RE.findall(_of_json_slice(decoder_text))


def extract_known_keys(decoder_text: str) -> list[str]:
    # Search inside the of_json slice only: nested decoders call
    # fields_are_unique_known with their own lists, and the first call in
    # file order is not the top-level one.
    match = KNOWN_RE.search(_of_json_slice(decoder_text))
    if match is None:
        raise ValueError("fields_are_unique_known list not found in the top-level decoder")
    return re.findall(r'"([^"]+)"', match.group(1))


def check_fixture(path: Path, required: set[str], known: set[str]) -> list[str]:
    findings: list[str] = []
    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                findings.append(f"{path}:{lineno}: not valid JSON: {error.msg}")
                continue
            if not isinstance(record, dict):
                findings.append(f"{path}:{lineno}: top level is not an object")
                continue
            keys = set(record)
            for name in sorted(keys - known):
                findings.append(f"{path}:{lineno}: unknown key {name!r} (decoder rejects: fields are not exact)")
            for name in sorted(required - keys):
                findings.append(f"{path}:{lineno}: missing required key {name!r} (decoder rejects: missing field)")
    return findings


def main(argv: list[str]) -> int:
    if argv:
        print(f"usage: {Path(__file__).name}", file=sys.stderr)
        return 1
    decoder_text = DECODER.read_text(encoding="utf-8")
    required = set(extract_required_keys(decoder_text))
    known = set(extract_known_keys(decoder_text))
    missing_from_known = required - known
    if missing_from_known:
        print(
            "decoder inconsistency: required keys outside the known list: "
            + ", ".join(sorted(missing_from_known)),
            file=sys.stderr,
        )
        return 1
    fixtures = sorted(REPO_ROOT.glob(FIXTURE_GLOB))
    if not fixtures_exist(fixtures):
        print(f"no fixture under {FIXTURE_GLOB}; nothing to check")
        return 0
    findings: list[str] = []
    for fixture in fixtures:
        findings.extend(check_fixture(fixture, required, known))
    if findings:
        print(f"{len(findings)} fixture line(s) the turn-record decoder rejects:")
        for finding in findings:
            print(f"  {finding}")
        return 1
    count = sum(1 for _ in fixtures)
    print(f"{count} fixture file(s) satisfy the turn-record decoder contract")
    return 0


def fixtures_exist(fixtures: list[Path]) -> bool:
    return bool(fixtures)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))