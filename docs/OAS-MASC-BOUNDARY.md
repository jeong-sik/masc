---
status: reference
last_verified: 2026-05-14
code_refs:
  - lib/masc_oas_bridge.ml
  - lib/worker_oas.ml
  - lib/verifier_oas.ml
  - lib/keeper/keeper_context_core.ml
  - lib/keeper/keeper_memory_policy.ml
---

# OAS-MASC Boundary Contract

OAS (OCaml Agent SDK)와 MASC 사이의 역할 경계를 정의한다.

**원칙**: OAS는 MASC를 모른다. OAS의 변경은 모든 소비자에게 유익해야 한다.

```
consumer → MASC (workspace collaboration/orchestration) → OAS (agent runtime)
```

## 문서 역할 (SSOT)

- 이 문서는 **boundary contract SSOT**다.
- `docs/spec/13-oas-integration.md`는 구현 세부와 open issue ledger를 유지한다.
- `docs/qa/OAS-BOUNDARY-HEALTHCHECK-2026-03-31.md`는 시점별 health snapshot이다.
- `docs/qa/OAS-OBSERVABILITY-TRUTH-AUDIT-2026-04-15.md`는 OAS observability producer -> bridge -> durable store -> dashboard consumer chain과 fixed gaps를 기록한다.
- `docs/KEEPER-STATE-OWNERSHIP.md`는 checkpoint, lane, domain receipt의 상태 소유권을 정의한다.

## 역할 분리

| 관심사 | OAS | MASC |
|--------|-----|------|
| 단일 에이전트 실행 | `Agent.run`, `Builder`, `Hooks`, `Guardrails`, `Checkpoint` | 언제/왜/어떤 agent를 돌릴지 결정 |
| 멀티에이전트 실행 | `Orchestrator`, `Agent_sdk_swarm.Runner` | workspace, board, workflow, policies, operator surfaces |
| 도구 실행 | `Tool.t`, hook lifecycle, raw trace | tool schema 정의, tool dispatch, auth/join/policy semantics |
| 컨텍스트 축약 | `Context_reducer` | 어떤 전략을 언제 적용할지 결정 |
| ContextOverflow retry | overflow detection, structured error, standalone/keeper compact retry | 최종 overflow 결과를 keeper state, receipt, operator surfaces에 attribution |
| 이벤트 전달 | `Event_bus` | 어떤 MASC 사건을 custom event로 publish할지 정의, SSE/dashboard에 연결 |
| 장기 메모리 | 없음 | keeper memory bank, institution episodes, procedural memory, workspace/task/social semantics |
| 조율 상태 | 없음 | workspace, tasks, board, Gate/HITL, social runtime |

## 의존 방향

```
MASC ──depends on──→ OAS
OAS  ──does not know──→ MASC
```

- MASC는 OAS 공개 API를 소비한다.
- MASC 전용 요구가 생겨도, 먼저 MASC adapter/bridge로 해결 가능한지 본다.
- OAS에 기능을 추가하더라도 MASC 전용 개념을 새 public contract로 밀어넣지 않는다.

## Config Ownership

- `config/runtime.toml`은 **MASC runtime contract**다. On-disk
  `runtime.json`은 retired compatibility input이며 더 이상 생성/소비하지 않는다. (MASC는 TOML에서 in-memory JSON representation을 렌더해 dashboard 등 소비자에게 제공한다.)
- MASC owns keeper-facing logical runtime configuration: named runtime/profile,
  declared capabilities, typed tool visibility, and lane/status projections.
- OAS owns concrete provider/model identity and execution. MASC must not branch
  on vendor/model literals or surface concrete provider/model ids in keeper
  runtime products; compatibility fields are redacted to `runtime`, `null`, or
  empty collections at MASC boundaries.
- OAS provider capability manifest / pricing override는 generic
  provider runtime contract다. MASC may pass logical runtime intent and
  capability requirements into those OAS contracts, but OAS must not learn MASC routes,
  keeper phases, runtimes, Board/Task/Gate semantics, or dashboard policy.
- `provider/model-free` in MASC means MASC policy code routes by logical use,
  declared capability, profile order, health, capacity, and receipt state; it
  does not branch on vendor/model literals. Provider/model ids remain
  OAS-owned runtime data, not MASC product data.
- 따라서 checked-in repo defaults는 review-stable pinning이 중요할 때 explicit `provider:model_id`를 쓰고, adapter default 자체를 계약으로 삼을 때만 `provider:auto`를 쓴다.
- legacy `allowed_providers` keeper TOML/meta fields는 더 이상 허용하지 않으며 load/parse boundary에서 reject한다.
- persisted legacy keeper meta tool-policy fields are scrubbed into canonical `tool_access` on read; direct `meta_of_json` callers must use canonical keeper meta keys.

## Current Integration Status

| Area | Status | Notes |
|------|--------|-------|
| Context compaction | Partial complete | `context_compact_oas.ml`는 OAS `Context_reducer`를 사용한다. MASC 전체 context system이 OAS `Context.t`로 통합된 것은 아니다. |
| ContextOverflow retry ownership | Complete for keeper hot path | Keeper dispatch keeps `auto_context_overflow_retry=true`, so OAS owns transcript mutation, emergency compaction, and retry. If OAS still returns structured `ContextOverflow`, MASC records the typed blocker and terminal receipt without compacting checkpoints or re-dispatching the agent turn. |
| Event bus bridge | Complete for current native/custom flow | `oas_event_bridge.ml` relays both OAS native events and `masc:*` custom events, persists them under `.masc/oas-events/`, and feeds dashboard SSE |
| Dashboard OAS runtime health | Complete with replay/live split | dashboard health SSOT is `durable oas_event replay + live SSE tail`, not live-only counters |
| Dashboard runtime counts | Complete with truth split | dashboard `counts` means active runtimes; configured keeper inventory is exposed separately as `configured_keepers` |
| Checkpoint integration | OAS-owned transcript state | OAS checkpoint is used in shared worker/runtime paths. MASC does not derive checkpoint state from assistant prose or maintain a duplicate prose-derived sidecar. Feature adapters may use typed, owner-specific checkpoint metadata only where the OAS contract explicitly exposes it. |
| Memory projection | Removed | MASC no longer creates or passes OAS memory objects; memory storage stays MASC-owned |
| Team-session swarm | Removed | `lib/team_session/` module purged; MASC no longer owns a session orchestration surface. OAS Swarm Runner is the sole substrate; consumers drive swarm runs via OAS primitives directly. |
| Provider/model identity ownership | OAS-owned | MASC resolves logical `runtime_id` / runtime lane intent only; concrete provider/model selection and cost identity are OAS-owned. Legacy `allowed_providers` inputs are rejected |

## Boundary Audit Snapshot

| Module / Surface | Classification | Why |
|------------------|----------------|-----|
| `lib/oas_worker*.ml`, `lib/worker_oas.ml`, `lib/verifier_oas.ml` | Correct | OAS is consumed as the runtime contract; MASC chooses prompts, tools, policy, and verification usage |
| `lib/context_compact_oas.ml` | Adapter | Runtime compaction delegates to OAS. MASC-owned typed anchors may influence retention, but raw assistant text is not a domain-state channel. |
| `lib/keeper/keeper_agent_run.ml` + keeper checkpoint/context path | Correct boundary | Keeper recovery reads canonical OAS checkpoints. MASC does not parse assistant replies into continuity state; owner-specific typed adapter metadata remains separate from the transcript. |

## Open Structural Gaps

- keeper runtime still has a small MASC-owned context facade around OAS context/checkpoint primitives for token observation and checkpoint loading; this facade must remain read-only with respect to OAS-owned runtime transcript state.
- assistant prose is context only. MASC must not parse it into goal, task, continuity, or lifecycle transitions and must not keep compatibility readers for retired prose protocols.
- runtime-health signaling still relies on a narrow boolean `resource_check` callback instead of a structured probe
- proof-store and `oas-runtime` filesystem layout must stay behind thin adapters instead of being reconstructed ad hoc
- provider/model ownership still has historical debug and lower-level
  compatibility leakage in MASC-side code. New keeper runtime manifest rows,
  `/runtime-trace` projections, and product summaries should stay
  capability/lane/status based and redact raw provider/model identifiers.
  No-tool-capable runtime errors should report allowed tools, candidate
  counts, and rejection reasons without naming configured providers. Keeper
  runtime/social status surfaces should keep legacy model-label keys null
  rather than resolving provider/model display labels. Runtime trust,
  composite execution, keeper status detail, and keeper FSM helper projections
  should preserve only non-identifying runtime/tool/sandbox signals and return
  null or empty collections for selected model/provider identity fields. Keeper
  execution receipt JSON and operator-broadcast payloads should preserve legacy
  compatibility keys but keep provider/model identity values null. Keeper
  decision-log and metrics snapshot JSONL projections should preserve
  non-identifying runtime/tool/usage/timing evidence while keeping model,
  provider, configured-label, and candidate-model fields null or empty.
  Dashboard normalizers and product UI should not resurrect concrete
  model/provider labels from older payloads; they should show runtime lane,
  outcome, attempt, fallback, tool, sandbox, and runtime-trust evidence instead.
  Gate/Board dashboard adapters should likewise keep judge/approval
  runtime evidence while nulling or hiding `model_used` and `selected_model`.
  Model-inference and cost/latency API projections may keep legacy field names
  such as `model_id`, `provider`, `agent`, `matrix.providers`, and
  `matrix.models` for client compatibility, but values must be redacted runtime
  lane labels or `null`, not concrete OAS provider/model identities. Keeper cost
  and decision dashboards must not display raw `model_used`. SSE journal text
  and operator digest normalizers follow the same redaction rule.
  Gate judge API/status records, human-judgment records, keeper detail
  metric windows, and handoff summaries should preserve runtime status and
  transition counts while keeping concrete `model_used`, `to_model`, and
  model-breakdown labels null or neutral. Operator control snapshots follow
  the same rule for keeper rows and context snapshots. Keeper approval queue
  dashboard rows, audit rows, and resolution broadcasts keep `selected_model`
  as a compatibility key only and emit `null`. Legacy keeper `models` inputs are rejected at TOML/meta parse
  boundaries rather than decoded into a neutral runtime label.
  Channel Gate turn stats follow the same rule: keeper response parsing keeps
  duration/token counts and collapses the legacy model slot to `runtime`, while
  outbound wire JSON emits `model_used: null`.
  Dashboard harness wake-payload telemetry and Yjs keeper updates keep the
  legacy `model_id` key but emit the neutral `runtime` lane.
  The OAS dashboard telemetry bridge accepts provider/model compatibility
  fields at ingress, but normalizes samples, provider-error counters, filters,
  and SSE/REST projections to the neutral `runtime` lane before MASC stores
  them.
  Operator pending-confirm runtime metadata keeps `model_used` as a
  compatibility key only and emits `null` at the boundary.
  Keeper detail provider-health projections, keeper execution memory context,
  keeper turn-complete SSE, and keeper turn-completed event payloads retain
  operational status/usage fields while redacting provider/model identity
  fields to `null`.
  Keeper meta JSON keeps the legacy `last_model_used` key but writes it as an
  empty string so new persisted meta does not carry concrete provider/model
  labels.
  Cost ledger JSONL keeps status diagnostics but redacts persisted `provider`
  and `model` values to the neutral `runtime` lane. MASC no longer estimates
  provider/model pricing locally or emits legacy cost/pricing compatibility
  fields; `cost_usd` is trusted only when
  OAS reports it, otherwise the row is marked `oas_cost_unreported`.
  No-tool provider rejection records now carry only non-identifying rejection
  reasons in the MASC structured error type; legacy payloads with
  provider/model-shaped fields still parse, but those identities are not
  re-emitted.
  Runtime attempt-liveness observer metrics keep the historical `provider`
  label key for dashboard compatibility but emit the neutral `runtime` lane;
  liveness budget history also uses a single neutral runtime candidate key
  instead of retaining concrete provider/model keys.
  Provider-error and OAS-run-timeout metric counters follow the same
  projection rule: they retain error kind, runtime, capacity scope, and timeout
  source, but the historical `provider` label value is the neutral `runtime`
  lane rather than a concrete provider/model identity. The keeper
  memory-summary outcome counter (`masc_keeper_memory_llm_summary_outcomes_total`)
  and its warn logs follow the same rule: they keep the historical `provider`
  label key and the `runtime_id`/`outcome` evidence, but the `provider` value is
  the neutral `runtime` lane and the warn logs name the runtime rather than the
  model id.
  The typed `Provider_error` contract itself is also runtime-lane scoped:
  variants no longer store provider/model identifiers, and legacy JSON keys
  such as `provider`, `affected`, and `model_name` emit neutral `runtime`
  values only.
  Runtime probe JSON and provider-health probe metric labels
  keep status/error/profile evidence but redact provider kind, model id,
  model string, endpoint, and metric provider/model labels to neutral runtime
  values.
  Runtime legacy observations and attempt/fallback audit rows now store
  runtime-lane candidate identities, and keeper turn-driver fallback/cooldown
  logs use runtime labels instead of concrete provider/model labels.
  Keeper runtime bookkeeping uses `Runtime_runtime_candidate` for health,
  capacity, probe, ordering, and timeout decisions so `Keeper_turn_driver` no
  longer exposes public `Provider_config.t` timeout helpers or directly
  inspects provider kind, endpoint, or model id in the keeper loop.
  Keeper liveness/pre-skip helpers now accept only neutral label-to-runtime-URL
  resolvers; label parsing and provider config access stay behind
  `Runtime_runtime_candidate`.
  Keeper usage-trust classification now accepts the OAS-derived cache
  capability signal instead of a provider-kind value; provider kind remains
  confined to the OAS telemetry bridge and provider resolver.
  Keeper turn-context label filtering no longer parses configured labels into
  `Provider_config.t`; model-id compatibility checks are delegated to
  `Runtime_runtime_candidate`.
  Keeper OAS hook public helpers no longer accept provider-kind arguments;
  typed provider evidence is consumed only inside telemetry bridge helpers.
  `Keeper_turn_driver.mli` also no longer re-exports the full
  `Runtime_oas_runner`, provider-attempt FSM APIs, or config/preflight helpers
  from `Runtime_error_classify`; provider/model-shaped helpers stay behind
  lower-level OAS boundary modules instead of the keeper facade.
  Documented boundary-allow exception: `keeper_runtime_attempt.ml`
  `enrich_sdk_error` (`openai_compat_not_found_detail`) intentionally
  interpolates `model_id`, `base_url`, `request_path`, and the composed
  `endpoint` into the OpenAI-compatible 404/invalid-request error message it
  appends. This is a diagnostic-only leak: it exists so an operator can see the
  exact misconfigured endpoint that a neutral runtime lane would hide, the
  values come from the masc-owned `runtime.toml` provider binding, and they are
  surfaced only on the error message path — never in metric labels or product
  telemetry. It is retained deliberately rather than redacted.
  The stricter OAS-owned provider/model migration is tracked in
  <https://github.com/jeong-sik/masc/issues/15028>.

## Delivery-Contract Split

- MASC owns the delivery contract itself: `contract_id`, acceptance checks, required artifacts, repair budget, evaluator role/runtime, proof/report surfaces.
- OAS should stay generic and receive only reusable harness/runtime primitives.
- Current local implementation keeps the contract in MASC workspace collaboration state (Board, Goal, Task, Keeper FSM, and Gate requests) and feeds it into worker verification and proof artifacts without teaching OAS about MASC semantics.

## Candidate Upstream Work

These are the next changes that are generic enough to propose upstream:

- generic provider capability / pricing manifest contracts for
  broad cloud APIs and non-interactive CLI/subscriber runtimes
- harness case/result/verdict/repair-directive primitives that MASC evaluators can reuse
- richer swarm `agent_entry` metadata so `planned_worker` routing and telemetry survive end to end
- structured runtime-health probe callback to replace the current boolean `resource_check`

These stay in MASC:

- workspace/Task/Board/Keeper/Gate semantics
- planner session policy and repair-budget policy
- proof/report JSON/markdown contracts and workspace collaboration-specific evidence rules

## Priority Order

1. **P1 — keeper runtime state ownership**
   - keep domain state out of OAS transcript/checkpoint content; reduce remaining adapter metadata when its typed owner has stable storage
2. **P2 — prose/state separation** — Required invariant
   - prompt text and model replies never encode or authorize typed domain transitions
3. **P3 — team-session bridge fidelity** — Resolved (2026-04, team_session module purged; OAS Swarm Runner is sole substrate)
   - MASC team-session surface removed; workspace collaboration needs served via board posts + keeper FSM, swarm runs driven through OAS directly
4. **P4 — memory projection hard cut** — Resolved by removal
   - OAS memory projection/hooks/flush paths removed; MASC-owned memory remains the runtime storage surface
5. **P5 — doc truth alignment**
   - keep this contract, the implementation spec, and the utilization audit in sync

## What This Means Practically

- “Context integration in progress” now means **broader state unification**, not compaction.
- “Event_bus bridge planned” is no longer true for the current dashboard/SSE path.
- dashboard OAS runtime health should be read as **durable replay + live tail**, not as a live-only pulse.
- dashboard runtime `counts` should be read as **active truth**, while keeper inventory belongs to `configured_keepers`.
- “team_session pending migration” is no longer true; the `lib/team_session/` module has been **removed** — swarm runs go through OAS directly, workspace collaboration state lives in board posts and keeper FSM.

## Boundary Review Checklist

Use this checklist when reviewing boundary-touching PRs:

1. **OAS가 MASC를 새로 알게 되는가?**
   - generic runtime/harness primitive가 아니라 Workspace/Task/Board/Keeper/Gate semantics가 OAS public contract로 새어 나오면 안 된다.
2. **MASC core가 provider/model 세부를 새로 배우는가?**
   - model ID, vendor, token/cost detail은 config 또는 OAS-facing adapter/bridge에 머물러야 한다.
   - routing/policy code가 vendor/model literal로 분기하면 provider/model-free 위반이다.
3. **문서 truth가 코드 truth와 일치하는가?**
   - 특히 runtime labels, runtime-health semantics, boundary-audit snapshot은 구현과 SSOT 문서가 함께 갱신되어야 한다.
4. **Checked-in runtime labels are explicit enough for stable review**
   - repository-default `config/runtime.toml` entries should pin explicit provider/model labels when review stability depends on an exact model. `provider:auto` is acceptable only when the adapter-level default is itself the intended checked-in contract.

## Boundary Rules for Future Work

1. If the problem is “single agent execution contract”, prefer fixing `oas_worker` / `worker_oas` / OAS-facing adapters.
2. If the problem is “Workspace, Task, Goal, Board, Keeper, Gate, Connector semantics”, keep it in MASC.
3. If a bridge is lossy, fix the MASC-side adapter first before proposing OAS API expansion.
4. Do not claim a subsystem is “migrated” if the runtime path works but key semantics are still dropped.

## OAS API Surface Drift — Detection & Repair

Three complementary mechanisms keep the OAS/MASC boundary honest. The first keeps upstream OAS agent-stream-agnostic; the other two keep MASC's consumer-side type boundary honest.

### Layer 0 — SDK independence gate (`scripts/ci/check-masc-oas-boundary.sh`)

MASC's boundary guard resolves an OAS checkout and, when that checkout provides `scripts/check-sdk-independence.sh`, delegates upstream vocabulary scanning to OAS itself. This prevents the downstream repo from proving independence by scanning MASC-side adapters such as `lib/oas_*.ml`.

```bash
AGENT_SDK_LOCAL_REPO=/path/to/oas \
MASC_STRICT_OAS_INDEPENDENCE=1 \
bash scripts/ci/check-masc-oas-boundary.sh
```

Without `MASC_STRICT_OAS_INDEPENDENCE=1`, the guard warns and continues when the OAS checkout or OAS-owned script is unavailable. That keeps downstream PR ordering decoupled while still giving local reviewers a strict mode.

### Layer 1 — Fingerprint gate (`scripts/oas-drift-check.sh`)

Dumps OAS public types at the pinned SHA (Event_bus variants / Http_client error variants / Metrics.t fields) and diffs against `scripts/oas-api-surface.json`. Runs automatically as a one-line summary inside `make diagnostics-oas-pin`:

```
OAS pin verified: main@92c3077a (base version v0.155.1)
OAS API surface: ✓ matches fingerprint
```

Drift shows as `⚠ drift (added N, removed M) — run 'make diagnostics-oas-drift' for detail`. `make diagnostics-oas-drift` prints the section-grouped added/removed lists and the repair sequence.

### Layer 2 — Type adapter (`lib/oas_compat/`)

Consumer-side pattern matches against OAS variants and record literals against OAS records are consolidated in `lib/oas_compat/oas_compat.ml` (Http_client + Metrics so far; Event_bus pending). When OAS adds a variant or field, only this module fails to compile, not every consumer. Adding a new surface to the adapter requires both:

1. Extend `oas_compat.mli` / `.ml` with the new projection
2. Migrate call sites to use the adapter (one line each, usually)

### Repair flow when drift is reported

```bash
# 1. Investigate: what actually changed upstream?
make diagnostics-oas-drift             # section-grouped added/removed

# 2. Fix the consumer side (usually: update lib/oas_compat/oas_compat.ml
#    so the adapter compiles against the new OAS; migrate any remaining
#    call sites that match OAS types directly)

# 3. Verify build is clean
dune build @check

# 4. Refresh the fingerprint and commit it together with the consumer change
bash scripts/oas-drift-check.sh --regenerate
git add scripts/oas-api-surface.json lib/
git commit -m 'chore(oas): adopt <variant/field>, refresh surface fingerprint'
```

Regenerate-before-fix is an anti-pattern: the fingerprint must always describe a state where MASC consumers compile cleanly.

### Source resolution (no manual config for common cases)

`oas-drift-check.sh` auto-discovers the OAS checkout in this order:

1. `$AGENT_SDK_LOCAL_REPO` (explicit override)
2. `<masc-parent>/oas` (sibling checkout)

Each candidate must be a git checkout at the pinned SHA. If none qualifies, the script falls back to `git fetch` into a temp bare clone from the upstream URL. Network is required only for that fallback.
