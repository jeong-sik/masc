# RFC 0061 — Cache-invalidation broadcast envelope

- **Status**: Draft
- **Author**: Vincent + Claude
- **Depends on**: RFC-0040 (mention-dedup)
- **Resolves**: Reactive axis stage-1 death — broadcast rewrite swallows mention tokens before `pre_extract_mention` runs.

---

## 1. Problem

`lib/coord/coord_broadcast.ml:79-121` rewrites `content` to a `cache_invalidated` notice **before** `pre_extract_mention` (line 130). The rewritten string contains no `@target` token, so `Mention.extract` returns `None`. Downstream wake logic (`keeper_prompt.ml:16`, `keeper_exec_context.ml:418`) never sees the mention. The recipient stays asleep even though the sender intended a directed ping.

This is the single largest blocker in the Reactive axis. While it is alive, improvements in Cascade, Sandbox, or Tool axes are invisible to operators because the feedback loop dies at stage 1.

### Concrete failure path

1. taskmaster broadcasts `"@nick0cave task-037 is stale"`.
2. `cache_invalidated` guard (line 91) fires because task-037 is terminal.
3. `content` is rewritten to `"[cache_invalidated] coord_broadcast: task-037 is done — stale broadcast suppressed"`.
4. `pre_extract_mention = Mention.extract content` (line 130) sees no `@nick0cave`.
5. `mention` field in the persisted `msg` record is `None`.
6. nick0cave reads the board on its next turn; `Mention.any_mentioned ~targets:["nick0cave"]` is false.
7. No wake. No reaction. Loop broken.

---

## 2. Non-Goals

- Changing the pull model (keeper reads board, checks its own name). RFC-0040 preserves this.
- Changing mention dedup logic. RFC-0040 owns dedup.
- Adding push-time recipient filtering. `Mention.resolve_targets` has 0 production callers; out of scope.

---

## 3. Design

### 3.1 `broadcast_envelope` type

Introduce a record that preserves original content alongside any rewrites.

```ocaml
type rewrite_reason =
  | Cache_invalidated of { task_id : string; status : task_status }
  | Task_cache_rewrite of { module_name : string }

type broadcast_envelope = {
  original_content : string;
  rewrites : rewrite_event list;
  mention_tokens : string list;
  msg_type : msg_type;
}

and rewrite_event = {
  reason : rewrite_reason;
  replaced_content : string;
  timestamp_s : float;
}

and msg_type =
  | Broadcast
  | Cache_invalidated
  | Dedup_skipped
  | System_alert
```

**Why a closed variant for `msg_type`**:
The current code uses `string` (line 65 `?(msg_type = "broadcast")`). A closed variant lets the compiler force every downstream consumer to handle new message kinds, preventing silent drift.

### 3.2 Surgical fix — move `pre_extract_mention` before rewrite block

```ocaml
let broadcast ... =
  ensure_initialized config;

  (* STEP A: extract mention from ORIGINAL content, before any rewrite. *)
  let pre_extract_mention = Mention.extract content in

  (* STEP B: fleet-wide invariant (PR-B) — rewrite ONLY if needed,
     but preserve original for mention/wake logic. *)
  let content, msg_type, rewrites =
    if task_cache_invariant_checked then (content, msg_type, [])
    else if String.equal msg_type "broadcast" then
      ... (* existing rewrite logic, but also emit a rewrite_event *)
    else (content, msg_type, [])
  in

  (* STEP C: RFC-0040 dedup runs on original mention + original content hash. *)
  let dedup_skipped = ... in
  ...
```

Key change: `pre_extract_mention` moves from line 130 to **before** line 79. The `mention` field in the persisted `msg` record is populated from `pre_extract_mention`, not from the rewritten `content`.

### 3.3 Subscriber contract

- **Wake / reactivity**: uses `original_content` (or `mention_tokens`) to decide whether the keeper was mentioned.
- **UI / log display**: uses `rewrites` list to show that a rewrite occurred and why.
- **Persisted `msg` record**: `mention` field is `pre_extract_mention` (from original). `content` field is the rewritten string for display compatibility.

---

## 4. Cross-Reference to RFC-0040

RFC-0040 introduced sender-side mention dedup at `coord_broadcast.ml:122`. Its `content_topic_hash` (SHA1 of original content) and `should_skip` logic assume the original content is available at the point of dedup. After this RFC, that assumption holds because `pre_extract_mention` (and thus dedup) runs before rewrite.

| RFC-0040 element | This RFC guarantee |
|---|---|
| `Mention.extract content` at line 130 | Moved earlier; operates on original |
| `content_topic_hash content` at line 135 | Hash of original, not rewritten |
| `Mention_dedup.should_skip` | Correctly keyed to original content |

---

## 5. TLA+ Bug Model Requirement

Per CLAUDE.md TLA+ Bug Model pattern, provide a spec that proves the invariant catches the bug.

### 5.1 Actions

- `BroadcastRewriteSwallowsMention`: models the buggy code — rewrite happens before mention extraction.
- `MentionExtractedBeforeRewrite`: models the fixed code — extraction happens on original content.

### 5.2 Invariant

```
MentionTokensExtractedBeforeRewrite ==
  \A env \in broadcast_envelopes :
    env.mention_tokens = MentionExtract(env.original_content)
```

### 5.3 Verification matrix

| Config | Expected TLC result |
|---|---|
| `RFC0061Clean.cfg` (`Next = MentionExtractedBeforeRewrite`) | No error — invariant holds |
| `RFC0061Buggy.cfg` (`Next = BroadcastRewriteSwallowsMention`) | Invariant violated in 3 steps |

Both `.cfg` outputs must be attached to the PR description before Ready transition.

---

## 6. Layer 3 Adversarial Review Trigger

After PR opens (Draft), invoke `Agent(subagent_type=adversarial-reviewer)` with:
- **No JIRA/Slack context** — structural verification only.
- **Checklist**:
  1. `pre_extract_mention` is syntactically before any `content` mutation.
  2. `msg_type` is a closed variant (not `string`).
  3. `rewrite_reason` is a closed variant (not `string` or `option string`).
  4. No `_ -> false` or `_ -> None` catch-all in `msg_type` or `rewrite_reason` consumers.
  5. `Mention.extract` caller count in `coord_broadcast.ml` is exactly 1 (no second extraction after rewrite).
  6. `content_topic_hash` in RFC-0040 dedup is keyed to original content (grep for hash call site).

Reviewer must return a boolean `PASS`/`FAIL` per item, not a narrative summary.

---

## 7. Migration

### 7.1 Files changed

- `lib/coord/coord_broadcast.ml` — move extraction, add envelope type, populate `mention` from original.
- `lib/coord/coord_broadcast.mli` — export `broadcast_envelope`, `rewrite_reason`, `msg_type`.

### 7.2 Backward compatibility

The persisted `msg` JSON format gains an optional `original_content` field. Old readers ignore it. `msg.content` continues to hold the rewritten string, so UI that displays `content` needs no change.

---

## 8. Risks

- **Double extraction**: a future refactor might re-add `Mention.extract` after the rewrite block. Mitigation: Layer 3 review item 5.
- **String `msg_type` leakage**: external callers (grpc, eio variant) may still pass `"broadcast"` as string. Mitigation: convert at boundary, keep internal closed variant.
- **Envelope memory overhead**: one extra `string` per broadcast (original content). Acceptable — broadcasts are not high-frequency enough for this to matter.

---

## 9. Implementation Plan

| Step | File | Change | LOC |
|---|---|---|---|
| S1 | `coord_broadcast.ml` | Add `broadcast_envelope`, `rewrite_reason`, `msg_type` types | ~25 |
| S2 | `coord_broadcast.ml` | Move `pre_extract_mention` before rewrite block | ~5 |
| S3 | `coord_broadcast.ml` | Populate `mention` from `pre_extract_mention`, stamp `rewrites` | ~15 |
| S4 | `coord_broadcast.mli` | Export new types | ~10 |
| S5 | `test/test_coord_broadcast.ml` | Add "rewrite preserves mention" test | ~30 |
| S6 | TLA+ spec | `RFC0061.tla` + `.cfg` + `-buggy.cfg` | ~40 |
| S7 | dune build + test green | — | — |
| S8 | Draft PR + Layer 3 review | — | — |

Total **~125 LOC** (OCaml) + **~40 LOC** (TLA+).

---

## 10. References

- RFC-0040 (mention-dedup) — dedup logic that this RFC preserves.
- `lib/coord/coord_broadcast.ml:64-198` — current broadcast implementation.
- `lib/keeper/keeper_prompt.ml:16` — pull-model mention check.
- `lib/keeper/keeper_exec_context.ml:418` — direct_mention boolean injection.
- CLAUDE.md TLA+ Bug Model pattern — `BugAction` + `SafetyInvariant` verification.
- Memory: `feedback_main_blocker_chain_4x_session` — admin-merge / PR chain bypass forbidden.
