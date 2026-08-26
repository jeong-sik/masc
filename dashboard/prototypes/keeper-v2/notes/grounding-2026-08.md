# Source diff — jeong-sik/masc@main (cf68b4fc, 2026-08-05) vs grounding.md(2026-07-15)

근거: `dashboard/src/config/navigation.ts`, `README.md`, `CHANGELOG.md` (Unreleased + 0.21.0~0.21.2).
최신 릴리스 = **0.21.2 (2026-07-20)** → mock FL_VERSION `v0.20.1` 은 stale.

## A. IA 변경 (navigation.ts)
- rail(`V2_PRIMARY_SURFACE_IDS`) **변화 없음**: overview · keepers · registry · monitoring · workspace · approvals(Gate) · schedule · board · fusion · logs · code · connectors · settings.
- Settings 12섹션 **변화 없음**.
- **monitoring 섹션 추가**: `internal-agents` = "Internal Agents · Nondeterministic runs and tool evidence."
  → 현재: agents(Keeper Fleet) · internal-agents · fleet-health(Tool Monitor) · runtime · observatory. hidden: transport-health · feature-health · journey.
- **monitoring:cognition 제거** (hidden 이었음) → `agents` 로 redirect.
- **lab 섹션 추가**: `audit-integrity` = "감사 무결성 · Per-keeper resilience audit hash-chain verification result."
- **lab:memory-subsystems(Memory OS) 제거** — `lab:memory-explore` → `keeper-memory-health`, `lab:design-canvas` → `tools`.
  → lab 현재: tools · harness · performance · keeper-memory-health(키퍼 메모리 상태) · audit-integrity(감사 무결성).
- 새 redirect: `monitoring:attribution` → fleet-health?view=attribution · `monitoring:cost` → **runtime?view=cost**.
- SECTIONS_WITH_VIEW: fleet-health · runtime · agents · observatory · repositories · operations · ide-shell · planning.

## B. 기능 제거 (dashboard 영향)
1. **Memory OS 주기 consolidation 제거** — full-store LLM consolidation fiber·runtime route·env toggle·prompt/schema·**dashboard projection** 삭제. 남은 것: bounded Librarian 의 producer-declared fact upsert + `valid_until` 지난 행만 GC. **semantic supersession/tombstone 없음** → 만료 전 행은 유지되며 score/clock/model sweep 으로 은퇴 불가. 배포 전 `memory_os_consolidation` 키 제거 필수.
2. **Keeper compaction policy 저작 UI 제거** — profile alias·threshold 표·ratio/message/token 파라미터·env knob·**dashboard controls** 삭제. compaction ratio/message/token gate 는 keeper status/metrics/dashboard config/PATCH 에서 제거, `context_within_budget` FSM 조건도 제거. 관측 이벤트는 `Compaction_started` 하나.
3. **context occupancy = not_observed** — fabricated occupancy·persisted metrics 판독 제거. 현재 스냅샷은 typed `not_observed` occupancy + provider-reported **last-turn usage** 만 별도 노출. `last_model_used = null` placeholder 제거. metrics 행은 `schema="keeper.metrics.v1"` + `record_kind` 필수.
4. **keeper TOML `base=` 상속 제거** — `keeper.base` 미인식 키. 남아있으면 boot 는 되지만 상속값 전부 소실 + warn + `masc_config_unknown_keys_ignored_total` + **dashboard drift 행** + `/health` `keeper_config_schema: config_unknown_keys` (status `blocked`, `operator_action_required: true`).
5. **handoff_rate / Handoff_triggered 제거** (producer 없음). Agent_joined/left 디코더 alias 제거. telemetry store = date-split `.masc/telemetry/YYYY-MM/DD.jsonl` 만.
6. **approval snapshot**: `summary_status.failed.retryable` 제거 → `status` + `reason` 만. 구 스냅샷은 fail-closed.
7. **Goal-loop OODA 완전 은퇴** (2026-07-21 · RFC-0352 Path B): Goal 엔티티·MCP 도구·task 링크는 유지, **scheduler script·server broadcast·dashboard 패널 삭제**. 부활 시엔 새 typed Scheduler 설계.
8. keeper chat wire: 행마다 producer-assigned `id` 필수, typed **`surface`** 식별자만 저장(중복 `source` 레인 라벨 제거).
9. Fusion board 메타: `origin.source` / `origin.fusion_run_id` 가 유일 identity — 없으면 Board evidence/Fusion 표면에 미수용.
10. Provider Failover 여전히 ❌ (수동 편집+재시작). CODE/IDE ❌, TUI ❌ 유지.

## C. 기능 추가 / 변경
- **Internal Agents** (monitoring) · **감사 무결성**(lab, per-keeper audit hash-chain) 신규 섹션.
- **Cost ledger 재설계**: date-split `.masc/costs/YYYY-MM/DD.jsonl`, runtime-owned identity `(trace_id, keeper_turn_id, oas_turn_ordinal)` 정확 일치 병합(타임스탬프/토큰 근사 dedupe 없음), `masc-cost --json` 은 `status`→**`state`**, `by_agent[]` 은 여러 모델 걸친 집계에 `model` 미노출. malformed/중복은 명시적 diagnostic. → runtime?view=cost.
- **Gate 상태 소유**: `.masc/gate/` (BasePath 기반). Always Allowed 규칙 저장소 손상 시 exact-rule lookup 만 degrade. Auto Judge 는 outer-turn causal context 를 그대로 영속, retryable judgment 는 재시작 없이 provider attempt 로 재개.
- **Keeper tool admission**: identity-translated `Execute`/`WebSearch`/`WebFetch` 는 public descriptor validation 이 단일 schema Gate.
- **Prompt override 영속화**: prompt body SHA256 revision + template-variable contract 에 바인딩된 schema-versioned envelope. legacy/malformed/contract-drift = fail-closed + 관측 가능한 fallback, 원자적 쓰기, dashboard set/clear 는 영속 성공 후 커밋.
- **stream idle timeout floor 600s** (env/toml 미설정 시). boot log 가 effective 값과 출처를 명시.
- keeper failure reason: `fiber_unresolved(unexpected)` · `graceful_shutdown` · `cancelled_by_parent`.
- recall injection ledger **schema v3** — 필수 typed `reset` 마커, keeper process 첫 행이 replay 상태 리셋. v2 거부.
- host FD pressure override 는 `MASC_HOST_FD_PRESSURE_STATE_FILE` 하나 (+ `--base-path`).
- workspace root marker = `.masc/root-state.json` 만.
- config 카탈로그: AGENT_CORE embedded catalog + `agent-core-models-overlay.toml` (deployment-local rows). `MASC_MODEL_CATALOG` discovery 제거, `MASC_MODEL_CATALOG` 만 명시적 override.
- README 신규 언급: `prompts/keeper.world.md` = 모든 keeper 에 주입되는 공용 **World prompt**; `personas/<name>/profile.json` overlay (replace-if-non-empty).
