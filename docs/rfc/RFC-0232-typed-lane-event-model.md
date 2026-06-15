---
rfc: "0232"
title: "Typed lane event model: parse at the write boundary, never re-derive by string scan"
status: Draft
created: 2026-06-11
updated: 2026-06-11
author: vincent
supersedes: []
superseded_by: null
related: ["0223", "0225", "0226", "0228", "0230", "0231"]
implementation_prs: []
---

# RFC-0232: Typed lane event model

Status: Draft · The lane stays the state (RFC-0230), but its event model
becomes closed types parsed once at the write boundary · Retires every
observation-time string scan (role strings, content tokenizers, prefix
classifiers, fuzzy identity matching, wall-clock ordering).
Drafted by: Claude Fable 5 (multi-channel turn-lifecycle audit pass with owner,
2026-06-11).

> Anchors marked **(verified)** were read against `origin/main` (`e0b184684`)
> on 2026-06-11 while writing this RFC.

---

## §1 Problem — the lane is the state, but the state is stringly typed

RFC-0230 made the keeper chat lane the single source of reactive truth:
"have I answered" is "is the mention newer than my last line", with no
cursor and no stored engagement. The principle is right. The *carrier* is
not: every semantic fact a consumer needs is re-derived from strings at
observation time instead of being parsed once at the write boundary.

### §1.1 Inventory of string-derived semantics (all verified)

1. **Role is an open string.** `chat_message.role : string`
   (`lib/keeper/keeper_chat_store.mli:57` **(verified)**), written as
   literals (`keeper_chat_store.ml:181,196,222,245`) and compared as
   literals at the watermark and the pending filters
   (`keeper_world_observation_message_scope.ml:120,141,164` **(verified)**):

   ```ocaml
   | Some ts when m.role = "assistant" && ts > acc -> ts
   ```

   A typo'd or new role value silently falls out of both the watermark
   *and* the pending set — the compiler cannot enumerate readers.

2. **Ordering is wall-clock float.** The RFC-0230 watermark is
   `last_self_ts : float`, and "answered" is `ts > my_last_ts`. The
   only reason a turn's own user line does not appear pending is that
   `append_turn` stamps the whole pair with one `Time_compat.now ()`
   (`keeper_chat_store.ml:177` **(verified)**) — an *implicit* equal-ts
   convention. Clock skew, NTP steps, or any future writer that stamps
   lines independently can reorder the lane's meaning. The lane is an
   append-only file: **file order is already the true order**, and it is
   free of clocks.

3. **Mentions are re-tokenized from content on every observation.**
   `line_mentions` + `trim_token_edges`
   (`keeper_world_observation_message_scope.ml:51-88` **(verified)**) is a
   hand-rolled tokenizer with a hand-maintained word-character class,
   run over every lane line on every observation. Meanwhile the Discord
   boundary *already receives structured mentions* and throws them away,
   keeping only a bool
   (`discord_gateway_state.ml` `decode_message_create`, `mentions_bot`
   **(verified)**). PR #20874 (open) splits broad vs explicit `<@bot>`
   mentions — at the same boundary, in the same direction as this RFC.

4. **Self-identity is fuzzy string matching.** `is_self_author` matches
   the author through `identity_tokens_of_value` — lowercase/trim plus
   two canonicalization functions, sort_uniq'd
   (`keeper_world_observation_message_scope.ml:13-41` **(verified)**).
   "Is this me?" — the question this entire audit exists to answer —
   is a heuristic over name spellings instead of equality on a canonical
   identity minted at the boundary.

5. **A prefix classifier decides lane persistence.**

   ```ocaml
   let continuation_checkpoint_prefix = "Continuation checkpoint saved;"
   ```

   (`server_routes_http_keeper_stream.ml:296` **(verified)**) — whether a
   completed turn is persisted to the lane at all is decided by sniffing
   the visible reply text. The producer *knows* it emitted a checkpoint;
   the type system is not told. This is the exact string-classifier
   signature CLAUDE.md's workaround bar rejects, living on the lane's
   write path.

6. **Source/surface is an open string.** `source : string option`
   ("dashboard" / "discord" / "slack" / "agent",
   `keeper_chat_store.mli` doc comment **(verified)**) while
   `Keeper_external_attention.surface_ref` (#20862) already defines the
   typed surface coordinates for the same concept. Two vocabularies for
   one concept, one typed and one stringly, is split-brain by
   construction.

### §1.2 This is not theoretical — it bit today

PR #20870 (merged 2026-06-11 23:29, `ca5320441` **(verified)**) fixed
connector-dispatched turns whose assistant replies were **never persisted
to the lane**. Consequence under RFC-0230 semantics: the keeper's
watermark never advanced, every Owner line stayed "unanswered" forever,
and the keeper re-answered the same message on every observation — the
"replies to its own conversation like a fool" failure mode, in
production. The convention "completing a turn must append an assistant
line" was load-bearing and *unchecked*: no type connected turn completion
to watermark advancement, so the omission compiled cleanly and failed
silently.

A second silent hazard sits in the same shape: dashboard turns persist
their user+assistant pair only at turn *end*
(`server_routes_http_keeper_stream.ml:678-690` **(verified)**), and not at
all when the reply matches the checkpoint prefix (§1.1.5). What the
operator saw in the dashboard and what the keeper can ever recall from
its lane silently diverge.

### §1.3 Why now

Three concurrent work streams are adding *more* consumers of these
strings: RFC-0231 Memory OS (#20876) will recall from persisted lanes;
external-attention wiring (#20873, merged) projects lane-adjacent state;
#20874 (open) enriches Discord mention semantics. Every new consumer of a
stringly lane multiplies re-derivation sites. The boundary work in those
PRs is the right direction — this RFC closes the model they feed.

---

## §2 Design principles

1. **Parse, don't re-derive.** Every semantic fact (role, mentions,
   author identity, surface, turn outcome) is parsed into a closed type
   exactly once, at the write boundary. Observation-time code reads
   typed fields; it never scans content.
2. **The lane stays the state.** No new cursors, no stored engagement
   (RFC-0230 §2 holds). This RFC changes the *type* of the state, not
   its location or its cursor-free semantics.
3. **Closed sums, exhaustive matches.** Adding a role/surface/outcome
   variant must break every reader at compile time. No `_ -> false`
   arms in the new code (CLAUDE.md FSM rule).
4. **Order is structural.** The lane's order is its append order. No
   wall-clock comparisons decide semantics; `ts` remains for display.
5. **Identity is equality on a canonical type**, minted at the boundary
   by the existing `Keeper_identity` canonicalizers — fuzzy matching
   happens once where data enters, never where it is consumed.

---

## §3 The typed model

### §3.1 Role (closed sum)

```ocaml
module Role : sig
  type t = User | Assistant | Tool
  val to_label : t -> string            (* "user" / "assistant" / "tool" *)
  val of_label : string -> t option
end
```

`chat_message.role : Role.t`. The JSONL codec maps unknown labels to a
typed read drop (the exact precedent `speaker_authority` already set:
parse failure is reported, row dropped from semantics, never defaulted —
`keeper_chat_store.mli:69-72` **(verified)**). All
`m.role = "assistant"` comparisons become exhaustive matches.

### §3.2 Watermark by lane position, not clock

`load` already returns lines in file order. The watermark becomes the
*position* of the keeper's last `Assistant` line; a `User` line is
pending iff it appears **after** that position:

```ocaml
(* answered = appears at-or-before my last Assistant line, in lane order *)
let pending messages =
  let _, pend =
    List.fold_left
      (fun (i, acc) m -> match m.role with
         | Role.Assistant -> (i + 1, [])          (* my line clears the slate *)
         | Role.User when is_candidate m -> (i + 1, m :: acc)
         | _ -> (i + 1, acc))
      (0, []) messages
  in
  List.rev pend
```

No floats, no equal-ts convention, no skew sensitivity. `append_turn`'s
"user then tools then assistant, one write" already guarantees the pair
collapses correctly. `ts` is demoted to display/telemetry.

### §3.3 Mentions parsed at the boundary, persisted on the line

```ocaml
type chat_message = {
  ...
  mentions : Keeper_id.t list;   (* parsed at append; [] = none *)
}
```

- **Discord**: keep the full structured `mentions` array at
  `decode_message_create` (today reduced to `mentions_bot : bool`),
  map member ids → keeper bindings at the gate, persist on the ambient
  / dispatch user line. Composes with #20874's broad/explicit split —
  that PR decides *which* mentions trigger; this RFC decides *where
  the parse lives* (once, at decode).
- **Dashboard / agent text**: tokenize once at `append_user_message` /
  `append_turn` (the current `line_mentions` tokenizer moves there,
  renamed as the boundary parser), persist the result.
- **Observation**: `pending_mentions_of_messages` filters on
  `m.mentions`, never on `m.content`.

### §3.4 Identity: `Keeper_id.t`

```ocaml
module Keeper_id : sig
  type t = private string                  (* canonical form *)
  val of_string : string -> t option       (* via Keeper_identity canonicalizers *)
  val equal : t -> t -> bool
end
```

`is_self_author` becomes `Keeper_id.equal` on ids minted at the parse
boundary. The multi-form normalization in `identity_tokens_of_value`
moves inside `of_string` — it runs where data enters, and consumers can
no longer disagree about who "me" is.

### §3.5 Turn outcome is producer-typed

```ocaml
type turn_outcome =
  | Visible_reply of string                (* persist to lane *)
  | Continuation_checkpoint                (* internal; not a lane line *)
```

The pipeline that *creates* the checkpoint returns
`Continuation_checkpoint`; the keeper-stream persistence site matches on
the variant. `is_continuation_checkpoint_reply` and its prefix constant
are deleted. New outcome variants (e.g. a future `Deferred`) break the
persistence site at compile time instead of silently persisting or
silently vanishing.

This also closes §1.2 structurally: turn completion returns a value the
persistence layer must consume — "completed a turn but never appended the
assistant line" stops being expressible as an accidental omission on the
happy path.

### §3.6 Surface: one vocabulary

Extract `Keeper_external_attention.surface_ref` into a shared
`Surface_ref` module; `chat_message.source : Surface_ref.t option`
replaces the open string. The lane, the attention store (#20862/#20873),
and the gate then speak one typed surface vocabulary. (Phase-ordered
last; coordinates with the in-flight attention wiring.)

---

## §4 Migration — no runtime re-derivation

Lanes are append-only JSONL under
`<base_path>/.masc/keeper_chat/<keeper>.jsonl` with legacy lines lacking
`mentions` and carrying free-form `role` / `source` strings.

- **Codec**: `Role.of_label` / `authority_of_label`-style parsing covers
  all lines ever written by this codebase ("user"/"assistant"/tool
  lines). Unknown → typed read drop (existing policy).
- **Mentions backfill**: a one-shot offline migration tool (server
  stopped) rewrites each lane file, running the legacy tokenizer once
  per historical user line and persisting `mentions`. After migration,
  the runtime never string-scans content. The tool backs up each lane
  file beside the original before rewriting.
- **Explicitly rejected**: a read-time fallback that tokenizes
  `mentions`-less lines. It would keep the scanner alive in the hot
  path forever — the pattern this RFC exists to end.

---

## §5 Phases

| Phase | Scope | Files (primary) |
|---|---|---|
| P1 | `Role.t` + positional watermark; delete role-string comparisons | `keeper_chat_store.{ml,mli}`, `keeper_world_observation_message_scope.ml` |
| P2 | Turn outcome variant; delete prefix classifier | `server_routes_http_keeper_stream.ml`, keeper msg pipeline |
| P3 | `Keeper_id.t`; structural self-identity | `keeper_identity.{ml,mli}`, message scope, board signal |
| P4 | Boundary mention parse + persisted `mentions` + offline backfill tool | gate decode, chat store, `bin/` migration tool |
| P5 | Shared `Surface_ref`; retire `source` strings | new `surface_ref.{ml,mli}`, chat store, attention store, gate |

Each phase is independently shippable and independently revertible; P1
and P2 remove the two production-bitten hazards (§1.2) first.

## §6 Verification harness

- **Self-echo impossibility (property)**: for arbitrary generated lanes,
  appending an `Assistant` line never grows the pending set, and a
  keeper's own lines never appear in it. (QCheck over the pure
  functions — they are already I/O-free.)
- **Watermark monotonicity (property)**: pending is monotone
  non-increasing under appending self lines, monotone non-decreasing
  under appending qualifying Owner lines, independent of `ts` values
  entirely (fuzz ts with skew; semantics must not change).
- **Boundary-parse equivalence (golden)**: replay captured lane corpora
  through the P4 boundary parser and assert equality with the legacy
  tokenizer's output before deleting it.
- **Outcome totality**: exhaustive-match CI already in place catches new
  `turn_outcome` variants at every consumer.

## §7 Non-goals

- Recall/rendering semantics of Memory OS (RFC-0231 P2+).
- Attention lifecycle policy (Recorded/Claimed/Resolved — #20862/#20873
  trajectory); §3.6 only unifies the *coordinate type*.
- Discord trigger policy (mention_only vs broad — #20874 owns it).
- Any change to RFC-0230's cursor-free semantics; this RFC types them.

## §8 Risks

- **Parallel-stream collisions**: #20874 (open) touches the same gate
  decode; #20876 will consume lane types. Mitigation: land P1/P2 small
  and fast; P4 rebases on #20874's mention split rather than racing it.
- **Lane rewrite (P4 backfill)**: file rewrite on operator data.
  Mitigation: per-file backup, dry-run mode, server-stopped requirement,
  golden equivalence test (§6) before enabling.
- **Codec drift between old binaries and new lanes**: `mentions` is an
  additive field; old readers ignore it. `role` labels are unchanged on
  disk — only the in-memory type closes.
