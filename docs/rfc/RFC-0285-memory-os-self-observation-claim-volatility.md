# RFC-0285: Memory OS — Self-Observation Claim Volatility (closing RFC-0259's internal-state gap)

**Status**: Draft
**Date**: 2026-06-23
**Supersession note (2026-06-25)**: The external-ref side of RFC-0259 is no longer
active policy. This RFC's self-observation `claim_kind` handling remains relevant,
but comparisons to external-ref parsing/GitHub grounding are historical context.
**Renumbered from 0283/0284**: 0283 taken by `RFC-0283-fusion-judge-of-judges.md` (#22093, merged); 0284 contended by `RFC-0284-keeper-guidance-visibility-drift-guard.md` (#22121, open). Moved to 0285 to separate at the filename level. See PR review thread.
**Verified against base main**: `08c4ccd50d`
**Builds on**: [RFC-0259](./RFC-0259-memory-os-volatile-claim-grounding-retraction-decay.md) (volatile external claim grounding/retraction/decay — this RFC is its internal-state symmetric pair), [RFC-0247](./RFC-0247-memory-os-associative-graph-forgetting-brain.md) ("a fact's value is the librarian's judgment, not a number"; exhaustive classification), [RFC-0244](./RFC-0244-memory-os-recall-turn-seeded-lexical-retrieval.md) (Tier-2 shared store / promotability)
**Related**: [RFC-0276](./RFC-0276-purge-keeper-social-model-self-report-protocol.md) (social model purge left fact-store residue)

## 1. Summary

A keeper that is idle or blocked emits **self-observation claims** about its own transient state — "the agent experienced a persistent execution loop", "the Write tool is experiencing approval timeouts", "no unclaimed tasks were available". The librarian classifies these into durable categories (`Lesson`/`Blocker`/`Constraint`/`Validated_approach`), so they persist with `valid_until = None` (durable, immortal). Recall re-injects every durable fact every turn (`keeper_memory_os_recall.ml:256` filters only on `fact_is_current`, which returns `true` for `valid_until = None`), so the keeper re-reads its own past self-narrative and re-confirms it — a **self-fulfilling echo loop**. Some self-observations are classified `Lesson`, which is `is_promotable` (`keeper_memory_os_types.ml:88`), so the self-narrative also leaks fleet-wide.

RFC-0259 closed the **external-state** durable gap (a `Fact` naming `PR #X` is volatile, never durable). This RFC closes the symmetric **internal-state** gap: a claim naming the keeper's own transient state is volatile by the same right ("yesterday idle ≠ today idle"). The fix moves classification to a **typed marker emitted at the producer (librarian) write boundary** — `claim_kind` — parallel to `external_ref`, and explicitly rejects a read-time string classifier (the workaround this RFC's first draft itself fell into; see §6).

The boundary stays where RFC-0247/0259 put it — **judgment = LLM, structure = deterministic** — with one honesty the design states up front: a self-observation has **no external verification oracle** (unlike a PR id checkable against GitHub), so its decay is a blind TTL backstop, not a grounded reconcile. The load-bearing layers are at the producer (typed tag + stable id), not the decay.

## 2. Problem (first-hand evidence)

Reproduced against the live store at `<base-path>/.masc` (canonical runtime root resolved from `MASC_BASE_PATH`, not the home-anchored form) (2026-06-23):

| source | category | valid_until | claim |
|--------|----------|-------------|-------|
| executor episode g0268 | `blocker` | None (durable) | "The Write tool is experiencing persistent approval timeouts" |
| executor episode g0268 | `constraint` | None (durable) | "The sandbox root environment blocks git usage" |
| **idealist episode g0170** | **`lesson`** | None (durable) | **"The agent experienced a persistent execution loop, repeatedly invoking keeper..."** |
| idealist episode g0170 | `validated_approach` | None (durable) | "The agent determined the correct action when facing a structural block" |

- `recall_injections/2026-06/{19..23}.jsonl`: self-observation facts (`id:agent-loop-avoidance`, `claim:the agent entered an idle state because no unclaimed tasks were available`) re-injected deterministically every turn.
- albini trace-1781224572742: `claim:removing social_model fields ... breaks the bdi speech model loop` re-injected **101×**, `id:pr-22065-fix-bdi-loop` **117×**, over 200 turns / ~5 hours.

The exact mechanism, traced to source:

1. **Recall's gate passes durable unconditionally.** `fact_is_current` returns `true` whenever `valid_until = None`:
   ```ocaml
   (* keeper_memory_os_types.ml:274-277 *)
   let fact_is_current ~now (fact : fact) =
     match fact.valid_until with
     | None -> true
     | Some ts -> ts >= now
   ```
   Recall filters on exactly this (`keeper_memory_os_recall.ml:256`, `|> List.filter (fact_is_current ~now)`). A durable fact is re-injected forever (`keeper_memory_os_recall.ml:103` "durable knowledge does not decay").

2. **Self-observation is classified durable.** `category_valid_until` gives a finite TTL **only to `Ephemeral`** (`keeper_memory_os_types.ml:209-221`); `Lesson | Blocker | Constraint | Validated_approach | Fact` → `None`. The librarian mints self-narrative into these (§2 table).

3. **External-ref volatility does not solve it.** Current production code does not infer operational volatility from PR/issue/task prose. Self-observation needs its own typed producer marker (`claim_kind = Self_observation`) and finite horizon; it cannot be rescued by an external-id path.

4. **The librarian re-extracts the self-narrative every compaction.** Decaying one row is moot if the next compaction re-mints the same claim from the same source — the 117× re-injection above is this loop. Storage decay alone is a downstream symptom-suppressant; the root is at the producer.

## 3. Design — defense in depth

> Layer-priority note (corrected from this RFC's first draft after a direct source trace, 2026-06-23). The draft and an initial audit treated anchor inheritance as load-bearing on the assumption that re-mint resets the horizon. It does not: `reobserve_fact` (`keeper_memory_os_policy.ml:53-70`) preserves `existing.valid_until` in **both** branches (`Some _` returns `existing` whole; `None` returns `{existing with last_verified_at = Some now}`). The real moot path is **APPEND**: `merge_episode_facts` (`keeper_memory_os_io.ml:597-606`) appends a fresh-horizon row whenever `claim_identity` misses. So the load-bearing layers are **L1 (producer: typed tag + stable claim_id)** and **L3 (finite horizon at first mint)**; the `reobserve_fact` change (L2) is a minor cap-rank refinement.

Add a structured field `claim_kind` to `fact`, parallel to `external_ref`, orthogonal to `category` (a `Lesson` can be a self-observation). Classify at the **producer boundary, parse-once** — the same place `category` is already parsed — not by a read-time string match.

### 3.1 Type (closed sum, no silent escape)

`keeper_memory_os_types.ml` (near the `category` definition, ~line 50):
```ocaml
type claim_kind =
  | Self_observation   (* transient first-person agent state: idle, looping, tool-timeout *)
  | External_state     (* about the world/PR/issue; verifiable elsewhere *)
  | Durable_knowledge  (* timeless rule / lesson independent of transient state *)
```
`type fact` (`keeper_memory_os_types.ml:247`) gains `claim_kind : claim_kind option`, parallel to `external_ref`, omitted from JSON when `None` (legacy rows stay byte-identical — RFC-0259 schema-stability). An `Unknown of string` escape is added only if a JSON round-trip drift-guard requires it, and if added it routes to **durable** (pre-RFC status quo), never to volatile, pinned by a test.

### 3.2 L1 — producer mint boundary (the real root: tag + stable id)

L1 emits two things at the librarian write boundary; (a) drives L3's horizon, (b) routes a re-mint to merge instead of append.

**(a) `claim_kind` tag.** Add an optional field to the LLM JSON schema (`keeper_librarian_runtime.ml:301`):
```json
"claim_kind": "self_observation|external_state|durable_knowledge"
```
and a system-prompt instruction: *do not emit transient first-person self-state as a durable claim; tag it `self_observation`.* Parse it beside `category` in `fact_of_json` (`keeper_librarian.ml:202`, next to `category_of_string` at `:224`); absent/legacy → `None`.

**(b) Stable `claim_id` (load-bearing).** Self-observation claims must carry a **conclusion-keyed stable `claim_id`** (e.g. the same idle-loop observation always emits `self-obs:idle-loop`). Rationale: `merge_episode_facts` (`keeper_memory_os_io.ml:597-606`) appends when `claim_identity` (`keeper_memory_os_types.ml:485`: `"id:"^slug` when a `claim_id` is present, else `"claim:"^normalize_claim` — exact text, whitespace/case only) misses. A reworded re-extraction ("is looping" → "has been looping") yields a different `normalize_claim` key → append → fresh-horizon duplicate row → re-injected forever (moot). With a stable `claim_id`, the existing RFC-0259 §3.7 P6/F machinery (`keeper_memory_os_types.ml:472-484`, "a reworded re-extraction of the same conclusion reuses the id and UPSERTs ... inherits its first_seen anchor") applies unchanged to self-observation. Deriving the id in code is forbidden (`keeper_librarian.ml:215` rejects it as "the string-classifier workaround"); only the librarian emits it. Self-observation decay reliability is therefore bounded by the librarian's `claim_id` consistency (§7, High).

### 3.3 L2 — reobserve routing (minor: cap-rank consistency)

In `reobserve_fact` (`keeper_memory_os_policy.ml:53-70`), route `claim_kind = Some Self_observation` to the inherit branch (return `existing` whole) like `external_ref = Some`. This is **not** load-bearing: the `None` branch already preserves `valid_until`, so hard expiry works either way. The reason to inherit is to avoid advancing `last_verified_at`, which would raise `reference_time` → `retention_rank` (`keeper_memory_os_policy.ml:36`) and make the cap keep a self-observation as "recently verified" — the opposite of the goal. Expiry itself is guaranteed by L3.

### 3.4 L3 — storage decay (load-bearing: finite horizon at first mint)

In `fact_valid_until` (`keeper_memory_os_types.ml:235`), add a `claim_kind` arm:
```ocaml
| Some Self_observation -> Some (now +. self_observation_ttl_seconds)
```
`fact_is_current` / `partition_expired` then drop expired rows automatically. The horizon is a **separate constant** (`self_observation_ttl_seconds`), intentionally shorter than the ordinary Ephemeral/category TTL so first-person self-state quiets faster. Not so short that a legitimate short-lived self-state ("waiting on this block") vanishes within the same turn — tune in cycles.

### 3.5 Promotability block

`is_promotable` (`keeper_memory_os_types.ml:88-91`) is category-keyed and **exhaustive** (RFC-0247 §2.5: a new durable category must be classified at compile time). Do **not** widen its signature to take `claim_kind` and break that contract. Instead, gate at the **consolidator / Tier-2 promotion call site**: exclude `claim_kind = Self_observation` before promotion, asserted by a test. Self-narrative is keeper-local.

## 4. Verification

- **Unit**: `fact_of_json` parses each `claim_kind` string → correct variant; absent → `None`. `fact_valid_until` gives `Self_observation` a finite horizon regardless of `category`. The promotion call site drops `Self_observation`.
- **Property**: a `Self_observation` fact is `fact_is_current = false` once `now > valid_until` (recall drop); a `Durable_knowledge` `Lesson` keeps `valid_until = None` and survives. **Re-mint property (load-bearing)**: minting the same `claim_id` twice as `Self_observation` does NOT extend the horizon past the original anchor + N·cycle — proves the merge path (not append) and anchor inheritance hold.
- **TLA** (reuse RFC-0259's spec-mutation pattern): bug action `SelfObservationRemintResetsHorizon` (re-mint refreshes the anchor) must violate invariant `SelfObservationDecaysWithinHorizonDespiteRemint`; clean `Next` (anchor-inheriting reobserve) satisfies it. Both `.cfg` and `-buggy.cfg` must pass-as-specified.
- **Regression fixture**: idealist `[lesson] "experienced a persistent execution loop"` tagged `self_observation` → finite horizon + non-promotable.

## 5. Non-goals

- Cleaning up existing residue (stale `[SYNTHETIC]` progress.md, durable self-observation rows already on disk) is separate operational work. The code fix only changes newly minted claims; a legacy durable row (`valid_until = None`) is inherited whole by `reobserve_fact` and stays durable until the cleanup. See §7.
- The continuity / forward-looking summary channel (`keeper_memory_policy_summary_filter.ml`) is text-based and does NOT honor `valid_until`. It carries prose, not fact rows, so it is not a fact re-injection vector — but if self-narrative leaks into that prose, decay won't touch it. Separate concern.
- Anti-thrash `User_facing` exemption (`keeper_unified_turn_success.ml`) is a separate RFC.
- `[STATE]` prose-block ceremony (typed continuity schema) is a separate concern.

## 6. Rejected first draft (workaround-signature avoidance)

The first draft proposed `self_observation_horizon_of_claim : claim -> bool`, a read-time free-text tense/modal classifier ("is experiencing", "entered idle state"). That is workaround signature #2 in the project's rejection bar (a string/substring classifier where a typed variant is possible):

- **No closed token set, no verifier.** Natural-language tense/modality is unbounded and locale/model-phrasing dependent. "the agent has been looping" or a non-English claim silently falls to the durable path; new phrasings accrete by hand-editing the matcher (the accretion spiral the rule warns about). `external_ref` is *not* this pattern even though it also reads the claim string: it extracts a **structured token** (PR id) with a typed referent and an **objective verifier** (GitHub) — parse-don't-validate. The self-obs classifier has neither.
- **Self-defeating by its own conservative design.** The draft set the matcher to under-match ("bar high"), which guarantees that every phrasing the regex misses stays `None` → durable → re-injected forever. It would silently no-op on exactly the cases it exists to catch.
- **Correction.** Move classification to the write-time typed `claim_kind` (§3.1–3.2). This is still an LLM judgment, but captured once at the live-context boundary into a closed type — the same trust model as `category` and `claim_id` already on the row — not re-derived every recall from frozen wording. RFC-0259 §6's own argument ("the LLM only sees stale history") cuts *for* the mint-time tag and *against* the read-time classifier: at mint time the librarian is summarizing the live turn, not re-reading stale history.

## 7. Open questions

- **(High)** `claim_kind` accuracy and `claim_id` stability depend on the librarian LLM (non-deterministic). Mitigation: closed type + default-to-durable means a **missed tag degrades to pre-RFC status quo (safe)**, never to wrong-volatile. There is **no deterministic oracle** for "is this self-observation still true" (unlike `external_ref` → GitHub), so L3 decay is a blind TTL, not a grounded reconcile. Accept this; do not pretend a reconciler exists.
- **(Medium) Post-expiry re-append oscillation.** After a row expires and drops, if the librarian re-extracts the same self-observation from a stale source (progress.md/transcript), it re-appends with a fresh horizon → "present for one horizon, expires, re-extracted, present again". Ending the steady state depends on L1(a) reducing re-extraction at source. The fix breaks the every-turn re-injection (227/200 turns) but may not drive oscillation to zero; a shorter `self_observation_ttl` shrinks each window.
- **(Medium) L2 × `claim_id` UPSERT composition** — *resolved by 2026-06-23 grounding* (see §3 note): `reobserve_fact` never resets `valid_until`; the moot path is append on `claim_identity` miss, handled by L1(b). The re-mint property test (§4) is the focused check to keep before merge.
- **(Low) Horizon length**: set `self_observation_ttl_seconds` shorter than 86_400, or equal? Shorter quiets the echo faster but risks dropping a legitimate short-lived self-state.
- **(Low) Legacy durable rows**: the code fix does not retrofit a horizon onto existing `valid_until = None` self-observation rows (reobserve inherits `existing` whole). Removal is via the §5 cleanup only. Alternative: have reobserve take `min(existing, incoming) valid_until` to self-heal legacy rows — but that complicates the "inherit anchor, no reset" invariant. Pure-inherit is recommended (cleanup is already separate).
- **(Low) `Unknown of string` escape on `claim_kind`**: add only if a round-trip drift-guard requires it; if added, pin to durable routing by test.

## 8. Addendum (2026-07-07): echo anchor suppression — closing §7's mistag gap structurally

**Status**: implemented alongside this addendum (task-1857).

§7 (High) accepted that a librarian mistag "degrades to pre-RFC status quo (safe)".
Keeper albini falsified the "safe" half: the librarian *affirmatively* tagged
self-referential inaction doctrine ("zero tool calls, one short line" and 80
sibling rows, 81/316 of the store) as `durable_knowledge`, so the §3 layers never
engaged. The flywheel that resulted is one line of policy: `reobserve_fact`
advanced `last_verified_at` on every librarian re-extraction, recall ranks by
that anchor, and recall had *injected the same claim into the very window the
librarian summarized* — so injection → restatement → re-extraction → anchor
refresh → re-injection. A fact could hold its recall slot indefinitely,
independent of truth and immune to every claim_kind-keyed defense, because the
mistagged kind routed it to the anchor-refreshing arm.

The §8 fix is structural and content-blind — it does not read the claim, so no
mistag can route around it:

- **`reobservation_provenance`** (closed sum in `keeper_memory_os_policy.ml`):
  `Independent_observation | Recalled_echo`. `reobserve_fact` takes it as a
  required argument; a `Recalled_echo` inherits the row whole, for every
  `claim_kind`. Not an optional flag: no call site can skip the judgment and
  silently default to anchor refresh.
- **`Keeper_recall_injection_window`** (new, in-memory): recall's
  `render_if_enabled` notes the injected `claim_identity` keys per keeper per
  turn (bounded to `window_turns = 32`, over-approximating the librarian slice
  span). This is deliberately NOT the RFC-0264 ledger, whose contract is
  telemetry-only/never-read-on-decision-paths; the window is the load-bearing
  read model. Lost window (restart) degrades to the pre-§8 status quo, never to
  wrong suppression.
- **Write-boundary join** (`keeper_librarian_runtime.ml`): before folding each
  incoming claim, join its `claim_identity` against the window; injected ⇒
  `Recalled_echo` (+ `masc_keeper_memory_os_reobserve_echo_suppressed_total`
  counter, labelled by keeper), else `Independent_observation`.

Resulting dynamics: a fact that recall keeps injecting can no longer sustain its
own recency — its anchor freezes, the staleness marker appears after the §"one
day" horizon, fresher independently-observed facts outrank it, and it rotates
out of the recall window. Once it has been out of the window for
`window_turns`, a genuinely independent re-derivation (from real work, not from
reading the prompt) refreshes the anchor again. Growth stays possible; only
self-sustained doctrine decays.

Known limits (stated, not hidden):
- A *reworded* echo with no stable `claim_id` produces a different
  `normalize_claim` identity and appends as a new row (fresh anchor) — the same
  append-path residual as §3.2(b); L1(b)'s stable-id discipline is the
  mitigation, and the observed albini rows were verbatim re-mints, which §8
  does catch.
- A legitimate re-verification that the keeper performs *while the fact is
  still being injected* is also suppressed (indistinguishable from echo by
  identity alone). The anchor then refreshes only after rotation — one
  recall-cycle of delay, bounded by `window_turns`. Typed re-verification
  evidence (tool-outcome-backed) would lift this; out of scope here.
- Existing on-disk doctrine rows keep their current anchors; §8 stops the
  *refresh*, so they age out from now rather than being retroactively decayed
  (§5 cleanup posture unchanged).
