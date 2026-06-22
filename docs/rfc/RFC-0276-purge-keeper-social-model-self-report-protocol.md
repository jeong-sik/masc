# RFC-0276: Purge the keeper social model self-report protocol (Phase 2)

- Status: Draft
- Author: jeong-sik (with adversarial agent blast-radius survey + direct prompt verification + 4-claim adversarial refutation, 2026-06-22)
- Completes: RFC-0275 §3 deferred "Phase 2" (replace the SPEECH_ACT/DELIVERY_SURFACE self-declared header protocol). RFC-0275 (BDI triple + `magentic_ledger_v1`) is Phase 1.
- Supersedes: `docs/design/keeper-social-model-fsm.md`, `keeper-social-model-inventory.md`, `composite-fsm-matrix-design.md` (social-model portions); RFC-0275 §3 "Non-goals (what stays)".
- Reconciles: RFC-0239 (semantic-identity-guards) R3 and RFC-0242 — both pinned no-progress control flow onto `delivery_surface`; this RFC re-grounds that flow on runtime-observed turn facts.

## 1. Summary

Remove the keeper **social model** end to end: the self-declared header protocol
(`SOCIAL_MODEL`/`BLOCKER`/`NEED`/`SPEECH_ACT`/`DELIVERY_SURFACE`) taught by the
prompt, the `social_state` record, the `speech_act` (8) and `delivery_surface`
(6) enums, `model_id`, the registry, the sole implementation `bdi_speech_v1`,
the header parser, and the `Keeper_social_model` facade. Delete the
`masc.keeper_social` types library.

The social model asks the LLM to **self-report**, in non-cacheable output
headers every turn fleet-wide, facts the runtime can **observe
deterministically**: which tools were called, whether visible text was emitted,
whether the turn produced validated evidence. Two consumers are genuinely
load-bearing and are handled explicitly rather than deleted blind:

1. **No-progress loop detector** (RFC-0239) — **decoupled, not removed**. Its
   engine is already social-model-free (primitive-bool interface,
   `keeper_no_progress_loop_detector.ml:55`); only the ~6-line
   `surface_requires_evidence` computation reads `delivery_surface`. Re-derive it
   from `run_result` facts.
2. **`blocker` structured-payload cap** (#9933 `cap_blocker`) — **preserved by
   folding** the `[masc_oas_error]` non-truncation rule into the runtime
   `blocker_class` detail path.

Everything else — request-help auto board-post, reply-suppression blanking — is
removed: the first is redundant with the independent typed `blocker_class`
operator surface (verified independent, C3 below), the second with RFC-0232
`Keeper_turn_outcome` (verified no chat/board emission, C2 below).

Structural change: a product type, the `keeper_meta` runtime contract, two
persisted JSON formats, the keeper prompt; ~25 modules + prompt + dashboard TS +
one TLA+ spec. Hence an RFC.

## 2. Motivation (evidence, not theory)

### 2.1 The protocol is self-report of runtime-observable facts

`config/prompts/keeper.unified.system.md:158-165` mandates **"Start every
response with machine-readable headers"** every turn. The runtime then
*re-derives* the same surface from tool names + text presence anyway
(`keeper_social_model_bdi_speech_v1.ml:235-276`; the tool-only path at `:239`
overrides the self-declared header when tools are present). The header layer
duplicates what the runtime already measures — the "complecting" (Hickey) of
*self-reported intent* with *observable fact*. Parse-don't-validate: observe the
fact at the boundary, do not ask the model to declare it and then validate the
declaration.

### 2.2 Recurring output-token cost

The static instruction (~200 tokens) is prefix-cacheable, but every keeper
emits **five header lines as non-cacheable output tokens every turn,
fleet-wide**, feeding only parse → derive → persist → render. RFC-0275 removed
three of eight such lines (the BDI triple); this removes the rest and the
protocol that generates them.

### 2.3 Negative precedent, no eval

The declare-intent-via-headers design caused 0-tool-call proactive turns
(#5573). No eval/benchmark ever validated the social model
(`keeper-social-model-inventory.md:75-76`).

### 2.4 Corrected premise (adversarial finding)

The blast-radius survey (9 agents) initially concluded request-help routing was
"dormant scaffolding, zero product loss." **Direct verification of
`config/prompts/keeper.unified.system.md` falsified this**: `:113,:147` instruct
`SPEECH_ACT: request_help` when blocked; `:148`/`core_behavior.md:4` instruct
`SPEECH_ACT: stay_silent`+`DELIVERY_SURFACE: silent` when idle. The protocol is
**live**, not dormant. This RFC therefore treats removal as a behavior change to
be justified — not a no-op cleanup — and documents what each removed behavior is
replaced by (§3.4), each load-bearing claim adversarially verified (§9).

## 3. Decision

### 3.1 Remove (the purge)

| Target | Files |
|---|---|
| Prompt header protocol | `config/prompts/keeper.unified.system.md:113,147,148,158-165`; `keeper.core_behavior.md:4` |
| Types library | `lib/keeper_social/keeper_social_model_types.ml(i)` + `lib/keeper_social/dune` (`masc.keeper_social`) |
| Facade | `lib/keeper/keeper_social_model.ml(i)` |
| Registry + impl + protocol | `keeper_social_model_registry.ml`, `keeper_social_model_bdi_speech_v1.ml(i)`, `keeper_social_model_protocol.ml` |
| Runtime contract fields | `keeper_meta_contract.ml` `social_model`/`last_speech_act`/`last_social_transition_reason`/`last_need`/social part of `last_blocker`; parse/scrub/json round-trip |
| TOML parser validation | `keeper_types_profile_toml_parser.ml:48-66` (social_model validation) + `:182` field + `keeper_types_profile_toml_normalizers.ml:27-36` `normalize_social_model_opt`/`valid_social_model_strings` |
| Decision/metrics writers | `keeper_unified_metrics_decision.ml:90-101`, `keeper_unified_metrics_result.ml:227,239` |
| Dashboard | `dashboard_http_keeper_feeds.ml:382` speech_act render; `keeper_status_bridge.ml:328`, `keeper_status_detail.ml:914` social fields; `/bdi-snapshot` (`dashboard_http_keeper_snapshot.ml`) |
| Dead TS | `inspector-keeper-bdi.ts:45-47,101-103` (belief/desire/intention already dead), `core.ts:1166-1172` |
| TLA+ | `SocialStateCap.tla` + `.cfg` + `-buggy.cfg` + INDEX + `tla-check.sh` + `check-spec-truth.sh` annotation (mirror the Phase-1 magentic deletion) |
| Live tests | the social_model cases in `test/test_keeper_toml_parser.ml`, `test/test_social_state_cap.ml`, `test/test_dashboard_k2_feeds.ml` |
| Orphan test (cleanup) | `test/test_keeper_toml.ml` — **not wired into any dune stanza** (no `test_keeper_toml.inc`; live tests are `test_keeper_toml_parser.ml`/`_loader.ml`). Contains stale `magentic_ledger_v1` from before Phase 1. Delete or wire; either way drop the magentic refs |
| Request-help board post | `deliver_request_help_post`, `should_dedupe_request_help`, `request_help_post_body` |
| Reply-suppression blanking | `apply_output_to_result` `response_text=""` arms (`bdi_speech_v1.ml:283-293`) |

### 3.2 Decouple, do not remove — no-progress detector (RFC-0239)

`keeper_unified_turn_success.ml:88-93` computes `surface_requires_evidence` by
matching `social_state.delivery_surface` — a *single already-resolved* enum. The
resolution (collapsing multiple turn signals into one surface) happens upstream
in the removed `inferred_tool_surface` (`bdi_speech_v1.ml:156-185`), a strict
if/else-if: `board_comment > board_post > broadcast > claim > (else) visible`.
That **precedence is load-bearing** and must be reproduced when the collapse
moves into the new derivation, or a multi-signal turn (e.g. a board post that
*also* emitted text) could be mis-routed and the anti-thrash invariant would
flip. The replacement is therefore a *total* function over `run_result` facts
already in scope (`Keeper_agent_result`: `tool_names`, `response_text`,
`run_validation`), with the same precedence made explicit:

```ocaml
(* Runtime-observed delivery classification, replacing the LLM self-declared
   delivery_surface. Derived once from turn facts; no social model. *)
type turn_delivery =
  | Peer_only   (* peer-surface tool (board/comment/broadcast/keeper-msg), or
                   silent: no peer/claim tool and no visible text *)
  | User_facing (* non-empty visible reply, no peer/claim tool *)
  | Task_claim  (* task-claim tool *)

(* Total derivation. Precedence (peer > claim > visible text > silent) mirrors
   the removed inferred_tool_surface order: tools dominate text — text is
   consulted only when no peer/claim tool is present — so a board-post-plus-text
   turn stays Peer_only and cannot flip to exempt. Tool classification is
   delegated to the typed Keeper_tool_capability_axis SSOT (no hardcoded
   tool-name literals; CLAUDE.md anti-pattern #1). *)
let classify_delivery ~tools ~has_visible_text =
  if Keeper_tool_capability_axis.(supports_any Board_activity tools) then Peer_only
  else if Keeper_tool_capability_axis.(supports_any Claim_task tools) then Task_claim
  else if has_visible_text then User_facing
  else Peer_only

(* Exhaustive, no `_ ->` catch-all (CLAUDE.md anti-pattern #4). *)
let surface_requires_evidence = function
  | Peer_only -> true
  | User_facing | Task_claim -> false
```

Invariant preserved (RFC-0239 anti-thrash): a board/broadcast/silent turn with
no substantive tool calls and no validated output **counts as no-progress**; a
visible reply or a task claim is exempt. The accountability-surface label at
`keeper_unified_turn_success.ml:303` shares the new helper.

**Peer-set expansion, as-built (Phase 2a).** Delegating to
`Keeper_tool_capability_axis.Board_activity` makes the peer set
`{keeper_board_post, keeper_board_comment, masc_broadcast, masc_keeper_msg}` —
wider than the removed social-model set `{board_post, board_comment, broadcast}`
by `masc_keeper_msg` (keeper→keeper message; `masc_broadcast` is the public name
of the same `keeper_broadcast` tool, not a new entry). This is an **intentional,
more complete** peer-surface definition: a turn that only sends a peer message
with no durable evidence now accrues the streak (the old social model let it
reset), which is exactly RFC-0239's "only posts to peers without evidence" case.
Because the no-progress *policy* now reuses a multi-consumer *taxonomy*
(`Board_activity` also serves tool disclosure), the intended peer set is **pinned
by an explicit-literal test** (`test_no_progress_loop_detector`): any future
`Board_activity` change fails that assertion and forces a conscious no-progress
review, converting the coupling from silent to guarded.

**Behavior change, made explicit (adversarial C1 finding).** The decouple is
*not* a byte-exact reproduction of today's `delivery_surface`. Adversarial
verification (wf_7fc10231) refuted "exact": in the *current* code a **toolless**
turn can self-declare `DELIVERY_SURFACE: board_post` via the header
(`social_state_of_headers`, `bdi_speech_v1.ml:133-168`) → `requires_evidence=true`,
where a header-less identical turn infers `Visible_reply` → `false`. That
divergence is **eliminated by this RFC**: the header protocol and its parser are
removed, so no self-declared surface remains to diverge. Net change is confined
to the rare "toolless turn that self-declared a board/broadcast surface":
post-purge it is `User_facing` if it emitted text, else `Peer_only`. This is the
parse-don't-validate correction — to post to the board a keeper must *call the
board tool* (observable), not assert a header (unverifiable). Tool-bearing turns
unaffected. A unit test pins the post-purge mapping (§7).

### 3.3 Preserve by folding — #9933 structured blocker payload

`cap_blocker` (`keeper_social_model_types.ml:160-210`) protects `[masc_oas_error]`
JSON from the 200-char narrative truncation (up to 2000). The genuine "blocked"
signal — `runtime.last_blocker` typed `blocker_class` from
`Keeper_status_bridge_blocker.blocker_class_of_sdk_error` — **survives untouched**
(adversarial C3: holds; consumed by operator/dashboard/governance/fleet with no
`speech_act` dependency; `social_state.blocker` was only an optional detail
string with a `public_reason` fallback at `keeper_unified_metrics_failure.ml:178`).
Move the `[masc_oas_error]` non-truncation rule into whatever caps the
`blocker_class` detail string.

### 3.4 What replaces each removed behavior

| Removed | Replaced by | Verified |
|---|---|---|
| `SPEECH_ACT: request_help` → board post | typed `blocker_class` operator surface | C3 holds |
| `stay_silent`/`silent` → `response_text=""` | RFC-0232 `Keeper_turn_outcome` (gates the dashboard preview at `keeper_unified_metrics_result.ml:184` via `is_visible_reply`; interactive path never used the social model) | C2: no chat/board sink |
| `delivery_surface` → no-progress | §3.2 runtime-observed `turn_delivery` | C1: behavior change documented |

## 4. Removal plan (compiler-driven, phased)

- **Phase 1** (RFC-0275, **merged to main** #22023): BDI triple + `magentic_ledger_v1`. Done.
- **Phase 2a — decouple** (**merged to main** #22036): implemented §3.2 `turn_delivery`; social model still compiles; unit-tested the anti-thrash mapping + multi-signal precedence + peer-set drift guard. Shipped green before any deletion. Done.
- **Phase 2b — purge** (high risk): delete prompt protocol + types lib + facade + registry + impl + protocol + TOML validation. The OCaml closed-sum deletion forces the compiler to enumerate every remaining consumer. Remove request-help post + reply-suppression arms. Fold §3.3.
- **Phase 2c — clean-up**: dashboard TS dead fields, `/bdi-snapshot`, TLA+ `SocialStateCap.tla`, orphan `test_keeper_toml.ml`, metrics/decision writers, design-doc supersession.

## 5. Persistence migration & rollback (adversarial C4)

- **JSON parser tolerates unknown/missing keys** (verified: `keeper_meta_json_parse.ml` via `Safe_ops.json_string` defaults; `reject_removed_keeper_meta_shapes` does not reject these fields). Old checkpoints carrying `social_model`/`last_speech_act`/… load clean. ✅
- **TOML parser actively validates** `social_model` (`keeper_types_profile_toml_parser.ml:48-66`) and rejects unknown values (e.g. `experimental_v99`). Therefore removing `social_model` is **not** "ignore the key" — the validation block, the `:182` field, and `normalize_social_model_opt` must be deleted, and any `[keeper] social_model = …` line in real profiles becomes an unknown key (handled by the unknown-key warning path, not an error). Old configs that *set* `social_model` will warn, not fail.
- **Rollback** = revert the PR; old keepers re-emit headers harmlessly into ignored JSON fields until redeploy. No data-migration script (additive-ignore, not destructive-rewrite).

## 6. Risks

| Risk | Mitigation |
|---|---|
| No-progress detector regresses (anti-thrash) | §3.2 preserves the mapping; Phase 2a ships + unit-tested before deletion. Behavior change for header-declared toolless turns documented (§3.2) |
| Operators lose "keeper blocked" visibility | C3 verified `blocker_class` independent + survives; only the redundant board auto-post drops |
| Silent-turn text leaks to a visible surface | C2 verified: autonomous path never appends `response_text` to chat/board; only the RFC-0232-gated preview reads it |
| `response_requests_confirmation` flips on non-blanked silent turns | C2 flagged: field is written to decision JSONL (`keeper_unified_metrics_decision.ml:223`) but **no live consumer found**. Phase 2b: confirm no reader of the JSON key; if one exists, gate it on the typed turn outcome. Otherwise it reflects actual model output (more honest) |
| Structured `[masc_oas_error]` truncated after cap removal | §3.3 folds the 2000-char non-truncation into the `blocker_class` detail path |
| Orphan TLA+ / spec-mirror CI failure | Mirror the Phase-1 fix: delete spec + `.cfg` + INDEX regen + `tla-check.sh` line + `check-spec-truth.sh` annotation |
| Future product wants proactive help-posts | Re-introduce under a new RFC as an explicit `keeper_request_help` tool (typed, observable), not a self-declared header |

## 7. Verification / acceptance

- [ ] `surface_requires_evidence` unit test: `Peer_only -> true`, `User_facing|Task_claim -> false`; thrash scenario (repeated toolless board post) accrues the streak.
- [ ] `classify_delivery` **multi-signal precedence** test (not single-signal only): peer-tool + visible text -> `Peer_only`; peer-tool + claim-tool -> `Peer_only`; claim-tool + text -> `Task_claim`; no-tool + text -> `User_facing`; silent -> `Peer_only`.
- [ ] Peer-set **drift guard**: the `Board_activity` set is pinned by explicit literal (`{keeper_board_post, keeper_board_comment, masc_broadcast, masc_keeper_msg}`), so adding an axis tool fails the test; the `masc_keeper_msg` inclusion vs the old social-model set is asserted as the documented intentional change.
- [ ] `rg 'speech_act|delivery_surface|social_state|social_model' lib/ bin/ config/prompts/` returns zero (excluding this RFC + CHANGELOG).
- [ ] Compiler green after deleting `masc.keeper_social` (no orphan consumers).
- [ ] `check-spec-truth.sh`: 0 orphan refs; `make -C specs check-clean`; `tla-index.yml` regen clean.
- [ ] `blocker_class` dashboard surface unchanged; `[masc_oas_error]` round-trips uncut through the new cap site.
- [ ] No prompt references the removed protocol; keeper turns emit no header lines.
- [ ] `test_keeper_toml_parser.ml` social_model cases removed; orphan `test_keeper_toml.ml` deleted/wired.
- [ ] No reader of the `response_requests_confirmation` decision-JSON key (or it is re-gated).
- [ ] Required `CI Gate` green.

## 8. Governance reconciliation

- `docs/design/keeper-social-model-fsm.md`, `keeper-social-model-inventory.md`: mark social-model sections superseded by RFC-0276.
- RFC-0275 §3 "Non-goals (what stays)": superseded — the deferred Phase 2 is executed; `speech_act`/`delivery_surface`/`blocker`/`need` removed (load-bearing uses re-grounded per §3.2/§3.3).
- RFC-0239 R3 / RFC-0242: update the cited control-flow anchor from `delivery_surface` to the §3.2 `turn_delivery` runtime classification; anti-thrash invariant unchanged.
- `docs/observability/fsm-spec-code-drift.md`: social-model rows → removed.

## 9. Adversarial verification record (wf_7fc10231, 2026-06-22)

Four load-bearing claims refuted-by-default by independent skeptic agents
against the code:

- **C1 (decouple exact)**: REFUTED → §3.2 reframed as a documented behavior
  change eliminated by header removal (not byte-exact).
- **C2 (suppression no-op)**: no chat/board sink confirmed; lone residue is the
  `response_requests_confirmation` decision-JSON field (no live consumer found) →
  §6 flag.
- **C3 (blocker_class independent)**: HOLDS — request-help removal safe.
- **C4 (persistence)**: JSON tolerant ✅; TOML validates → must delete the
  validation + field, not merely "ignore key" → §5. Surfaced the orphan
  `test_keeper_toml.ml`.
