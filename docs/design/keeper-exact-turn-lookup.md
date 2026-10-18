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
| Open source directly from Ask TUI | Local source attribution only | `O` opens a pinned source inspector over the retained question draft |

`test_memory_input_store.ml` authors store-to-HTTP-response-helper-to-TUI-decoder
scenarios for an original beyond a 50-row page with 80 newer rows, same-number
foreign traces, unrelated damage, named target corruption, readable absence,
invalid/repeated queries, foreign Keepers, ambiguous response envelopes, and
unreadable history. The HTTP helper is production code, but these are not an
executed HTTP router, transport or live TUI observation.

Evidence for this layer is source inspection, OCaml syntax parsing and
`git diff --check`. Type checking, scenario execution, independent approval,
installation and runtime/UI behavior remain unverified.

## Pinned Ask inspector

`o` shows the immutable question origin locally. `O` opens that source in the
inspector's request tab, using the open question or, with none open, the last
answer receipt. A visible origin remains the selected source. A missing
Turn_ref stays unavailable; the Keeper's current turn is never a replacement.
The overlay preserves the question's answer draft. Esc closes an opened part
first, then closes the inspector and returns to the question. Printable text
entry keeps `o` and `O` as text.

The state distinguishes a recent-page offset from a pinned Turn_ref. Bracket
navigation applies only to recent pages. Closing or replacing the target
cancels its reads and clears part ownership; workspace, generation and Keeper
admission still govern every delivered observation. Search and row navigation
use the inspector's items even when its underlying surface is Approvals.

For a known source the client starts three independent reads: exact TurnRecord,
exact provider-input manifest, and the retained turn-transcript response joined
on the complete Turn_ref. Each completion is published while the others remain pending. No
TurnRecord dependency prevents a known input read. Pending is distinct from a
failed read, and late pending fields in the same admitted generation cannot
erase completed observations. A refresh clears the previous generation before
starting another. Lazy text parts keep their Keeper/Turn_ref/index/digest keys.

Historical composition omits the current next-request forecast and runtime
catalogue. Recent request tabs now use the same stepped record for the input,
token scale and response counters. Missing attribution does not remove a known
pinned record or its independently retained input.

| Scenario | Before | Source change in this layer |
|---|---|---|
| Original input known, record unavailable | Record dependency prevents the input read | Input read and part access remain independent |
| One observation is slow | Final combined result hides already completed reads | Completed observations publish while siblings remain pending |
| A pending snapshot arrives late | It could erase an already observed field | Same-generation observation merge preserves completed fields |
| Ask is being answered | Only local origin could be opened | Pinned source overlay retains the draft underneath |
| An original response is outside the newest chat page | No exact response in that page | Pinned inspection reads the versioned retained turn transcript |

`tui_ask_source_inspect` logs the frozen origin at request time.
`tui_context_source_read` records each component's Keeper, full Turn_ref,
shared `read_started_ns`, component start/observation times and decoded/unavailable
result. Group component receipts by their captured read start and source;
elapsed time includes client scheduling, worker wait and decoding. These are
read observations, not painted-screen, model-adoption or Task-completion proof.
Each component emits a `started` receipt before the read and an `observed`
receipt after it. Cancellation need not produce an observed receipt; retain
started components without an observation as unfinished comparison samples.

Three additional authored, unexecuted scenarios in `test_tui_context_inspector`
cover usable original input despite record failure, an unattributed pinned
record with a settled response failure, and out-of-order partial observations
without borrowing another source's data. No TUI wording, row-order, layout or
PTY checks are added. Keyboard/HTTP scheduling and visible behavior remain
unverified; syntax parsing does not establish them.

## Retained response contract

`GET /api/v1/keepers/:name/turn-transcript?turn_ref=...` requires a unique valid
Turn_ref and returns `schema: masc.keeper.turn-transcript.v2`, `keeper`,
`turn_ref`, `found`, `source: keeper_chat_store`, `user` and `assistant`.
Each line carries only `role`, `content` and a finite timestamp `ts`.
User lines have role `user`; assistant-side lines have role `assistant` or
the distinct server-owned `request_failure`. Tool I/O retains its separate
execution-ID store and is not fabricated from response text.

The server uses the shared I/O pool to scan descriptor-bound history pages,
without a recent-row or elapsed-time cutoff. It retains only matching turn
rows, then selects accepted-user rows through the canonical terminal delivery
keys. The same first page and cursor boundary start both passes, so a later
append cannot widen the second pass. Accepted-user append order is irrelevant;
no adjacent-row or timestamp inference joins it. Redaction is captured once.
Memory holds the captured first page, the current page and selected rows.
Both passes can scan the whole file, and identity validation and decoding add
work; this layer makes no constant-time or latency-reduction claim.
Page boundaries yield in Eio to settle cancellation of an entered read. A
single row exceeding the existing page reader's byte window is still an
explicit unavailable observation, never a skipped row or an empty transcript.

Readable absence returns 200 with `found: false`. Storage failure, incomplete
tail, stale cursor, malformed row/identity/provenance or ambiguous fields returns
503; a partial positive is not called a complete transcript. Query errors return
400. Paged errors name physical byte offsets rather than a synthetic line one.

TUI and Dashboard bind v2 responses to the requested Keeper and Turn_ref,
validate every line and require `found` to agree with the arrays. Unversioned
responses are unavailable, not evidence that complete retained history was
read. New client/server code therefore needs the same contract when installed.
Only pinned TUI inspection uses this complete response read; recent browsing
keeps its explicitly limited newest-page observation.

Four authored, unexecuted store/HTTP-response-helper/TUI-decoder scenarios cover
an original beyond the actual 4 MiB history window, accepted-user delivery join
despite reversed append order, different traces with the same turn number,
readable absence, unavailable/invalid history, typed request failure, malformed
queries and version/source binding. Seven additional authored Dashboard cases
reject unversioned/foreign/contradictory or malformed payloads. Neither suite
has run; HTTP router, pool scheduling, UI painting, typing and speed remain
unverified.

## Full-response reader

The response has a fourth tab, reachable with `4` or the tab strip. It renders
all retained response parts with the existing Markdown renderer, without the
old 14-line preview cutoff. It owns its scroll and uses the actual viewport for
line, page, Home/End and wheel navigation. Entering it preserves the input/proof
selection, opened item, split focus and both input scroll positions. Esc returns
to that exact reading position. Choosing a different input tab resets the old
selection. Closing or changing source releases the response scroll.

The response observation remains independent: pending, unavailable, an empty
newest-page observation and an empty retained transcript are distinct. Typed
request failures remain visible in the request summary and response reader.
Input or turn-record failure does not hide an observed pinned response.

| Scenario | Before | Source change in this layer |
|---|---|---|
| Long response | Fourteen preview lines; remaining text inaccessible here | Explicit scrollable response tab over all retained parts |
| Request list render | Whole response Markdown transformed before truncation | Compact response state; no response-body Markdown transform |
| Scroll or frame row counting | Preview Markdown transformed again | One-entry immutable body projection reused at the same width/theme |
| Reading an opened input then checking its response | No full reader in this pane | Independent response scroll; Esc restores the opened input and position |
| Refreshing a pinned historical source | Current runtime catalogue fetched despite being unrelated | Only the immutable source reads; catalogue refresh remains on recent browsing |

The projection key includes Keeper, typed target, physical immutable parts list,
width, terminal palette generation and table-frame setting. Only the current
response body projection is memoized. Entering or scrolling the response tab
introduces no HTTP read; the existing independent source load owns the observations. First Markdown
projection still runs synchronously when the response tab is opened. No elapsed
time, responsiveness or speedup is established by these source changes.

Two authored, unexecuted state scenarios cover returning to the opened request
or proof, choosing a different tab, and cancellation/reset on close. They assert
stored navigation and cancellation state, not screen text or layout.

## Remaining user-facing work

Cold/reconfirmed local directory scheduling now has a source-only followup in
[local workspace loading](tui-local-workspace-loading.md), including independent
Keeper metadata versus task/history reads. Synchronous context/post-action paths,
the other panels and preparation reuse remain.
Then compare
matched before/after samples: first usable input, preparation p50/p95, repeated
discovery reads, resource-conflict waiting, and answer-to-original-work progress.
Retain failed and unfinished samples. Source changes alone establish none of
those speed improvements.
