# RFC-0328 — Keeper perseveration: grounding-gated memory promotion, active residue purge, health-driven failover, and semantic-stagnation recovery

- Status: Draft
- Date: 2026-07-08
- Type: Incident RFC (owns the perseveration-engine fixes: memory Gap C, failover/stagnation Gap D)
- Scope: `lib/keeper/keeper_memory_bank.ml`, keeper runtime routing (`config/runtime.toml [runtime.assignments]`), provider health, stagnation detection.
- Companion: RFC-0329 owns the operative-gate fixes (Gap A payload-blind Execute governance and Gap B's typed-exemption acceptance bar). This RFC and RFC-0329 come from the same incident; each is independently landable.
- Relates to / activates: RFC-0207 Part B (Draft, deferred), RFC-0260 (Draft, unimplemented), RFC-keeper-memory-consolidation (Draft, unimplemented).
- Cross-references: RFC-0082, RFC-0126, RFC-0207, RFC-0211, RFC-0216, RFC-0239, RFC-0246, RFC-0257, RFC-0259, RFC-0260, RFC-0271, RFC-0285, RFC-0302, RFC-0312, RFC-0315, RFC-0326.

---

## 1. Incident post-mortem

### 1.1 Symptom

Keeper `mad-improver` (repo `~/me/workspace/yousleepwhen/masc`, runtime state `<base-path>/.masc`) ran for approximately 26 hours / 70+ turns broadcasting a single message:

> "Execute hard_forbidden — operator must add execute=true to keeper_repo_mappings.toml to grant Execute permission."

The keeper produced no tool-side progress (48h agent-timeline: `tool_calls=0`, `turns_completed=0`). Each "successful" turn wrote memory notes rather than doing work.

### 1.2 Verified timeline

- T-~26h: provider `runpod_mtp.qwen36-35b-a3b-mtp` begins returning empty completions (`reason_kind=no_usable_progress`; `shape=empty`; `stop_reason=max_tokens/end_turn`; `text_chars=0`; `content_blocks=0`; `tool_use_count=0`). Also `Capacity backpressure ... cooldown_cause=terminal_failure; retry_after≈3599s`. The keeper is starved of usable output. The provider endpoint was serving a Jupyter Server (HTTP 403).
- Governance layer (independent of provider): any shell Execute attempt is classified `risk=Critical` unconditionally and blocked before HITL (`Block`, "unconditional block regardless of HITL mode"). Confirmed `mad-improver.json` `last_blocker` was later `capacity_backpressure`, and at the time of the confabulation `last_blocker: null`, so the block was pure `risk=Critical`. The mechanism of this block is the subject of RFC-0329.
- The keeper reports the mechanism-true fact "Execute is blocked" but confabulates the cause and the fix.
- Memory poison closes the loop: `<base-path>/.masc/keepers/mad-improver.memory.jsonl` (60 rows) had 47 rows repeating the false causal claim, `source=progress_consolidation`, `priority≈90`, tagged `[consolidated:N]`. Each turn: read poisoned memory → re-derive false conclusion → broadcast → re-consolidate.
- On 2026-07-02 an operator manually rerouted `issue_king` off `runpod_mtp` to a working endpoint (`runtime.toml:504` `"issue_king" = "runpod_rtxa6000.gemma4-coder-fable5-q4km"`) but left `mad-improver` on the dead endpoint one line below (`runtime.toml:505`). `mad-improver` is the keeper the hand-edit missed.

### 1.3 Keeper error taxonomy (kept verbatim for the record)

- RIGHT: "Execute is blocked" — mechanism-true (see RFC-0329 §2).
- WRONG CAUSE: attributes the block to the repo mapping. Design-false: the `hard_forbidden` formula has no repo-mapping term (`rg -ni "repo_mapping|repositories" lib/governance_pipeline*.ml` = 0 hits).
- WRONG FIX: "edit `keeper_repo_mappings.toml` execute=true". No such field exists; the parser reads only the `repositories` key, so the write is silently ignored — a provable no-op. `mad-improver` already has a normal mapping identical to `executor`/`garnet`/`verifier`.
- OVER-GENERALIZED: "all tools hard_forbidden". False — only Critical ops block. `board_comment`/`tasks_list`/`read_file`/`search`/`keeper_memory_write` are Low and worked fine (the 70+ broadcasts and per-turn memory writes are the evidence).
- CONFABULATED: claims "git status tried 3x → hard_forbidden" while `tool_calls=0`. The commands were never issued; the provider returned empty and the keeper narrated an attempt that did not happen.

### 1.4 What the keeper likely pattern-matched (so neither RFC re-encodes it)

Two repo-adjacent Execute failures exist elsewhere and both surface as `cwd_not_directory` / identity-mismatch, never as `hard_forbidden`:
- `exec_policy_paths.ml` catalog whitelist (RFC-0324), denies unregistered/identity-mismatched repo paths, ignores the mapping's `repositories` list.
- The historical "sandbox root cannot run git/gh: multiple sandbox repos exist. Set cwd explicitly" cwd-disambiguation hard-fail (RFC-0104).

Neither is the advisory `keeper_repo_mappings.toml`. RFC-0312 (Accepted, §2) states the toml is advisory/default-scope metadata only and `access_decision` discards a found mapping. The keeper's model is a confabulation reinforced by poisoned memory.

---

## 2. Root-cause taxonomy — four gaps, split across two RFCs

The incident is one symptom over four distinct systemic gaps. Two form the *operative gate* (why shell Execute is blocked at all) — owned by **RFC-0329**. Two form the *perseveration engine* (why the keeper stayed stuck instead of recovering) — owned by **this RFC**.

| Gap | One-line | Layer | Owner |
|-----|----------|-------|-------|
| A | Governance Execute risk is payload-blind and pre-empts the typed Shell-IR read-only classifier | governance PreToolUse | RFC-0329 |
| B | No active typed exemption exists; the removed raw keeper-name bypass neither scoped code effects nor opened the earlier Critical Execute block | keeper guard | RFC-0329 |
| **C** | Durable memory promotion is gated by repetition frequency, not grounding — a repeated false claim becomes priority-90 durable memory, and there is no active purge of already-consolidated residue | memory_bank | **this RFC** |
| **D** | No persisted health-driven per-keeper failover, and no semantic-stagnation detector — a keeper on a dead provider with zero-effect "successful" turns is invisible to every existing loop-break | runtime routing + stagnation | **this RFC** |

Gaps C and D are why a transient provider outage plus a payload-blind gate did not self-heal but calcified into a 26-hour loop. Fixing them stops the loop even while Gaps A/B remain (the keeper cannot run shell, but it recovers, reports the real blocker, and does not re-derive a false one).

---

## 3. Design invariants (apply to every change in this RFC)

These are hard constraints, not preferences. A change that violates one is rejected, not merged behind a comment.

1. **No hidden hardcoding.** No magic thresholds, no hardcoded keeper/phrase/command lists embedded in decision paths. Every threshold or capability is either derived from a typed structural fact or read from configuration with a typed schema. Naming a constant is not enough — the value must have a reason a reader can check, and a list that grows by hand is a config file with a schema, not a `match … with "x" -> … | _ -> …`.
2. **Parse, don't validate.** Decisions are made over parsed typed values (closed sum types with exhaustive match), never over substrings of prose or command text.
3. **Fail closed on Unknown.** Missing, unparseable, or non-decidable input maps to the conservative outcome (`Ungrounded` / not-promoted / `Down`), never to a permissive default.
4. **Control, not telemetry.** A counter that makes a failure visible is not a fix. Every change here alters control flow (promotion gate, purge, dispatch target, pause).
5. **Remove, don't accrete.** Prefer deleting a pathological mechanism to bolting a guard on top of it.

---

## 4. Gap C — memory promotion gated by frequency, plus no purge of existing residue

**Operative mechanism (verified).** The poisoned store is the memory_bank (`lib/keeper/keeper_memory_bank.ml`), not the Memory OS fact store. `consolidate_memory_notes` groups `kind = "progress"` rows by `trace_id`; when `List.length group >= consolidation_min_group_size` (`= 3`, `keeper_memory_bank.ml:225`) it emits one `long_term` note at `:266`, `source = Progress_consolidation`, `priority ≈ 90`, text `"[consolidated:N] t1; t2; ..."`. The sole promotion gate is repetition count. The only text filter, `is_meaningful_memory_text`, is a length/non-empty check, not a truth check. `compaction_priority` boosts `long_term` + `Progress_consolidation` (`:417`), so consolidated rows dominate re-injection. A keeper that repeats a confabulated conclusion three times — even on a zero-tool-call turn — manufactures a priority-90 durable note it then re-reads and re-derives. "kind=progress" (a horizon-slot label) is conflated with "actual progress was made".

Note that `consolidation_min_group_size = 3` is itself a magic frequency threshold standing in for "this is important/true". The fix does not re-tune it; it removes frequency as the gate.

### 4.1 Prevention — move the gate from frequency to grounding, at the producer boundary

Do not inspect claim text. Use a structural runtime fact that already exists:

1. Type each note's evidence provenance: `grounding : Grounded of evidence_ref | Ungrounded`, set from the runtime turn's `tool_use_count` (already tracked; the incident cites `tool_use_count=0`), never parsed from prose. A progress/decision note emitted on a zero-external-tool turn is `Ungrounded` by construction. Writing memory is not external progress: `keeper_memory_write` (and other non-external-progress tools) must be excluded from the grounded set, otherwise the loop self-grounds.
2. Gate promotion on grounding: `consolidate_memory_notes` refuses to promote a group whose members are all `Ungrounded`. Repetition of an ungrounded assertion can no longer manufacture a durable note — this directly kills the "git status tried 3x → hard_forbidden" path (all `Ungrounded`).
3. Fail closed on Unknown: missing/unparseable grounding ⇒ `Ungrounded` ⇒ not promoted (RFC-0239 §4 principle 2). A string allowlist would fail *open* (unknown → allow); grounding fails closed.
4. Give a promoted narrative a finite typed lifetime: treat a consolidated causal/progress narrative as a `Self_observation`/`External_state` claim class with a producer-tag-keyed `valid_until` (RFC-0259 P7 / RFC-0285), so an un-re-grounded consolidated note hard-expires instead of re-injecting forever.

### 4.2 Remediation — active purge of already-consolidated residue (the librarian must clean, not only guard)

Prevention alone leaves the 26 hours of poison already promoted to priority-90 durable memory. A write-time guard does not remove what is already there. The consolidation/librarian pass must also evict residue:

- On each consolidation pass (and on keeper (re)start), re-validate existing `Progress_consolidation` `long_term` notes against their `grounding` and `valid_until`. A note that is `Ungrounded` or past `valid_until` is evicted, not re-injected. This is typed re-validation over the note's own provenance fields, not a blocklist of forbidden phrases — an ungrounded consolidated note is evicted regardless of what it says.
- The eviction is idempotent and logged as a control action (rows removed), so a keeper that has accumulated ungrounded residue converges to a grounded memory set instead of carrying it forever.

The principled destination is RFC-keeper-memory-consolidation's plan: collapse memory_bank into the Memory OS so there is one typed store carrying `claim_kind` + `grounding` + decay, and the frequency-only promotion path ceases to exist. That RFC is Draft/unimplemented and scopes the grounding/score model out (§2); this RFC supplies the grounding gate and the purge as the missing elements and scopes RFC-keeper-memory-consolidation to *activation*.

### 4.3 On the over-generalization / config-contradiction dimension

Do not try to prove "repo mapping gates Execute" false — that reintroduces a classifier and hardcodes what a "wrong claim" looks like. Per RFC-0285's honest boundary, a causal claim about system internals has no deterministic oracle, so its correct type is `Self_observation`-volatile: grounding-gated promotion + finite TTL + active eviction together bound the blast radius. The claim may exist for a bounded window but can never become immortal priority-90 durable memory, so the loop terminates.

### 4.4 Why this is not a workaround

It gates on a typed structural fact (`tool_use_count → Grounded/Ungrounded`) read at the producer boundary and fails closed on Unknown, never inspecting claim text for forbidden substrings, and it removes the frequency gate rather than tuning it. The purge evicts by provenance type, not by phrase. Contrast the rejected naive fixes: a read-time grep for `keeper_repo_mappings.toml` (workaround signature #2, and a hidden hardcoded phrase list), lowering `consolidation_min_group_size` (cap-tuning, and still a magic number), or a "config-contradicting notes consolidated" counter (signature #1).

---

## 5. Gap D — no persisted failover, no semantic-stagnation recovery

**Operative mechanism (verified).** The `mad-improver` model pin lives in `runtime.toml [runtime.assignments]` (`:505`). It is loaded once at boot into a `loaded_state Atomic.t` (`lib/runtime/runtime.ml`, `init_default`) and read from that cache each turn; there is no SIGHUP/live-reload path, so an on-disk re-pin takes effect only on server restart (this is itself part of why the 2026-07-02 hand-edit's omission persisted). No persisted per-keeper failover binding exists:

- RFC-0207 Part B (ordered per-keeper `runtime_failover` list consumed in `keeper_error_classify`) is explicitly deferred (Draft).
- RFC-0260 (provider health probe + declarative fallback chain + audited `assignment_change` ledger) is Draft/unimplemented; `provider_health.ml` does not exist; the `runpod_mtp` healthcheck is `enabled = false`, so the dead endpoint is undetected.
- The only off-dead-provider path is an untracked manual toml edit — the exact hand-edit that rerouted `issue_king` but missed `mad-improver`.

An in-turn `degraded_rotation` lane exists (`keeper_error_classify.ml`) but is ephemeral (rotates within one turn, never rewrites the pin) and error-triggered only. `mad-improver`'s turns mostly *pass accept* — the dead provider returns empty, but the poisoned-text broadcasts pass accept, so no error is raised and no rotation fires.

Every existing stuck-loop detector keys on the wrong invariant: `keeper_turn_livelock` on identical `turn_id` re-attempts; `Goal_stagnation` (RFC-0315) only on a stale goal in Executing phase (`mad-improver` has `active_goal_ids=[]`, so it cannot fire); `consecutive_noop_count` only on turns with no visible output; RFC-0082 only on a `last_blocker` latch (`null` during the confabulation); `NoProgressStreak` is a metric with no control. `mad-improver`'s signature — N consecutive distinct turns that each pass accept (visible ~640-token broadcast) with zero task/goal/PR transition and near-identical content — is invisible to all of them. Stagnation is defined *structurally* everywhere; `mad-improver`'s stagnation is *semantic*.

### 5.1 (D1) Provider health lattice + persisted failover

Activate RFC-0207 Part B and RFC-0260 together. A closed sum `provider_health = Healthy | Degraded of reason | Down of reason` produced by the `provider_health.ml` probe RFC-0260 names, armed by the existing typed signals (`Accept_no_usable_progress` empty-response streak and `Cooldown_terminal_failure`, already deterministic). The per-keeper binding becomes an ordered non-empty list; resolution is "first entry whose health = Healthy"; an exhausted chain is an explicit typed operator error (RFC-0126 fail-closed, never a silent local-model default); a keeper pinned to a `Down` provider is not dispatched to it. Each reassignment is persisted as an audited `assignment_change` event (RFC-0260 §3) so it survives across turns and across the boot-cache boundary, replacing today's ephemeral in-turn rotation and the untracked manual edit.

No hardcoding: the failover order is per-keeper config (the ordered list), not a hardcoded fallback constant; the health thresholds (empty-response streak length, cooldown class) are the typed signals RFC-0271/0260 already define, not new magic numbers.

### 5.2 (D2) Semantic-progress stagnation FSM

New — no existing RFC owns non-goal, successful-turn stagnation (RFC-0326 owns failure *typing*; this is stagnation over *successful* turns). Classify each turn's effect as a closed sum:

```
turn_effect = Progress of progress_kind | No_effect
progress_kind = Tool_calls | Task_transition | Goal_advance | Pr_action
```

`No_effect` = accept-passed but zero side-effect and content-signature ≈ prior turn, where the signature is a structural digest of the parsed effect (tool set, task/goal/PR deltas) — not substring equality on broadcast text. An FSM `Stagnant of {turns; signature} | Advancing` over the last N turns escalates to pause/handoff when `Stagnant ≥ N`, independent of goal presence, `turn_id`, noop, or error. The exhaustive match forces every new turn-effect kind to declare Progress-or-not, so the detector cannot silently regress.

No hardcoding: N is a keeper/config field with a typed default, not a literal buried in the detector; the signature is computed from parsed structure, not a hardcoded set of "loop phrases".

### 5.3 Why this is not a workaround

Both pieces are *control* actions (persisted failover + pause), not telemetry. `NoProgressStreak` already exists as a dead metric proving counters do not stop the loop (signature #1). Detecting "identical broadcast" via substring would be signature #2 and a hidden hardcoded phrase list; D2 uses a typed progress predicate over parsed turn effect. A hand-edit reroute is the untracked-manual-edit / N-of-M pattern (signature #3) RFC-0260 Problem #2 names; D1 makes it health-gated and audited. Bumping the cooldown or dedup'ing the broadcast is cap/cooldown/dedup symptom suppression — the provider being `Down` is the root.

---

## 6. Workaround-bar self-check (CLAUDE.md 7-item checklist)

1. **makes-visible-only / instrument-only.** Not tripped. Gap C rejects a "config-contradicting notes" counter; Gap D rejects a `NoProgressStreak` counter (it already exists and did not stop the loop). Both change control flow (promotion/purge gate, dispatch target, pause).
2. **string/substring classifier added.** Not tripped. Gap C gates on `tool_use_count` grounding and evicts by provenance type, not by grepping note text. Gap D's stagnation signature is a structural digest of parsed turn effect, not a substring match on broadcast text.
3. **N-of-M self-admission.** Not tripped. Gap C replaces the frequency gate with one typed grounding axis; Gap D1 activates the ordered-failover mechanism once rather than rerouting keepers one hand-edit at a time.
4. **catch-all `_ ->` added.** Not tripped. Every mapping (grounding, turn-effect → Progress/No_effect, provider_health lattice) is an exhaustive closed-sum match; a new constructor forces a compile-time decision. Non-decidable arms map to `Ungrounded` / `Down` (fail-closed).
5. **cap/cooldown/dedup/repair suppression.** Not tripped. Gap D rejects bumping the cooldown, capping retries, and dedup'ing the broadcast; the replacement is health-gated persisted failover + a stagnation FSM. Gap C rejects lowering `consolidation_min_group_size`.
6. **test backdoor exposed.** Not tripped. Tests drive the classifiers through real inputs (a turn's `tool_use_count` → grounding; a turn's parsed effect → Progress/No_effect).
7. **same fix N times across N sites.** Not tripped. The grounding gate lives in one place (`consolidate_memory_notes` producer boundary); the failover decision lives in one place (health-gated resolution).

Override clause: neither fix is production-blocking-only, so no `WORKAROUND:` label is required. This RFC is the RFC the workaround bar directs these fixes into.

---

## 7. Verification plan

### 7.1 Grounding gate (Gap C)

- A group of 3 progress notes all emitted on turns with `tool_use_count=0` (`Ungrounded`) → `consolidate_memory_notes` does NOT promote to `long_term`/`Progress_consolidation`.
- A group of 3 progress notes with `tool_use_count>0` on non-`keeper_memory_write` tools (`Grounded`) → promotion occurs.
- A group of 3 notes whose only tool calls are `keeper_memory_write` → `Ungrounded` → not promoted (the self-grounding hole is closed). Replay the incident's memory-write-only turns and assert not promoted.
- Missing/unparseable grounding → `Ungrounded` → not promoted (fail-closed).
- A promoted `Self_observation` narrative with `valid_until` in the past is excluded from re-injection and evicted by the purge pass.

### 7.2 TLA+ bug-model — stagnation-recovery FSM (Gap D2)

Per the CLAUDE.md TLA+ pattern (a safety invariant a bug action must violate), mirroring `KeeperOASAdvanced.tla`:

- State: `turnEffect ∈ {Progress, NoEffect}` history over a window; `fsm ∈ {Advancing, Stagnant}`; `dispatched ∈ BOOLEAN`.
- `Next` (clean): after N consecutive `NoEffect` turns, `fsm' = Stagnant` and the keeper is paused/handed off.
- `BugAction` (`StagnationNeverEscalates`): keeps dispatching after N `NoEffect` turns without setting `Stagnant` (models today's behavior — successful-but-zero-effect turns reset the streak).
- `SafetyInvariant` (`NoUnboundedZeroEffectDispatch`): never `>N` consecutive `NoEffect` turns while `dispatched` stays true and `fsm = Advancing`.
- Two cfgs: clean `SPECIFICATION Spec` → TLC "no error"; `-buggy.cfg` `SPECIFICATION SpecBuggy` (`Next \/ BugAction`) → invariant violated. Both must hold for the invariant to be non-vacuous.

The provider-health lattice (D1) is also expressible (`Down` provider must never be the resolved dispatch target), but the stagnation FSM is the primary bug-model fit because its failure is a liveness-shaped loop the structural detectors miss.

### 7.3 Integration check

Replay the incident shape: keeper pinned to a `Down` provider producing empty completions, memory seeded with 3 ungrounded progress notes. Assert: (a) failover re-resolves to a Healthy provider and persists an `assignment_change`; (b) the ungrounded notes are not consolidated and existing ungrounded residue is evicted; (c) after N zero-effect turns the stagnation FSM pauses the keeper. Absent all three, the fix is incomplete.

---

## 8. Cross-references to existing RFCs

| RFC | Status (as found) | Relation |
|-----|-------------------|----------|
| RFC-0329 (companion) | Draft (this incident) | Owns Gaps A/B (the operative gate). This RFC stops the loop; RFC-0329 removes the payload-blind gate structure. |
| RFC-keeper-memory-consolidation | Draft, unimplemented | Names the memory_bank subsystem and its missing anti-thrash guards, cites `mad-improver`, and plans to collapse the bank into Memory OS. Gap C supplies the grounding gate + purge it scopes out (§2) and scopes that RFC to *activation*. |
| RFC-0239 semantic-identity-guards-for-keeper-memory-and-anti-thrash | Draft | Its R1–R5 guards target the Memory OS fact store, not `keeper_memory_bank.ml`, and compare parsed structure, not claim meaning. Supplies the fail-closed principle Gap C adopts. (Numbering collision with `RFC-0239-concurrency-ownership-model` should be resolved.) |
| RFC-0259 memory-os-volatile-claim-grounding-retraction-decay | Draft (P7 landed) | Its producer-tag-keyed `valid_until` is the typed-decay pattern Gap C reuses; memory_bank never received it. |
| RFC-0285 memory-os-self-observation-claim-volatility | Draft | The honest boundary Gap C respects: a self-observation/causal claim has no external oracle → finite-TTL volatile at the producer boundary, not a read-time string classifier. |
| RFC-0216 per-keeper-decline-memory | Draft | Precedent for the typed-signal-consumed-at-decision idiom (record a typed signal, consume it at the decision point, no threshold/timer). |
| RFC-0257 / RFC-0302 | Draft | Memory IO lane / off-main offload; orthogonal to promotion/truth logic. |
| RFC-0207 per-keeper-runtime-routing-ordered-failover | Draft (Part A impl, Part B deferred) | Gap D1 activates Part B (ordered `runtime_failover` list). |
| RFC-0260 provider-health-gate-audited-failover | Draft, unimplemented | Owns health probe + declarative fallback + audited `assignment_change`; documents this incident class. Gap D1 activates it. |
| RFC-0211 persona-runtime-decouple | Draft | Establishes `[runtime.assignments]` as the runtime SSOT; Gap D1 makes the pin an ordered health-gated binding and notes the boot-cache reload gap. |
| RFC-0082 keeper-last-blocker-autoclear-and-recovery-escalation | Implemented | Recovery escalation is scoped to a `last_blocker` latch (`null` here), so it never engaged. Explains why an existing recovery path missed this soft loop. |
| RFC-0271 in-turn-recovery-accept-rejected | Draft (§4.1 landed) | Confirms empty responses are typed `Accept_rejected{Accept_no_usable_progress}`, the signal Gap D1 arms failover with; disclaims health failover (defers to 0207B/0260). |
| RFC-0315 wake-turn-self-description | Draft (Goal_stagnation impl) | The only stagnation wake is goal-scoped and requires an Executing-phase goal; `active_goal_ids=[]` here. Gap D2 is the non-goal, successful-turn detector 0315 does not cover. |
| RFC-0326 keeper-failure-typed-classification | present in tree | Types keeper *failures*; Gap D2 is stagnation over *successful* turns (a distinct axis). Align the `No_effect`/`Progress` sum with 0326's failure taxonomy where they meet. |
| RFC-0246 wake-cascade-recovery-tombstone | Draft | Recovery/tombstone for stuck wake cascades; does not cover successful-turn semantic stagnation. |
| RFC-0126 silent-fallback-discipline | Implemented | The fail-closed requirement Gap D1 honors: an exhausted failover chain is an explicit typed error, never a silent local-model default. |
| RFC-0312 keeper-repo-mapping-advisory-scope | Accepted | Primary refutation of the keeper's model (advisory toml, no `execute` field, mapping discarded). Cited in §1. |

---

## 9. Open questions

- Gap C: the authoritative `tool_use_count` read site at `append_memory_notes_from_reply` — confirm it is available at the producer boundary without a new plumb-through, and the exact non-external-progress tool set to exclude from `Grounded` (`keeper_memory_write` at minimum).
- Gap C: the `valid_until` TTL length for a consolidated `Self_observation` narrative and its producer-tag key; the purge pass cadence (per consolidation vs per (re)start vs both).
- Gap D2: the window size N default and the structural-signature equivalence definition for `No_effect` (which effect fields enter the digest).
- Gap D1: interaction with RFC-0211's per-turn read and the boot-cache — the persisted `assignment_change` must be the SSOT the resolution consults, not a shadow store, and must survive without a server restart.
- Sequencing: land Gap C (closes the perseveration engine's memory half) and Gap D1 (re-pin health-gated) first; Gap D2 (stagnation FSM) second. Confirm no ordering hazard where D1 re-pins before D2 exists (acceptable: D1 stops the empty-response starvation; D2 is the backstop).

---

## 10. Immediate remediation (incident, already applied 2026-07-08)

The following was applied manually on 2026-07-08 to stop the live loop; it is the manual form of the mechanisms this RFC makes systemic. Backups: `*.bak-*-20260708-2010`.

1. Re-pinned `runtime.toml:505` `mad-improver` off the dead `runpod_mtp.qwen36-35b-a3b-mtp` to `runpod_rtxa6000.gemma4-coder-fable5-q4km` (the healthy endpoint `issue_king` already uses). Takes effect on the next masc server restart (the assignment is boot-cached; see §5). This is the manual form of Gap D1.
2. Purged the poisoned memory: `mad-improver.memory.jsonl` reduced from 60 rows to 13 grounded rows by evicting every `source=progress_consolidation` residue note. This is the manual form of Gap C §4.2.
3. Did not edit `keeper_repo_mappings.toml` (a provable no-op that would validate the false model).
4. Cleared the stale `last_blocker` (`capacity_backpressure` on the dead provider) and reset the noop counters; restarted the keeper (`masc_keeper_down`/`keeper_up`) so it reloaded clean memory.

Re-pin + purge stop the perseveration loop, but the keeper still cannot run shell Execute until RFC-0329 (Gaps A/B) lands — that is expected fail-closed behavior, not a regression. Until the next server restart, `mad-improver` remains routed to the dead provider and stays quiet (erroring, not broadcasting) because its memory is now clean.
