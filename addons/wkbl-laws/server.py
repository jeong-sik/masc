"""Check WKBL box-score conservation laws with the checker extracted from Laws.v.

Only supplied snapshot rows are read. No network, database, or game action is
performed by this worker. Rocq proves the checker against the laws in Laws.v.
This file and driver.ml are outside the proof; fixtures/law-cases.* pin the
text that passes between them from both sides.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import InvalidInput, Source, row, serve, stable_id, string

CHECKER = Path(__file__).resolve().with_name("wkbl-laws-check")
CHECKER_TIMEOUT_SECONDS = 120
KIND = "wkbl_game_box"
LANE = "wkbl/laws"
SIDE_KEYS = frozenset({"team", "final", "quarters"})
LINE_FIELDS = 7


@dataclass(frozen=True, slots=True)
class Side:
    team: str
    final: int | None
    quarters: tuple[int, ...] | None


@dataclass(frozen=True, slots=True)
class Line:
    row_id: str
    team: str
    player: str | None
    points: int
    two_made: int
    three_made: int
    free_made: int


@dataclass(frozen=True, slots=True)
class Game:
    observation: dict
    game_id: str
    home: Side
    away: Side
    lines: tuple[Line, ...]


def field(value: object, name: str) -> str:
    text = string(value, name)
    if any(mark in text for mark in "\t\n\r"):
        raise InvalidInput(f"{name} must not contain tabs or line breaks")
    return text


def count(value: object, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InvalidInput(f"{name} must be a nonnegative integer")
    return value


def side(value: object, name: str) -> Side:
    if not isinstance(value, dict) or set(value) != SIDE_KEYS:
        raise InvalidInput(f"{name} must be an object with exactly team, final and quarters")
    final = value["final"]
    quarters = value["quarters"]
    if quarters is not None and (not isinstance(quarters, list) or not quarters):
        raise InvalidInput(f"{name}.quarters must be a nonempty array or null")
    return Side(field(value["team"], f"{name}.team"),
                None if final is None else count(final, f"{name}.final"),
                None if quarters is None else
                tuple(count(item, f"{name} quarter") for item in quarters))


def line(value: object) -> Line:
    if not isinstance(value, list) or len(value) != LINE_FIELDS:
        raise InvalidInput(f"a box-score row must be an array of {LINE_FIELDS} values")
    row_id, team, player, points, two_made, three_made, free_made = value
    return Line(field(row_id, "row id"), field(team, "row team"),
                None if player is None else field(player, "row player"),
                count(points, "points"), count(two_made, "two_made"),
                count(three_made, "three_made"), count(free_made, "free_made"))


def game(observation: dict) -> Game:
    lines = observation.get("lines")
    if not isinstance(lines, list):
        raise InvalidInput("lines must be an array")
    parsed = tuple(line(item) for item in lines)
    if len({item.row_id for item in parsed}) != len(parsed):
        raise InvalidInput("row ids must be unique within a game")
    home, away = side(observation.get("home"), "home"), side(observation.get("away"), "away")
    if home.team == away.team:
        raise InvalidInput("home and away must be different teams")
    return Game(observation, field(observation.get("game_id"), "game_id"), home, away, parsed)


def bits(value: int | None) -> str:
    return "" if value is None else format(value, "b")


def encode(games: tuple[Game, ...]) -> str:
    """The text driver.ml reads: base-2 numbers, an empty field for absent."""
    rows = []
    for item in games:
        rows.append(("G", item.game_id, item.home.team, item.away.team,
                     bits(item.home.final), bits(item.away.final),
                     ",".join(map(bits, item.home.quarters or ())),
                     ",".join(map(bits, item.away.quarters or ()))))
        rows.extend(("L", other.row_id, other.team, other.player or "", bits(other.points),
                     bits(other.two_made), bits(other.three_made), bits(other.free_made))
                    for other in item.lines)
    return "".join("\t".join(fields) + "\n" for fields in rows)


def run_checker(text: str) -> str:
    try:
        result = subprocess.run([str(CHECKER)], input=text, capture_output=True,
                                encoding="utf-8", timeout=CHECKER_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired as error:
        raise InvalidInput(f"law checker did not finish within {CHECKER_TIMEOUT_SECONDS} seconds") from error
    except OSError as error:
        raise InvalidInput(f"law checker could not start: {error}") from error
    if result.returncode != 0:
        raise InvalidInput(f"law checker refused the input: {result.stderr.strip()}")
    return result.stdout


def binary(text: str) -> int:
    if not text or any(digit not in "01" for digit in text) or (text[0] == "0" and text != "0"):
        raise InvalidInput(f"law checker printed a malformed number: {text!r}")
    return int(text, 2)


def named_row(item: Game, row_id: str) -> Line:
    found = [candidate for candidate in item.lines if candidate.row_id == row_id]
    if len(found) != 1:
        raise InvalidInput(f"law checker named an unknown row: {row_id!r}")
    return found[0]


def team_side(item: Game, team: str) -> Side:
    for candidate in (item.home, item.away):
        if candidate.team == team:
            return candidate
    raise InvalidInput(f"law checker named a team outside the game: {team!r}")


def report(source: Source, item: Game, kind: str, values: list[str]) -> dict:
    """One Lane row per reported violation. Values the snapshot already holds
    must match it; a mismatch means the text boundary is broken."""
    match kind, values:
        case "box_points", [team, final, box]:
            owner = team_side(item, team)
            if owner.final != binary(final):
                raise InvalidInput("law checker reported a final score the snapshot does not hold")
            law, subject = "final_equals_box_total", team
            title = f"{item.game_id} {team}: final {owner.final}, box score total {binary(box)}"
            fields = {"team": team, "final": owner.final, "box_total": binary(box),
                      "row_ids": [other.row_id for other in item.lines if other.team == team]}
        case "quarter_points", [team, final, quarters]:
            owner = team_side(item, team)
            if owner.final != binary(final) or owner.quarters is None:
                raise InvalidInput("law checker reported quarters the snapshot does not hold")
            law, subject = "final_equals_quarter_total", team
            title = f"{item.game_id} {team}: final {owner.final}, quarter total {binary(quarters)}"
            fields = {"team": team, "final": owner.final, "quarters": list(owner.quarters),
                      "quarter_total": binary(quarters)}
        case "composition", [row_id, points, composed]:
            found = named_row(item, row_id)
            if found.points != binary(points):
                raise InvalidInput("law checker reported points the snapshot does not hold")
            law, subject = "points_from_made_shots", row_id
            title = f"{item.game_id} row {row_id}: {found.points} points, made shots give {binary(composed)}"
            fields = {"row_id": row_id, "team": found.team, "player": found.player,
                      "points": found.points, "two_made": found.two_made,
                      "three_made": found.three_made, "free_made": found.free_made,
                      "composed": binary(composed)}
        case "foreign_team", [row_id, team]:
            found = named_row(item, row_id)
            if found.team != team:
                raise InvalidInput("law checker reported a team the row does not hold")
            law, subject = "row_team_plays_in_game", row_id
            title = f"{item.game_id} row {row_id}: team {team} is not in the game"
            fields = {"row_id": row_id, "team": team, "player": found.player,
                      "home_team": item.home.team, "away_team": item.away.team}
        case "repeated_player", [row_id, player]:
            found = named_row(item, row_id)
            if found.player != player:
                raise InvalidInput("law checker reported a player the row does not hold")
            law, subject = "one_row_per_player", row_id
            title = f"{item.game_id} row {row_id}: player {player} has another row"
            fields = {"row_id": row_id, "player": player,
                      "row_ids": [other.row_id for other in item.lines if other.player == player]}
        case _:
            raise InvalidInput(f"law checker printed an unexpected report: {kind!r} "
                               f"with {len(values)} values")
    result = row(source, item.observation, lane=LANE, subject=f"{item.game_id}/{subject}",
                 title=title, fields={"law": law, "game_id": item.game_id,
                                      "source_cursor": source.cursor, **fields})
    result["id"] = stable_id(source.source_id, source.incarnation,
                             item.observation.get("id"), law, subject)
    return result


def check(source: Source) -> tuple[list[dict], int]:
    games = tuple(game(item) for item in source.observations)
    by_id = {item.game_id: item for item in games}
    if len(by_id) != len(games):
        raise InvalidInput("game_id must be unique within a source")
    printed = run_checker(encode(games)).split("\n")
    if printed[-1] != "" or printed[-2:-1] != [f"C\t{len(games)}"]:
        raise InvalidInput("law checker did not confirm every game it was given")
    rows = []
    for text in printed[:-2]:
        tag, *rest = text.split("\t")
        if tag != "V" or len(rest) < 2 or rest[0] not in by_id:
            raise InvalidInput(f"law checker printed an unexpected line: {text!r}")
        rows.append(report(source, by_id[rest[0]], rest[1], rest[2:]))
    return rows, sum(1 for item in games for other in item.lines if other.player is None)


def observe(_binding: dict, sources: tuple[Source, ...]) -> dict:
    if not sources:
        return {"rows": [], "coverage": [{
            "source_id": "wkbl-box", "incarnation": "unobserved", "cursor": None,
            "complete": False, "detail": "No box-score snapshot supplied"}]}
    output, coverage = [], []
    for source in sources:
        status = source.coverage(set())
        if not source.complete:
            status["detail"] = status["detail"] or "Box-score snapshot is incomplete"
            coverage.append(status)
            continue
        skipped = {str(item.get("kind", "untyped")) for item in source.observations
                   if item.get("kind") != KIND}
        if skipped:
            status["complete"] = False
            status["detail"] = "Unexpected observation kinds: " + ", ".join(sorted(skipped))
            coverage.append(status)
            continue
        rows, unnumbered = check(source)
        output.extend(rows)
        counts = (f"{len(source.observations)} games checked, {len(rows)} violations, "
                  f"{unnumbered} rows without a player number")
        status["detail"] = counts if status["detail"] is None else f"{status['detail']}; {counts}"
        coverage.append(status)
    return {"rows": output, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-wkbl-laws", observe)
