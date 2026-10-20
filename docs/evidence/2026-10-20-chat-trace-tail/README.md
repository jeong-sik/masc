# Decode only the displayed chat trace window

The live server was `2f3c5aa58048266e257ef01eb0759b344629debc`, instance
`01a15964-9d62-7000-9707-261261f60a0d`. Six sequential code-reviewer aggregate
history requests returned HTTP 200, 1,073,063 bytes each, in 1966.9, 701.5,
163.3, 244.1, 178.7 and 691.3ms. This differs from the earlier 34-second 504
observation; fleet activity and warmth differ. These are baseline observations,
not evidence of a change in installed performance. The frontend PR #44312 merged
during this investigation, but the measured server still identified the older
commit.

A concurrent three-second process sample includes chat history's trajectory read,
JSON decoding/encoding and GC coordination. It does not isolate the endpoint's
total cost or establish a single cause. The live trajectory's last 500 JSON rows
included 453 carrying one turn ID; the existing 200-step display window excludes
253 of those rows. This shape count is not a native decoder verdict.

The old projection converted every matching trajectory line, including parsing
nested arguments/results, then discarded steps outside that window. The new
projection chooses the same tail first. Both trajectory variants contribute
exactly one step; dedupe, order, omission count, literal JSON fallback and withheld
reasoning remain unchanged. Repeated exact-turn lookups reuse their block within
the existing per-render trace observation. No cache crosses requests.

## Reproducible isolated source experiment

```sh
python3 docs/evidence/2026-10-20-chat-trace-tail/projection_probe.py \
  --before ff628cafff535ff690df002732edc041831ec166
```

The probe embeds the actual before/after projection modules in an OCaml
interpreter with real Yojson and small in-memory dependency adapters. It does not
build MASC or exercise its filesystem reader, runtime, full types or HTTP stack.
400 seeded cases compared both modules' blocks across mixed tool/thinking rows,
dedupe, multiple traces/turns, missing/disallowed references, repeated lookups and
an append after first observation. All matched.

For a synthetic 453-tool turn with 8KiB JSON arguments/results, one cold lookup
allocated 21,805,112 bytes before and 9,661,744 after (55.7% less). Ten lookups in
the same render allocated 217,755,056 versus 9,662,536 bytes. One timing sample
was 52.1/22.3ms cold and 461.2/51.8ms repeated; allocation is the stronger narrow
observation. These figures are not native server latency or a fleet speedup.

Both changed `.ml` files pass `ocamlc -stop-after parsing`; `git diff --check`
passes. A native test covers retained payload/fallback, omission and per-render
snapshot behavior, but has not run. No local Dune build or CI was run. Installed
API/TUI/browser and shared checkpoint allocation remain unverified follow-up in
#44249. Private raw runtime packets remain local.
