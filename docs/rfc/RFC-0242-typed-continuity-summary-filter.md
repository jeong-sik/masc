---
rfc: "0242"
title: "Typed continuity-summary filtering (RFC-0239 guard #6)"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent (drafted by Claude Opus 4.8)
supersedes: null
superseded_by: null
related: ["0239", "0230", "0228", "0042"]
implementation_prs: []
---

# RFC-0242: Typed continuity-summary filtering (RFC-0239 guard #6)

Status: Draft · Extends RFC-0239 (semantic-identity guards) to a sixth guard ·
Drafted 2026-06-15 after PR #21203 (closed) tried and failed to remove the
hardcoded substring classifier in `keeper_memory_policy_summary_filter`.

## §0 TL;DR

`keeper_memory_policy_summary_filter.filter_forward_looking_summary` decides which
lines of a keeper continuity summary survive into the next prompt by
**substring-matching rendered prose** against three hardcoded marker lists
(`backward_labels`, `inert_next_markers`, `stale_tool_surface_markers`,
`stale_goal_capacity_markers`), introduced by #21065 (`6cc5031e5`).

This is the **same root RFC-0239 names**: a guard keyed on a *surface token*
(a substring of rendered text) instead of *semantic identity* (a typed field or a
typed speech-act). RFC-0239 fixed five guards that share this flaw; the
continuity-summary filter is the sixth. PR #21203 attempted a fix but only wrapped
the dispatch in a `line_kind` variant while leaving the substring marker lists and
`contains_substring_ci` classification intact — a typed shell over an unchanged
string classifier, which is the CLAUDE.md workaround signature #2. It was closed.

The summary is **already a typed record** (`keeper_state_snapshot`,
`keeper_memory_policy.ml:90`, with separate `goal` / `next_items` / `decisions` /
`open_questions` fields). The substring filter exists only because the snapshot is
rendered to prose (`keeper_state_snapshot_to_summary_text`,
`keeper_memory_policy.ml:440`/`:973`) and then scrubbed as text. The fix is to
decide keep/drop **on the typed snapshot, before rendering**, and to source the
"inert" and "stale" judgments from typed state rather than from prose.

## §1 Problem (file:line)

### 1.1 The filter classifies rendered prose by substring

`lib/keeper_metrics/keeper_memory_policy_summary_filter.ml`:

- `backward_labels = ["Done"; "Progress"; "Decisions"]` — `is_backward_line`
  strips a line if it `String.starts_with` one of these prefixes.
- `inert_next_markers = ["stay_silent"; "stay silent"; "대기 유지"; "침묵";
  "할 일 없음"; ...]` — `is_inert_next_line` keeps a `Next:`/`Next plan:` line only
  if its value contains none of these substrings (`contains_substring_ci`).
- `stale_tool_surface_markers = ["masc_* only"; "no keeper_* tools"; ...]` and
  `stale_goal_capacity_markers = ["goal cap"; "active_goal_ids"; "새 작업 못"; ...]`
  — `is_stale_tool_surface_line` / `is_stale_goal_capacity_line` drop lines whose
  text contains these substrings.

`filter_forward_looking_summary` splits the rendered summary on `\n` and drops each
line matching any of the above. The classification unit is a free-text line; the
classifier is a hardcoded substring list.

### 1.2 The classified text was typed one step earlier

The thing being scrubbed is produced from a typed record:

- `keeper_memory_policy.ml:90` — `type keeper_state_snapshot = { goal; next_items;
  decisions; open_questions; ... }`.
- `keeper_memory_policy.ml:440`/`:973` — `keeper_state_snapshot_to_summary_text`
  renders each field to prose (`Printf.bprintf buf "Goal: %s\n" g`, etc.).
- `keeper_memory_policy.mli:187` — a function that **re-parses the rendered prose
  back into a snapshot** ("Inverse of …"). The round-trip
  `snapshot → prose → snapshot` is what forces downstream consumers to work in
  prose and re-discover field identity by substring.
- `keeper_unified_prompt.ml:746` — calls `filter_forward_looking_summary` at prompt
  assembly on the rendered text.

The `backward_labels` filter is re-deriving, by substring, a field distinction
(`decisions` is a struct field) the type system already had.

### 1.3 Inert/stale markers duplicate RFC-0239's failing guard

`inert_next_markers` substring-matches `"stay_silent"` / `"대기 유지"` in prose.
RFC-0239 §0 documents that the `stay_silent` *loop detector*
(`keeper_stay_silent_loop_detector.ml:48,66-74`) keys on the literal
`speech_act="stay_silent"` token and is evaded when a keeper posts its "I'll stay
quiet" message as a `Post_board` act. The summary filter and the loop detector are
**two guards keyed on the same surface token** for the same underlying concept
("this turn produced no actionable next step"). The stale tool-surface / goal-cap
markers are stale copies of live runtime facts the model echoed into prose.

## §2 Root

One root, shared with RFC-0239: **the guard keys on a surface token (a substring of
rendered text) instead of semantic identity (a typed field, or a typed
speech-act/decision).** Consequences:

- A reworded backward line, a translated inert directive, or a new phrasing of a
  stale claim evades the filter — the marker lists must grow forever (the #21065
  list already carries Korean and English variants of each concept).
- The compiler cannot see that `decisions` is being filtered, so a new backward
  field is silently un-filtered until someone adds a marker.
- Two subsystems (summary filter, loop detector) maintain divergent token lists for
  the same concept.

## §3 Design

Decide on the typed snapshot before rendering; never substring-scan prose.

### Layer A — backward fields: drop by field, render forward-only

Add `forward_projection : keeper_state_snapshot -> keeper_state_snapshot` that
clears backward-only fields (`decisions`, and any `done`/`progress` carrier) and
keep `keeper_state_snapshot_to_summary_text` as the single renderer. Prompt
assembly renders `forward_projection snapshot` instead of post-filtering prose.

- Removes `backward_labels` entirely (no substring path for Done/Progress/Decisions).
- A new backward field is a compile-time decision in `forward_projection`, not a
  forgotten marker.

### Layer B — inert next: typed speech-act, sourced at write time

`next_items` (and the keeper's "next action") must carry the typed decision that
RFC-0239 R3 already reasons about. "Inert" is a predicate on that typed value
(`is_actionable : decision -> bool`), evaluated when the snapshot is built — not a
substring scan of `Next:` prose. Inert next-items are not written into the
continuity summary at the source.

- Reuses RFC-0239's typed speech-act; deletes `inert_next_markers`.
- A keeper that decides "stay silent" records it as the typed decision, so the
  summary filter and the loop detector read the same typed value.

### Layer C — stale tool-surface / goal-cap: live state, not persisted prose

Tool surface and goal capacity are live runtime facts. They must not be persisted
as prose claims in the continuity summary (where they go stale and then need
stripping). Inject the live values at prompt assembly from the typed runtime state,
and exclude them from the persisted snapshot.

- Deletes `stale_tool_surface_markers` / `stale_goal_capacity_markers`.
- Cross-references RFC-0239: a stale persisted claim is a semantic-identity failure
  (the claim's identity is its content, which drifts from live state).

### After A+B+C

`keeper_memory_policy_summary_filter` and its `mli` are deleted (the public
`filter_forward_looking_summary` surface collapses into `forward_projection` +
typed render). The `snapshot → prose → snapshot` re-parse
(`keeper_memory_policy.mli:187`) is removed; the snapshot is the single source and
prose is a terminal rendering only.

## §4 Verification

- Property test: a `keeper_state_snapshot` with `decisions` and inert `next_items`
  set renders, via `forward_projection` + the typed renderer, with the backward and
  inert content absent — and **no `contains_substring`/marker-list call is on the
  path** (asserted by a module-boundary check, not by output text).
- Reuse RFC-0239's typed-speech-act test for the `is_actionable` predicate so the
  filter and the loop detector are tested against one definition of "inert".
- Drift gate: a ratchet asserting the marker lists in
  `keeper_memory_policy_summary_filter.ml` are removed and no new prose substring
  classifier is added in `lib/keeper*` (extends the existing code-smell baseline).
- Live-state test for Layer C: with stale tool-surface/goal-cap in a loaded
  snapshot, the assembled prompt shows the live values and not the stale ones.

## §5 Migration

1. Land Layer A (lowest risk, removes the `backward_labels` path).
2. Land Layer B once the typed decision is threaded into `next_items` (depends on
   RFC-0239 R3's typed speech-act being the single source).
3. Land Layer C with live-state injection at prompt assembly.
4. Delete the three marker lists and the prose re-parse; remove the filter module.

Until Layer A lands, the existing #21065 substring filter stays in place: removing
it without the typed replacement would stop filtering backward/inert/stale content
and regress the prompt. It is deprecated, not endorsed — removal target is this
RFC's Layer A/B/C landing. (`WORKAROUND` per CLAUDE.md: the existing markers are a
production filter that must not be dropped before the typed path exists.)

## §6 Alternatives considered

- **Keep the substring filter (status quo / #21065).** Rejected: it is the
  surface-token anti-pattern RFC-0239 closes; the marker lists grow per phrasing and
  per language and diverge from the loop detector's token list.
- **Typed wrapper over the substring lists (PR #21203).** Rejected and closed: a
  `line_kind` variant whose `classify` still calls `contains_substring_ci` on the
  marker lists is a typed shell over an unchanged string classifier — CLAUDE.md
  workaround signature #2. It legitimizes the hardcoding without removing it.
- **Fold into RFC-0239 (#21196).** Reasonable, but #21196 is already drafted with a
  fixed set of five guards and an implementation status table; this is tracked as a
  sibling guard (#6) that reuses #21196's typed speech-act rather than reopening it.

## §7 Relation to RFC-0239

RFC-0239 fixes five guards (loop detector, wake debounce, recall dedup, retention,
write-side) that key on surface tokens. This RFC fixes the sixth: the
continuity-summary content filter. Layer B explicitly consumes RFC-0239's typed
speech-act so "inert" has one definition across the loop detector and the summary
filter.

## §8 RFC ledger

This RFC takes `0242`. `docs/rfc/.next-number` is bumped to `0243` in this PR so a
concurrent claim of the same number conflicts on that file instead of merging
(RFC-0239 §ledger / #20776).
