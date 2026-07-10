---
rfc: "0239"
title: "Semantic-identity guards for keeper memory and anti-thrash"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent (drafted by Claude Opus 4.8)
supersedes: ["0238"]
superseded_by: null
related: ["0231", "0228", "0144", "0152", "0113", "0042", "0230", "0225", "0126", "0145", "0077"]
implementation_prs: []
---

# RFC-0239: Semantic-identity guards for keeper memory and anti-thrash

Status: Draft · Supersedes RFC-0238 (closed, #21186) · Drafted 2026-06-15 from a ground-truth audit of the 7-keeper "Confidence Inversion" board thrash.

## §0 TL;DR

A cluster of 7 keepers (garnet, sangsu, analyst, taskmaster, ramarama, executor, rondo)
looped 30+ turns each re-posting the same conclusion ("Confidence Inversion proven,
차기작 structurally complete, operator's turn, I'll stay quiet"). The keepers diagnosed
the loop as a **Memory OS "Confidence Inversion"** and proposed scoring-tweak PRs
(#21177, #21183, #21175, #21179, #21192).

A code + GitHub + live-store audit shows the keeper self-diagnosis is **wrong about the
root and wrong about its own status claims**:

- The loop's engine is a **cross-keeper wake cascade with no working termination**, not a
  memory bug. The `stay_silent` loop detector that should pause them keys on the literal
  `speech_act="stay_silent"` token, but the keepers *post* their "I'll stay quiet" message
  (a `Post_board` act), which **resets the silence streak every cycle** — the detector can
  never fire (`keeper_no_progress_loop_detector.ml:48,66-74`).
- Memory OS is a real **amplifier** (immortal, append-only facts re-inject the conclusion)
  but not the root: if the wake cascade stopped, the loop dies.
- The keepers' status claims are mostly fabricated/stale: "5 PRs blocked only by operator
  `--admin`" → actually 6 OPEN-but-`mergeable=UNKNOWN`, 3 already MERGED, 2 CLOSED;
  "~1,800 lines of fix on origin" → actually 32+57+0 = **89 lines** (one branch is a no-op).

Every one of these defects shares **one root**: *guards key on a surface token instead of
semantic identity*, so a semantically-identical event (a reworded post, a new `post_id`, a
non-literal speech act, an unchanged claim) evades every dedup / expiry / debounce /
termination check in the system. This RFC fixes the five guards that share that flaw.

### Implementation status (this branch)

| Root | State | Reference |
|---|---|---|
| R3 no-progress loop detector | **Implemented + tested** | `keeper_no_progress_loop_detector`, commit `R3` |
| R4 wake content-fingerprint debounce | **Implemented + tested** | `keeper_keepalive_signal` / `keeper_registry`, commit `R4` |
| R2 recall-time claim dedup | **Implemented + tested** | `keeper_memory_os_recall`, commit `R2` |
| Retention sweep (supersedes RFC-0238) | **Implemented + tested** | `keeper_memory_os_io.cap_facts`, Q4 commit |
| R1 per-fact lifetime at write | **Closed — subsumed** | Q5: drop per-fact TTL (avoids the category string-classifier); store bounding is handled by the retention sweep |
| R0 wire inert recall signals | **Closed — subsumed** | Q3: naive `bump_access_for_turn` wiring *worsens* the inversion (frequently-recalled stale facts would score higher); R2 dedup + the retention cap cover the in-session symptom. Revisit only if measurement still shows inversion |

R3 + R4 are the loop engine: together they stop the cross-keeper thrash (R3 pauses a
keeper after a threshold of no-progress turns; R4 stops identical re-posts re-waking peers).
R2 stops duplicate conclusions crowding recall, and the retention sweep bounds the
append-only store to `fact_recall_window` (256) facts per keeper by score. R0 and R1 are
closed as subsumed: per the Q3/Q5 ratification, the right write-side fix is one deterministic
bounding sweep, not per-fact TTLs (an LLM-trust / string-classifier hazard) or an access
boost (which would re-amplify the inversion).

## §1 Problem (with live evidence)

### 1.1 The observable

The board (`reports/memory-systems-comparison-2026-06-15.html` triggered the audit) shows
the 7-keeper cluster repeating a single conclusion across 30+ turns, with each "I'll be
quiet now" post immediately followed by another. The keepers themselves named the pattern
"P(stale_fact_outranks_correct_fact) = 1.00" and attributed it to the Memory OS.

### 1.2 Live store measurement (2026-06-15, `/Users/dancer/me/.masc/config/keepers/`)

17,426 facts across the 7 loop keepers (ramarama alone: 6,077 facts / 2.08 MB):

| Metric | Measured | What it proves |
|---|---|---|
| `valid_until` is `None`/absent | **17,426 / 17,426 = 100.0%** | The only expiry signal fires on **0%** of facts. Every fact is immortal. |
| confidence distribution | mean 0.928, median 0.95, stdev 0.0625; **0.95=37.1%, 0.90=22.5%, 1.00=14.6%, 0.99=7.8%** (top-4 = 82%) | "Gradient collapse" is real: 6 rounded LLM values dominate; 6,471 facts tie at exactly 0.95. |
| duplicate claims (first 90 chars) | **8.2%**; most-duplicated are the loop conclusions: `"executor is offline due to an operator issue"` ×14, `"...next idle turn **would** end the session"` ×13 **and** `"...**will** end the session"` ×13 | No dedup; reworded variants ("would"/"will") coexist as distinct immortal facts. |
| total facts / keeper | unbounded append-only growth (367 → 6,077) | No GC; the store only grows. |

The reworded-duplicate pair (`would` vs `will`) is the surface-token-bypass thesis made
visible in data: two byte-different strings carrying one meaning both persist forever.

### 1.3 Two layers, one root

- **Layer A — coordination (the engine):** the wake cascade + the loop detector blind spot.
  This is what keeps cycles *firing*.
- **Layer B — memory (the fuel):** immortal, undeduplicated, score-collapsed facts that keep
  *re-emitting* the same conclusion into each keeper's prompt.

Neither alone explains the loop; both are instances of the same root (§2).

## §2 Root cause: guards key on surface tokens, not semantic identity

Every termination/dedup/expiry guard in the path observes the wrong thing:

| # | Guard | Keys on (surface) | Should key on (semantic) | Bypass observed | Cite |
|---|---|---|---|---|---|
| R1 | fact expiry | `valid_until` written `None` always | a TTL/lifetime set at write | 100% immortal (§1.2) | `keeper_librarian.ml:141-144` |
| R2 | fact store write | append-only, no compare | claim fingerprint | 8.2% dup, reworded twins (§1.2) | `keeper_memory_os_io.ml:125-127` |
| R3 | thrash detector | `speech_act="stay_silent"` literal | no-progress (no new tool evidence + near-dup body) | streak resets on every `Post_board` (§3) | `keeper_no_progress_loop_detector.ml:48,66-74` |
| R4 | wake debounce | `post_id` (60 s) | `(keeper, content fingerprint)` | each cycle mints a new `post_id` | `keeper_registry.ml:402-412`, `keeper_keepalive_signal.ml:229` |
| R5 | board write dedup | exact body bytes | normalized/near-dup body | reworded re-posts pass | `board_core_persist.ml:426-457` |

Background amplifier (not a guard, but feeds R1/R2): the recall score collapses within a
session. `score_fact = confidence × exp(−λ·Δt) × (1+access_count)^0.5`
(`keeper_memory_os_policy.ml:26-28`), where:

- `λ = 1/(86400·7)` (7-day e-folding) → within a minutes-to-hours keeper session,
  `exp(−λ·Δt) ≈ 1.0` for every fact;
- `access_count` is only incremented by `bump_access_for_turn`, which is **referenced solely
  by `test/test_keeper_memory_os.ml`** — never wired in `lib/` or `bin/`
  (`keeper_memory_os_policy.ml:65-84`). Production `access_count` stays 0 → `access_factor ≡ 1.0`.

So in production the score degrades to `≈ confidence`, an LLM-rounded near-uniform value
(§1.2) with no power to rank a true fact above a stale-false one. This is the mechanism the
keepers called "gradient collapse" — it is an **inert-signal** problem, not a confidence-mutation
problem.

## §3 Why the existing detector cannot fire (the single most important defect)

`keeper_no_progress_loop_detector.ml` bumps a streak **only** when `speech_act = "stay_silent"`
(line 48) and **resets the streak to 0 on any other speech act** (lines 66-74).
`speech_act` is an eight-variant legacy type from the retired personality-state path, in which `Stay_silent`
is distinct from `Post_board`/`Comment_board`/`Broadcast`/`Inform`.

A keeper that *announces* "I'll stay quiet" by **posting it** emits `Post_board` — which
resets the streak. The keepers talk about being silent without ever emitting the silent act
the detector counts. `default_threshold = 10` is therefore unreachable for this cluster.

The wake side is genuinely cross-keeper (self-wake is excluded,
`keeper_world_observation_board_signal.ml:80`): one keeper's post fans out via Stigmergy
goal-keyword overlap (`+5` per shared keyword, wakes if score `> 0`,
`keeper_world_observation_board_signal.ml:152-171`; `keeper_keepalive_signal.ml:363-417`).
The 7 keepers share goal keywords, so each post re-wakes the other 6 — which is exactly why
this specific cluster of 7 thrashes together.

## §4 Principles

1. **Parse, don't validate (Alexis King).** A guard must compare the *parsed meaning*
   (claim fingerprint, no-progress predicate, content hash) — never a raw surface token that
   a reworded duplicate can dodge.
2. **No escape hatch / no permissive default.** Expiry, dedup, and retention policies are
   closed sums with exhaustive `match`; no `unknown ⇒ keep-forever` arm
   (continues RFC-0042, RFC-0126, RFC-0145).
3. **Termination is a safety property, not a heuristic.** "A keeper that adds no new
   tool evidence and repeats a recent post is making no progress" must be *decidable and
   enforced*, with a TLA+ invariant (§6).
4. **Harness-first.** §1.2 live measurements are the regression baseline; no fix merges
   without a test that would fail against today's store.
5. **Reuse the substrate.** RFC-0238 already designed a typed retention policy over
   `Dated_jsonl`; this RFC absorbs it rather than reinventing GC.

## §5 The four roots + design

### R1 — Set a real lifetime at write (memory write side)

`fact_of_json` hardcodes `valid_until = None` (`keeper_librarian.ml:144`). The librarian
already emits a `category`; extend the librarian contract so each fact carries an
**expected lifetime** chosen by category (e.g. an ephemeral "session status" fact expires in
hours; a durable "user preference" fact may have no TTL). Store it as a typed
`lifetime : Ephemeral of { ttl_seconds } | Durable | Until of timestamp` rather than a bare
`float option`, so "no lifetime" is an explicit, auditable choice — not the silent default.

This is the RFC-0238 `Capped_by_score` / forgetting-curve idea applied at *write* time
instead of only at sweep time.

### R2 — Dedup/merge on claim fingerprint (memory write side)

`append_fact` (`keeper_memory_os_io.ml:125-127`) is pure append. Before appending, compute a
normalized fingerprint of the claim (case-fold, collapse whitespace, strip trailing
punctuation — enough to fold "would"/"will" twins is a non-goal; see §8 Q2 for how
aggressive). On fingerprint match within the tail window, **bump the existing fact's
`access_count` and `last_accessed`** (the adaptive signal that R0 wires on) instead of
writing a new immortal row. This is the legitimate use of the `bump_access_for_turn` code
that today is test-only.

Precedent and discipline: RFC-0144 (workaround-sunset for keeper dedup) — this dedup is a
*root* fix (it stops the producer of duplicates), not a symptom-suppressing dedup arm, so it
is in-scope to add, not to sunset.

### R3 — Make the no-progress detector semantic (coordination — highest leverage)

Extend `keeper_no_progress_loop_detector` (or the turn classifier feeding it) so a turn
counts toward the loop streak when it is **no-progress**, defined as:

```
delivery_surface ∈ {Board_post, Board_comment, Broadcast}
  AND has_substantive_tool_calls = false
  AND body is a near-duplicate of a recent self-authored post
```

i.e. a keeper that only re-posts its conclusion accrues the streak and gets paused at the
threshold — regardless of whether the literal speech act is `Stay_silent`. The detector's
observable changes from "did it emit the silent token" to "did it make progress".

Pause path must auto-resume per RFC-0152 (avoid creating another `Manual_resume_required`
dead-end); use `Auto_resume_with_backoff` so a genuine new signal re-activates the keeper.

### R4 — Wake cooldown on content fingerprint (coordination)

`board_wakeup_allowed` debounces per `(keeper, post_id)` for 60 s
(`keeper_registry.ml:402-412`). Re-key the cooldown on `(keeper, content_fingerprint)` so a
keeper is not re-woken by a peer post that is semantically identical to one it already
reacted to, even with a fresh `post_id`. Optionally fold R5 (board write dedup) onto the
same fingerprint so reworded re-posts are rejected at write time.

### R0 — (prerequisite) wire the inert recall signals

Wire `bump_access_for_turn` into the recall/turn path (it is currently test-only) so
`access_count`/`last_accessed` actually move, OR re-tune `λ` to a session-relevant
timescale. Without this the score stays `≈ confidence` and even correct R1/R2 facts cannot
out-rank stale ones inside a session. (Design choice in §8 Q3.)

### Retention / GC (supersedes RFC-0238)

Adopt RFC-0238's typed policy verbatim as the sweep layer:
`Dated_prune{keep_days} | Capped_by_score{max_items; half_life_days} | Compact_event_log{keep_after_days}`,
exhaustive match, registered + swept on boot + daily heartbeat (never on hot path). The live
17,426-fact stores (§1.2) are the Phase-1 target for `Capped_by_score`. RFC-0238 was closed
on a contested premise (it claimed `decisions.jsonl` = 1.4 G as the grower; that figure is
itself disputed as a directory-total misattribution — re-measure per store-type before
wiring, per the 2026-06-15 measurement-discipline note).

## §6 Workaround absorption (per RFC-0144 §"누적 메커니즘")

The keeper-authored PRs are **scoring tweaks on the recall ranking** — the
cap/cooldown/repair symptom-suppression class. Under the CLAUDE.md Workaround Rejection Bar
they must be absorbed or rejected, not merged as precedent:

| PR | What it adds | Verdict | Disposition |
|---|---|---|---|
| #21177 `inverse_recency_factor` | reweight recall by recency | Symptom (re-ranks; doesn't stop immortal dup production) | Absorb into R0/R1; close as standalone |
| #21183 `stale_factor` (Phase3/3d/4.5) | penalize stale facts in score | Symptom (penalizes after the fact exists forever) | Absorb into R1 (set lifetime at write); close |
| #21175 `phase3a-inverse-recency-bonus` (+32 LOC) | recall bonus | Symptom | Absorb into R0; close |
| #21179 Phase5+ GC (task-1169) | GC module | Root-adjacent | Fold into §5 Retention (RFC-0238 policy); keep author, retarget |
| #21192 Phase6 episode TTL (`valid_until`+`terminal_marker`) | episode-level TTL | Right idea, wrong layer | Absorb into R1 — fact `valid_until` is written `None` first; fix the writer before adding more TTL fields |

None of these touch R3/R4 (the actual loop engine). Merging all five leaves the 7-keeper
thrash intact. They are catalogued here so the work is not lost, but they do not ship as-is.

## §7 Verification plan

1. **Live baseline (regression target).** Re-run the §1.2 measurement script; assert
   post-fix: `valid_until`-None ratio < 100% on new facts; dup ratio strictly decreasing on
   a replayed turn stream; per-keeper fact count bounded under `Capped_by_score`.
2. **R3 unit (the load-bearing one).** Simulate a keeper emitting N consecutive
   no-progress `Post_board` turns with near-duplicate bodies and zero substantive tool
   calls; assert the loop detector pauses it by turn `threshold`. Today this test FAILS
   (streak resets), which is the proof the fix is real.
3. **R2 unit.** Append the same claim twice (and a reworded twin per the §8 Q2 policy);
   assert one stored row with bumped `access_count`, not two immortal rows.
4. **R1 unit.** Librarian-extract an ephemeral-category fact; assert a non-`None`
   `valid_until`; assert `fact_is_current` drops it after TTL.
5. **TLA+ termination invariant (per masc TLA+ bug-model convention).** Model the wake
   cascade; `BugAction` = "no-progress post resets streak"; `SafetyInvariant`
   `NoUnboundedNoProgressLoop` = a keeper cannot emit > K consecutive no-progress posts
   without a pause. Clean spec passes; `Next ∨ BugAction` must violate the invariant.
6. **Exhaustiveness.** Retention policy and `lifetime` sums compile only with all arms
   (no catch-all), per RFC-0042.
7. Build green (`dune build .` and `@check`; note `@check` alone misses expression-level
   type errors — run the default target too).

## §8 Scope and non-goals

In scope: R1–R4 + R0 wiring + the RFC-0238 retention sweep. Out of scope: embedding-based
recall (the deterministic/offline property is intentional), cross-keeper shared fact
namespace (the 456-paradox — separate RFC), and any change to credential/identity/sandbox
surfaces.

## §9 Open questions (ratification needed)

1. **Q1 — R3 placement.** *Resolved: detector layer.* `speech_act` is social intent, not
   progress; the no-progress predicate (`turn_made_progress`) lives in the detector and the
   caller maps `delivery_surface` (exhaustive) to it. Keeping it out of the classifier avoids
   re-coupling the two concepts.
2. **Q2 — dedup aggressiveness (R2).** *Resolved: normalized-conservative.* Implemented as
   lowercase + whitespace-collapse fingerprint at recall time (folds case/spacing twins; does
   not fold genuinely different wordings like "would"/"will" — those still collapse only if a
   future write-side dedup normalizes further).
3. **Q3 — R0 (open).** Wiring `bump_access_for_turn` as-is *worsens* the inversion: it raises
   the score of frequently-recalled facts, and stale conclusions are the most-recalled. R0
   needs a signal that *lowers* a fact that keeps being recalled but never re-validated
   (e.g. decay on recall-without-write, or contradiction tracking), not a naive access boost.
   Alternatively re-tune `λ` to session scale (fixes in-session ranking but flattens the
   7-day cross-session curve). Decision required before any code.
4. **Q4 — retention defaults (inherited from RFC-0238, open).** `Capped_by_score` `max_items`
   per keeper and `half_life_days`; legacy handling for the existing 17,426 facts
   (archive-and-restart vs fold-into-partitions). Re-measure store size per type first
   (RFC-0238's 1.4 G `decisions.jsonl` premise is disputed).
5. **Q5 — R1 lifetime determination (open).** How is a fact's lifetime assigned without a
   string classifier on the free-text `category` (forbidden by §2 principle 1)? Options:
   (a) a typed category taxonomy (closed sum) with a lifetime per variant; (b) extend the
   librarian JSON contract so the LLM emits an explicit `ttl_seconds`/`lifetime`, validated
   like `confidence`, with an eval harness; (c) drop per-fact TTL entirely and bound the
   store only by the Q4 retention sweep. Decision required before any code.

## §10 Evidence record

- Code audit (file:line as cited) — verified on `jeong-sik/masc` HEAD `915c94584`, 2026-06-15.
- Live store — `/Users/dancer/me/.masc/config/keepers/*.facts.jsonl`, 2026-06-15
  (17,426 facts; 100% `valid_until`-None; conf top-4 = 82%; dup 8.2%).
- PR/branch ground truth — `gh`/`git ls-remote` on `jeong-sik/masc`, 2026-06-15
  (#21174/#21189/#21190 MERGED; #21186/#21188 CLOSED; #21175/#21177/#21179/#21183/#21187/#21192
  OPEN-`mergeable=UNKNOWN`; named fix branches diff = 32+57+0 LOC).
- Supersedes RFC-0238 (closed #21186). Workaround discipline per RFC-0144 and
  CLAUDE.md §"워크어라운드 거부 기준".

RFC-WAIVED: this is a design document (no credential/identity/sandbox/hooks code change);
the keeper coordination + memory-os surfaces it touches are governed by this RFC itself.
