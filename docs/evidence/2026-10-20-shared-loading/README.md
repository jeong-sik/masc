# Shared loading optimization observations, 2026-10-20

These packets distinguish the installed server from source and isolated computation probes.
The changes have not been installed or measured through the TUI/browser.

## Prefix encoding buffer

`prefix_buffer_probe.ml` compares the old/new Yojson buffer lifetime on a frozen
82,825,306-byte checkpoint containing 32,494 messages. The input was read locally;
conversation contents and credentials are not included here. Three alternating
runs returned identical SHA256 values. Temporary allocation was 340,689,888 vs
109,518,816 bytes (67.85% lower); elapsed results are in `prefix-buffer-results.txt`.

This probe loads checkpoint message JSON directly, so it measures JSON encoding
and hashing only. It does not execute `Agent_core.Checkpoint.message_to_json`,
range selection, the worker pool, or the whole capture/restore operation.

Run with OCaml 5.5.1 and the installed Yojson/Digestif packages:

```sh
ocamlfind ocamlopt -package yojson,digestif.c,unix -linkpkg prefix_buffer_probe.ml -o /tmp/prefix_buffer_probe
/tmp/prefix_buffer_probe /path/to/frozen-checkpoint.json
```

The source change passed OCaml parsing, `git diff --check`, and an independent
subagent source review with no P0/P1/P2 findings. This is not a GitHub approval.
No local Dune build or CI was run, under the constitution's execution protocol.
The existing `test_librarian_continuity_snapshot` checkpoint-array digest and
restore cases are the integration target; they were not executed this session.

## Historical source span projection

`source_span_probe.ml` extracts the previous and candidate `source_spans`,
`atom_spans`, `annotate`, `atom_opening_digest`, and `slice` implementations.
It supplies minimal message, boundary and unread-source adapters; checkpoint
message encoding is represented by an ID. Both versions receive identical
fixtures. It compares complete marshalled output with sharing disabled.

500 deterministic fixtures, each with unread inclusion enabled and disabled,
matched in 1,000 comparisons. Fixtures vary pinned messages, orphan/tool groups,
partial/nonzero selections, unknown attribution, boundary-only evidence,
unread hashes, and refused boundary rows. This does not prove the real module
interfaces, persistence, queue publication or UI behavior.

The separate 11,962-message/300-cut fixture retains three unread holes. Observed
old/new results were 527ms/1.49ms (include unread) and 851ms/1.54ms (exclude
unread), with allocations of 1.325GB/4.60MB and 2.295GB/4.94MB respectively.
Those are adapted computation measurements, not product or end-to-end speedups.
An earlier 39,922-message/1,000-cut run completed the include-unread arm in
12.29s/8.51ms; the exclude-unread arm was interrupted, then the smaller explicit
fixture was run to completion. No completion claim uses the interrupted arm.

```sh
ocamlfind ocamlopt -package yojson,digestif.c,unix -linkpkg source_span_probe.ml -o /tmp/source_span_probe
/tmp/source_span_probe
```

A real `test_keeper_librarian_continuity` case was added for tool atom membership,
pinned context, clipping inside a later turn, and a nonzero continuation start.
Its execution, full API type checking and installed behavior remain unverified.
All changed ML/MLI files passed parsing and `git diff --check`. Independent
subagent source review found no P0/P1/P2 issues; it is not a GitHub approval.

## Installed server baseline

`api-baseline.json` records 15 concurrent rounds per endpoint, plus MCP ping,
against one installed runtime. All 75 responses were valid, without stale samples.
The chat history endpoint ranged up to 33.85ms; next-request inspection had
692.57ms median and 1,215.59ms maximum. Roster had 74.30ms median and 203.84ms
maximum. The runtime identity remained unchanged throughout this packet.

The earlier `runtime-observation.json` snapshot reported resident memory of
33,522,221,056 bytes and a 5,771ms maximum scheduler stall in its preceding
60-second window. The later baseline window had no >1s stall. These establish
variable shared runtime pressure, not that every slow chat has one cause.
A three-second process sample showed JSON encoding, SHA256 and GC barrier work;
the raw process sample remains local at `/tmp/masc-optimization-sample.txt`.

No synthetic chat messages were sent and no Keeper was paused or restarted.
The installed commit is recorded in the JSON. It does not include these patches.
Next: independently review current PR heads, integrate the whole native stack,
then compare the same API/TUI/browser scenarios on a source-verified installed
candidate under comparable fleet/data load. Preserve runtime identity and
failures; do not infer screen latency from either computation probe.
