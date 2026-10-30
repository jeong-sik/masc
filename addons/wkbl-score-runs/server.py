"""Derive the largest unanswered scoring run from one complete WKBL PBP period.

Only supplied snapshot rows are read. No network, database, or game action is
performed by this worker.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import InvalidInput, Source, row, serve, string

CLOCK = re.compile(r"^[0-9]{2}:[0-5][0-9]$")


def nonnegative_int(value: object, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InvalidInput(f"{name} must be a nonnegative integer")
    return value


def score(value: object, name: str) -> tuple[int, int]:
    if not isinstance(value, list) or len(value) != 2:
        raise InvalidInput(f"{name} must contain two scores")
    return nonnegative_int(value[0], name), nonnegative_int(value[1], name)


def derive(observation: dict) -> dict | None:
    game_id = string(observation.get("game_id"), "game_id")
    period = string(observation.get("period_code"), "period_code")
    teams = (string(observation.get("team1"), "team1"),
             string(observation.get("team2"), "team2"))
    current = score(observation.get("initial_score"), "initial_score")
    final = score(observation.get("final_score"), "final_score")
    events = observation.get("rows")
    if not isinstance(events, list):
        raise InvalidInput("rows must be an array")

    best = None
    side = None
    points = 0
    start = current
    indexes: list[int] = []
    ids: list[int] = []
    last_index = -1
    for item in events:
        if not isinstance(item, dict):
            raise InvalidInput("PBP row must be an object")
        index = nonnegative_int(item.get("event_index"), "event_index")
        if index <= last_index:
            raise InvalidInput("event_index must be strictly increasing")
        last_index = index
        event_id = nonnegative_int(item.get("id"), "PBP row id")
        clock = string(item.get("clock"), "clock")
        if CLOCK.fullmatch(clock) is None:
            raise InvalidInput("clock must be MM:SS")
        left, right = item.get("team1_score"), item.get("team2_score")
        if left is None and right is None:
            continue
        next_score = score([left, right], "event score")
        delta = (next_score[0] - current[0], next_score[1] - current[1])
        if min(delta) < 0 or (delta[0] > 0 and delta[1] > 0):
            raise InvalidInput(f"invalid score transition at event_index {index}")
        if delta == (0, 0):
            continue
        next_side = 0 if delta[0] > 0 else 1
        scoring_side = nonnegative_int(item.get("team_side"), "scoring team_side")
        if scoring_side != next_side + 1:
            raise InvalidInput(f"scoring side conflicts at event_index {index}")
        if side != next_side:
            side, points, start, indexes, ids = next_side, 0, current, [], []
        points += delta[next_side]
        indexes.append(index)
        ids.append(event_id)
        if best is None or points > best["points"]:
            best = {
                "game_id": game_id,
                "period_code": period,
                "team": teams[next_side],
                "points": points,
                "score_before": list(start),
                "score_after": list(next_score),
                "ending_clock": clock,
                "source_event_indexes": list(indexes),
                "snapshot_row_ids": list(ids),
            }
        current = next_score
    if current != final:
        raise InvalidInput(f"last observed score {current} differs from final_score {final}")
    return best


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    if not sources:
        return {"rows": [], "coverage": [{
            "source_id": "wkbl-pbp", "incarnation": "unobserved", "cursor": None,
            "complete": False, "detail": "No PBP snapshot supplied"}]}
    output, coverage = [], []
    for source in sources:
        status = source.coverage(set())
        if not source.complete:
            status["detail"] = (status["detail"] or "PBP snapshot is incomplete")
            coverage.append(status)
            continue
        skipped = {str(item.get("kind", "untyped")) for item in source.observations
                   if item.get("kind") != "wkbl_pbp_period"}
        if skipped:
            status["complete"] = False
            status["detail"] = "Unexpected observation kinds: " + ", ".join(sorted(skipped))
            coverage.append(status)
            continue
        source_rows = 0
        for item in source.observations:
            result = derive(item)
            if result is None:
                continue
            source_rows += 1
            output.append(row(
                source, item, lane="wkbl/score-runs",
                subject=f"{result['game_id']}/{result['period_code']}",
                title=f"{result['team']} {result['points']} unanswered points",
                fields={"metric": "unanswered_scoring_run", "source_cursor": source.cursor,
                        **result},
                clock={"domain": "wkbl_game_clock", "value": result["ending_clock"]},
            ))
        if not source.observations:
            status["detail"] = "Complete source contained no PBP periods"
        elif source_rows == 0:
            status["detail"] = "No scoring run in supplied PBP periods"
        coverage.append(status)
    return {"rows": output, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-wkbl-score-runs", observe)
