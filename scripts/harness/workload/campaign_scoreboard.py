#!/usr/bin/env python3
"""E0 campaign scoreboard: k-of-3 per mission band from three pinned runner bundles.

Inputs are files only, so the scoreboard is deterministic and testable:

* ``--catalog``   the mission catalog (``masc.keeper_multi_collaboration_missions.v1``);
  bands are derived from mission ``phase`` values, never from hard-coded ids.
* ``--bundle``    exactly three runner bundles (``masc.keeper_multi_collaboration_evidence.v1``)
  with distinct ``run_id`` and one shared ``source_sha``.
* ``--residuals`` this round's residual classification
  (``masc.keeper_campaign_residuals.v1``): every assertion that failed in any of
  the three runs needs one entry with a ``cause`` from the closed enum.
* ``--previous-residuals`` (optional) last round's residual file; the round is
  counted only when every issue it names is CLOSED.
* ``--issue-states`` (required when previous residuals name issues)
  ``masc.github_issue_states.v1`` written by ``campaign_issue_states.sh``.

The output (``masc.keeper_campaign_scoreboard.v1``) is what Goal
``goal-campaign-ratchet-20260902`` reads: ``verification_band.k_of_3_passed``.
``counted=false`` never blocks anything; it records why the round is not a score.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping

CATALOG_SCHEMA = "masc.keeper_multi_collaboration_missions.v1"
BUNDLE_SCHEMA = "masc.keeper_multi_collaboration_evidence.v1"
RESIDUALS_SCHEMA = "masc.keeper_campaign_residuals.v1"
ISSUE_STATES_SCHEMA = "masc.github_issue_states.v1"
SCOREBOARD_SCHEMA = "masc.keeper_campaign_scoreboard.v1"

RUNS_PER_ROUND = 3
VERIFICATION_BAND_PHASES: frozenset[str] = frozenset({"verification", "delivery_proof"})
PILOT_BAND_PHASES: frozenset[str] = frozenset({"claim_reproduction"})
RESIDUAL_CAUSES: frozenset[str] = frozenset(
    {"infra_rate_limit", "harness", "model_behavior", "product"}
)
ISSUE_REF = re.compile(r"^[^/\s#]+/[^/\s#]+#[1-9][0-9]*$")
ISSUE_STATE_CLOSED = "CLOSED"
ISSUE_STATE_OPEN = "OPEN"
COUNTED_REASONS: frozenset[str] = frozenset(
    {"ok", "residual_unclassified", "previous_issue_open"}
)


class ScoreboardError(RuntimeError):
    """Input that cannot become a score. Exit code 2."""


@dataclass(frozen=True, slots=True)
class Mission:
    id: str
    phase: str
    assertions: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class MissionResult:
    id: str
    status: str
    failed_assertions: tuple[str, ...]
    assertion_names: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Bundle:
    run_id: str
    source_sha: str
    generated_at: str
    missions: Mapping[str, MissionResult]


@dataclass(frozen=True, slots=True)
class Residual:
    mission_id: str
    assertion: str
    cause: str
    issue: str | None
    summary: str


@dataclass(frozen=True, slots=True)
class Residuals:
    source_sha: str
    entries: tuple[Residual, ...]

    def issues(self) -> tuple[str, ...]:
        return tuple(sorted({e.issue for e in self.entries if e.issue is not None}))

    def covers(self, mission_id: str, assertion: str) -> bool:
        return any(e.mission_id == mission_id and e.assertion == assertion for e in self.entries)


def _read_json(path: pathlib.Path) -> dict[str, object]:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ScoreboardError(f"{path}: cannot read JSON: {error}") from error
    if not isinstance(loaded, dict):
        raise ScoreboardError(f"{path}: top level must be an object")
    return loaded


def _require_schema(doc: dict[str, object], expected: str, where: str) -> None:
    if doc.get("schema") != expected:
        raise ScoreboardError(f"{where}: schema must be {expected!r}, got {doc.get('schema')!r}")


def _require_str(doc: Mapping[str, object], key: str, where: str) -> str:
    value = doc.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ScoreboardError(f"{where}: {key} must be a non-empty string")
    return value


def _require_list(doc: Mapping[str, object], key: str, where: str) -> list[object]:
    value = doc.get(key)
    if not isinstance(value, list):
        raise ScoreboardError(f"{where}: {key} must be a list")
    return value


def parse_catalog(doc: dict[str, object], where: str = "catalog") -> tuple[Mission, ...]:
    _require_schema(doc, CATALOG_SCHEMA, where)
    missions: list[Mission] = []
    for index, raw in enumerate(_require_list(doc, "missions", where)):
        if not isinstance(raw, dict):
            raise ScoreboardError(f"{where}: missions[{index}] must be an object")
        label = f"{where}: missions[{index}]"
        assertions = tuple(
            _require_str({"a": a}, "a", f"{label}.assertions")
            for a in _require_list(raw, "assertions", label)
        )
        missions.append(
            Mission(
                id=_require_str(raw, "id", label),
                phase=_require_str(raw, "phase", label),
                assertions=assertions,
            )
        )
    ids = [m.id for m in missions]
    if not ids:
        raise ScoreboardError(f"{where}: catalog declares no missions")
    if len(set(ids)) != len(ids):
        raise ScoreboardError(f"{where}: duplicate mission ids")
    return tuple(missions)


def parse_bundle(doc: dict[str, object], where: str) -> Bundle:
    _require_schema(doc, BUNDLE_SCHEMA, where)
    results: dict[str, MissionResult] = {}
    for index, raw in enumerate(_require_list(doc, "missions", where)):
        if not isinstance(raw, dict):
            raise ScoreboardError(f"{where}: missions[{index}] must be an object")
        label = f"{where}: missions[{index}]"
        mission_id = _require_str(raw, "id", label)
        status = _require_str(raw, "status", label)
        if status not in {"passed", "failed"}:
            raise ScoreboardError(f"{label}: status must be passed or failed, got {status!r}")
        failed: list[str] = []
        names: list[str] = []
        for a_index, assertion in enumerate(_require_list(raw, "assertions", label)):
            if not isinstance(assertion, dict):
                raise ScoreboardError(f"{label}.assertions[{a_index}] must be an object")
            name = _require_str(assertion, "name", f"{label}.assertions[{a_index}]")
            passed = assertion.get("passed")
            if not isinstance(passed, bool):
                raise ScoreboardError(f"{label}.assertions[{a_index}].passed must be a boolean")
            names.append(name)
            if not passed:
                failed.append(name)
        if (status == "passed") != (failed == []):
            raise ScoreboardError(
                f"{label}: status {status!r} disagrees with its assertions "
                f"(failed={failed}); the scoreboard trusts assertions, not the label"
            )
        if mission_id in results:
            raise ScoreboardError(f"{where}: duplicate mission id {mission_id}")
        results[mission_id] = MissionResult(
            id=mission_id,
            status=status,
            failed_assertions=tuple(failed),
            assertion_names=tuple(names),
        )
    return Bundle(
        run_id=_require_str(doc, "run_id", where),
        source_sha=_require_str(doc, "source_sha", where),
        generated_at=_require_str(doc, "generated_at", where),
        missions=MappingProxyType(results),
    )


def parse_residuals(doc: dict[str, object], where: str) -> Residuals:
    _require_schema(doc, RESIDUALS_SCHEMA, where)
    entries: list[Residual] = []
    for index, raw in enumerate(_require_list(doc, "entries", where)):
        if not isinstance(raw, dict):
            raise ScoreboardError(f"{where}: entries[{index}] must be an object")
        label = f"{where}: entries[{index}]"
        cause = _require_str(raw, "cause", label)
        if cause not in RESIDUAL_CAUSES:
            raise ScoreboardError(
                f"{label}: cause must be one of {sorted(RESIDUAL_CAUSES)}, got {cause!r}"
            )
        issue = raw.get("issue")
        if issue is not None and (not isinstance(issue, str) or not ISSUE_REF.fullmatch(issue)):
            raise ScoreboardError(f"{label}: issue must be null or 'owner/repo#N', got {issue!r}")
        entries.append(
            Residual(
                mission_id=_require_str(raw, "mission_id", label),
                assertion=_require_str(raw, "assertion", label),
                cause=cause,
                issue=issue,
                summary=_require_str(raw, "summary", label),
            )
        )
    return Residuals(source_sha=_require_str(doc, "source_sha", where), entries=tuple(entries))


def parse_issue_states(doc: dict[str, object], where: str) -> Mapping[str, str]:
    _require_schema(doc, ISSUE_STATES_SCHEMA, where)
    raw = doc.get("issues")
    if not isinstance(raw, dict):
        raise ScoreboardError(f"{where}: issues must be an object")
    states: dict[str, str] = {}
    for issue, state in raw.items():
        if not isinstance(state, str) or state not in {ISSUE_STATE_OPEN, ISSUE_STATE_CLOSED}:
            raise ScoreboardError(f"{where}: {issue} state must be OPEN or CLOSED, got {state!r}")
        states[issue] = state
    return MappingProxyType(states)


def band_missions(catalog: tuple[Mission, ...], phases: frozenset[str]) -> tuple[Mission, ...]:
    return tuple(m for m in catalog if m.phase in phases)


def _check_round(catalog: tuple[Mission, ...], bundles: tuple[Bundle, ...]) -> str:
    if len(bundles) != RUNS_PER_ROUND:
        raise ScoreboardError(f"a round is exactly {RUNS_PER_ROUND} runs, got {len(bundles)}")
    run_ids = [b.run_id for b in bundles]
    if len(set(run_ids)) != RUNS_PER_ROUND:
        raise ScoreboardError(f"run_id must be distinct across the round, got {run_ids}")
    shas = {b.source_sha for b in bundles}
    if len(shas) != 1:
        raise ScoreboardError(f"all runs must pin one source_sha, got {sorted(shas)}")
    expected = {m.id for m in catalog}
    for bundle in bundles:
        missing = sorted(expected - set(bundle.missions))
        if missing:
            raise ScoreboardError(f"run {bundle.run_id} lacks catalog missions {missing}")
        for mission in catalog:
            got = sorted(bundle.missions[mission.id].assertion_names)
            if got != sorted(mission.assertions):
                raise ScoreboardError(
                    f"run {bundle.run_id} mission {mission.id} reports assertions {got}, "
                    f"catalog declares {sorted(mission.assertions)}"
                )
    return shas.pop()


def _band_report(
    missions: tuple[Mission, ...], bundles: tuple[Bundle, ...], *, counted: bool
) -> dict[str, object]:
    """``k_of_3_passed`` is the score and exists only for a counted round.

    An uncounted round still records what happened (``passes_of_k`` and
    ``k_of_3_if_counted``) so the number is not lost, but the field a Goal
    reads stays null: the round is evidence, not a score."""
    per_mission: dict[str, int] = {}
    for mission in missions:
        per_mission[mission.id] = sum(
            b.missions[mission.id].failed_assertions == () for b in bundles
        )
    k_of_3 = sum(1 for v in per_mission.values() if v == RUNS_PER_ROUND)
    return {
        "missions": [m.id for m in missions],
        "k": RUNS_PER_ROUND,
        "passes_of_k": per_mission,
        "k_of_3_passed": k_of_3 if counted else None,
        "k_of_3_if_counted": k_of_3,
        "mission_count": len(missions),
    }


def _unclassified(
    bundles: tuple[Bundle, ...], residuals: Residuals
) -> tuple[dict[str, str], ...]:
    seen: set[tuple[str, str]] = set()
    rows: list[dict[str, str]] = []
    for bundle in bundles:
        for result in bundle.missions.values():
            for assertion in result.failed_assertions:
                key = (result.id, assertion)
                if key in seen or residuals.covers(result.id, assertion):
                    continue
                seen.add(key)
                rows.append({"mission_id": result.id, "assertion": assertion, "run_id": bundle.run_id})
    return tuple(rows)


def build_scoreboard(
    *,
    catalog: tuple[Mission, ...],
    bundles: tuple[Bundle, ...],
    residuals: Residuals,
    previous_residuals: Residuals | None,
    issue_states: Mapping[str, str],
    generated_at: str,
) -> dict[str, object]:
    source_sha = _check_round(catalog, bundles)
    if residuals.source_sha != source_sha:
        raise ScoreboardError(
            f"residuals source_sha {residuals.source_sha} != round source_sha {source_sha}"
        )
    known = {(m.id, a) for m in catalog for a in m.assertions}
    for entry in residuals.entries:
        if (entry.mission_id, entry.assertion) not in known:
            raise ScoreboardError(
                f"residual {entry.mission_id}/{entry.assertion} names no catalog assertion"
            )
    unclassified = _unclassified(bundles, residuals)
    previous_issues: list[dict[str, str]] = []
    if previous_residuals is not None:
        for issue in previous_residuals.issues():
            state = issue_states.get(issue)
            if state is None:
                raise ScoreboardError(f"issue state for {issue} is missing from --issue-states")
            previous_issues.append({"issue": issue, "state": state})
    if unclassified:
        counted_reason = "residual_unclassified"
    elif any(row["state"] != ISSUE_STATE_CLOSED for row in previous_issues):
        counted_reason = "previous_issue_open"
    else:
        counted_reason = "ok"
    assert counted_reason in COUNTED_REASONS
    counted = counted_reason == "ok"
    verification = _band_report(
        band_missions(catalog, VERIFICATION_BAND_PHASES), bundles, counted=counted
    )
    pilot = _band_report(band_missions(catalog, PILOT_BAND_PHASES), bundles, counted=counted)
    everything = _band_report(catalog, bundles, counted=counted)
    return {
        "schema": SCOREBOARD_SCHEMA,
        "generated_at": generated_at,
        "source_sha": source_sha,
        "run_ids": [b.run_id for b in bundles],
        "run_generated_at": [b.generated_at for b in bundles],
        "counted": counted,
        "counted_reason": counted_reason,
        "verification_band": {"phases": sorted(VERIFICATION_BAND_PHASES), **verification},
        "pilot_band": {"phases": sorted(PILOT_BAND_PHASES), **pilot},
        "all_missions": everything,
        "residuals": {
            "classified": [
                {
                    "mission_id": e.mission_id,
                    "assertion": e.assertion,
                    "cause": e.cause,
                    "issue": e.issue,
                    "summary": e.summary,
                }
                for e in residuals.entries
            ],
            "unclassified": list(unclassified),
            "causes": sorted(RESIDUAL_CAUSES),
        },
        "previous_round_issues": previous_issues,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog", required=True, type=pathlib.Path)
    parser.add_argument("--bundle", action="append", required=True, type=pathlib.Path)
    parser.add_argument("--residuals", required=True, type=pathlib.Path)
    parser.add_argument("--previous-residuals", type=pathlib.Path)
    parser.add_argument("--issue-states", type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        catalog = parse_catalog(_read_json(args.catalog))
        bundles = tuple(parse_bundle(_read_json(p), str(p)) for p in args.bundle)
        residuals = parse_residuals(_read_json(args.residuals), str(args.residuals))
        previous = (
            parse_residuals(_read_json(args.previous_residuals), str(args.previous_residuals))
            if args.previous_residuals is not None
            else None
        )
        states: Mapping[str, str] = MappingProxyType({})
        if args.issue_states is not None:
            states = parse_issue_states(_read_json(args.issue_states), str(args.issue_states))
        board = build_scoreboard(
            catalog=catalog,
            bundles=bundles,
            residuals=residuals,
            previous_residuals=previous,
            issue_states=states,
            generated_at=_dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        )
    except ScoreboardError as error:
        print(f"campaign_scoreboard: {error}", file=sys.stderr)
        return 2
    try:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(board, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print(f"campaign_scoreboard: cannot write {args.out}: {error}", file=sys.stderr)
        return 2
    band = board["verification_band"]
    assert isinstance(band, dict)
    print(
        f"scoreboard: verification_band k_of_3_passed={band['k_of_3_passed']}/{band['mission_count']} "
        f"counted={board['counted']} ({board['counted_reason']}) -> {args.out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
