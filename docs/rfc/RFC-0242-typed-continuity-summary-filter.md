---
rfc: "0242"
title: "Continuity state as system-of-record (retire the prose summary filter)"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent (drafted by Claude Opus 4.8)
supersedes: null
superseded_by: null
related: ["0239", "0230", "0228", "0042"]
implementation_prs: []
---

# RFC-0242: Continuity state as system-of-record (retire the prose summary filter)

Status: Draft · Extends RFC-0239 (semantic-identity guards) · Drafted 2026-06-15.

> **Revision note (v2).** The first draft (PR #21207, merged as Draft) framed the
> fix as "type the summary filter": replace the substring marker lists with
> typed-field projection plus an `is_actionable` predicate. That framing was wrong
> in the same way PR #21203 was wrong — it keeps the filter as a concept and swaps
> its internals. A typed predicate on rendered prose is still a heuristic on
> rendered prose. This revision reframes the RFC around the actual structural
> defect: **the keeper turn already has a typed continuity record and a tested
> schema for enforcing it, but the runtime does not enforce structure — it relies
> on the model voluntarily emitting JSON, falls back to prose, re-parses the prose
> back into a record, and then substring-scrubs the prose.** The fix is to make the
> typed record the enforced system-of-record and delete the round-trip — not to make
> the scrubber smarter.
>
> v2 also corrects four factual errors in v1 (call-site count, marker-list
> inventory, #21065 attribution, and the stay_silent loop-detector state) and
> redesigns the inert-next-item handling (§3.6) after an adversarial audit showed v1
> would have relocated the `inert_next_markers` list rather than removed it.

## §0 TL;DR

The keeper continuity state is a typed record (`keeper_state_snapshot`,
`keeper_memory_policy.ml:90`, all eight fields `string option` / `string list`) and
there is a **fully defined, unit-tested** structured schema for enforcing its
emission (`structured_state_snapshot_schema`, `keeper_memory_policy.ml:741-797`;
parse test `test/test_keeper_state_snapshot_json.ml:122-139`). That schema — the
*enforcement* layer (`Agent_sdk.Structured`, the same API keeper already drives at
`keeper_deliberation.ml:664`) — is **wired to nothing in the runtime**:
`rg structured_state_snapshot_schema lib bin` returns only the definition and the
`.mli`; the sole caller is the test.

What the runtime *does* do is parse structure **opportunistically, unenforced**.
`keeper_agent_run_response_text.ml:18-47` runs a four-way cascade:

1. `reported_state_snapshot_from_checkpoint` → **dead** (hard `None`,
   `keeper_agent_run_finalize_response.ml:12-18`; its comment records that the
   `keeper_report_state` tool was removed).
2. `parse_structured_state_snapshot_from_reply` (`keeper_memory_policy.ml:814`) —
   best-effort: strip ` ```json ` fences, `Yojson.Safe.from_string`,
   `structured_state_snapshot_of_json`. Note this does **not** use the schema; it
   parses whatever JSON the model happened to put in free text.
3. `parse_state_snapshot_from_reply` (`:287`) — parse a `[STATE]` prose block.
4. `synthesize_state_from_run_result` (`:905-953`) — fabricate a snapshot from
   `tools_used` / `stop_reason` / the first 103 bytes of `response_text`.

The cascade's branch is recorded in an **untyped string** `state_snapshot_source`
(`keeper_agent_run_response_text.ml:5`), classified downstream by `String.equal` /
`String.starts_with ~prefix:"synthesized_"` (`keeper_memory_policy.ml:112-115`).

Two of these branches re-derive the typed record from prose, and one site then
substring-scrubs the *rendered* prose. The scrubber
(`keeper_memory_policy_summary_filter.ml`, called via re-export at
`keeper_unified_prompt.ml:746`) drops lines by matching three named substring lists
(`backward_labels`, `inert_next_markers`, `stale_tool_surface_markers`) plus an
inline goal-cap list inside `is_stale_goal_capacity_line`. The goal-cap list was
added by #21065 (`6cc5031e5`); the module and the other three lists predate it
(created in #20156, refactored in #20232).

**The filter exists only because structure is never enforced.** Wire the schema as
the enforced system-of-record, carry the typed value, and three distinct defects
disappear:

- field identity (`backward_labels` re-discovering which field a prose line came
  from) is free from the record type;
- the prose re-parse (`state_snapshot_of_summary_text`, three call sites:
  `keeper_memory_policy.ml:534`, `keeper_tool_memory_runtime.ml:477`,
  `keeper_turn.ml:327`) is deleted;
- stale tool-surface / goal-cap claims are never persisted as prose to be stripped —
  they are live runtime facts injected at assembly.

What does **not** disappear, and which this RFC refuses to disguise: deciding
whether a turn was substantive is a real judgment. The honest part is that it has a
**structural** answer that already exists in the codebase — RFC-0239 R3's
tool-evidence signal (`turn_made_progress`,
`keeper_stay_silent_loop_detector.ml:57`) — so the inert judgment moves off the
`next_items` *text* entirely (§3.6), rather than relocating the substring list. The
genuinely irreducible residue (§5) is narrow.

## §1 What is actually there today (file:line)

### 1.1 A typed record exists upstream

`keeper_memory_policy.ml:90` — `type keeper_state_snapshot = { goal; progress;
done_summary; next_summary; next_items; decisions; open_questions; constraints }`,
every field `string option` or `string list`. Field identity is in the type; the
leaf values are model-authored NL.

### 1.2 A schema to enforce its emission exists and is tested — but unwired

`keeper_memory_policy.ml:741-797` — `structured_state_snapshot_schema :
keeper_state_snapshot Agent_sdk.Structured.schema`, eight params, `parse` returning
`Ok snapshot` / `Error "..."`. `test/test_keeper_state_snapshot_json.ml:129` parses a
raw `{progress; decisions}` object through `schema.parse` and asserts the typed
fields — so the schema **works**. It is reachable from no runtime code path
(`rg` → definition + `.mli:176` + the one test, nothing else). Keeper already drives
this exact `Agent_sdk.Structured` API in production at `keeper_deliberation.ml:664`
(`structured_result_schema`), so wiring it connects existing infrastructure, it does
not build new infrastructure.

### 1.3 Structured *enforcement* was removed; only best-effort parsing remains

`keeper_agent_run_finalize_response.ml:12-18` is a hard-`None` stub whose comment
records that the `keeper_report_state` tool was removed and state reporting moved to
`[STATE]` prose blocks. The schema in §1.2 is the residue of that removed,
enforced path. The runtime now relies on the model *voluntarily* emitting JSON
(`parse_structured_state_snapshot_from_reply`, `keeper_memory_policy.ml:814`, which
calls `structured_state_snapshot_of_json` directly — not the schema), with no
provider-level guarantee the object appears or conforms.

### 1.4 The runtime reconstructs the record from prose at three sites

`state_snapshot_of_summary_text` (`keeper_memory_policy.ml:299`, `.mli:186`) parses
`[STATE]` prose back into the record. Call sites (verified by `rg`, excluding the
def and three `.mli` declarations):

- `keeper_memory_policy.ml:534`
- `keeper_tool_memory_runtime.ml:477` (`... meta.continuity_summary`)
- `keeper_turn.ml:327` (`... meta.continuity_summary`)

This is the inverse of `keeper_state_snapshot_to_summary_text`
(`keeper_memory_policy.ml:310`); the pair forms a `snapshot → prose → snapshot`
round-trip.

`synthesize_state_from_run_result` (`:905-953`, called at
`keeper_agent_run_response_text.ml:36`) is the no-model-output fallback:
`progress = "Used: …"` (line 917), `String_util.utf8_safe ~max_bytes:103` of
`response_text` → `decisions = ["Last output: …"]` (lines 937, 942).

### 1.5 Only then is the rendered prose substring-scrubbed

`lib/keeper_metrics/keeper_memory_policy_summary_filter.ml`, all inside
`filter_forward_looking_summary`:

- `backward_labels = ["Done"; "Progress"; "Decisions"]` (line 19) — `is_backward_line`
  (56-62) drops a line by `String.starts_with trimmed ~prefix:(label ^ ":")`. This
  re-derives, by substring, the field a line was rendered from (`decisions` is a
  struct field).
- `inert_next_markers` (lines 20-33; EN+KO, incl. `"stay_silent"`, `"stay silent"`,
  `"대기 유지"`, `"침묵"`) — `is_inert_next_line` (64-73) strips a `Next:` /
  `Next plan:` prefix and keeps the line only if the payload contains none of the
  markers (`String_util.contains_substring_ci`).
- `stale_tool_surface_markers` (lines 35-43) — `is_stale_tool_surface_line` (74-85).
- An **inline** goal-cap list (lines 89-97, `let markers = [...]` inside
  `is_stale_goal_capacity_line`, 87-101) — not a named top-level binding.

The classification unit is a free-text line; the classifier is a hardcoded
substring list, grown per phrasing and per language.

## §2 Root

One root, shared with RFC-0239: **structure is not enforced, so the typed record is
repeatedly reconstructed from a surface token (a substring of rendered prose)
instead of read as a typed field.** The substring filter is a symptom; the prose
round-trip (§1.4) is the cause; the unwired schema (§1.2) is the fix that was already
built and then disconnected.

Consequences of the current shape:

- A reworded backward line, a translated inert directive, or a new phrasing of a
  stale claim evades the filter; the marker lists must grow forever (the inert list
  already carries EN and KO variants of each concept).
- The compiler cannot see that `decisions` is being filtered, so a new backward
  field is silently un-filtered until someone adds a marker.
- The continuity filter is a **laggard**: RFC-0239 R3 already moved the sibling
  `stay_silent` loop detector off the literal token. The detector's comment
  (`keeper_stay_silent_loop_detector.ml:45-56`) records that the
  `speech_act="stay_silent"` predicate was **retired** because a keeper could evade
  it by *posting* its "nothing to do" conclusion; it now uses the structural bools
  `turn_made_progress ~strong_evidence ~surface_requires_evidence` (line 57). The
  summary filter's `inert_next_markers` still keys on the literal token the detector
  abandoned — it should adopt the same structural signal (§3.6).

## §3 Design — make the typed record the enforced system-of-record

The continuity snapshot for a turn is produced **once**, enforced as a typed value,
carried typed, and rendered to prose only at the terminal prompt-assembly step.
Nothing downstream re-parses prose.

### 3.1 Enforce structured emission (replaces the dead stub + best-effort parse)

Drive the turn's continuity emission through the existing
`structured_state_snapshot_schema` via `Agent_sdk.Structured` (the path already used
at `keeper_deliberation.ml:664`), so the provider guarantees a parseable object. The
current best-effort `parse_structured_state_snapshot_from_reply` (§1.3) becomes
unnecessary: instead of hoping the model put valid JSON in free text, the schema
makes the structured object the response. Result type:

- `Some snapshot` — enforced structured state; carry it typed.
- `None` — the provider/model failed to produce the object. This is the
  **irreducible producer-boundary parse** (§5, core A): even an enforcing API can
  return malformed or empty output. The `None` arm must be explicit, not collapsed
  to a default.

### 3.2 Type the cascade discriminant; keep one honest fallback

The four-way cascade (§0) collapses to: enforced structured (§3.1) → on `None`,
`synthesize_state_from_run_result`. The `[STATE]`-prose and reply-JSON branches are
removed with the round-trip (§3.3).

Replace the untyped `state_snapshot_source : string`
(`keeper_agent_run_response_text.ml:5`, classified by `String.equal` /
`starts_with ~prefix:"synthesized_"` at `keeper_memory_policy.ml:112-115`) with a
closed variant:

```ocaml
type state_snapshot_source = Structured_enforced | Synthesized_from_run
```

This removes a self-inflicted instance of the very anti-pattern this RFC targets:
v1 leaned on `state_snapshot_source` as the "honesty" / provenance signal while it
was itself a `starts_with`-prefix classifier (CLAUDE.md workaround signature #2).
The dead `"model_structured_state_tool"` value (only set by the §1.3 dead stub) is
dropped. `Synthesized_from_run` is the explicit, typed mark that continuity is
degraded for that turn — visible, not hidden, and not a string match.

### 3.3 Delete the prose round-trip

With the typed snapshot carried from §3.1/§3.2, the three call sites of
`state_snapshot_of_summary_text` (§1.4) consume the typed value directly.
`state_snapshot_of_summary_text`, `parse_structured_state_snapshot_from_reply`,
`parse_state_snapshot_from_reply`, and their `.mli` entries are deleted. Prose
becomes a terminal rendering of a snapshot the caller already holds typed, never an
input.

### 3.4 Project forward fields on the typed record (replaces `backward_labels`)

"Forward-only" is a projection on the typed record:
`forward_projection : keeper_state_snapshot -> keeper_state_snapshot` clears
backward-only fields (`decisions`, `done_summary`, `progress`). (A related
`forward_looking_snapshot` already exists at `keeper_memory_policy.ml:306` clearing
`progress`/`done_summary` — extend it to cover `decisions` and make it the single
forward projector.) Prompt assembly renders `forward_projection snapshot` with the
existing renderer (`keeper_state_snapshot_to_summary_text`). `backward_labels` and
`is_backward_line` are deleted — a new backward field is a compile-time decision in
`forward_projection`, not a forgotten marker.

### 3.5 Inject live tool-surface / goal-cap, do not persist them (replaces stale markers)

Tool surface and goal capacity are live runtime facts. They are excluded from the
persisted snapshot and injected at prompt assembly from typed runtime state, so they
cannot go stale and then need stripping. `stale_tool_surface_markers` and the inline
goal-cap list (with their `is_stale_*` functions) are deleted.

### 3.6 Inert turns: structural tool-evidence, not next-item prose (eliminates `inert_next_markers`)

This is the part v1 got wrong. v1 proposed a typed predicate "is this `next_items`
entry inert", which — because `next_items` is `string list` of model-authored text —
has no typed discriminant except the NL content, leaving the only implementation a
`contains_substring_ci` over `inert_next_markers` **relocated** from prompt-assembly
to snapshot-build. That is the same list wearing a type.

The correct signal already exists and is structural: RFC-0239 R3's
`turn_made_progress ~strong_evidence ~surface_requires_evidence`
(`keeper_stay_silent_loop_detector.ml:57`) decides whether a turn produced durable
work (substantive tool calls / validated output) **without reading any prose**. The
continuity path adopts the same signal:

- A turn with no durable tool-evidence does not carry its `next_items` forward as
  actionable, regardless of how the text is worded.
- There is no substring scan of `Next:` prose. `inert_next_markers` and
  `is_inert_next_line` are deleted.

This is a deliberate **semantic change**, stated plainly: "inert" stops meaning "the
text says *I'll stay quiet*" and starts meaning "the turn produced no durable work".
The text reading was unreliable in both directions — a keeper can write "continuing
X" while doing nothing, or do real work and phrase it as "대기". Tool-evidence is the
honest signal, and it is the one the loop detector already trusts (§2). Reusing it
gives the loop detector and the continuity path **one** definition of inert.

### 3.7 After 3.1–3.6

`keeper_memory_policy_summary_filter` and its `.mli` are deleted; the public
`filter_forward_looking_summary` surface collapses into `forward_projection` + the
existing renderer. The `snapshot → prose → snapshot` re-parse is gone. All four
substring classifiers (three named lists + the inline goal-cap list) are gone.

## §4 What this RFC explicitly does NOT claim

To avoid the failure mode that closed #21203 and that v1 fell into:

1. **Enforcing the schema does not make NL judgment vanish.** The schema's fields are
   `String` / `Array of String` (`keeper_memory_policy.ml:748-787`); the model emits
   NL into typed slots. What enforcement buys is reliable *field identity and
   presence*, not content meaning. The content judgment that remains is scoped down
   to §5 — and the inert case is removed from it entirely by §3.6's structural
   signal.
2. **The fallback is not a structured emission.** `synthesize_state_from_run_result`
   (§3.2) fabricates state from run metadata; when the provider returns `None`,
   continuity quality degrades. That is a property of the model/provider, not
   something this RFC repairs. It is made *visible* via the typed
   `Synthesized_from_run` (§3.2), not hidden.
3. **`backward`/`stale` handling is field/state projection, not text deletion;
   `inert` handling migrates to a structural signal.** None of these is "a smarter
   scrubber". The scrubber is deleted.

## §5 Irreducible core (do not type-wrap these)

After §3, what genuinely cannot be closed by a type is narrow. Any PR that claims to
have closed it is a typed shell over a classifier (CLAUDE.md workaround signature #2):

- **(A) enforced structured output → typed value.** The §3.1 boundary keeps a
  `None` arm because even an enforcing provider can return malformed/empty output
  (mirrors oas `api_common.ml:147` `member "name" |> to_string` and `types.ml:299`
  `| other -> Unknown other` — a separate repo; cross-repo reference). Keep the
  `None` arm; never collapse it to a default snapshot.
- **(B) semantic equivalence/staleness of arbitrary model NL where no structural
  signal exists.** This is *narrower than v1 claimed*. v1 put "did this turn make
  progress / is it inert" in (B); §3.6 shows that is answerable **structurally** by
  tool-evidence, so it is **not** in (B). (B) is only judgments with no structural
  proxy at all — e.g. deciding two differently-worded goals are "the same goal", or
  whether a free-text constraint is still semantically current — where there is no
  tool-evidence, content-hash, or live-state to diff against. RFC-0239 deliberately
  routes such cases through structural proxies (content-hash, tool-evidence) rather
  than NL semantics; this RFC keeps any residual NL judgment out of the keep/drop
  *correctness* path and never expresses it as a substring list over rendered prose.

## §6 Verification

- **Enforcement test:** with the structured producer (§3.1) returning a snapshot,
  the assembled prompt reflects the typed fields and **no
  `state_snapshot_of_summary_text` call is on the path** (module-boundary assertion,
  not output-text matching).
- **Fallback test:** with §3.1 returning `None`, `synthesize_state_from_run_result`
  produces the snapshot and the source is typed `Synthesized_from_run`.
- **Forward projection:** a snapshot with `decisions` + `done_summary` set renders,
  via `forward_projection` + the typed renderer, with backward content absent, and
  **no `contains_substring` / marker-list call on the path**.
- **Live-state injection (§3.5):** with stale tool-surface/goal-cap in a loaded
  snapshot, the assembled prompt shows live values, not persisted stale ones.
- **Shared inert definition (§3.6):** the continuity path and the loop detector are
  driven by the same `turn_made_progress` signal; a no-tool-evidence turn does not
  carry `next_items` forward and accrues the loop streak — tested against one signal,
  not two token lists.
- **Drift gate:** ratchet asserting the three named marker lists, the inline goal-cap
  list, and `state_snapshot_of_summary_text` are removed, and no new prose substring
  classifier is added in `lib/keeper*` (extends the code-smell baseline). The gate
  measures **disappearance of the surface-string lists**, not the presence of a
  variant.

## §7 Migration

The enforced producer (§3.1) is the gating dependency; until it lands, the prose
paths cannot be deleted without regressing continuity.

1. Land §3.1 + §3.2: enforce `structured_state_snapshot_schema`; type the source as
   `Structured_enforced | Synthesized_from_run`, keeping
   `synthesize_state_from_run_result` as the explicit `None` fallback.
2. Land §3.4 (forward projection) — removes `backward_labels`.
3. Land §3.5 (live injection) — removes the stale tool-surface + inline goal-cap
   lists.
4. Land §3.6 (structural inert via `turn_made_progress`) — removes
   `inert_next_markers`.
5. Land §3.3 (delete the three `state_snapshot_of_summary_text` call sites + the two
   reply parsers) and delete the filter module.

Until step 1 lands, the substring filter stays in place; removing it first would stop
filtering and regress the prompt. It is deprecated, not endorsed.
(`WORKAROUND` per CLAUDE.md: the existing markers are a production filter that must
not be dropped before the enforced producer exists. Replacement: this RFC. Removal
target: §7 step 5.)

## §8 Alternatives considered

- **Keep the substring filter (status quo).** Rejected: surface-token anti-pattern;
  lists grow per phrasing/language; the inert list keys on the literal token the loop
  detector already abandoned (§2).
- **Typed wrapper over the substring lists (PR #21203, closed).** Rejected: a
  `line_kind` variant whose `classify` still calls `contains_substring_ci` on the
  marker lists is a typed shell over an unchanged string classifier (CLAUDE.md
  workaround signature #2).
- **Type the filter / `is_actionable` on rendered prose (this RFC, v1, #21207).**
  Rejected by this revision: a typed predicate over rendered prose is still a
  heuristic over rendered prose; for `next_items` it would have relocated
  `inert_next_markers` rather than removed it (the audit's finding). It kept the
  round-trip (§1.4) and the filter concept. The defect is the unenforced record, not
  the scrubber's internals.
- **Fold into RFC-0239 (#21196).** Reasonable; #21196 is already drafted with a fixed
  five-guard table. Tracked as a sibling that reuses #21196/RFC-0239 R3's
  tool-evidence signal (§3.6) rather than reopening it.

## §9 Relation to RFC-0239

RFC-0239 fixes five guards that key on surface tokens, and its R3 already replaced
the `stay_silent` loop detector's literal-token predicate with a structural
tool-evidence signal (`turn_made_progress`). This RFC fixes the continuity-summary
content filter — the laggard that still keys on the token R3 abandoned — by (a)
removing the structural cause (the unenforced record and its prose round-trip) and
(b) adopting R3's tool-evidence signal for the inert judgment (§3.6), so "inert" has
one structural definition across the loop detector and the continuity path.

## §10 RFC ledger

This RFC reuses number `0242` (the v1 file at this path, merged via #21207). It
modifies an existing RFC in place rather than adding a new number, so
`docs/rfc/.next-number` (currently `0243`) is unchanged.
