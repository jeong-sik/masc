# Official-history projection: repeated full scans

The live CPU sample of PID 20089 on 2026-11-16 contained a worker dominated by
`Keeper_turn_fragments.of_turn`'s filter callback, with explicit
`Keeper_librarian_durable_capture` callers. That process also used 18.7 GiB
physical footprint, with a peak of 23.8 GiB. Its exact embedded revision was not
captured. Separate PID 84983 advertised embedded commit
`7aaf98eb34a853cde8ee4eb9a7b4b3ba5296c93a`; allocation profiles of multiple
processes showed substantial checkpoint and request restoration work too.

The projection in that source concatenated and scanned a trace's complete
main and internal histories for **each selected official turn**. A stable
before/after-fingerprinted, read-only observation of runtime files found one
trace with 75,752 rows and 3,774 structurally unread official cuts. Those counts
imply 285,888,048 row visits per projection. They are a structural diagnostic,
not execution of the full typed selector or a reconstruction of the CPU sample.
The real consumer projects both to build input and to verify the retained
capture. Both checks remain.

The repair groups rows by exact typed turn identity once per selected trace.
It indexes only requested identities. For one distinct requested identity in
a trace, it uses the original selector once. Main/internal order, repeated
fragments and selected cuts, first duplicate trace behavior, missing-trace
refusal, empty turns and historical offsets are preserved. Indexes live only
for this immutable source observation; full captures and their digest/refusal
checks remain authoritative.

## Isolated source experiment

From the candidate checkout:

```sh
python3 docs/evidence/librarian-official-index-20261116/probe_official_index.py \
  --repo "$PWD" --out "$PWD/artifacts/librarian-official-index-new-run"
```

This uses `ocamlfind ocamlopt` with fatal warnings 4 and 8; it does not invoke
Dune. The real `Turn_ref` module, old `of_turn` selector and new grouping helper
are extracted unchanged. Payloads are opaque strings and the lookup adapters
are local to the experiment. All **400 deterministic oracle cases** passed.

On the synthetic 75,752-row, 3,774-selected-turn case, CPU time changed from
6.899257 to 0.041438 seconds, wall time from 7.886015 to 0.068863 seconds, and
allocation from 429,202,362 to 5,502,966 machine words. The latter is about
3.20 GiB versus 42.0 MiB at eight bytes per word; neither number is peak or
retained memory. Raw measurements and source hashes are in `results.json`.

Independent review found that grouping all history turns regressed sparse
selection. That candidate was rejected: one selected turn took 0.024839 CPU
seconds instead of 0.000830 seconds. The final candidate indexes only requested
identities and uses the original single-identity path. Its one-cut result is
0.001168 versus 0.000969 CPU seconds, with 42 extra allocated words. Ten cuts
improve from 0.013015 to 0.002327 CPU seconds. These are individual observations,
not statistical bounds. `rejected-sparse-cpu.json` retains the rejected timing;
that earlier probe's coarse allocation counter is deliberately excluded.

The registered `test_keeper_librarian_durable_capture` case exercises the real
public projection's order, full identities, repeats, empty selection results,
missing sources and message/tool offsets. Its source was parsed, not executed.
An independent session reviewed the source and the experiment and found no
unresolved P0/P1/P2 issues after the sparse regression was fixed.

## Scope limits

No full project typecheck, Dune build, Alcotest suite, CI or candidate runtime
measurement was performed. The isolated experiment does not execute the full
projection, capture validation, Eio consumer, provider calls or the live fleet.
It does not prove that the server's overall CPU or memory problem is resolved.
Checkpoint restoration and repeated large original-request restoration remain
separate measured work. Private runtime captures and conversation bodies are
excluded from this retained bundle.
