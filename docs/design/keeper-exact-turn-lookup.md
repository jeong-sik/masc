# Inspect an immutable source turn

Ask rows retain the complete original `source_turn_ref`. The recent
`GET /api/v1/keepers/:name/turn-records?limit=N` page cannot reliably inspect
that source after newer turns move it outside the page. A different trace can
also use the same absolute turn number. Increasing the recent limit does not
establish the original identity.

## Exact read contract

`GET /api/v1/keepers/:name/turn-records?turn_ref=trace%231` selects the exact
mode of the existing route. Encode the entire reference as a query value;
an unescaped `#` starts a URL fragment and is not sent to the server.

- No `turn_ref`: the existing recent-page response and dashboard schema apply.
- One valid reference: read the request workspace's canonical Keeper store,
  joining on both trace and absolute turn. Recent `limit` does not bound this
  mode. The writer owns one canonical record per Keeper turn.
- Repeated, empty or malformed reference: 400, without falling back to a recent
  page. Invalid Keeper names are also rejected before store access.
- A readable match: 200 with exactly `keeper`, `turn_ref`, `count`,
  `skipped_rows`, `source`, and `entries`. Count is one, source is
  `turn_record`, and the one entry contains `record` and `diff_vs_prev: null`.
  This read does not claim a previous-turn comparison.
- A fully readable miss: 404. Storage failure, a malformed row naming the
  target, or a target carrying another Keeper's identity: 503.
- A scan with unidentified malformed rows cannot establish absence: 503.
  A known valid positive can still return 200, retaining the encountered
  malformed-row count in `skipped_rows`.

The shared I/O pool owns the scan. Existing pool absence, non-Eio and nested
worker policies choose inline entry; an entered worker failure is never retried
inline. The dated store reverse-streams history and stops at the match, without
materializing an expanded recent page. Old or absent targets may scan all
history. This is not a constant-time lookup or a measured latency reduction.

The TUI exact-response decoder binds the envelope and the sole canonical row
to the requested Keeper and full Turn_ref. Duplicate fields, foreign rows,
multiple entries and invalid partial-history metadata fail the reading. It
does not select the latest attributed row as an alternative.

## Before and after boundaries

| Scenario | Before | Source change in this layer |
|---|---|---|
| Original falls outside recent page | Recent read cannot reach it | Exact mode scans canonical history for its full identity |
| Another trace uses the same turn number | Number alone cannot identify source | Store and decoder require the complete Turn_ref |
| Damaged rows prevent proving absence | Recent omission cannot prove absence | Exact miss remains unavailable rather than an authoritative 404 |
| Requested row survives unrelated damage | Broad failure would hide a known positive | Return the exact row with partial-history metadata |
| Open source directly from Ask TUI | Local source attribution only | Still pending; this layer supplies the lookup and decoder |

`test_memory_input_store.ml` authors store-to-HTTP-response-helper-to-TUI-decoder
scenarios for an original beyond a 50-row page with 80 newer rows, same-number
foreign traces, unrelated damage, named target corruption, readable absence,
invalid/repeated queries, foreign Keepers, ambiguous response envelopes, and
unreadable history. The HTTP helper is production code, but these are not an
executed HTTP router, transport or live TUI observation.

Evidence for this layer is source inspection, OCaml syntax parsing and
`git diff --check`. Type checking, scenario execution, independent approval,
installation and runtime/UI behavior remain unverified.

## Remaining user-facing work

Connect the immutable Ask origin to an explicitly pinned inspector target.
Keep that target distinct from relative recent-turn navigation, and preserve
workspace, Keeper, generation and lazy-part ownership through cancellation.
Record, exact provider input and response observations should fail independently;
historical inspection must not present the current next-request forecast as
evidence about the original turn.

Separately finish independent panel loading and preparation reuse, then compare
matched before/after samples: first usable input, preparation p50/p95, repeated
discovery reads, resource-conflict waiting, and answer-to-original-work progress.
Retain failed and unfinished samples. Source changes alone establish none of
those speed improvements.
