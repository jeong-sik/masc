# WKBL score runs Lane Add-on

This read-only worker turns one complete play-by-play period into its largest
unanswered scoring run. It uses the common Lane Add-on MCP `lane_observe`
surface and returns a row with the scoring event indexes, snapshot row IDs,
game clock and before/after score. It does not fetch games or act on a run.

## Real replay

The [fixture](fixtures/046-01-48-X2.json) holds all 46 X2 (second overtime)
rows of game `046-01-48`, captured from the WKBL production
`play_by_play_events` table on 2026-09-29 17:04 UTC with a read-only,
autocommit query. Its SHA-256 is
`962ba99b96588b26bf8718e52a9787612f5a565288feb60797544d4aa1c70dd0`.
The [raw export](fixtures/046-01-48-X2-raw.json) preserves the original
46-row query result byte for byte (SHA-256
`1522d732fcaa12f690c375bc7e9a6773430c51655af3995025b0379d1b3f1b6c`).
Use that same file for both arms of a Hook-versus-Add-on comparison. The
Add-on fixture wraps those rows in a `snapshot_file` source envelope.
The source query selected `id, event_index, team_side, clock, description,
team1_score, team2_score` where `game_id='046-01-48'` and
`period_code='X2'`, ordered by `event_index`. The prior X1 period's last
non-null score supplied the X2 initial score (72:72).

The [public X2 PBP](https://wkbl.win/boxscore/046-01-48/pbp?period=X2) shows
the same sequence. The [official result](https://www.wkbl.or.kr/game/result.asp?season_gu=046&gun=1&game_type=01&game_no=48)
independently confirms the final BNK 79:85 Shinhan score; it does **not**
independently confirm the derived scoring run.

| Derived field | Value |
| --- | --- |
| Team and run | 신한은행, 7 unanswered points |
| Score interval | 74:74 → 74:81 |
| End clock | 01:26 |
| Zero-based PBP event indexes | 12, 18, 21, 26 |
| Snapshot DB row IDs | 1435259, 1435265, 1435268, 1435273 |

Repeated identical score rows add zero points. Rows with both score fields
null carry no transition. A negative score change, simultaneous increase for
both teams, duplicate event index, mismatched scoring side, or missing final
score returns a tool error. An incomplete source emits no scoring claim and
retains incomplete coverage. An explicit complete empty source remains
distinguishable from an unavailable source.

## Reproduce

From the MASC repository root:

```sh
python3 -m unittest discover -s addons/tests -p test_wkbl_score_runs.py -v
python3 addons/wkbl-score-runs/bench.py
docker build -f addons/wkbl-score-runs/Dockerfile -t masc-lane-wkbl-score-runs:0.1.0 addons
```

The first command starts the real MCP stdio worker with the retained fixture.
The benchmark script prints its fixture hash, result and timing. The image
build is a separate check and requires Docker. To install, copy the
fixture to the MASC config root's `lane-addons/` directory and write an
installation declaration there with `manifest_path` pointing to this
`lane.toml`, and `binding.sources = [{source_id = "wkbl-pbp",
kind = "snapshot_file", path = "./046-01-48-X2.json"}]`. Set `run_id`
to the existing MASC run; see the
[installation guide](../../docs/guides/lane-addon-toml.md). The host retains
the snapshot bytes and prepends their own evidence reference to each
observation. The public PBP URL inside the fixture is a reference, not a
retained copy of that web page.

The fixture incarnation identifies this captured history. A newly captured
snapshot must use a new incarnation and cursor. The worker is stateless:
reobserving unchanged input returns the same row identity and values.

## Measurement boundary

On 2026-09-29 UTC in the Keeper Linux sandbox, 1,000 in-process calls to
`derive` on this 46-row fixture took a median 20.88 µs and p95 21.71 µs
(after 100 warm-up calls). This measures only Python derivation, excluding
MCP process startup, host capture, Docker, or Keeper tokens. The checked
replay establishes the worker's answer on one real period and the error
behavior in the unit cases. It does not establish a live MASC
installation, a Keeper reading the output, or improved Keeper judgment. An
A/B/C/D context trial with identical model, question, fixture, and token
accounting is described in the Board experiment thread; any effectiveness
claim needs those separate receipts.
