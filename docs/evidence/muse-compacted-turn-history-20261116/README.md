# Muse completion after compaction

Issue: [#52483](https://github.com/jeong-sik/masc/issues/52483).

An installed MASC build at `340154f49e00207942fc8ec4c35560aad88ccdfd`
received text and tool events from Muse Ember, then failed with
`view/page: history ended before the current turn's start boundary`.
The same turn had compacted its context before completion.

The stable schema exported by installed Muse Code 1.4.20 defines
`earlierHistory` as a checkpoint transcript tail replacing the pruned prefix.
It is outside any turn. Its bounded message texts do not restore the original
events. The host does not expose a stable raw-log reader for that prefix.

## Host observation

`host-observation.json` retains content-free measurements and hashes.

- A fresh offline echo turn has a durable `turn/started` and passes the original
  reader's assumptions. Backward pages are ascending; `nextCursor` equals the
  first event's cursor when more history remains.
- Reading a private copy of a compacted native log through a separate echo host
  returns 155 durable events, `nextCursor=null`, and an initial completed
  `earlierHistory` item. Neither `turn/started` nor a compaction item remains.
- The copied-log probe issued only `initialize`, `initialized`, and `view/page`.
  It did not resume a live session, send a model turn, call MCP tools, or carry
  an account's credentials. Native session text and raw wire remain private
  under the ignored run directory and are not part of this bundle.

## Source replay

From the candidate checkout:

```sh
python3 docs/evidence/muse-compacted-turn-history-20261116/replay_source.py \
  --before 1bee5910b2613b811117c785269bc88764ee57b6 \
  --out artifacts/muse-compacted-history-source-replay
```

Requires the repository's OCaml interpreter, Yojson, `ocamlfind`, and installed
`ppx_enumerate` preprocessor. This creates no Dune build. The script extracts
the production JSON shape checks, MSP codec, backward reader, and final/usage
policy, then injects protocol pages. It omits the unrelated provider-effort
adapter. The Eio process driver and its request dispatcher are not executed.

`source-replay.json` records source hashes and results:

- Original reader: ordinary completion succeeds; the compacted completion
  fixture fails with the observed missing-start error.
- Candidate: all 21 cases have their expected result, including multi-page
  completion, missing/truncated/wrong-turn finals, damaged history, invalid or
  repeated cursors, and partial usage. A partial usage sum remains unknown;
  an explicit terminal aggregate survives.

The registered `test_runtime_muse_serve` regressions exercise the real
`run_turn` consumer with scripted hosts, including failed-turn effect evidence
and terminal usage. They were written and parsed, **not executed** here.

## Evidence limits

- No repository typecheck, Dune build, Alcotest execution, or CI was run.
- This candidate has not been installed or verified in a live Keeper turn.
- Missing or unfinished agent completions remain conservative failures. If a
  completion push was lost and its durable item was later compacted, the
  retained suffix alone cannot discharge the old open item.
- Ordinary queued chat continues to wait for the current turn. This change
  does not interrupt active work or replay any request.
