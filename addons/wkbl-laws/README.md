# WKBL box-score laws Lane Add-on

This read-only worker checks five conservation laws of a basketball box score
and returns one row per violation. The checker is written and proved in Rocq,
extracted to OCaml and compiled into the image. The worker uses the common
Lane Add-on MCP `lane_observe` surface. It does not fetch games, read a
database or repair the data it reports.

## Laws

| `fields.law` | Statement | Applies when |
| --- | --- | --- |
| `final_equals_box_total` | A team's final score equals the sum of its players' points. | The result table has a final score and the box score has a row for the team. |
| `final_equals_quarter_total` | A team's final score equals the sum of its period points. | The result table has a final score and period points. |
| `points_from_made_shots` | A row's points equal 2 × two-point baskets + 3 × three-point baskets + free throws. | Always. |
| `row_team_plays_in_game` | A row's team is the game's home or away team. | Always. |
| `one_row_per_player` | No player number has two rows in one game. | The row has a player number. |

An absent value stays absent. A missing final score, missing period points or
a team without box-score rows makes the law that needs them not apply; it is
never read as zero. Each statement is a definition in [Laws.v](Laws.v)
(`side_laws`, `line_laws`, `game_laws`).

## What Rocq proves

[Laws.v](Laws.v) proves three theorems about the extracted `check` function:

- `check_spec`: `check` returns no violation exactly when every law holds.
- `check_reports_exactly`: every reported violation is a real failure with the
  reported numbers, and every failure is reported.
- `rows_bounded`: when `check` reports nothing for every game of a season, a
  player's rows for a team never outnumber that team's games. This law of
  games played follows from the per-game laws and is not checked separately.

The image build stops when a proof fails, when any of the three theorems rests
on an axiom (`Print Assumptions` in [Assumptions.v](Assumptions.v) must print
`Closed under the global context` three times), when the extracted code
contains `Obj.magic`, or when the compiled checker's answer to
[fixtures/law-cases.tsv](fixtures/law-cases.tsv) differs from
[fixtures/law-cases.out](fixtures/law-cases.out).

The proofs cover the checker against the laws as written. They do not show
that the laws match basketball rules; read the statements in `Laws.v` for
that. They also do not cover three pieces outside Rocq:

- [driver.ml](driver.ml) reads tab-separated text and prints the checker's
  answer. Numbers cross in base 2 and map digit by digit onto the extracted
  binary type, so neither side converts through a machine integer.
- [server.py](server.py) validates the snapshot, writes that text, runs the
  checker and turns each answer into a Lane row. A reported value that the
  snapshot holds (a final score, a row's points, team or player) must match
  the snapshot, or the call returns a tool error.
- `ExtrOcamlBasic` maps Rocq's `bool`, `list`, `option`, `prod` and `unit` to
  OCaml's types with the same constructors.

The two fixture files pin the text between the driver and the worker from
both sides: the image build runs the real checker on them, and
[the worker tests](../tests/test_wkbl_laws.py) check that `server.py` writes
the same input and reads the same output.

## Toolchain

The build stage installs Debian trixie's `coq` (8.20.1) and `ocaml-nox`
(5.3.0) on the same pinned `python:3.12-slim` image the worker runs on.
`BUILD_VERSIONS` and `BUILD_SHA256SUMS` in `/addon` record the versions and
the hashes of the sources, the extraction and the checker.

Trade-off: Debian ships Coq 8.20, not Rocq 9. The official Rocq images
(`rocq/rocq-prover`) are published for amd64 only, and this package is built
for amd64 and arm64. Debian's package is prebuilt for both; opam would compile
Rocq 9 from source on each. Whether `Laws.v` compiles unchanged under Rocq 9
has not been checked.

## Snapshot

A `snapshot_file` source holds observations of kind `wkbl_game_box`, one per
game:

```json
{"id": "game-1", "kind": "wkbl_game_box", "observed_at": 1795000000.0,
 "actor": null, "evidence": [], "game_id": "game-1",
 "home": {"team": "HOME", "final": 72, "quarters": null},
 "away": {"team": "AWAY", "final": 70, "quarters": [18, 17, 20, 15]},
 "lines": [["row-1", "HOME", "player-1", 12, 3, 1, 3]]}
```

Each line is `[row id, team, player number or null, points, two-point
baskets, three-point baskets, free throws]`. Team, player and row ids are
nonempty and contain no tab or line break. `game_id` is unique within a
source and a row id is unique within its game. `home` and `away` carry
exactly `team`, `final` and `quarters`. A malformed snapshot returns a tool
error. An incomplete source, or one with another observation kind, returns
no rows and incomplete coverage.

## Reproduce

From the MASC repository root:

```sh
python3 -m unittest discover -s addons/tests -p test_wkbl_laws.py -v
docker build -f addons/wkbl-laws/Dockerfile -t masc-lane-wkbl-laws:0.1.0 addons
```

The first command runs the worker over MCP stdio with a replay checker that
answers only `law-cases.tsv`. The second proves, extracts and compiles the
checker and compares its answer with `law-cases.out`; it requires Docker.

The fixture's seven games are constructed cases, one per law plus a clean and
an unplayed game; none was captured from a store. They establish the checker's
answers and the worker's error behavior. They do not establish how many
violations the WKBL store holds.
