# RFCs — masc

이 디렉토리는 masc 의 설계 RFC(Request for Comments) 를 보관한다. 새 RFC 를 작성하기 전 본 README 의 §정책 + §Frontmatter 표준 을 읽고 진행한다.

## 정책

- **번호 (발급 안 함)**: 번호 할당 메커니즘(`.next-number` ledger / `rfc-allocate-next.sh` allocator / number-collision guard)은 제거됐다. 전역 monotonic 카운터가 stale-base 동시 PR 간 TOCTOU 충돌원이었다(두 PR 이 같은 번호를 claim 후 둘 다 머지 — 시즌 5회). 신규 RFC 는 번호를 발급받지 않고 의미 있는 slug 파일명을 쓴다. slug 는 공유 가변 할당이 없어 충돌 클래스 자체가 사라진다. **기존 번호 RFC (`RFC-NNNN-*.md`) 는 그대로 유지** (rename 없음); 본 README 의 번호 인덱스 표와 cross-reference 도 유지된다.
- **파일명**: 신규 RFC 는 `RFC-<slug>.md` (예: `RFC-keeper-background-wait-tool.md`). slug 는 소문자/숫자/하이픈. 기존 번호 RFC 는 `RFC-NNNN-kebab-case-title.md` 유지.
- **Multi-phase RFC**: 한 RFC 가 phase 별 sub-document 를 가질 수 있다 (예: `RFC-NNNN-main-topic.md` + `RFC-NNNN-phase-5-followup.md`). 같은 번호를 공유하는 것은 *번호 충돌이 아니다* — 본문에서 main spec 을 cross-reference 하면 된다.
- **상태 이행**: Draft → (구현 중 작업 PR) → Implemented (Phase 별 closeout PR 머지 후) 또는 Withdrawn / Superseded. Status 갱신은 본문 frontmatter + (선택) 별도 closeout commit 으로 한다.
- **Superseded RFC**: 본문 상단에 `superseded_by: NNNN` 명시 + main spec 본문 §1 ~ §2 에 supersede 이유 1 단락 이상.
- **인덱스 갱신**: `python3 scripts/rfc-generate-index.py --update` 로 frontmatter 기반 자동 생성. 신규 RFC 작성 / Status 이행 후 실행. CI에서 `--check` 로 검증.

## Frontmatter 표준 (신규 RFC 부터 강제)

새 RFC 는 본문 1번째 `#` 헤더 위에 다음 YAML frontmatter 를 둔다. 기존 RFC retroactive 적용은 강제하지 않는다 — 의미 손실 위험 회피.

```yaml
---
rfc: "0070"                        # zero-pad 4자리 문자열 (YAML 1.1 octal 회피), 파일명의 NNNN 과 일치
title: "Short Imperative Title"
status: Draft                      # Draft | Active | Implemented | Superseded | Withdrawn
created: 2026-05-12                # ISO date
updated: 2026-05-12                # 본문 의미 변경 시 갱신, typo 수정은 생략 가능
author: <github-handle 또는 vincent>
supersedes: []                     # ["0042", "0055"] 형식 (문자열). 없으면 빈 배열
superseded_by: null                # "NNNN" 문자열 또는 null
related: ["0042", "0046"]          # 직접 참조 RFC 문자열. 없으면 빈 배열
implementation_prs: []             # [14181, 14550] 형식 (정수). RFC body 머지 PR 은 제외, spec 구현 PR 만
---
```

### Status 정의

| 값 | 의미 |
|---|---|
| `Draft` | 작성 중. 본문/PR 변경 가능. 구현 시작 전 또는 spec 합의 미완. |
| `Active` | spec 머지 완료, 구현이 진행 중인 RFC. 일부 Phase 가 main 에 들어갔으나 전체 closeout 미완. |
| `Implemented` | 모든 Phase 가 main 에 머지 완료. 명시적 `docs(rfc): ... closeout` commit 또는 본문 *Implementation summary* 섹션이 있어야 한다. |
| `Superseded` | 다른 RFC 가 본 RFC 를 대체. `superseded_by` 필드 필수. |
| `Withdrawn` | 작성자/팀 합의로 spec 자체를 폐기. 구현 안 함. |

## RFC 목록

이 표는 RFC 파일의 frontmatter와 제목에서 결정적으로 생성한다. 병합 방식에 따라
바뀌는 commit SHA나 날짜는 저장하지 않는다. Status 컬럼은 명시적 closeout
commit 이 있는 RFC 만 Implemented 로 표기한다 — RFC body 머지는 spec
implementation 머지가 아니므로 다수 RFC 가 `Draft` 로 남아있다.

| RFC | Title | Status | Sub-docs |
|---|---|---|---|
| 0000 | MASC × OAS Consolidated Master Design (SSOT) | Draft | - |
| 0001 | Withdraw heuristic uncertainty governance | Withdrawn | - |
| 0002 | Keeper 11-State Machine + Det/NonDet Boundary Formalization | reference | - |
| 0003 | Withdraw composite lifecycle projection hierarchy | Withdrawn | Phase 2: Turn-Scoped Observation Lifecycle (`RFC-0003-phase-2-turn-observation-lifecycle.md`, reference) |
| 0004 | OCaml ↔ TypeScript shared contract — SSE + gRPC-web | Active | - |
| 0005 | Withdraw the typed command-policy substrate | Withdrawn | - |
| 0006 | Keeper Surface And Sandbox | Draft | - |
| 0008 | Keeper Credential Provider | Draft | - |
| 0009 | Runtime Trust Phase 2: Operator Recommendations + Opt-in Persist | Draft | - |
| 0010 | ocamlformat config reconciliation | Implemented | - |
| 0012 | Mid-Turn Progress Probe | Draft | - |
| 0019 | Keeper Credential Unification | Draft | - |
| 0022 | Withdraw MASC attempt budgets and provider demotion | Withdrawn | - |
| 0024 | Ollama Runtime Integration + KV Cache Optimization | Draft | - |
| 0025 | Tiered Small-Model Runtime (4B → 9B → 70B+) | Draft | - |
| 0027 | Withdraw MASC capability profiles (`RFC-0027-capability-typed-runtime.md`)<br>Retired tension and meta-cognition draft (`RFC-0027-tension-type-safety.md`) | Draft<br>Superseded | - |
| 0029 | Dashboard Fiber-Batched Aggregation | Active | - |
| 0032 | Environment Knob Unification | Draft | - |
| 0034 | v2: Withdraw per-Goal Task caps (`RFC-0034-cap-all-callers.md`)<br>Task Oscillation Mitigation (Cooldown + Severe-Level Human Escalation) (`RFC-0034-task-oscillation-mitigation.md`) | Draft<br>Draft | - |
| 0035 | Cognitive IDE Master Plan Integration | Draft | - |
| 0036 | Multi-Keeper Docker Orchestration & Lifecycle Cleanup (`RFC-0036-multi-keeper-docker-orchestration.md`)<br>oas Cognitive Mapping (companion to RFC-0035) (`RFC-0036-oas-cognitive-mapping.md`) | Draft<br>Draft | - |
| 0037 | Board Multimedia & Vision — Eio/File-Based Adaptation (`RFC-0037-board-multimedia-vision-adapted.md`)<br>Local-first Keeper Enablement: Harness/User Boundary (`RFC-0037-local-first-keeper-enablement-boundary.md`) | Draft<br>Draft | - |
| 0038 | Opaque Identifier Types for Provider, Runtime, Model (`RFC-0038-opaque-identifier-types.md`)<br>Withdraw MASC capability-routing plan (`RFC-0038-runtime-routing-intent-preservation.md`) | Draft<br>Withdrawn | Withdraw identity-alias migration (`RFC-0038-phase-2-keeper-identity-canonical.md`, Withdrawn) |
| 0041 | Withdraw runtime group/item hierarchy | Withdrawn | - |
| 0042 | Withdraw Keeper terminal-reason hierarchy | Withdrawn | - |
| 0043 | Distribute legacy metrics backend metric ownership to domain modules | Active | - |
| 0044 | Typed persistence read-drop reason + Result-based reads | Active | - |
| 0045 | SDK turn boundary alignment with MASC keeper FSM | Draft | - |
| 0046 | Keeper Detail FSM Hub as SSOT | Active | - |
| 0047 | `oas_*` adapter family decomposition (consumer-only OAS boundary) | Draft | - |
| 0049 | Dashboard Surface Telemetry Foundation | Draft | - |
| 0050 | Dashboard Component Ownership Decomposition | Active | - |
| 0051 | run_named closure decomposition | Active | - |
| 0052 | Boot-time Required Invariants (typed) | Implemented | - |
| 0053 | Tool Dispatch Session-Local Handles | Implemented | - |
| 0054 | Withdraw code generation for command-policy GADTs | Withdrawn | - |
| 0056 | Incremental Sub-Library Extraction from Flat masc Library | Active | - |
| 0057 | Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation | Draft | - |
| 0058 | Withdraw terminal capability hierarchy | Withdrawn | Withdraw provider-variant migration plan (`RFC-0058-phase-5-erase-provider-variant.md`, Withdrawn) |
| 0062 | Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class (Reverse-Engineered Initi... | Draft | - |
| 0063 | Telemetry Feedback Loop & Cooperative Scheduling Safety | Draft | - |
| 0064 | Capacity Probe Adapter (`RFC-0064-capacity-probe-adapter.md`)<br>Descriptor-Owned Tool Surface (`RFC-0064-two-surface-tool-alias.md`) | Active<br>Superseded | - |
| 0065 | Withdraw policy-bearing tool-selection model | Withdrawn | - |
| 0067 | Goal-Scope Observation→Claim Atomicity | Draft | - |
| 0068 | Withdraw operator disposition hierarchy | Withdrawn | - |
| 0069 | Awareness Channel Split | Active | - |
| 0070 | Keeper Sandbox Runtime — Pure/Edge Separation | Active | - |
| 0071 | Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern | Implemented | - |
| 0072 | Type-encoded keeper sub-FSM transitions (runtime + turn_phase) | Implemented | - |
| 0073 | Withdraw pre-turn tool readiness filtering | Withdrawn | - |
| 0074 | Sandbox Credential Auto-provision | Retired | - |
| 0075 | Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate | Implemented | - |
| 0076 | Tool Readiness Notification Channel | Retired | - |
| 0077 | Write-side silent failure — typed propagation | Implemented | - |
| 0079 | Log row typed encoder + silent-drop removal | Implemented | - |
| 0080 | Registered descriptors are the tool-surface SSOT | Implemented | - |
| 0081 | OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline | Implemented | - |
| 0082 | Withdraw automatic blocker escalation and recovery | Withdrawn | - |
| 0083 | Dashboard system-actor convention typed unification | Implemented | - |
| 0084 | Tool dispatch handler and observation unification | Implemented | - |
| 0086 | Keeper namespace bulk promotion to sub-library | Implemented | - |
| 0087 | Tool Dispatch Path Unification + Legacy Purge | Implemented | - |
| 0088 | Counter-as-Fix → Result Propagation (umbrella scoping) | Active | - |
| 0089 | String Classifier to Typed Variant — direct replacement, no lint | Implemented | - |
| 0090 | Write-side success-model attribution — finish N-of-M migration | Implemented | - |
| 0091 | Execute tool: cmd string → typed Argv schema (lexer/validator 박멸) | Implemented | - |
| 0093 | Board persistence identity and atomic snapshot | Implemented | - |
| 0094 | Compact cooldown semantics split decision record | Superseded | - |
| 0095 | Provider-D-compat provider streaming wire-up | Implemented | - |
| 0096 | Keeper Turn Contract — multi-turn reasoning + runtime SPOF root-fix | Withdrawn | - |
| 0097 | Keeper sandbox container reuse (long-running sandbox per keeper) | Active | - |
| 0098 | Typed JSON-RPC error envelope & production-code silent-failure lint | Implemented | - |
| 0099 | Session lifecycle — typed events, explicit eviction, resume backpressure | Active | - |
| 0100 | Streamable HTTP as default transport (MCP 2025-03-26) | Active | - |
| 0101 | FD accountant — observation across process resource classes | Active | - |
| 0102 | Pre-turn runtime availability gate — reuse, not new surface | Superseded | - |
| 0103 | Log retention opt-in + JSONL volume root reduction | Draft | - |
| 0104 | Withdraw Task-to-repository authorization | Withdrawn | - |
| 0105 | OpenAI-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope | Implemented | - |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | - |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker ... | Active | Phase C.0 — `Eio_context.get_switch_opt` global access audit (`RFC-0107-eio-context-switch-audit.md`, Evidence)<br>Phase D — Connection pool design (interface-first) (`RFC-0107-phase-d-pool-design.md`, Active) |
| 0108 | Atomic JSONL Append (in-process) (`RFC-0108-atomic-jsonl-append.md`)<br>PR / Worktree Operation Safety Gates (`RFC-0108-pr-worktree-operation-safety-gates.md`) | Active<br>Implemented | - |
| 0109 | CDAL x Goal Integration Contract | Withdrawn | - |
| 0110 | Tool-pair atomicity at write boundary — sunset compaction repair fabrication | Superseded | - |
| 0111 | Goal mint atomicity — auto-goal uniqueness invariant at write boundary | Implemented | - |
| 0112 | Typed JSON parse boundary — eliminate silent-drop fallback across read sites | Implemented | - |
| 0113 | Withdraw KeeperReactionLiveness runtime hierarchy | Withdrawn | - |
| 0114 | Withdraw compact-retry and lifecycle guard model | Withdrawn | - |
| 0115 | KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_... | Implemented | - |
| 0116 | Withdraw fallback-count cap | Withdrawn | - |
| 0117 | Withdraw runtime health cooldown hierarchy | Withdrawn | - |
| 0118 | Withdraw terminal runtime projection contract | Withdrawn | - |
| 0119 | Withdraw lifecycle projection mapping hierarchy | Withdrawn | - |
| 0120 | Cross-spec set-name divergence — 3-class classification framework (STALE / DE... | Implemented | - |
| 0121 | Config-dir resolution — single active root, no implicit fallback | Active | - |
| 0122 | Keeper disk pressure — process-local fleet failure mode beyond FD | Implemented | - |
| 0123 | Briefing last_event fabrication — option-typed write boundary | Implemented | - |
| 0124 | Withdraw fleet resource admission denial | Withdrawn | - |
| 0125 | Withdraw Keeper watchdog and force-release discipline | Withdrawn | - |
| 0126 | Silent fallback discipline (typed split for option/result wildcard arms) | Implemented | - |
| 0127 | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | - |
| 0129 | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | - |
| 0131 | Withdraw policy-bearing shell command facade | Withdrawn | - |
| 0132 | Redaction SSOT — `runtime` boundary-label private type | Implemented | - |
| 0133 | Keeper Phase Casing SSOT Consolidation | Implemented | - |
| 0134 | Persistence read-drop root fix (recovery story for RFC-0044) | Active | - |
| 0135 | Supersede dashboard-derived Keeper disposition | Superseded | - |
| 0136 | Keeper Unified Turn — Stage Decomposition of run_keeper_cycle | Implemented | Keeper Unified Turn — Phase 4: Retry Loop Body Decomposition (`RFC-0136-phase-4-retry-loop.md`, Active) |
| 0137 | Host FD pressure observation — retired Keeper-pause proposal | Retired | - |
| 0138 | Dashboard Snapshot Lock-Free Immutable Architecture | Implemented | - |
| 0139 | Withdraw parallel agent and judge status hierarchies | Withdrawn | - |
| 0140 | Dashboard wire codec for source observations | Implemented | - |
| 0141 | TOML Field Resolution Typed Variant for repo_manager | Implemented | - |
| 0142 | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | - |
| 0143 | keeper_runtime_profile Typed Catalog Query Result | Active | - |
| 0144 | Withdraw recording-error dedup and metric sunset gates | Withdrawn | - |
| 0145 | Permissive-Silent-Fallback Elimination | Active | - |
| 0147 | Withdraw decomposition around deleted Keeper policy stages | Withdrawn | - |
| 0148 | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | - |
| 0149 | Audit-Driven Telemetry-as-Fix Sunset | Implemented | - |
| 0150 | Keeper Attention Signal — backend 단일 typed wire envelope | Implemented | - |
| 0151 | 4-metric monotone-decrease ratchet for code-smell metrics | Withdrawn | - |
| 0153 | Withdraw runtime tier admission | Withdrawn | - |
| 0154 | System_error_class typed SSOT — close substring-classifier loop across backen... | Implemented | - |
| 0155 | Withdraw centralized operational policy log taxonomy | Withdrawn | - |
| 0156 | Withdraw MASC turn-budget timeout policy | Withdrawn | - |
| 0157 | Withdraw MASC pre-dispatch provider capability filtering | Withdrawn | - |
| 0158 | Withdraw MASC retry-admission denial | Withdrawn | - |
| 0159 | Reason_internal_error typed split — close string-classifier catch-all | Draft | - |
| 0160 | Withdrawn Shell IR decision-substrate plan | Withdrawn | - |
| 0161 | Tool Error Hint Symmetry Enforcement | Draft | - |
| 0162 | JSONL Write-Path FD Pressure Root-Fix | Draft | - |
| 0163 | Tier-group capability profile route canonicalization — typed dedup and bypass... | Withdrawn | - |
| 0164 | Withdraw voice exceptions to provider capability filtering | Withdrawn | - |
| 0167 | Withdrawn product-specific runtime authorization cleanup | Draft | - |
| 0168 | Dashboard upstream-LLM-provider color palette purge | Draft | - |
| 0169 | Dashboard common/* MCP-client attribution header purge | Draft | - |
| 0170 | Dashboard provider-b palette closure (RFC-0168 N-of-M follow-up) | Draft | - |
| 0171 | Design-canvas + ui_kits mock data vendor purge | Draft | - |
| 0172 | Big-bang vendor purge across docs, audits, RFCs, design-system, tests | Draft | - |
| 0173 | OCaml lib/bin/test vendor purge (identifier + string literal) | Draft | - |
| 0174 | Dashboard substring classifier to typed — TypeScript | Draft | - |
| 0175 | Godfile decomposition Wave D — keeper core 5-file split | Draft | - |
| 0176 | OAS vendor-purge migration — consume agent_sdk 0.198.0 | Implemented | - |
| 0177 | Phonebook internal vendor-coupled enum purge | Draft | - |
| 0178 | Types Sub-library Extraction with `_intf.ml` mli-only Surface (typed-SSOT) | Draft | - |
| 0179 | ToolDescriptor Ecosystem Coverage Extension to Workspace Tools | Draft | - |
| 0180 | 24h Runtime ERROR 7-Pattern Sweep Roadmap | Draft | - |
| 0181 | Withdraw MASC capability-intent routing | Withdrawn | - |
| 0182 | masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation | Draft | - |
| 0184 | Runtime phonebook typed roundtrip for protocol/flavor/provider identifiers | Draft (Deferred) | - |
| 0189 | Typed Tool_result.result variant — eliminating boolean blindness in tool disp... | Draft | - |
| 0190 | Descriptor as Visibility/Metadata SSOT — Surface Projection from descriptor.p... | Draft | - |
| 0191 | Withdraw descriptor authorization policy | Withdrawn | - |
| 0192 | Runtime deadline propagation — retired admission-wait proposal | Retired | - |
| 0194 | Withdraw tool semantics as an authorization SSOT | Withdrawn | - |
| 0197 | Runtime Attempt Watchdog — Per-Candidate Wrap + Shared Deadline | Draft | - |
| 0198 | Execute Typed Redirection (Shell IR Syntax Leakage Closure) | Draft | - |
| 0199 | Withdraw deterministic task-completion auto approval | Withdrawn | - |
| 0200 | Time constants 를 leaf library 로 분리 | Draft | - |
| 0201 | Activity Events Wait-Free Snapshot | Draft | - |
| 0203 | In-process Discord connector | Implemented (Phase 3 cutover landed 2026-05-29) | - |
| 0204 | Dashboard Read Serving Isolation from Fleet Compute | Draft | - |
| 0205 | Keeper Module Consolidation — Eliminate Facade Anti-Pattern | Draft | - |
| 0206 | Runtime 개념 — runtime→Runtime 재탄생 | Draft | - |
| 0207 | Per-keeper LLM runtime routing | Draft | - |
| 0208 | Withdrawn compositional Shell IR policy algebra | Withdrawn | - |
| 0210 | Keeper Playground Repo Currency (fetch + fast-forward, work-preserving) | Draft | - |
| 0211 | Persona ⊥ {model, runtime}, opaque runtime id, runtime.toml keeper-assignment... | Draft | - |
| 0212 | Withdraw Keeper exposure policy axis | Withdrawn | - |
| 0213 | Keeper sandbox/playground isolation model (fix sandbox_repo_not_ready + macOS... | Draft | - |
| 0214 | OTel GenAI Semantic Convention Migration | Draft | - |
| 0215 | Keeper sub-library extraction campaign — sequence and per-PR gates | Draft | - |
| 0216 | Per-Keeper Decline Memory (orphan-task churn root fix) | Draft | - |
| 0217 | Telemetry Backend Otel 단일화 (Retired Backend Purge) | Draft | - |
| 0218 | Keeper tool-surface coherence + web-tooling roadmap — phases and per-phase gates | Draft | - |
| 0219 | Remove Sandbox Repo Patrol Gates | Draft | - |
| 0220 | Withdraw cross-Keeper verification scheduling | Withdrawn | - |
| 0221 | Atomic verification submission — task_status as the sole outcome authority | Implemented (steps 1-3 merged #20613/#20617; steps 4-5 measured then dropped, §3.3/§3.4) | - |
| 0222 | Withdraw harness-owned Task completion | Withdrawn | - |
| 0223 | Typed connector surfaces: presence in world prompt, pull-based lane context, ... | Draft | - |
| 0224 | Withdraw the mandatory structured completion checklist | Withdrawn | - |
| 0225 | Per-keeper turn single-flight admission | Draft | - |
| 0226 | Ambient lane recording: record-vs-trigger decouple for connector surfaces | Draft | - |
| 0228 | Paged lane pull + fact-retention harness: digest without a summarizer | Draft | - |
| 0229 | Keeper person notes: deliberate per-speaker memory beyond the log window | Draft | - |
| 0230 | Keeper mention/scope reactivity: cursor-free salience to complement pull-base... | Draft | - |
| 0232 | Typed lane event model: parse at the write boundary, never re-derive by strin... | Draft | - |
| 0233 | Typed turn observability: TurnRecord prompt-block provenance + canonical tool... | Draft | - |
| 0234 | Withdraw schedule-specific approval hierarchy | Withdrawn | - |
| 0235 | Stale-base revert guard: block PRs that silently revert recently-merged work (`RFC-0235-stale-base-revert-guard.md`)<br>Voice output transport: browser-addressed audio delivery with device-routed p... (`RFC-0235-voice-output-browser-transport-device-routing.md`) | Draft<br>Draft | - |
| 0236 | Voice input transport: browser-captured speech-to-text for the dashboard comp... | Draft | - |
| 0237 | Eliminate the write_meta ~force escape hatch (route snapshot writes through C... | Draft | - |
| 0239 | Concurrency ownership model (per-site mutex/atomic → protection by construction) (`RFC-0239-concurrency-ownership-model.md`)<br>Supersede no-progress pause and semantic debounce guards (`RFC-0239-semantic-identity-guards-for-keeper-memory-and-anti-thrash.md`) | Draft<br>Superseded | - |
| 0240 | Tool-pair invariant enforced at write-time (eliminate repair-on-read) | Draft | - |
| 0241 | external-attention store lifecycle: read-side bound, retention, and typed tai... | Retired | - |
| 0242 | Retired continuity prose-filter draft | Superseded | - |
| 0243 | Memory OS confidence mutability via write-side fact upsert | Draft | - |
| 0244 | Memory OS recall: turn-seeded deterministic lexical retrieval, with provenanc... | Superseded | - |
| 0245 | Exempt goalless tasks from the per-goal WIP claim cap | Withdrawn | - |
| 0247 | Memory OS as a brain: typed associative graph, spreading-activation recall, s... | Draft | Memory OS purge + LLM-judgment rebuild — implementation plan (phase of RFC-0247) (`RFC-0247-purge-implementation-plan.md`, Draft) |
| 0248 | Board context without local authority classification | Draft | - |
| 0249 | Remove the dead `stale_factor` field (execute RFC-0239/0243/0244/0247) | Draft | - |
| 0251 | Memory OS: record well, do not value — remove the scoring layer | Draft | - |
| 0252 | Fusion: 패널+심판(panel+judge) 심의 루프 (MASC 내장) | Draft | - |
| 0253 | Dashboard keeper-v2 surfaces: canonical spacing/radius token scale + off-scal... | Draft | - |
| 0254 | Shell IR Approval Gate — Autonomous Production Policy | Withdrawn | - |
| 0255 | Withdraw inferred argv path policy | Withdrawn | - |
| 0256 | Migrate hand-rolled Mutex lock/protect/unlock to Mutex.protect | Draft | - |
| 0257 | Per-Keeper memory execution lane | Draft | - |
| 0259 | Memory OS — Volatile Claim Grounding, Retraction & Decay | Draft | - |
| 0260 | Withdraw MASC provider-health gate | Draft | - |
| 0261 | gRPC LSP failed-initialize FD/process teardown | Draft | - |
| 0262 | Withdraw hierarchical Task-completion authority | Withdrawn | - |
| 0263 | Withdraw actor-priority turn preemption | Withdrawn | - |
| 0264 | Memory OS recall outcome-anchored eval harness | Draft | - |
| 0265 | Withdraw MASC modality capability rerouting | Withdrawn | - |
| 0266 | Fusion async-completion wake + in-progress 가시성 | Draft | - |
| 0267 | Make task↔goal links visible and explicitly assignable | Draft | - |
| 0269 | Process Critic Loop for Keeper Work Traces | Draft | - |
| 0270 | CI Gate merge guard: block merges on a non-success CI Gate and trip on red main | Draft | - |
| 0271 | Withdraw progress-based turn rejection and pause | Withdrawn | - |
| 0272 | Memory OS — Episode Log Retention (bounded append for events.jsonl / episodes) | Draft | - |
| 0273 | Withdraw policy-bearing Keeper configuration tiers | Withdrawn | - |
| 0274 | Workspace base_path SSOT — retire env runtime read, thread Workspace.config | Draft | - |
| 0275 | Retired cognitive-triple removal record | Implemented | - |
| 0276 | Remove Keeper social-model self-report protocol | Implemented | - |
| 0277 | Fusion: 이종 패널 그룹(heterogeneous panel groups) + 발동 예산 제거 | Draft | - |
| 0278 | Fusion: 같은 model을 다른 prompt로 (same-model panels via panel labels) | Draft | - |
| 0279 | Withdraw completion-contract result taxonomy | Withdrawn | - |
| 0280 | Fusion: validated preset type (Parse, don't validate) | Draft | - |
| 0281 | WebSocket transport SSOT — separate upgrade-attachment from session-protocol,... | Draft | - |
| 0282 | Reduce Keeper persona to ordinary instructions | Implemented | - |
| 0283 | Fusion: judge-of-judges 위상 (flat/staged reducer) | Draft | - |
| 0284 | Fusion 심판 실행 관측 record (judge observation record) (`RFC-0284-fusion-judge-observation-record.md`)<br>Goal-loop status SSE liveness — server-side change detection extends the goal... (`RFC-0284-goal-loop-sse-liveness.md`)<br>Supersede command-semantics guidance guards (`RFC-0284-keeper-guidance-visibility-drift-guard.md`) | Draft<br>Superseded — RFC-0352 Path B (2026-07-21). The goal-loop OODA<br>Superseded | - |
| 0285 | Memory OS — Self-Observation Claim Volatility (closing RFC-0259's internal-st... | Draft | - |
| 0286 | Superseded exec and Keeper boundary diagnosis | Superseded | - |
| 0287 | ws-direct — a single masc-owned WebSocket stack for server and client | Draft | - |
| 0288 | Remove per-Keeper goal-horizon fields | Implemented | - |
| 0289 | Extract progress-classification into its own library for a single substantive... | Draft | - |
| 0290 | Generic keeper background-work tool (spawn → wake-on-completion) | Draft | - |
| 0291 | Closed SSE event-type sum + typed broadcast — RFC-0004 Phase A0 Wave 2 increment | Draft | - |
| 0292 | Complete lib/auth de-duplication — remove drifted Masc.Auth* test copies | Draft | - |
| 0293 | Withdraw policy-bearing execution endpoints | Withdrawn | - |
| 0294 | Remove workspace Goal horizon | Implemented | - |
| 0295 | Withdraw derived fleet runtime bands | Withdrawn | - |
| 0296 | CI skip-gate main-push safety-net: always run Build and Test on non-PR events | Draft | - |
| 0298 | fusion judge pool — judge 모델을 preset에서 분리 | Draft | - |
| 0299 | RFC-0299 — Typed-Boundary Sweep (string-classifier → closed-sum, dead SSOT re... | Draft | - |
| 0300 | RFC-0300 — Dashboard design-token scope consolidation (radius / shadow / type... | Draft | - |
| 0301 | Keeper 생성 미디어(이미지/오디오) 대시보드 노출 | Draft | - |
| 0302 | Keeper 메모리 파일 I/O off-main-domain 오프로드 (HOL fix) | Draft | - |
| 0303 | Keeper wake without progress heuristics | Draft | - |
| 0304 | Withdraw Critical-class HITL escalation | Withdrawn | - |
| 0305 | Withdraw global fail-closed governance policy | Withdrawn | - |
| 0306 | Typed, comment-preserving fusion settings editor | Draft | - |
| 0307 | Mid-turn advisor consult for keepers — evaluation and deferral | Draft | - |
| 0308 | Withdraw verifier-required Task routing | Withdrawn | - |
| 0309 | Withdrawn product-specific capability hierarchy | Withdrawn | - |
| 0311 | Withdraw deterministic evidence floors | Withdrawn | - |
| 0312 | Keeper repo mappings are advisory default scope, not access caps | Accepted | - |
| 0315 | Typed wake-turn context and self-directed work lane | Active | - |
| 0316 | Merge gating convergence: enforce_admins=true + live Branch Protection Watchdog | Draft | - |
| 0317 | In-process Slack connector (Socket Mode) | In progress (PR-1/PR-2 landed; PR-3 implemented; PR-4 sidecar removal pending) | - |
| 0318 | Replace risk-tier auto approval with request-local Auto Judge | Withdrawn | - |
| 0319 | Replace hierarchical approval modes with Keeper Gate choices | Withdrawn | - |
| 0320 | Keeper connector-aware continuation: carry the originating channel through wa... | Draft | - |
| 0321 | Withdraw unconditional static tool-block proposal | Withdrawn | - |
| 0322 | Withdraw repository-catalog read authorization | Withdrawn | - |
| 0323 | Withdraw mandatory cross-verifier completion | Withdrawn | - |
| 0324 | keeper repo 경로를 filesystem 진실로 (catalog 거짓 주입 제거) | Draft | - |
| 0328 | Retire the combined governance and perseveration incident plan | Withdrawn | - |
| 0329 | Keeper Execute Governance Payload Mapping | Rejected | - |
| 0331 | Withdraw authorization by tool effect class | Withdrawn | - |
| 0332 | Rejected heuristic memory write dedup draft | Rejected | - |
| 0333 | Deterministic cost↔success frontier join for the eval harness | Draft | - |
| 0334 | Board signals as durable Keeper input | Draft | - |
| 0335 | TOML as the Single Settings Source | Draft | - |
| 0337 | Withdraw deterministic evidence-gate semantics | Withdrawn | - |
| 0338 | Lane-per-keeper durable persistence isolation | Draft | - |
| 0340 | Dashboard dev-token privilege reduction — demote from Admin, close the rebind... | Draft | - |
| 0341 | Keeper lifecycle projection SSOT | Draft | - |
| 0342 | Capability catalog overlay, deployment capability declarations, and boot posture | Draft | - |
| 0343 | Repo location SSOT (collapse dual-authority, attribute by git-remote) | Draft | - |
| 0345 | Streaming idle-timeout fail-safe floor (#25128) | Draft | - |
| 0346 | Gateway redelivery dedup: transcript single-authority, attention as wake-hint | Draft | - |
| 0347 | Typed EffectIntent + capability floor at the Keeper Gate | Draft | - |
| 0348 | Bounded lane acquisition for durable keeper_msg writes (#25398) | Draft | - |
| 0349 | Restore a reachable compaction admission path | Draft | - |
| 0350 | Unbounded request-fiber admission (durable queue + lifecycle-sibling worker +... | Draft | - |
| 0351 | Memory-first context management and compaction sunset | Draft | - |
| 0352 | Legacy Goal: RFC-0000 §3.2 ↔ §3.15 자기모순 해소 (결정 요청) | Draft | - |
| 0353 | 실패 분류가 모듈 경계에서 소실되는 결함 (결정 요청) | Draft | - |
| 0356 | Approval owns the effect (replay the approved payload, do not require byte-id... | Draft | - |
| 0357 | Scheduled-autonomous 턴은 heartbeat가 아니라 typed stimulus의 변화로 admit한다 | Draft | - |
| RFC-0034d-stale-agent-sync | d — release_stale_claims agent-side sync | Draft | - |
| RFC-async-log-sink-durable-append-offload | Offload the structured-log durable append off the emitting fiber | Draft | - |
| RFC-checkpoint-pinned-root-containment | Immutable boot-pinned root capability for checkpoint containment | Draft | - |
| RFC-compaction-deterministic-floor | Compaction must never deadlock: a deterministic structural floor, typed outco... | Draft | - |
| RFC-connector-ambient-attention-wake | Connector ambient attention wake: drive an idle keeper turn from external-att... | Draft | - |
| RFC-connector-deferred-reply-via-chat-queue | Durable Keeper chat receipts and connector delivery settlement | Active | - |
| RFC-eliminate-substring-destructive-classifier | Withdrawn command-policy classification experiment | Withdrawn | - |
| RFC-keeper-conversation-hitl-flow | # RFC: Keeper conversation and non-blocking HITL | Draft | - |
| RFC-keeper-media-degrade-floor | # RFC: Withdraw silent media degradation | Draft | - |
| RFC-keeper-memory-bank-write-reduction | Keeper memory-bank near-dup accumulation — write reduction, not write-boundar... | Superseded | - |
| RFC-keeper-memory-consolidation | Keeper durable memory consolidation — deprecate memory_bank into Memory OS | Implemented | - |
| RFC-keeper-memory-panel-real-data | Keeper memory panel: real-data backing (no fabrication, no score resurrection) | Superseded | - |
| RFC-keeper-runtime-context-observation-phase0 | Keeper runtime context observation Phase 0 | Draft | - |
| RFC-keeper-vision-delegation-tool | Vision-as-a-tool delegation (decouple multimodal input from conversation runt... | Draft | - |
| RFC-memory-os-bounded-context-and-librarian-curator | # RFC: Memory OS 2.0 — bounded working set 전송 계약과 librarian curator 계약 | Draft | - |
| RFC-runtime-note-field-and-dashboard-surfacing | Per-runtime note field & dashboard surfacing | Draft | - |
| RFC-typed-egress-resource-capability | Withdraw product-specific egress effect classification | Withdrawn | - |

### 신규 RFC

신규 RFC 는 번호를 발급받지 않는다 (번호 allocator 제거됨 — 전역 카운터 TOCTOU 회피). 의미 있는 slug 파일명 `RFC-<slug>.md` 로 작성한다. 본 표는 기존 번호 RFC 와 신규 slug RFC 를 함께 추적한다.

## 검색 / 발견

- 단일 RFC: `cat docs/rfc/RFC-NNNN-*.md`
- 키워드 검색: `rg <keyword> docs/rfc/`
- 본 README 의 표로 RFC 발견 및 상태 확인. 최근 활동은 해당 RFC 파일의 `git log`로 확인
- PR 작성 시 RFC 발견 체크: `bash ~/me/scripts/pr-rfc-check.sh --pr-body /tmp/pr-body.md`

## 비범위 (향후 별도 RFC)

- Frontmatter 자동 lint (CI hook)
- 기존 RFC retroactive frontmatter 통일
- Status sweep 전면 audit (Draft → Withdrawn 후보 식별)
