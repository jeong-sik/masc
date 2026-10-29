#!/usr/bin/env python3
"""Compare two runs of the auth baseline (plan layer A1), taken before and after a change.

Each directory holds `default/` and `strict/` with the `results.json` and
`extra.json` that `run.sh` writes. A route probe is keyed by method, route path and
probed path. The router can register a path twice and the later registration is the
one that answers, so rows with the same key collapse to the last one. The
`WWW-Authenticate` challenge names the server's own address, which differs per run,
so the port is blanked before comparing.

Runs made with credentials (`probe.py --tokens`) also hold, for every route and
identity (none, bad, worker, admin), the status, the response headers and the body
(a hash, and the text when `--keep-bodies` was given). Those are compared too.

Two runs of the same build still differ in some responses: a counter, a timestamp, an
`etag` that follows the body, a request that times out under load. `--noise DIR` names
a second run of the `before` build and says what may differ by itself:

- a response whose status differs between the two runs is not compared;
- a header that differs between the two runs is left out of the comparison of that
  response;
- a body that differs between the two runs is compared field by field when it is JSON
  and was kept: the fields whose value is the same in both `before` runs must have that
  value `after`. A body that is not JSON, or was not kept, is not compared.
- a body that is the same in both `before` runs must be the same `after`. When it is not,
  and it is JSON and was kept, every field must be the same except the ignored ones;
  otherwise the body differs.
- `--ignore-file FILE` and `--ignore-field REGEX` (repeatable) leave out the JSON fields
  whose path matches, for a value that differs between two builds by design (the commit a
  build reports) or that two runs give the same value for only by chance (a timing).
  A pattern written as `METHOD /route/path :: REGEX` applies to that route only; any
  other pattern applies to every route. `volatile_fields.txt` next to this script lists
  the ones this server has.

Exits 1 when a status differs, a header or a body differs where the two `before` runs
agree, a probe exists on one side only, or a run lost its server part-way (every later
probe would read 0 and look equal).
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path

MODES = ("default", "strict")
STATUS_FIELDS = ("http1_none", "http1_bad", "h2_none", "h2_bad")
SERVER_ADDRESS = re.compile(r"127\.0\.0\.1:\d+")
# probe.py blanks a number that looks like an epoch time as the bare word EPOCH. Read as 0
# it is a JSON number again, so the body still parses.
BLANKED_NUMBER = re.compile(r'(?<![\w"])EPOCH(?![\w"])')
ARRAY_INDEX = re.compile(r"\[\d+\]")

ProbeKey = tuple[str, str, str]
Statuses = tuple[int, ...]
ExtraKey = tuple[str, str, str]
ExtraView = tuple[int, str]
ResponseKey = tuple[str, str, str, str]
SCOPE_SEPARATOR = " :: "


@dataclass(frozen=True, slots=True)
class IgnoreRule:
    """A field-path pattern to leave out; `scope` limits it to one (method, route path)."""

    pattern: re.Pattern[str]
    scope: tuple[str, str] | None = None

    def applies_to(self, method: str, route_path: str) -> bool:
        return self.scope is None or self.scope == (method, route_path)


def parse_ignore_rule(text: str) -> IgnoreRule:
    """`REGEX`, or `METHOD /route/path :: REGEX` for one route."""
    if SCOPE_SEPARATOR not in text:
        return IgnoreRule(re.compile(text))
    scope, pattern = text.split(SCOPE_SEPARATOR, 1)
    parts = scope.split()
    if len(parts) != 2 or not parts[1].startswith("/"):
        raise SystemExit(f"an ignore rule with a scope reads `METHOD /route/path{SCOPE_SEPARATOR}REGEX`, got: {text}")
    return IgnoreRule(re.compile(pattern), (parts[0], parts[1]))


@dataclass(frozen=True, slots=True)
class Response:
    status: int
    headers: dict[str, str]
    body_sha256: str
    body_path: Path | None


def load_results(directory: Path, mode: str) -> tuple[dict[ProbeKey, Statuses], list[str]]:
    data = json.loads((directory / mode / "results.json").read_text(encoding="utf-8"))
    table: dict[ProbeKey, Statuses] = {}
    for row in data["rows"]:
        key = (row["method"], row["route_path"], row["probed_path"])
        table[key] = tuple(int(row[field]) for field in STATUS_FIELDS)
    return table, list(data["server_stopped_at"])


def load_extra(directory: Path, mode: str) -> tuple[dict[ExtraKey, ExtraView], object]:
    data = json.loads((directory / mode / "extra.json").read_text(encoding="utf-8"))
    table: dict[ExtraKey, ExtraView] = {}
    for row in data["rows"]:
        challenge = SERVER_ADDRESS.sub("127.0.0.1:PORT", row.get("www_authenticate") or "")
        table[(row["case"], row["protocol"], row["credential"])] = (int(row["status"]), challenge)
    return table, data.get("dev_token")


def load_responses(directory: Path, mode: str) -> dict[ResponseKey, Response]:
    data = json.loads((directory / mode / "results.json").read_text(encoding="utf-8"))
    table: dict[ResponseKey, Response] = {}
    for row in data["rows"]:
        for identity, fingerprint in row.get("http1_responses", {}).items():
            key = (row["method"], row["route_path"], row["probed_path"], identity)
            name = fingerprint.get("body_file")
            table[key] = Response(
                status=int(fingerprint["status"]),
                headers=dict(fingerprint["headers"]),
                body_sha256=fingerprint["body_sha256"],
                body_path=directory / mode / "bodies" / name if name else None,
            )
    return table


def flatten(value: object, path: str, out: dict[str, str]) -> None:
    """The scalar fields of a JSON value, by path (`.a.b[2].c`)."""
    if isinstance(value, dict):
        for name, child in value.items():
            flatten(child, f"{path}.{name}", out)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            flatten(child, f"{path}[{index}]", out)
    else:
        out[path] = json.dumps(value, sort_keys=True)


def json_fields(response: Response) -> dict[str, str] | None:
    """The fields of the kept body, or None when it was not kept or is not JSON."""
    if response.body_path is None or not response.body_path.exists():
        return None
    try:
        parsed = json.loads(BLANKED_NUMBER.sub("0", response.body_path.read_text(encoding="utf-8")))
    except ValueError:
        return None
    fields: dict[str, str] = {}
    flatten(parsed, "", fields)
    return fields


def is_ignored(path: str, ignore: list[re.Pattern[str]]) -> bool:
    flat = ARRAY_INDEX.sub("[]", path)
    return any(pattern.search(flat) for pattern in ignore)


@dataclass(frozen=True, slots=True)
class Verdict:
    """What comparing one response found."""

    problems: list[str]
    skipped: bool = False  # the status differs between the two before runs
    body: str = "same"  # same | fields | unverified
    fields_checked: int = 0


def judge(
    old: Response, new: Response, noise: Response | None, ignore: list[re.Pattern[str]]
) -> Verdict:
    if noise is not None and noise.status != old.status:
        return Verdict(problems=[], skipped=True, body="unverified")
    if old.status != new.status:
        return Verdict(problems=[f"status {old.status} -> {new.status}"], body="unverified")
    problems: list[str] = []

    unsteady = set()
    if noise is not None:
        unsteady = {name for name in old.headers.keys() | noise.headers.keys() if old.headers.get(name) != noise.headers.get(name)}
    names = (old.headers.keys() | new.headers.keys()) - unsteady
    changed = sorted(name for name in names if old.headers.get(name) != new.headers.get(name))
    if changed:
        problems.append(f"headers differ: {changed}")

    if old.body_sha256 == new.body_sha256:
        return Verdict(problems=problems)

    if noise is None or noise.body_sha256 == old.body_sha256:
        # The two before runs agree on this body, so every field is expected to be the same
        # after, except the ones that differ by design or by timing (the ignore rules).
        old_fields, new_fields = json_fields(old), json_fields(new)
        if old_fields is None or new_fields is None:
            problems.append("body differs")
            return Verdict(problems=problems)
        paths = {path for path in old_fields.keys() | new_fields.keys() if not is_ignored(path, ignore)}
        moved = sorted(path for path in paths if old_fields.get(path) != new_fields.get(path))
        if moved:
            problems.append(f"fields differ: {moved[:3]}")
        return Verdict(problems=problems, body="fields", fields_checked=len(paths))

    old_fields, noise_fields, new_fields = json_fields(old), json_fields(noise), json_fields(new)
    if old_fields is None or noise_fields is None or new_fields is None:
        return Verdict(problems=problems, body="unverified")
    steady = {
        path: value
        for path, value in old_fields.items()
        if noise_fields.get(path) == value and not is_ignored(path, ignore)
    }
    moved = sorted(path for path, value in steady.items() if new_fields.get(path) != value)
    if moved:
        problems.append(f"fields differ: {moved[:3]}")
    return Verdict(problems=problems, body="fields", fields_checked=len(steady))


def compare_routes(
    before_dir: Path, after_dir: Path, mode: str, csv_rows: list[list[object]]
) -> tuple[int, int]:
    """Print what differs in one mode. Returns (probes compared, problems found)."""
    before, before_stopped = load_results(before_dir, mode)
    after, after_stopped = load_results(after_dir, mode)
    problems = 0
    for side, stopped in (("before", before_stopped), ("after", after_stopped)):
        if stopped:
            problems += 1
            print(f"[{mode}] {side}: the server stopped at {stopped[:3]}")
    for key in sorted(set(before) - set(after)):
        problems += 1
        print(f"[{mode}] only before: {key}")
    for key in sorted(set(after) - set(before)):
        problems += 1
        print(f"[{mode}] only after:  {key}")
    shared = sorted(set(before) & set(after))
    for key in shared:
        csv_rows.append([mode, *key, *before[key], *after[key]])
        if before[key] != after[key]:
            problems += 1
            print(f"[{mode}] {key[0]:6s} {key[1]:52s} before={before[key]} after={after[key]}")
    print(f"[{mode}] route probes: {len(before)} before, {len(after)} after, {len(shared)} shared")
    return len(shared) * len(STATUS_FIELDS), problems


def compare_extra(before_dir: Path, after_dir: Path, mode: str) -> tuple[int, int]:
    """Print what differs in the cases outside the router table. Returns (cases, problems)."""
    before, before_dev = load_extra(before_dir, mode)
    after, after_dev = load_extra(after_dir, mode)
    problems = 0
    for key in sorted(set(before) | set(after)):
        if before.get(key) != after.get(key):
            problems += 1
            print(f"[{mode}] extra {key} before={before.get(key)} after={after.get(key)}")
    if before_dev != after_dev:
        problems += 1
        print(f"[{mode}] dev-token probe differs: {before_dev} vs {after_dev}")
    print(f"[{mode}] extra cases: {len(before)} before, {len(after)} after")
    return len(set(before) & set(after)), problems


@dataclass(slots=True)
class ResponseTally:
    compared: int = 0
    skipped: int = 0
    body_same: int = 0
    body_fields: int = 0
    body_unverified: int = 0
    problems: int = 0


def compare_responses(
    before_dir: Path,
    after_dir: Path,
    noise_dir: Path | None,
    mode: str,
    csv_rows: list[list[object]],
    ignore: list[IgnoreRule],
) -> ResponseTally:
    """Print what differs in the credentialed responses of one mode."""
    tally = ResponseTally()
    before = load_responses(before_dir, mode)
    after = load_responses(after_dir, mode)
    if not before and not after:
        return tally
    noise = load_responses(noise_dir, mode) if noise_dir is not None else {}
    for key in sorted(set(before) ^ set(after)):
        tally.problems += 1
        print(f"[{mode}] response on one side only: {key}")
    for key in sorted(set(before) & set(after)):
        applicable = [rule.pattern for rule in ignore if rule.applies_to(key[0], key[1])]
        verdict = judge(before[key], after[key], noise.get(key), applicable)
        tally.compared += 1
        tally.skipped += verdict.skipped
        tally.body_same += verdict.body == "same" and not verdict.skipped
        tally.body_fields += verdict.body == "fields"
        tally.body_unverified += verdict.body == "unverified" and not verdict.skipped
        tally.problems += bool(verdict.problems)
        csv_rows.append(
            [mode, *key, before[key].status, after[key].status, verdict.skipped, verdict.body,
             verdict.fields_checked, "; ".join(verdict.problems)]
        )
        if verdict.problems:
            print(f"[{mode}] {key[0]:6s} {key[1]} as {key[3]}: {'; '.join(verdict.problems)}")
    print(
        f"[{mode}] credentialed responses: {tally.compared} shared; "
        f"{tally.skipped} skipped (status differs between the two before runs); "
        f"body: {tally.body_same} same, {tally.body_fields} compared by JSON field, "
        f"{tally.body_unverified} not compared"
    )
    return tally


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before", type=Path, help="out-dir of the run before the change")
    ap.add_argument("after", type=Path, help="out-dir of the run after the change")
    ap.add_argument("--csv", type=Path, help="write every route probe of both runs here")
    ap.add_argument("--responses-csv", type=Path, help="write every credentialed response of both runs here")
    ap.add_argument("--noise", type=Path, help="a second run of the before build, to find what differs by itself")
    ap.add_argument(
        "--ignore-field", action="append", default=[], metavar="[METHOD /route :: ]REGEX",
        help="leave out the JSON fields whose path matches, on every route or on the one named (repeatable)",
    )
    ap.add_argument("--ignore-file", type=Path, help="a file of such rules, one per line")
    args = ap.parse_args()
    patterns: list[str] = list(args.ignore_field)
    if args.ignore_file is not None:
        for line in args.ignore_file.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                patterns.append(line.strip())
    ignore = [parse_ignore_rule(pattern) for pattern in patterns]

    csv_rows: list[list[object]] = []
    response_rows: list[list[object]] = []
    compared = 0
    problems = 0
    totals = ResponseTally()
    for mode in MODES:
        route_count, route_problems = compare_routes(args.before, args.after, mode, csv_rows)
        extra_count, extra_problems = compare_extra(args.before, args.after, mode)
        tally = compare_responses(args.before, args.after, args.noise, mode, response_rows, ignore)
        compared += route_count + extra_count + tally.compared
        problems += route_problems + extra_problems + tally.problems
        totals.compared += tally.compared
        totals.skipped += tally.skipped
        totals.body_same += tally.body_same
        totals.body_fields += tally.body_fields
        totals.body_unverified += tally.body_unverified
    print(f"compared {compared} statuses, {problems} problems")
    if totals.compared or totals.skipped or totals.body_same or totals.body_fields or totals.body_unverified:
        print(
            f"credentialed bodies: {totals.body_same} same, {totals.body_fields} compared by JSON field, "
            f"{totals.body_unverified} not compared, {totals.skipped} responses skipped"
        )

    if args.csv is not None:
        with args.csv.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(
                ["mode", "method", "route_path", "probed_path"]
                + [f"before_{field}" for field in STATUS_FIELDS]
                + [f"after_{field}" for field in STATUS_FIELDS]
            )
            writer.writerows(csv_rows)
    if args.responses_csv is not None:
        with args.responses_csv.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(
                ["mode", "method", "route_path", "probed_path", "identity", "before_status", "after_status",
                 "skipped", "body", "fields_checked", "problems"]
            )
            writer.writerows(response_rows)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
