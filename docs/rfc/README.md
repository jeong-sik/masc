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

데이터 수집 시점: 2026-05-12. `Last activity` 는 해당 RFC 디렉토리 파일의 마지막 git commit. Status 컬럼은 명시적 closeout commit 이 있는 RFC 만 Implemented 로 표기한다 — RFC body 머지는 spec implementation 머지가 아니므로 다수 RFC 가 `Draft` 로 남아있다.

| # | Title | Status | Last activity | Sub-docs |
|---|---|---|---|---|
| 0000-MASTER-ROADMAP | MASC × OAS Consolidated Master Design (SSOT) | Draft | 34d5da45d5 2026-07-23 | - |
| 0001-det-nondet-boundary-harness | Withdraw heuristic uncertainty governance | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0002-keeper-state-machine | Keeper 11-State Machine + Det/NonDet Boundary Formalization | reference | 7b62a87d44 2026-07-13 | - |
| 0003-keeper-composite-lifecycle | Withdraw composite lifecycle projection hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | RFC-0003-phase-2-turn-observation-lifecycle.md |
| 0004-shared-contract-ocaml-ts | OCaml ↔ TypeScript shared contract — SSE + gRPC-web | Active | 03d5feaf25 2026-07-08 | - |
| 0005-typed-capability-substrate | Withdraw the typed command-policy substrate | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0006-keeper-surface-and-sandbox | Keeper Surface And Sandbox | Draft | 03d5feaf25 2026-07-08 | - |
| 0008-credential-provider | Keeper Credential Provider | Draft | 03d5feaf25 2026-07-08 | - |
| 0009-runtime-trust-phase2 | Runtime Trust Phase 2: Operator Recommendations + Opt-in Persist | Draft | 03d5feaf25 2026-07-08 | - |
| 0010-ocamlformat-config-reconciliation | ocamlformat config reconciliation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0012-mid-turn-progress-probe | Mid-Turn Progress Probe | Draft | 03d5feaf25 2026-07-08 | - |
| 0019-keeper-credential-unification | Keeper Credential Unification | Draft | 03d5feaf25 2026-07-08 | - |
| 0022-runtime-attempt-liveness | Withdraw MASC attempt budgets and provider demotion | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0024-ollama-runtime-integration | Ollama Runtime Integration + KV Cache Optimization | Draft | 03d5feaf25 2026-07-08 | - |
| 0025-tiered-small-model-runtime | Tiered Small-Model Runtime (4B → 9B → 70B+) | Draft | 03d5feaf25 2026-07-08 | - |
| 0027-capability-typed-runtime | Withdraw MASC capability profiles | Draft | 7b62a87d44 2026-07-13 | - |
| 0027-tension-type-safety | Retired tension and meta-cognition draft | Superseded | 434a7f5a76 2026-07-10 | - |
| 0029-dashboard-fiber-batched-aggregation | Dashboard Fiber-Batched Aggregation | Active | 03d5feaf25 2026-07-08 | - |
| 0032-env-knob-unification | Environment Knob Unification | Draft | 03d5feaf25 2026-07-08 | - |
| 0034-cap-all-callers | v2: Withdraw per-Goal Task caps | Draft | 7b62a87d44 2026-07-13 | - |
| 0034-task-oscillation-mitigation | Task Oscillation Mitigation (Cooldown + Severe-Level Human Escalation) | Draft | 03d5feaf25 2026-07-08 | - |
| 0034d-stale-agent-sync | d — release_stale_claims agent-side sync | Draft | 03d5feaf25 2026-07-08 | - |
| 0035-cognitive-ide-roadmap | Cognitive IDE Master Plan Integration | Draft | 03d5feaf25 2026-07-08 | - |
| 0036-multi-keeper-docker-orchestration | Multi-Keeper Docker Orchestration & Lifecycle Cleanup | Draft | 03d5feaf25 2026-07-08 | - |
| 0036-oas-cognitive-mapping | oas Cognitive Mapping (companion to RFC-0035) | Draft | 03d5feaf25 2026-07-08 | - |
| 0037-board-multimedia-vision-adapted | Board Multimedia & Vision — Eio/File-Based Adaptation | Draft | 434a7f5a76 2026-07-10 | - |
| 0037-local-first-keeper-enablement-boundary | Local-first Keeper Enablement: Harness/User Boundary | Draft | 03d5feaf25 2026-07-08 | - |
| 0038-opaque-identifier-types | Opaque Identifier Types for Provider, Runtime, Model | Draft | 03d5feaf25 2026-07-08 | - |
| 0038-runtime-routing-intent-preservation | Withdraw MASC capability-routing plan | Withdrawn | 7b62a87d44 2026-07-13 | RFC-0038-phase-2-keeper-identity-canonical.md |
| 0041-runtime-routing-group-item-hierarchy | Withdraw runtime group/item hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0042-keeper-terminal-code-closed-sum | Withdraw Keeper terminal-reason hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0043-metric-ownership-distribution | Distribute legacy metrics backend metric ownership to domain modules | Active | 03d5feaf25 2026-07-08 | - |
| 0044-persistence-read-drop-typed | Typed persistence read-drop reason + Result-based reads | Active | 03d5feaf25 2026-07-08 | - |
| 0045-sdk-turn-boundary-alignment | SDK turn boundary alignment with MASC keeper FSM | Draft | 03d5feaf25 2026-07-08 | - |
| 0046-keeper-detail-fsm-hub-ssot | Keeper Detail FSM Hub as SSOT | Active | 03d5feaf25 2026-07-08 | - |
| 0047-oas-adapter-decomposition | `oas_*` adapter family decomposition (consumer-only OAS boundary) | Draft | 03d5feaf25 2026-07-08 | - |
| 0049-surface-telemetry-foundation | Dashboard Surface Telemetry Foundation | Draft | 03d5feaf25 2026-07-08 | - |
| 0050-component-ownership-decomposition | Dashboard Component Ownership Decomposition | Active | 03d5feaf25 2026-07-08 | - |
| 0051-run-named-closure-decomposition | run_named closure decomposition | Active | 03d5feaf25 2026-07-08 | - |
| 0052-boot-time-required-invariants | Boot-time Required Invariants (typed) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0053-tool-dispatch-session-local-handles | Tool Dispatch Session-Local Handles | Implemented | 03d5feaf25 2026-07-08 | - |
| 0054-shell-ir-ppx-deriving | Withdraw code generation for command-policy GADTs | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0056-incremental-sublib-extraction | Incremental Sub-Library Extraction from Flat masc Library | Active | 03d5feaf25 2026-07-08 | - |
| 0057-tool-descriptor-codegen | Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation | Draft | 7b62a87d44 2026-07-13 | - |
| 0058-terminal-fallback-capability-exemption | Withdraw terminal capability hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | RFC-0058-phase-5-erase-provider-variant.md |
| 0062-typed-tool-result-and-blocker-class | Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class (Reverse-Engineered Initi... | Draft | 03d5feaf25 2026-07-08 | - |
| 0063-telemetry-feedback-loop | Telemetry Feedback Loop & Cooperative Scheduling Safety | Draft | 03d5feaf25 2026-07-08 | - |
| 0064-capacity-probe-adapter | Capacity Probe Adapter | Active | 03d5feaf25 2026-07-08 | - |
| 0064-two-surface-tool-alias | Descriptor-Owned Tool Surface | Superseded | 03d5feaf25 2026-07-08 | - |
| 0065-keeper-tool-selection-tla-coverage | Withdraw policy-bearing tool-selection model | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0067-goal-scope-observation-claim-atomicity | Goal-Scope Observation→Claim Atomicity | Draft | 03d5feaf25 2026-07-08 | - |
| 0068-keeper-turn-disposition-typed | Withdraw operator disposition hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0069-awareness-channel-split | Awareness Channel Split | Active | 361bf75eb5 2026-07-17 | - |
| 0070-keeper-sandbox-pure-edge-separation | Keeper Sandbox Runtime — Pure/Edge Separation | Active | 7b62a87d44 2026-07-13 | - |
| 0071-exhaustive-match-sweep-codemod | Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern | Implemented | 03d5feaf25 2026-07-08 | - |
| 0072-keeper-sub-fsm-transitions-typed | Type-encoded keeper sub-FSM transitions (runtime + turn_phase) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0073-tool-readiness-probe | Withdraw pre-turn tool readiness filtering | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0074-sandbox-credential-auto-provision | Sandbox Credential Auto-provision | Retired | 03d5feaf25 2026-07-08 | - |
| 0075-keeper-tools-smoke | Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate | Implemented | 03d5feaf25 2026-07-08 | - |
| 0076-tool-readiness-notification-channel | Tool Readiness Notification Channel | Retired | 03d5feaf25 2026-07-08 | - |
| 0077-write-side-silent-failure-typed | Write-side silent failure — typed propagation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0079-log-row-typed-encoder | Log row typed encoder + silent-drop removal | Implemented | 03d5feaf25 2026-07-08 | - |
| 0080-tool-registry-ssot | Registered descriptors are the tool-surface SSOT | Implemented | 7b62a87d44 2026-07-13 | - |
| 0081-telemetry-envelope-and-pivot-timeline | OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline | Implemented | 03d5feaf25 2026-07-08 | - |
| 0082-keeper-last-blocker-autoclear-and-recovery-escalation | Withdraw automatic blocker escalation and recovery | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0083-dashboard-system-actor-typed | Dashboard system-actor convention typed unification | Implemented | 03d5feaf25 2026-07-08 | - |
| 0084-keeper-tool-dispatch-unification | Tool dispatch handler and observation unification | Implemented | 7b62a87d44 2026-07-13 | - |
| 0086-keeper-namespace-bulk-promotion | Keeper namespace bulk promotion to sub-library | Implemented | 1fe1daf0e5 2026-07-16 | - |
| 0087-tool-dispatch-path-unification-and-legacy-purge | Tool Dispatch Path Unification + Legacy Purge | Implemented | 03d5feaf25 2026-07-08 | - |
| 0088-counter-as-fix-result-propagation | Counter-as-Fix → Result Propagation (umbrella scoping) | Active | 03d5feaf25 2026-07-08 | - |
| 0089-string-classifier-to-typed-variant | String Classifier to Typed Variant — direct replacement, no lint | Implemented | 7b62a87d44 2026-07-13 | - |
| 0090-write-side-success-model-attribution | Write-side success-model attribution — finish N-of-M migration | Implemented | 03d5feaf25 2026-07-08 | - |
| 0091-execute-typed-argv | Execute tool: cmd string → typed Argv schema (lexer/validator 박멸) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0093-board-persistence-path-unification | Board persistence identity and atomic snapshot | Implemented | 7b62a87d44 2026-07-13 | - |
| 0094-compact-cooldown-semantics-split | Compact cooldown semantics split decision record | Superseded | 434a7f5a76 2026-07-10 | - |
| 0095-openai-compat-streaming-wire-up | Provider-D-compat provider streaming wire-up | Implemented | 03d5feaf25 2026-07-08 | - |
| 0096-keeper-turn-contract-multi-turn-and-tier-group-spof | Keeper Turn Contract — multi-turn reasoning + runtime SPOF root-fix | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0097-keeper-sandbox-container-reuse | Keeper sandbox container reuse (long-running sandbox per keeper) | Active | 7b62a87d44 2026-07-13 | - |
| 0098-typed-jsonrpc-error-envelope | Typed JSON-RPC error envelope & production-code silent-failure lint | Implemented | 434a7f5a76 2026-07-10 | - |
| 0099-session-lifecycle-typed-events | Session lifecycle — typed events, explicit eviction, resume backpressure | Active | 63c38bf628 2026-07-17 | - |
| 0100-streamable-http-as-default-transport | Streamable HTTP as default transport (MCP 2025-03-26) | Active | 03d5feaf25 2026-07-08 | - |
| 0101-fd-accountant-generic-pool | FD accountant — observation across process resource classes | Active | 7b62a87d44 2026-07-13 | - |
| 0102-pre-turn-runtime-availability-gate | Pre-turn runtime availability gate — reuse, not new surface | Superseded | df319a9896 2026-07-11 | - |
| 0103-log-retention-opt-in-and-volume-root | Log retention opt-in + JSONL volume root reduction | Draft | 03d5feaf25 2026-07-08 | - |
| 0104-keeper-task-repo-binding | Withdraw Task-to-repository authorization | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0105-openai-compat-typed-error-mapping | OpenAI-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope | Implemented | 03d5feaf25 2026-07-08 | - |
| 0106-cancel-safe-try-with-discipline | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | 03d5feaf25 2026-07-08 | - |
| 0107-eio-context-switch-audit | Phase C.0 — `Eio_context.get_switch_opt` global access audit | Evidence | 03d5feaf25 2026-07-08 | - |
| 0107-outbound-http-stack-consolidation | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker ... | Active | 7b62a87d44 2026-07-13 | RFC-0107-phase-d-pool-design.md |
| 0108-atomic-jsonl-append | Atomic JSONL Append (in-process) | Active | 03d5feaf25 2026-07-08 | - |
| 0108-pr-worktree-operation-safety-gates | PR / Worktree Operation Safety Gates | Implemented | 03d5feaf25 2026-07-08 | - |
| 0109-cdal-goal-integration-contract | CDAL x Goal Integration Contract | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0110-tool-pair-atomicity-write-boundary | Tool-pair atomicity at write boundary — sunset compaction repair fabrication | Implemented | 03d5feaf25 2026-07-08 | - |
| 0111-goal-mint-atomicity-uniqueness-invariant | Goal mint atomicity — auto-goal uniqueness invariant at write boundary | Implemented | 434a7f5a76 2026-07-10 | - |
| 0112-typed-json-parse-boundary | Typed JSON parse boundary — eliminate silent-drop fallback across read sites | Implemented | 03d5feaf25 2026-07-08 | - |
| 0113-keeper-reaction-liveness-runtime | Withdraw KeeperReactionLiveness runtime hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0114-ksm-precondition-enforcement | Withdraw compact-retry and lifecycle guard model | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0115-ktc-turn-phase-spec-runtime-parity | KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0116-kcr-fallback-cap-mechanism-parity | Withdraw fallback-count cap | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0117-kcr-health-state-representation-parity | Withdraw runtime health cooldown hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0118-kct-terminal-runtime-contract | Withdraw terminal runtime projection contract | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0119-observer-spec-mapping-table-drift-lint | Withdraw lifecycle projection mapping hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0120-cross-spec-set-divergence-classification | Cross-spec set-name divergence — 3-class classification framework (STALE / DE... | Implemented | 7b62a87d44 2026-07-13 | - |
| 0121-config-dir-resolution-single-active-root | Config-dir resolution — single active root, no implicit fallback | Active | 03d5feaf25 2026-07-08 | - |
| 0122-keeper-disk-pressure | Keeper disk pressure — process-local fleet failure mode beyond FD | Implemented | 03d5feaf25 2026-07-08 | - |
| 0123-briefing-last-event-fabrication-write-boundary | Briefing last_event fabrication — option-typed write boundary | Implemented | 03d5feaf25 2026-07-08 | - |
| 0124-keeper-admission-denial-boundary | Withdraw fleet resource admission denial | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0125-bounded-subprocess-discipline | Withdraw Keeper watchdog and force-release discipline | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0126-silent-fallback-discipline | Silent fallback discipline (typed split for option/result wildcard arms) | Implemented | 7b62a87d44 2026-07-13 | - |
| 0127-runtime-fast-fail-and-termination-provenance | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | 03d5feaf25 2026-07-08 | - |
| 0129-http-idle-timeout-and-streaming-progress | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | 03d5feaf25 2026-07-08 | - |
| 0131-shell-command-gate-facade | Withdraw policy-bearing shell command facade | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0132-redaction-ssot | Redaction SSOT — `runtime` boundary-label private type | Implemented | 03d5feaf25 2026-07-08 | - |
| 0133-keeper-phase-casing-ssot-consolidation | Keeper Phase Casing SSOT Consolidation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0134-persistence-read-drop-root-fix | Persistence read-drop root fix (recovery story for RFC-0044) | Active | 7b62a87d44 2026-07-13 | - |
| 0135-dashboard-keeper-operational-ssot | Supersede dashboard-derived Keeper disposition | Superseded | 7b62a87d44 2026-07-13 | - |
| 0136-keeper-unified-turn-decomposition | Keeper Unified Turn — Stage Decomposition of run_keeper_cycle | Implemented | 03d5feaf25 2026-07-08 | RFC-0136-phase-4-retry-loop.md |
| 0137-host-fd-pressure-keeper-pause | Host FD pressure observation — retired Keeper-pause proposal | Retired | 7b62a87d44 2026-07-13 | - |
| 0138-dashboard-snapshot-lock-free-architecture | Dashboard Snapshot Lock-Free Immutable Architecture | Implemented | fdbf1c08d6 2026-07-19 | - |
| 0139-agent-status-vocabulary-ssot | Withdraw parallel agent and judge status hierarchies | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0140-dashboard-wire-codec-layer | Dashboard wire codec for source observations | Implemented | 7b62a87d44 2026-07-13 | - |
| 0141-toml-field-resolution-typed-variant | TOML Field Resolution Typed Variant for repo_manager | Implemented | 03d5feaf25 2026-07-08 | - |
| 0142-runtime-error-classify-decomp | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | 03d5feaf25 2026-07-08 | - |
| 0143-keeper-runtime-profile-typed-catalog | keeper_runtime_profile Typed Catalog Query Result | Active | 03d5feaf25 2026-07-08 | - |
| 0144-workaround-sunset-keeper-dedup-carryover | Withdraw recording-error dedup and metric sunset gates | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0145-permissive-silent-fallback-elimination | Permissive-Silent-Fallback Elimination | Active | 03d5feaf25 2026-07-08 | - |
| 0147-keeper-agent-run-decomposition | Withdraw decomposition around deleted Keeper policy stages | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0148-typed-tool-error-variant | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | 03d5feaf25 2026-07-08 | - |
| 0149-audit-telemetry-as-fix-sunset | Audit-Driven Telemetry-as-Fix Sunset | Implemented | 03d5feaf25 2026-07-08 | - |
| 0150-keeper-attention-signal-typed-envelope | Keeper Attention Signal — backend 단일 typed wire envelope | Implemented | 434a7f5a76 2026-07-10 | - |
| 0151-code-smell-monotone-ratchet | 4-metric monotone-decrease ratchet for code-smell metrics | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0153-runtime-backpressure-and-admission | Withdraw runtime tier admission | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0154-system-error-class-typed-ssot | System_error_class typed SSOT — close substring-classifier loop across backen... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0155-system-log-category-typed-ssot | Withdraw centralized operational policy log taxonomy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0156-oas-total-timeout-removal | Withdraw MASC turn-budget timeout policy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0157-runtime-pre-turn-required-tool-filter | Withdraw MASC pre-dispatch provider capability filtering | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0158-oas-retry-admission-typed-error | Withdraw MASC retry-admission denial | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0159-reason-internal-error-typed-split | Reason_internal_error typed split — close string-classifier catch-all | Draft | 03d5feaf25 2026-07-08 | - |
| 0160-shell-ir-first-class | Withdrawn Shell IR decision-substrate plan | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0161-tool-hint-symmetry-enforcement | Tool Error Hint Symmetry Enforcement | Draft | 03d5feaf25 2026-07-08 | - |
| 0162-jsonl-write-path-fd-pressure | JSONL Write-Path FD Pressure Root-Fix | Draft | 03d5feaf25 2026-07-08 | - |
| 0163-tier-group-route-canonicalization-typed-dedup | Tier-group capability profile route canonicalization — typed dedup and bypass... | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0164-voice-tool-abstraction-integrity | Withdraw voice exceptions to provider capability filtering | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0167-codex-llama-feature-path-purge | Withdrawn product-specific runtime authorization cleanup | Draft | 7b62a87d44 2026-07-13 | - |
| 0168-dashboard-provider-palette-purge | Dashboard upstream-LLM-provider color palette purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0169-dashboard-common-attribution-purge | Dashboard common/* MCP-client attribution header purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0170-dashboard-moonshot-palette-closure | Dashboard provider-b palette closure (RFC-0168 N-of-M follow-up) | Draft | 03d5feaf25 2026-07-08 | - |
| 0171-design-canvas-vendor-mock-purge | Design-canvas + ui_kits mock data vendor purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0172-everything-purge | Big-bang vendor purge across docs, audits, RFCs, design-system, tests | Draft | 03d5feaf25 2026-07-08 | - |
| 0173-ocaml-vendor-purge | OCaml lib/bin/test vendor purge (identifier + string literal) | Draft | 03d5feaf25 2026-07-08 | - |
| 0174-dashboard-substring-classifier-to-typed | Dashboard substring classifier to typed — TypeScript | Draft | 03d5feaf25 2026-07-08 | - |
| 0175-godfile-decomposition-wave-d | Godfile decomposition Wave D — keeper core 5-file split | Draft | 71c70f2806 2026-07-18 | - |
| 0176-oas-vendor-purge-migration | OAS vendor-purge migration — consume agent_sdk 0.198.0 | Implemented | 03d5feaf25 2026-07-08 | - |
| 0177-phonebook-internal-vendor-purge | Phonebook internal vendor-coupled enum purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0178-types-sublib-intf-mli-only | Types Sub-library Extraction with `_intf.ml` mli-only Surface (typed-SSOT) | Draft | 03d5feaf25 2026-07-08 | - |
| 0179-descriptor-ecosystem-coverage | ToolDescriptor Ecosystem Coverage Extension to Workspace Tools | Draft | 03d5feaf25 2026-07-08 | - |
| 0180-runtime-error-sweep-roadmap | 24h Runtime ERROR 7-Pattern Sweep Roadmap | Draft | 03d5feaf25 2026-07-08 | - |
| 0181-capability-intent-runtime-ssot | Withdraw MASC capability-intent routing | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0182-masc-descriptor-projection | masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation | Draft | 7b62a87d44 2026-07-13 | - |
| 0184-runtime-phonebook-typed-roundtrip | Runtime phonebook typed roundtrip for protocol/flavor/provider identifiers | Draft (Deferred) | 03d5feaf25 2026-07-08 | - |
| 0189-typed-tool-result-variant | Typed Tool_result.result variant — eliminating boolean blindness in tool disp... | Draft | 03d5feaf25 2026-07-08 | - |
| 0190-descriptor-visibility-ssot | Descriptor as Visibility/Metadata SSOT — Surface Projection from descriptor.p... | Draft | 03d5feaf25 2026-07-08 | - |
| 0191-descriptor-policy-ssot | Withdraw descriptor authorization policy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0192-runtime-deadline-propagation | Runtime deadline propagation — retired admission-wait proposal | Retired | 7b62a87d44 2026-07-13 | - |
| 0194-tool-surface-semantic-ssot | Withdraw tool semantics as an authorization SSOT | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0197-runtime-attempt-watchdog-per-candidate-wrap | Runtime Attempt Watchdog — Per-Candidate Wrap + Shared Deadline | Draft | 44966887a6 2026-07-18 | - |
| 0198-execute-typed-redirection | Execute Typed Redirection (Shell IR Syntax Leakage Closure) | Draft | 214eec8f6c 2026-07-14 | - |
| 0199-evidence-driven-auto-approval | Withdraw deterministic task-completion auto approval | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0200-time-constants-leaf-library | Time constants 를 leaf library 로 분리 | Draft | 03d5feaf25 2026-07-08 | - |
| 0201-activity-events-wait-free-snapshot | Activity Events Wait-Free Snapshot | Draft | fdbf1c08d6 2026-07-19 | - |
| 0203-discord-builtin-gateway | In-process Discord connector | Implemented (Phase 3 cutover landed 2026-05-29) | 8a8a90a2f0 2026-07-18 | - |
| 0204-dashboard-serving-isolation | Dashboard Read Serving Isolation from Fleet Compute | Draft | 7b62a87d44 2026-07-13 | - |
| 0205-keeper-module-consolidation | Keeper Module Consolidation — Eliminate Facade Anti-Pattern | Draft | ec50013248 2026-07-19 | - |
| 0206-runtime-concept-runtime-rebirth | Runtime 개념 — runtime→Runtime 재탄생 | Draft | 03d5feaf25 2026-07-08 | - |
| 0207-per-keeper-runtime-routing-ordered-failover | Per-keeper LLM runtime routing | Draft | 03d5feaf25 2026-07-08 | - |
| 0208-shell-ir-compositional-risk-ast | Withdrawn compositional Shell IR policy algebra | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0210-keeper-playground-repo-currency | Keeper Playground Repo Currency (fetch + fast-forward, work-preserving) | Draft | 03d5feaf25 2026-07-08 | - |
| 0211-persona-runtime-decouple-opaque-id-runtime-toml-ssot | Persona ⊥ {model, runtime}, opaque runtime id, runtime.toml keeper-assignment... | Draft | 03d5feaf25 2026-07-08 | - |
| 0212-module-tag-policy-axis-separation | Withdraw Keeper exposure policy axis | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0213-keeper-sandbox-isolation | Keeper sandbox/playground isolation model (fix sandbox_repo_not_ready + macOS... | Draft | 7b62a87d44 2026-07-13 | - |
| 0214-otel-genai-dual-emission | OTel GenAI Semantic Convention Migration | Draft | 03d5feaf25 2026-07-08 | - |
| 0215-keeper-sublibrary-extraction-campaign | Keeper sub-library extraction campaign — sequence and per-PR gates | Draft | 0ed4982f58 2026-07-15 | - |
| 0216-per-keeper-decline-memory | Per-Keeper Decline Memory (orphan-task churn root fix) | Draft | 03d5feaf25 2026-07-08 | - |
| 0217-telemetry-otel-single-backend | Telemetry Backend Otel 단일화 (Retired Backend Purge) | Draft | 03d5feaf25 2026-07-08 | - |
| 0218-keeper-tool-surface-coherence-and-web-tooling-roadmap | Keeper tool-surface coherence + web-tooling roadmap — phases and per-phase gates | Draft | 03d5feaf25 2026-07-08 | - |
| 0219-remove-sandbox-repo-gates | Remove Sandbox Repo Patrol Gates | Draft | 03d5feaf25 2026-07-08 | - |
| 0220-verification-scheduling-decouple | Decouple keeper liveness from verification state + guaranteed satisfier for e... | Draft | 03d5feaf25 2026-07-08 | - |
| 0221-atomic-verification-submission | Atomic verification submission — task_status as the sole outcome authority | Implemented (steps 1-3 merged #20613/#20617; steps 4-5 measured then dropped, §3.3/§3.4) | 03d5feaf25 2026-07-08 | - |
| 0222-typed-acceptance-criterion-and-harness-driven-completion | Withdraw harness-owned Task completion | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0223-typed-connector-surfaces-presence-pull-speaker | Typed connector surfaces: presence in world prompt, pull-based lane context, ... | Draft | 03d5feaf25 2026-07-08 | - |
| 0224-structured-completion-report | Withdraw the mandatory structured completion checklist | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0225-per-keeper-turn-single-flight | Per-keeper turn single-flight admission | Draft | 03d5feaf25 2026-07-08 | - |
| 0226-ambient-lane-recording | Ambient lane recording: record-vs-trigger decouple for connector surfaces | Draft | 03d5feaf25 2026-07-08 | - |
| 0228-paged-lane-pull-fact-retention-harness | Paged lane pull + fact-retention harness: digest without a summarizer | Draft | 03d5feaf25 2026-07-08 | - |
| 0229-keeper-person-notes | Keeper person notes: deliberate per-speaker memory beyond the log window | Draft | 7b62a87d44 2026-07-13 | - |
| 0230-keeper-mention-scope-reactivity | Keeper mention/scope reactivity: cursor-free salience to complement pull-base... | Draft | 03d5feaf25 2026-07-08 | - |
| 0232-typed-lane-event-model | Typed lane event model: parse at the write boundary, never re-derive by strin... | Draft | 03d5feaf25 2026-07-08 | - |
| 0233-turn-observability-execution-identity | Typed turn observability: TurnRecord prompt-block provenance + canonical tool... | Draft | 434a7f5a76 2026-07-10 | - |
| 0234-scheduled-internal-automation | Withdraw schedule-specific approval hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0235-stale-base-revert-guard | Stale-base revert guard: block PRs that silently revert recently-merged work | Draft | 03d5feaf25 2026-07-08 | - |
| 0235-voice-output-browser-transport-device-routing | Voice output transport: browser-addressed audio delivery with device-routed p... | Draft | 03d5feaf25 2026-07-08 | - |
| 0236-voice-input-browser-transport | Voice input transport: browser-captured speech-to-text for the dashboard comp... | Draft | 03d5feaf25 2026-07-08 | - |
| 0237-write-meta-force-escape-hatch-removal | Eliminate the write_meta ~force escape hatch (route snapshot writes through C... | Draft | 434a7f5a76 2026-07-10 | - |
| 0239-concurrency-ownership-model | Concurrency ownership model (per-site mutex/atomic → protection by construction) | Draft | 03d5feaf25 2026-07-08 | - |
| 0239-semantic-identity-guards-for-keeper-memory-and-anti-thrash | Supersede no-progress pause and semantic debounce guards | Superseded | 7b62a87d44 2026-07-13 | - |
| 0240-tool-pair-write-time-enforcement | Tool-pair invariant enforced at write-time (eliminate repair-on-read) | Draft | 03d5feaf25 2026-07-08 | - |
| 0241-external-attention-store-lifecycle | external-attention store lifecycle: read-side bound, retention, and typed tai... | Draft | 03d5feaf25 2026-07-08 | - |
| 0242-typed-continuity-summary-filter | Retired continuity prose-filter draft | Superseded | 434a7f5a76 2026-07-10 | - |
| 0243-memory-os-confidence-mutability-write-side-upsert | Memory OS confidence mutability via write-side fact upsert | Draft | 03d5feaf25 2026-07-08 | - |
| 0244-memory-os-recall-turn-seeded-lexical-retrieval | Memory OS recall: turn-seeded deterministic lexical retrieval, with provenanc... | Draft | 03d5feaf25 2026-07-08 | - |
| 0245-goalless-wip-goal-cap-exemption | Exempt goalless tasks from the per-goal WIP claim cap | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0247-memory-os-associative-graph-forgetting-brain | Memory OS as a brain: typed associative graph, spreading-activation recall, s... | Draft | 03d5feaf25 2026-07-08 | - |
| 0247-purge-implementation-plan | Memory OS purge + LLM-judgment rebuild — implementation plan (phase of RFC-0247) | Draft | 03d5feaf25 2026-07-08 | - |
| 0248-announce-as-data-observation-provenance | Board context without local authority classification | Draft | 7b62a87d44 2026-07-13 | - |
| 0249-remove-dead-stale-factor-field | Remove the dead `stale_factor` field (execute RFC-0239/0243/0244/0247) | Draft | 03d5feaf25 2026-07-08 | - |
| 0251-memory-os-record-well-not-value | Memory OS: record well, do not value — remove the scoring layer | Draft | 03d5feaf25 2026-07-08 | - |
| 0252-fusion-panel-judge-deliberation | Fusion: 패널+심판(panel+judge) 심의 루프 (MASC 내장) | Draft | ba354b7bb0 2026-07-17 | - |
| 0253-dashboard-v2-spacing-token-scale | Dashboard keeper-v2 surfaces: canonical spacing/radius token scale + off-scal... | Draft | 03d5feaf25 2026-07-08 | - |
| 0254-shell-ir-approval-autonomous-policy | Shell IR Approval Gate — Autonomous Production Policy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0255-shell-ir-path-typed-scope-and-floor-narrow | Withdraw inferred argv path policy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0256-mutex-protect-migration | Migrate hand-rolled Mutex lock/protect/unlock to Mutex.protect | Draft | 727a060579 2026-07-16 | - |
| 0257-per-keeper-memory-execution-lane | Per-Keeper memory execution lane | Draft | 7b62a87d44 2026-07-13 | - |
| 0259-memory-os-volatile-claim-grounding-retraction-decay | Memory OS — Volatile Claim Grounding, Retraction & Decay | Draft | 03d5feaf25 2026-07-08 | - |
| 0260-provider-health-gate-audited-failover | Withdraw MASC provider-health gate | Draft | 7b62a87d44 2026-07-13 | - |
| 0261-grpc-lsp-failed-init-fd-teardown | gRPC LSP failed-initialize FD/process teardown | Draft | 03d5feaf25 2026-07-08 | - |
| 0262-completion-authority-typing | Withdraw hierarchical Task-completion authority | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0263-owner-priority-turn-preemption | Withdraw actor-priority turn preemption | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0264-memory-os-recall-outcome-anchored-eval | Memory OS recall outcome-anchored eval harness | Draft | 03d5feaf25 2026-07-08 | - |
| 0265-capability-driven-proactive-runtime-reroute | Withdraw MASC modality capability rerouting | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0266-fusion-async-completion-wake-and-visibility | Fusion async-completion wake + in-progress 가시성 | Draft | 03d5feaf25 2026-07-08 | - |
| 0267-task-goal-linkage-projection-and-explicit-assignment | Make task↔goal links visible and explicitly assignable | Draft | 03d5feaf25 2026-07-08 | - |
| 0269-process-critic-loop | Process Critic Loop for Keeper Work Traces | Draft | 03d5feaf25 2026-07-08 | - |
| 0270-ci-gate-merge-guard | CI Gate merge guard: block merges on a non-success CI Gate and trip on red main | Draft | 03d5feaf25 2026-07-08 | - |
| 0271-in-turn-recovery-accept-rejected-and-thinking-budget | Withdraw progress-based turn rejection and pause | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0272-memory-os-episode-log-retention | Memory OS — Episode Log Retention (bounded append for events.jsonl / episodes) | Draft | 03d5feaf25 2026-07-08 | - |
| 0273-dashboard-driven-keeper-config-and-runtime-persistence | Withdraw policy-bearing Keeper configuration tiers | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0274-workspace-base-path-ssot-threading | Workspace base_path SSOT — retire env runtime read, thread Workspace.config | Draft | 03d5feaf25 2026-07-08 | - |
| 0275-excise-bdi-triple-from-keeper-social-model | Retired cognitive-triple removal record | Implemented | 434a7f5a76 2026-07-10 | - |
| 0276-purge-keeper-social-model-self-report-protocol | Remove Keeper social-model self-report protocol | Implemented | 434a7f5a76 2026-07-10 | - |
| 0277-fusion-heterogeneous-panels | Fusion: 이종 패널 그룹(heterogeneous panel groups) + 발동 예산 제거 | Draft | 27c5da70fc 2026-07-16 | - |
| 0278-fusion-same-model-panels | Fusion: 같은 model을 다른 prompt로 (same-model panels via panel labels) | Draft | 03d5feaf25 2026-07-08 | - |
| 0279-typed-completion-contract-reason | Withdraw completion-contract result taxonomy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0280-fusion-validated-preset | Fusion: validated preset type (Parse, don't validate) | Draft | 03d5feaf25 2026-07-08 | - |
| 0281-websocket-transport-ssot | WebSocket transport SSOT — separate upgrade-attachment from session-protocol,... | Draft | 03d5feaf25 2026-07-08 | - |
| 0282-destructure-keeper-self-model | Reduce Keeper persona to ordinary instructions | Implemented | 434a7f5a76 2026-07-10 | - |
| 0283-fusion-judge-of-judges | Fusion: judge-of-judges 위상 (flat/staged reducer) | Draft | ba354b7bb0 2026-07-17 | - |
| 0284-fusion-judge-observation-record | Fusion 심판 실행 관측 record (judge observation record) | Draft | 03d5feaf25 2026-07-08 | - |
| 0284-goal-loop-sse-liveness | Goal-loop status SSE liveness — server-side change detection extends the goal... | Superseded — RFC-0352 Path B (2026-07-21). The goal-loop OODA | 9144909e70 2026-07-21 | - |
| 0284-keeper-guidance-visibility-drift-guard | Supersede command-semantics guidance guards | Superseded | 7b62a87d44 2026-07-13 | - |
| 0285-memory-os-self-observation-claim-volatility | Memory OS — Self-Observation Claim Volatility (closing RFC-0259's internal-st... | Draft | 434a7f5a76 2026-07-10 | - |
| 0286-exec-keeper-boundary-ownership | Superseded exec and Keeper boundary diagnosis | Superseded | 7b62a87d44 2026-07-13 | - |
| 0287-ws-direct-masc-owned-websocket-stack | ws-direct — a single masc-owned WebSocket stack for server and client | Draft | 03d5feaf25 2026-07-08 | - |
| 0288-purge-keeper-goal-horizons | Remove per-Keeper goal-horizon fields | Implemented | 434a7f5a76 2026-07-10 | - |
| 0289-keeper-progress-lib-split | Extract progress-classification into its own library for a single substantive... | Draft | 03d5feaf25 2026-07-08 | - |
| 0290-keeper-background-wait-tool | Generic keeper background-work tool (spawn → wake-on-completion) | Draft | ba354b7bb0 2026-07-17 | - |
| 0291-closed-sse-event-type-sum | Closed SSE event-type sum + typed broadcast — RFC-0004 Phase A0 Wave 2 increment | Draft | 9144909e70 2026-07-21 | - |
| 0292-complete-lib-auth-dedup | Complete lib/auth de-duplication — remove drifted Masc.Auth* test copies | Draft | b568e023bf 2026-07-16 | - |
| 0293-keeper-exec-endpoint-backend | Withdraw policy-bearing execution endpoints | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0294-purge-workspace-goal-horizon | Remove workspace Goal horizon | Implemented | 434a7f5a76 2026-07-10 | - |
| 0295-fleet-runtime-transient-band | Withdraw derived fleet runtime bands | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0296-ci-skip-gate-main-push-build | CI skip-gate main-push safety-net: always run Build and Test on non-PR events | Draft | 03d5feaf25 2026-07-08 | - |
| 0298-fusion-judge-pool | fusion judge pool — judge 모델을 preset에서 분리 | Draft | 03d5feaf25 2026-07-08 | - |
| 0299-typed-boundary-sweep | RFC-0299 — Typed-Boundary Sweep (string-classifier → closed-sum, dead SSOT re... | Draft | 7b62a87d44 2026-07-13 | - |
| 0300-dashboard-design-token-scope-consolidation | RFC-0300 — Dashboard design-token scope consolidation (radius / shadow / type... | Draft | 03d5feaf25 2026-07-08 | - |
| 0301-keeper-generated-media-exposure | Keeper 생성 미디어(이미지/오디오) 대시보드 노출 | Draft | 03d5feaf25 2026-07-08 | - |
| 0302-keeper-memory-io-offmain-offload | Keeper 메모리 파일 I/O off-main-domain 오프로드 (HOL fix) | Draft | 03d5feaf25 2026-07-08 | - |
| 0303-stimulus-gated-keeper-wake | Keeper wake without progress heuristics | Draft | 7b62a87d44 2026-07-13 | - |
| 0304-hitl-critical-bounded-escalation | Withdraw Critical-class HITL escalation | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0305-safety-gate-failclosed-default | Withdraw global fail-closed governance policy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0306-fusion-settings-typed-editor | Typed, comment-preserving fusion settings editor | Draft | ba354b7bb0 2026-07-17 | - |
| 0307-midturn-advisor-consult | Mid-turn advisor consult for keepers — evaluation and deferral | Draft | 512aa17c23 2026-07-18 | - |
| 0308-verification-required-done-guard | Withdraw verifier-required Task routing | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0309-typed-gh-capability-gating | Withdrawn product-specific capability hierarchy | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0311-typed-evidence-gate | Withdraw deterministic evidence floors | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0312-keeper-repo-mapping-advisory-scope | Keeper repo mappings are advisory default scope, not access caps | Accepted | 03d5feaf25 2026-07-08 | - |
| 0315-wake-turn-self-description | Typed wake-turn context and self-directed work lane | Active | 434a7f5a76 2026-07-10 | - |
| 0316-merge-gating-enforce-admins | Merge gating convergence: enforce_admins=true + live Branch Protection Watchdog | Draft | 03d5feaf25 2026-07-08 | - |
| 0317-slack-builtin-gateway | In-process Slack connector (Socket Mode) | In progress (PR-1/PR-2 landed; PR-3 implemented; PR-4 sidecar removal pending) | c8b5216a15 2026-07-18 | - |
| 0318-operator-overlay-llm-approval-resolver | Replace risk-tier auto approval with request-local Auto Judge | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0319-operator-approval-mode | Replace hierarchical approval modes with Keeper Gate choices | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0320-keeper-connector-aware-continuation | Keeper connector-aware continuation: carry the originating channel through wa... | Draft | 7b62a87d44 2026-07-13 | - |
| 0321-hard-forbidden-typed-error | Withdraw unconditional static tool-block proposal | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0322-playground-repo-read-authz | Withdraw repository-catalog read authorization | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0323-done-via-verification-linked-rerun | Withdraw mandatory cross-verifier completion | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0324-keeper-filesystem-repo-truth | keeper repo 경로를 filesystem 진실로 (catalog 거짓 주입 제거) | Draft | 7b62a87d44 2026-07-13 | - |
| 0328-keeper-perseveration-memory-grounding-and-failover-recovery | Retire the combined governance and perseveration incident plan | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0329-keeper-execute-governance-payload-aware-and-typed-exemption | Keeper Execute Governance Payload Mapping | Rejected | 7b62a87d44 2026-07-13 | - |
| 0331-effect-class-typed-tool-effect | Withdraw authorization by tool effect class | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0332-memory-write-boundary-dedup | Rejected heuristic memory write dedup draft | Rejected | 434a7f5a76 2026-07-10 | - |
| 0333-eval-cost-success-frontier | Deterministic cost↔success frontier join for the eval harness | Draft | ae027bed8f 2026-07-09 | - |
| 0334-board-mailbox-turn-digest | Board signals as durable Keeper input | Draft | 7b62a87d44 2026-07-13 | - |
| 0335-toml-single-settings-source | TOML as the Single Settings Source | Draft | e5e4c44f2b 2026-07-09 | - |
| 0337-evidence-gate-semantics | Withdraw deterministic evidence-gate semantics | Withdrawn | 7b62a87d44 2026-07-13 | - |
| 0338-lane-per-keeper-persistence-isolation | Lane-per-keeper durable persistence isolation | Draft | 8033528ee3 2026-07-11 | - |
| 0340-dashboard-token-only-auth | Dashboard dev-token privilege reduction — demote from Admin, close the rebind... | Draft | 97387d9e7d 2026-07-11 | - |
| 0341-keeper-lifecycle-projection-ssot | Keeper lifecycle projection SSOT | Draft | 7b62a87d44 2026-07-13 | - |
| 0342-capability-catalog-overlay-and-boot-posture | Capability catalog overlay, deployment capability declarations, and boot posture | Draft | 25a1c593b5 2026-07-16 | - |
| 0343-repo-location-ssot | Repo location SSOT (collapse dual-authority, attribute by git-remote) | Draft | f463ec7b82 2026-07-15 | - |
| 0345-stream-idle-failsafe | Streaming idle-timeout fail-safe floor (#25128) | Draft | 5805c199d6 2026-07-20 | - |
| 0346-gateway-redelivery-dedup-authority | Gateway redelivery dedup: transcript single-authority, attention as wake-hint | Draft | f1d21b989d 2026-07-21 | - |
| 0347-typed-effect-intent-capability-floor | Typed EffectIntent + capability floor at the Keeper Gate | Draft | 92c23f85a5 2026-07-21 | - |
| 0348-bounded-durable-write-wait | Bounded lane acquisition for durable keeper_msg writes (#25398) | Draft | dce1ab3b71 2026-07-21 | - |
| 0349-compaction-admission-restore | Restore a reachable compaction admission path | Draft | 8c0a5d7c61 2026-07-21 | - |
| 0350-unbounded-request-fiber-admission | Unbounded request-fiber admission (durable queue + owner-lane drain + typed s... | Draft | 4f3062d649 2026-07-21 | - |
| 0351-memory-first-context-management-compaction-sunset | Memory-first context management and compaction sunset | Draft | ee6e9bb8ca 2026-07-21 | - |
| 0352-legacy-goal-contradiction-resolution | Legacy Goal: RFC-0000 §3.2 ↔ §3.15 자기모순 해소 (결정 요청) | Draft | 6952c01917 2026-07-21 | - |
| 0353-failure-classification-boundary | 실패 분류가 모듈 경계에서 소실되는 결함 (결정 요청) | Draft | 25993cb494 2026-07-21 | - |
| async-log-sink-durable-append-offload | Offload the structured-log durable append off the emitting fiber | Draft | 3ec8a423be 2026-07-21 | - |
| checkpoint-pinned-root-containment | Immutable boot-pinned root capability for checkpoint containment | Draft | 810be9566e 2026-07-18 | - |
| compaction-deterministic-floor | Compaction must never deadlock: a deterministic structural floor, typed outco... | Draft | ca5652a705 2026-07-21 | - |
| connector-ambient-attention-wake | Connector ambient attention wake: drive an idle keeper turn from external-att... | Draft | 7b62a87d44 2026-07-13 | - |
| connector-deferred-reply-via-chat-queue | Durable Keeper chat receipts and connector delivery settlement | Active | 9d59e83655 2026-07-14 | - |
| eliminate-substring-destructive-classifier | Withdrawn command-policy classification experiment | Withdrawn | 7b62a87d44 2026-07-13 | - |
| keeper-conversation-hitl-flow | Keeper conversation and non-blocking HITL | Draft | 29300f3f4f 2026-07-22 | - |
| keeper-credential-device-flow | OAuth Addon Plugin — Keeper별/MASC 전체 외부 서비스 Credential (GitHub, Figma, …) | Draft | 7a7dfe6d9f 2026-07-23 | - |
| keeper-media-degrade-floor | Withdraw silent media degradation | Draft | 7b62a87d44 2026-07-13 | - |
| keeper-memory-bank-write-reduction | Keeper memory-bank near-dup accumulation — write reduction, not write-boundar... | Draft | 3dd14baa54 2026-07-20 | - |
| keeper-memory-consolidation | Keeper durable memory consolidation — deprecate memory_bank into Memory OS | Draft | 434a7f5a76 2026-07-10 | - |
| keeper-memory-panel-real-data | Keeper memory panel: real-data backing (no fabrication, no score resurrection) | Draft | 03d5feaf25 2026-07-08 | - |
| keeper-vision-delegation-tool | Vision-as-a-tool delegation (decouple multimodal input from conversation runt... | Draft | 7b62a87d44 2026-07-13 | - |
| runtime-note-field-and-dashboard-surfacing | Per-runtime note field & dashboard surfacing | Draft | 03d5feaf25 2026-07-08 | - |
| typed-egress-resource-capability | Withdraw product-specific egress effect classification | Withdrawn | 7b62a87d44 2026-07-13 | - |

### 신규 RFC

신규 RFC 는 번호를 발급받지 않는다 (번호 allocator 제거됨 — 전역 카운터 TOCTOU 회피). 의미 있는 slug 파일명 `RFC-<slug>.md` 로 작성한다. 본 표의 번호 인덱스는 기존 번호 RFC 만 추적한다.

## 검색 / 발견

- 단일 RFC: `cat docs/rfc/RFC-NNNN-*.md`
- 키워드 검색: `rg <keyword> docs/rfc/`
- 본 README 의 표 + Last activity 컬럼으로 최근 활동 추적
- PR 작성 시 RFC 발견 체크: `bash ~/me/scripts/pr-rfc-check.sh --pr-body /tmp/pr-body.md`

## 비범위 (향후 별도 RFC)

- Frontmatter 자동 lint (CI hook)
- 기존 RFC retroactive frontmatter 통일
- 자동 인덱스 생성 (`scripts/rfc-index.sh` 또는 GitHub Action) — 이 표 자동 갱신을 포함
- Status sweep 전면 audit (Draft → Withdrawn 후보 식별)
| 0102 | Pre-turn runtime availability gate — historical | Superseded | (this PR) 2026-07-11 | The pre-turn health gate is no longer a live contract. Actual provider/model outcomes belong to OAS and do not pause or deny a Keeper lane. |
| 0103 | Log retention opt-in + volume-root anchoring | Draft | 9f7b4ce520 2026-05-17 | retroactive index entry — body merged via #15850 (5-PR sprint). Default-disabled retention with explicit opt-in env knob + log volume-root anchored archiver. |
| 0104 | Keeper task → repository binding — historical | Withdrawn | (this PR) 2026-07-13 | Repository catalog membership no longer grants or denies access; execution uses BasePath/path jail and sandbox containment. |
| 0105 | Provider-D-compat boundary: `Agent_sdk.Error.t` → HTTP status + typed envelope | Implemented | (this PR) 2026-05-17 | RFC-0098 closeout follow-up audit. RFC-0098 (Implemented #15828) cleared `server_mcp_transport_http` (0 literal codes, 9 typed `Mcp_error_code` sites). This RFC closes the sole remaining lossful boundary in `lib/server/`: `server_openai_compat.ml:125` `Agent_sdk.Error.to_string` typed→string compression, amplified by `route_runtime (_, string) result` signature and `handle_chat_completions` blanket 500 / `"server_error"` flattening. `Openai_compat_error_map.t` total mapping + widened Error tag + envelope `code` field population landed in #15899 (21/21 Alcotest PASS, exhaustive over 9 sdk_error top-level variants, no catch-all). `route_keeper` deeper site at `keeper_turn.ml:521-531` deferred to a separate RFC (larger scope). Related RFC-0098, RFC-0095. |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | (this PR) 2026-05-21 | Existing `scripts/lint-cancel-guard.sh` only matches single-arm `try X with exn -> Y`. **P0 (helper module) + P1 partial 머지**: 8 PR (#15894, 15904, 15917, 15919, 15920, 15925 initial P0+P1 batch + #16949 masc_http_client/pool + #16951 fd_accountant). `lib/cancel_safe/cancel_safe.{ml,mli}` SSOT 존재. **P2 (callbacks) / P3 (ppxlib AST lint) / P4 (regex lint deprecation) 미시작** — P3 가 RFC-0126 Phase 2b prereq. Status promoted Draft → Active. Related RFC-0072, RFC-0097, RFC-0101, RFC-0126. |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport | Draft | (this PR) 2026-05-17 | 2026-05-16 ENFILE storm 의 진짜 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant) 는 같은 사고의 transitional defense — 1/4 kind 만 wired, 3 kind dead branch. (1) cohttp-eio 6.1.1 socket-not-closed bug → `make_closing_client` 워크어라운드 (Eio issue #244 권고 위반); (2) connection pool 부재 (masc + oas); (3) `run_turn:196` ambient switch (turn-scoped FD boundary 없음); (4) subprocess-heavy Docker (`docker run/exec`, `/var/run/docker.sock` 미사용, RFC-0097 spec-only). 4-layer 설계: L1 Transport (Phase B spike → piaf default / cohttp-eio latest 검토), L2 `(host:port) → Client.t` keyed pool, L3 `run_turn` fresh `Eio.Switch.run`, L4 Docker UDS + RFC-0097 활성화. RFC-0101 은 머지 직후 transitional → Phase D + 30일 production soak gate 후 retire. PR #15881 (Sandbox_exec wrap) close. Prior Art: piaf, Tarides Ocsigen→Eio (2025-03), cohttp #85, Eio #244, Eio.Switch axiom. Related RFC-0097, RFC-0100, RFC-0101. |
| 0108 | Atomic JSONL Append (in-process) | Draft | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. 코드베이스에 **3 단계 동시성 보호 누적** (Tier-0: 없음 / Tier-1: `Stdlib.Mutex` + `Append_fd_cache` / Tier-2: `Eio.Mutex`) — 모든 tier 에서 손상 발생. 직접 원인 두 가지: (a) `output_string + flush` 가 두 syscall 이라 race window 존재, (b) record + '\n' 의 *직렬화 단계와 write 단계 분리*로 large record (PIPE_BUF 초과 trajectory prompt dump) 가 multiple `write(2)` 로 쪼개져 다른 writer 끼어듦. 새 `lib/jsonl_atomic/` 모듈 + Eio.Mutex per-path registry + single write(2) loop 으로 SSOT 수렴. 4 writer (`log.ml`, `trajectory.ml`, `dated_jsonl.ml`, → runtime_event_bridge / keeper_reaction_ledger 자동 fix) 마이그레이션. Cross-process flock + Stdlib.Mutex 전역 audit 는 명시적 비목표. 5-PR sprint (RFC → 모듈 → log → trajectory → dated_jsonl). Originally allocated as RFC-0107 but renumbered after RFC-0107 (outbound HTTP) merged first to main (#15900). Related RFC-0079, RFC-0088. |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport | Active | (this PR) 2026-05-17 | 2026-05-16 ENFILE storm 의 진짜 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant) 는 같은 사고의 transitional defense — 1/4 kind 만 wired, 3 kind dead branch. (1) cohttp-eio 6.1.1 socket-not-closed bug → `make_closing_client` 워크어라운드 (Eio issue #244 권고 위반); (2) connection pool 부재 (masc + oas); (3) `run_turn:196` ambient switch (turn-scoped FD boundary 없음); (4) subprocess-heavy Docker (`docker run/exec`, `/var/run/docker.sock` 미사용, RFC-0097 spec-only). 4-layer 설계: L1 Transport (Phase B spike → piaf default / cohttp-eio latest 검토), L2 `(host:port) → Client.t` keyed pool, L3 `run_turn` fresh `Eio.Switch.run`, L4 Docker UDS + RFC-0097 활성화. RFC-0101 은 머지 직후 transitional → Phase D + 30일 production soak gate 후 retire. PR #15881 (Sandbox_exec wrap) close. Prior Art: piaf, Tarides Ocsigen→Eio (2025-03), cohttp #85, Eio #244, Eio.Switch axiom. Related RFC-0097, RFC-0100, RFC-0101. |
| 0108 | Atomic JSONL Append (in-process) | Draft | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. 코드베이스에 **3 단계 동시성 보호 누적** (Tier-0: 없음 / Tier-1: `Stdlib.Mutex` + `Append_fd_cache` / Tier-2: `Eio.Mutex`) — 모든 tier 에서 손상 발생. 직접 원인 두 가지: (a) `output_string + flush` 가 두 syscall 이라 race window 존재, (b) record + '\n' 의 *직렬화 단계와 write 단계 분리*로 large record (PIPE_BUF 초과 trajectory prompt dump) 가 multiple `write(2)` 로 쪼개져 다른 writer 끼어듦. 새 `lib/jsonl_atomic/` 모듈 + Eio.Mutex per-path registry + single write(2) loop 으로 SSOT 수렴. 4 writer (`log.ml`, `trajectory.ml`, `dated_jsonl.ml`, → runtime_event_bridge / keeper_reaction_ledger 자동 fix) 마이그레이션. Cross-process flock + Stdlib.Mutex 전역 audit 는 명시적 비목표. 5-PR sprint (RFC → 모듈 → log → trajectory → dated_jsonl). Originally allocated as RFC-0107 but renumbered after RFC-0107 (outbound HTTP) merged first to main (#15900). Related RFC-0079, RFC-0088. |
| 0109 | CDAL × GOAL Integration Contract — historical | Withdrawn | (this PR) 2026-07-13 | CDAL output is observation only and cannot transition Goal or Task state. Semantic completion uses the configured LLM. |
| 0124 | Keeper admission denial boundary — historical | Withdrawn | (this PR) 2026-07-13 | FD, disk, and fleet measurements are observations only; they do not deny unrelated Keeper lanes. |
| 0125 | Withdraw Keeper watchdog and force-release discipline | Withdrawn | (this PR) 2026-05-21 | Elapsed-time watchdog, restart authority, and semaphore force-release are retired. Process/socket resource scopes remain local typed boundaries. |
| 0126 | Silent fallback discipline (typed split for option/result wildcard arms) | Active | (this PR) 2026-05-21 | 본 RFC body (#15959) + amendment (#16000) + Phase 1 PR-1 (#16019 runtime attempt provenance) + Phase 1 PR-2 (#16024 provider health probe loop) + Phase 1 cross-listed (#16189 RFC-0127 PR-1, §6.1.b absorbs into Phase 1 canary). Phase 2a (`scripts/lint/no-unknown-permissive-default.sh` grep-based) in place. **Phase 2b (ppxlib AST) / Phase 3 (codemod) / Phase 4 (CI hard-fail) 미시작** — Phase 2b 는 RFC-0106 §3.3 dependency. Phase 1 OAS upstream (C2/C3/V16 labels) 도 별도 OAS RFC 대기. Status promoted Draft → Active. Related RFC-0042, RFC-0088, RFC-0106, RFC-0127. |
| 0127 | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | (this PR) 2026-05-18 | 2026-05-17 ~13:00–13:30 UTC incident: RunPod pod `ur1wah58zebjov` 502 storm 30분 동안 10-keeper fleet `fiber_unresolved`, supervisor log 가 *어떤 provider 가 502 인지* 한 줄도 출력 안 함 (`fiber_terminated(fiber_unresolved)` 만). Two gaps: **(A)** `runtime.toml` 의 `[providers.X.healthcheck]` 블록은 parser 에 들어가지만 runtime 동작 0 (probe loop wiring 부재) → **RFC-0126 PR-2 (#16024)** 가 main 에 wiring 완료, RFC-0127 scope 와 implementation overlap. **(B)** `Fiber_terminated { outcome }` 가 `provider_id` / `http_status` 정보를 string-squash 으로 잃어버림 → **PR-1 (#16189 MERGED 2026-05-18)** 가 carrier widen + 5 caller propagation + display surface (event_to_string, JSON, failure_reason_to_string) + 7 carrier-preservation tests. **Remaining**: data-flow from `Provider_error.ServerError { code }` (already captured at `keeper_turn_driver.ml:364`) into the now-typed `Fiber_terminated` carrier so supervisor log shows `fiber_terminated(fiber_unresolved provider=runpod_mtp http=502)`. Originally PR-2/PR-3 spec'd as new module + integration test; PR-2 reduced to data-flow plumbing now that probe loop ships via RFC-0126. Related RFC-0024, RFC-0027, RFC-0058, RFC-0088, RFC-0126. |
| 0129 | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | (this PR) 2026-05-21 | 2026-05-18 incident: reserve_fraction band-aid 가 keeper-level workaround. **2-PR plan 완료**: PR-1 #16084 (piaf idle-timeout API + pool layer reference, RFC-0121 commit subject 와 dual-listed), PR-2 #16158 (`delete reserve_fraction band-aid` — fleet fix). §5 acceptance 24h soak 경과 (2026-05-19). Second audit-sweep RFC to land directly at Implemented (RFC-0132 #17187 다음). Related RFC-0107, RFC-0121 (#16084 dual-listing). |
| 0131 | Shell Command Gate facade — historical | Withdrawn | (this PR) 2026-07-13 | Command/product policy was removed; typed argv/path/sandbox invariants remain and external effects use the generic Gate. |
| 0132 | Redaction SSOT — `runtime` boundary-label private type | Implemented | (this PR) 2026-05-21 | `lib/runtime/` 와 `lib/keeper/` 에 `"runtime"` 리터럴이 ~23 사이트 산재. **3-phase 완전 closure**: PR-1 #16531 (`Boundary_redaction` SSOT 모듈), PR-2 #16536 (23-site codemod), PR-3 #16537 (`scripts/lint/no-runtime-literal-outside-boundary-redaction.sh` + Fundamental Check workflow). `feedback_runtime_lens_boundary_carve_out` (#15040/#15070/#15089) 회귀 root fix. Workaround Rejection Bar §AI 안티패턴 1 (Scattered Hardcoded Defaults). Status promoted Draft → Implemented. Related RFC-0085, RFC-0088, RFC-0089, RFC-0126, RFC-0131. |
| 0135 | Dashboard Keeper Operational Surface — historical | Superseded | (this PR) 2026-07-13 | One observation still renders consistently, but the dashboard no longer derives blocked, stuck, risk, or operator-action hierarchies. |
| 0133 | Keeper Phase Casing SSOT Consolidation | Draft | (this PR) 2026-05-19 | PR-1 (#16312) closed 11 dead `snapshot.phase === '<PascalCase>'` compares but the structural duplication remains: backend emits lowercase + snake_case via `phase_to_string`, dashboard normalizes flat `keeper.phase` to PascalCase via 4 separate normalizers (`toKeeperPhase`, `normalizePhase`, `toPascalPhase`, `keeper-state-diagram` internal map), and `STATE_DISPLAY_NAMES` carries both casings as defensive double-keying. Single PR sweep flips canonical type to lowercase, deletes 4 normalizers + dual map keys, promotes schema to picklist + `{unknown}` carrier (RFC-0042 closed-sum). 사용자 절대 원칙: no transitional shims, legacy 박멸 in same PR. Renumbered from 0131 → 0133 after PR #16323 ledger-snapshot collision. Related RFC-0042, RFC-0046, RFC-0088. |
| 0108 | Atomic JSONL Append (in-process) | Active | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. **§2.5 진단 evolution** (implementation 진행 중 갱신): 초기 가설 (Stdlib.Mutex multi-domain 무효) 은 부분만 맞았고, 실제 root cause 는 *OCaml `out_channel` buffer 가 도메인-safe 아님* — `Append_fd_cache` 의 cached channel 을 두 도메인이 공유하면 mutex critical section 안에서도 buffer corrupt. 결정적 fix = per-call open_out_gen + close (fresh fd, cache 우회). **Implementation 6 PR MERGED**: #15906 Eio SSOT 모듈, #15922 system_log in-line, #15926 trajectory in-line, #15928 dated_jsonl in-line, **#15936 `Fs_compat.append_jsonl` root-fix** (~30 caller 자동 안전), **#15949 `Fs_compat.append_file` root-fix + `Append_fd_cache` 모듈 완전 제거** (-91 LoC). #15953 cleanup Draft (inline 헬퍼 → library delegate, -109 LoC). 운영 실측: 5 malformed 정적 (3 tick 연속), 새 손상 0. Originally allocated as RFC-0107, renumbered after #15900 collision. Related RFC-0079, RFC-0088. |
| 0136 | Keeper Unified Turn — Stage Decomposition of `run_keeper_cycle` | Active | (this PR) 2026-05-19 | `lib/keeper/keeper_unified_turn.ml` 1943 LOC (5위 godfile, fundamental_roadmap.md Phase 5 명시 target) 의 단일 함수 `run_keeper_cycle` 을 stage-typed sub-module 로 분해. **PR-1 #16604 MERGED** (Phase Gate, -102), **PR-2 #16624 MERGED** (Runtime Resolution, -51), **PR-3 #16643 MERGED** (Pre-Dispatch, -48) — 누적 1943 → 1742 = **-201 LoC (10.3%)**. Phase 4 sub-doc (`RFC-0136-phase-4-retry-loop.md`) 으로 retry loop body (~1100 LOC) 5 sub-PR 분할 (PR-4-a outer setup, PR-4-b error marker, PR-4-c retry core, PR-4-d retry decision, PR-4-e final dispatch). 예상 최종 `keeper_unified_turn.ml` ~620 LOC (-68%). Workaround Rejection Bar 7-check: 모두 N/A. Related RFC-0051, RFC-0056, RFC-0085. |
| 0136 | Phase 4 — Retry Loop Body Decomposition | Draft | (this PR) 2026-05-19 | RFC-0136 main spec §4.2 PR-3 (deferred — *Retry loop body 별도 sub-doc 검토*) 의 구체 계획. `rec retry_loop` (L604, ~1100 LOC) 가 *single PR 불가* — 새 file 600 LOC cap 위반 + nested helpers (`mark_terminal_error` 9 callsites, `do_run`, `attempt_result`) 동시 추출 필요. 5 sub-PR 분할: PR-4-a outer setup (-167), PR-4-b mark_terminal_error (-53), PR-4-c retry core (-400), PR-4-d retry decision (-300), PR-4-e final dispatch (-180). Sequencing: PR-4-a/b parallel → PR-4-c (depends a+b) → PR-4-d/e parallel. typed `retry_setup` + `terminal_error_outcome` record 도입. Workaround Rejection Bar §3 (N-of-M migration) 경계선 — *해당 RFC closure 의 일부* 명시 + PR-4-final 마감 commit 필수. Related RFC-0051, RFC-0056. |
| 0137 | Host FD pressure observation — retired Keeper-pause proposal | Retired | (this PR) 2026-07-13 | Host FD pressure remains observable, but automatic Keeper pause and Docker pre-spawn refusal were withdrawn. Resource evidence cannot stop unrelated Keeper lanes. Related RFC-0097, RFC-0101, RFC-0122. |
| 0139 | Withdraw parallel agent and judge status hierarchies | Withdrawn | (this PR) 2026-05-21 | Dashboard projections must use Keeper runtime and Gate source facts instead of a parallel status hierarchy. Historical implementation PRs remain in Git. |
| 0141 | TOML Field Resolution Typed Variant for repo_manager | Implemented | (this PR) 2026-06-02 | `Field_resolution.t` keeps repository TOML defaults explicit while rejecting type mismatches. The deleted repository credential subsystem is no longer part of this RFC. Related RFC-0088, RFC-0126, RFC-0142, RFC-0148, RFC-0154. |
| 0142 | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | (this PR) 2026-05-21 | 2026-05-20 silent-failure audit Tier B1. `lib/runtime/runtime_error_classify.ml` 873→939 LoC + 33 catch-all godfile. 3-phase 분해. **Phase 1 부분 머지**: #16790 (Json_field 모듈), #16806 (telemetry_unified migration), #16894 (dashboard_http_helpers), #16899 (server_dashboard_http). 그러나 *origin 모듈 (runtime_error_classify.ml) 자체 migration 미완* — 4 Json_field usage / 33+ catch-all 잔존. Phase 2 (`runtime_internal_error` / `runtime_error_from_sdk` / `runtime_codex_preflight` split) 미시작. Phase 3 (reachability sweep) 미시작. Status promoted Draft → Active to signal partial landing. Related RFC-0085, RFC-0088, RFC-0148, RFC-0154. |
| 0143 | keeper_runtime_profile Typed Catalog Query Result | Active | (this PR) 2026-05-21 | 2026-05-20 silent-failure audit Tier A2. `catalog_query_result = Catalog_ok \| Catalog_unavailable of {reason; message}` 변형 + caller-side decision protocol. **PR-1 (bridge) 머지** (#16860 `catalog_metadata_query` typed bridge + Otoml string-error → typed translation, transitional). **PR-2~5 미머지** — PR-2 keeper_runtime_profile self (6 sites), PR-3 lib/keeper external batch (8 files), PR-4 lib/runtime + dashboard + server batch (5 files), PR-5 API deletion + ratchet regenerate. Status promoted Draft → Active. Related RFC-0088, RFC-0141, RFC-0142, RFC-0148, RFC-0154. |
| 0144 | Withdraw recording-error dedup and metric sunset gates | Withdrawn | (this PR) 2026-05-21 | Typed source errors remain visible; metric thresholds do not control lifecycle or removal. |
| 0145 | Permissive-Silent-Fallback Elimination | Draft | (this PR) 2026-05-21 | 2026-05-20 PR audit Cluster A 워크어라운드 7건 root-fix 우산. `lib/parse_outcome/` (stdlib + Eio only, no Yojson dep) 가 `try f s with _ -> None/[]/default` 패턴을 typed `('a, [`Json_parse_error of string \| `Other of exn]) result` 로 교체. Cancellation 은 re-raise (Eio rules). 7 predecessor PR (#15820/15840/15866/15883/15980/15781/15954) 코드 그대로 유지, 사이트별 별도 PR 로 migration; counter 는 §Override exemption 으로 transitional. Demo: `tool_keeper.cache_ttl_seconds` (#15954 site). Sunset = 6/7 사이트 마이그레이션 + counter 제거 + CI grep gate. Body PR #16780, renumber from 0144 (#16779, collision recovery). Related RFC-0088, RFC-0109, RFC-0144. |
| 0148 | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | (this PR) 2026-05-21 | LLM 이 호출하는 tool 들의 *실패 분류* 가 `Failure msg` (catch-all 문자열) 으로 ~30 사이트 분산. closed sum type `tool_error` 7 variant (`Not_found \| Permission_denied \| Invalid_input \| Resource_exhausted \| Timeout \| Cancelled \| Internal_error`) 로 root-fix — 새 실패 클래스 추가 시 컴파일 강제 exhaustive match. Same-day closure: PR-1 #16948 (module + 7 Alcotest), PR-2 #16958 (6 LLM-facing site codemod + RFC §1.1 hallucination 정정 — audit 인용 8 사이트 → 실측 6 사이트). RFC-0154 (operator-facing System_error_class) 의 LLM-facing 자매. JSON wire `{"kind":"...","detail":"..."}`, `Internal_error.exn` 은 in-process debug 전용 (wire 노출 안 함). Related RFC-0088, RFC-0091, RFC-0105, RFC-0154. |
| 0151 | 4-metric monotone-decrease ratchet for code-smell metrics | Draft | (this PR, renumbered from 0149 due to race w/ PR #16930) 2026-05-20 | PR #16833 ("DIRTY + CI/RFC surface" CLOSED) 의 3-split 첫 번째 step. 4 metric (`godfile_loc_1000plus`=51, `catch_all_arms`=3843, `contains_substring_defs`=29→28, `ignore_no_comment`=113; baseline 2026-05-20) 을 CI 에서 monotone-decrease ratchet 으로 enforce. 절대 임계치 (`legacy metrics backend module` LoC cap 같은 evasion 유도 패턴, legacy metrics backend extraction feedback 참조) 가 아닌 *방향성* gate. `RATCHET-WAIVED: <metric_id> <RFC-NNNN reason>` escape hatch + Override 3-요건 (split-evasion 차단, deprecated path 명시, hard_cap 금지). 본 PR 은 docs-only; `scripts/code-smell/measure.{ml,sh}` + `ci/code-smell-baseline.json` + GH Actions step 은 별도 narrow follow-up 2 PR. Related RFC-0085, RFC-0088, RFC-0126. |
| 0155 | Withdraw centralized operational policy log taxonomy | Withdrawn | (this PR) 2026-05-21 | Source modules emit typed domain events; the generic logger owns no policy classification. |
| 0153 | Runtime Backpressure & Tier Admission — historical | Withdrawn | (this PR) 2026-07-13 | Saturation remains observable but no tier or admission decision controls Keeper execution. |
| 0154 | System_error_class typed SSOT — close substring-classifier loop across backend + telemetry + dashboard | Implemented | (this PR) 2026-05-21 | 5-PR sprint #17015~#17051 (Tool Monitor dashboard UX) 후속. OS-level 실패 분류가 backend 4 substring matcher (`keeper_fd_pressure.ml:97`, `keeper_disk_pressure.ml:55`, `workspace_utils_ops.ml:410`, `keeper_stale_watchdog.ml:203`) 로 분산 + `Telemetry_coverage_gap.record ~error:string` 의 13 caller 가 `Printexc.to_string exn` 으로 압축 + dashboard `classifyCoverageError` 가 *같은 substring vocab 으로 재분류* 하는 정보 손실 cycle. `lib/core/system_error_class.ml` closed-sum SSOT (`Fd_exhaustion \| Disk_exhaustion \| Permission_denied \| Connection_refused \| Timeout \| Other of string`) + wire `error_class` typed tag + dashboard typed-first cascading lookup. 4-PR phased rollout 24h 안 closure: PR-1 #17064 (모듈), PR-3 #17073 (dashboard lookup), PR-4 #17072 (cutover runbook), PR-2 #17078 (wire + 4 matcher 통폐합). Workaround Rejection Bar 시그니처 #2 (substring 분류기) + #3 (N-of-M, PR #17051 disk_exhaustion 가 2-of-M 누적 시작) root fix. Related RFC-0042, RFC-0088, RFC-0097, RFC-0105, RFC-0122, RFC-0142, RFC-0148, RFC-0149. |
| 0160 | Withdrawn Shell IR decision-substrate plan | Withdrawn | (this PR) 2026-07-13 | Representation work remains historical context; policy stamping and hierarchy-oriented phases are superseded by the non-hierarchical Keeper Gate. |
| 0162 | JSONL Write-Path FD Pressure Root-Fix | Draft | (this PR) 2026-05-23 | Dashboard fleet-health 패널 audit (2026-05-23) 가 추적한 7 surface signal 이 `.masc/` JSONL writer 의 단일 write-path fd/disk 압박으로 수렴. RFC-0108 §3.3 의 *cross-domain fd cache 비목표* 가정 (fd 수가 keeper N≤64 수준) 을 production evidence (22,440 calls × ENFILE, 30 day-file × 465 MB, dashboard 30s self-amplification) 로 반증. 4-phase migration: Phase 0a (`Fs_compat.append_jsonl` `mkdir_p` once-per-path memoize — append 당 stat 1→0, RFC-0108 직교), Phase 0b (`Dated_jsonl.count_entries` 10s TTL cache — dashboard scan amplification 3× ↓), Phase 1 (`MASC_TOOL_CALL_LOG_RETENTION_DAYS` opt-in → opt-out default 30d, *mli line 99-103 의 "default is 30 days" 약속 회복*), Phase 2 (per-domain fd cache — RFC-0108 §3.3 invalidate). 별도 RFC 후보로 `blocker_class` typed variant 에 `Fd_pressure_blocked` 추가 (§3.5 observability gap, scope 밖). Workaround Rejection Bar §1 (counter/WARN 추가 아닌 syscall 제거) + §2 (substring 없음) + §3 (N-of-M 회피 — 각 phase 가 root contributor 1 개 닫음) 모두 회피. Related RFC-0089, RFC-0097, RFC-0108, RFC-0137, RFC-0154. |

## Closed RFC Archive

> Archive of RFCs whose frontmatter `status` is `Implemented` or `Superseded`.
> Generated from `rg "^status: (Implemented|Superseded)" docs/rfc/`.
> Last updated: 2026-05-23.

### Implemented

- [RFC-0010 — ocamlformat config reconciliation](RFC-0010-ocamlformat-config-reconciliation.md)
- [RFC-0071 — Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern](RFC-0071-exhaustive-match-sweep-codemod.md)
- [RFC-0072 — Type-encoded keeper sub-FSM transitions (runtime + turn_phase)](RFC-0072-keeper-sub-fsm-transitions-typed.md)
- [RFC-0073 — Tool Readiness Probe — Typed Precondition + Runtime Gap Disclosure](RFC-0073-tool-readiness-probe.md)
- [RFC-0077 — Write-side silent failure — typed propagation](RFC-0077-write-side-silent-failure-typed.md)
- [RFC-0079 — Log row typed encoder + silent-drop removal](RFC-0079-log-row-typed-encoder.md)
- [RFC-0080 — Tool registry SSOT — collapse 15-fold OR membership into typed Tool_name boundary](RFC-0080-tool-registry-ssot.md)
- [RFC-0081 — OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline](RFC-0081-telemetry-envelope-and-pivot-timeline.md)
- [RFC-0084 — Keeper→Tool Dispatch Unification + 100% Trace/Telemetry](RFC-0084-keeper-tool-dispatch-unification.md)
- [RFC-0086 — Keeper namespace bulk promotion to sub-library](RFC-0086-keeper-namespace-bulk-promotion.md)
- [RFC-0087 — Tool Dispatch Path Unification + Legacy Purge](RFC-0087-tool-dispatch-path-unification-and-legacy-purge.md)
- [RFC-0089 — String Classifier to Typed Variant — direct replacement, no lint](RFC-0089-string-classifier-to-typed-variant.md)
- [RFC-0090 — Write-side success-model attribution — finish N-of-M migration](RFC-0090-write-side-success-model-attribution.md)
- [RFC-0091 — Execute tool: cmd string → typed Argv schema (lexer/validator 박멸)](RFC-0091-execute-typed-argv.md)
- [RFC-0093 — Board persistence — path unification (snapshot vs append)](RFC-0093-board-persistence-path-unification.md)
- [RFC-0095 — Provider-D-compat provider streaming wire-up](RFC-0095-provider-d-compat-streaming-wire-up.md)
- [RFC-0096 — Keeper Turn Contract — multi-turn reasoning + runtime SPOF root-fix](RFC-0096-keeper-turn-contract-multi-turn-and-runtime-spof.md)
- [RFC-0098 — Typed JSON-RPC error envelope & production-code silent-failure lint](RFC-0098-typed-jsonrpc-error-envelope.md)
- [RFC-0102 — Pre-turn runtime availability gate — reuse, not new surface](RFC-0102-pre-turn-runtime-availability-gate.md)
- [RFC-0105 — Provider-D-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope](RFC-0105-provider-d-compat-typed-error-mapping.md)
- [RFC-0110 — Tool-pair atomicity at write boundary — sunset compaction repair fabrication](RFC-0110-tool-pair-atomicity-write-boundary.md)
- [RFC-0111 — Goal mint atomicity — auto-goal uniqueness invariant at write boundary](RFC-0111-goal-mint-atomicity-uniqueness-invariant.md)
- [RFC-0112 — Typed JSON parse boundary — eliminate silent-drop fallback across read sites](RFC-0112-typed-json-parse-boundary.md)
- [RFC-0113 — Withdraw KeeperReactionLiveness runtime hierarchy](RFC-0113-keeper-reaction-liveness-runtime.md)
- [RFC-0114 — KSM event precondition enforcement at apply_event boundary](RFC-0114-ksm-precondition-enforcement.md)
- [RFC-0115 — KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_exhausted](RFC-0115-ktc-turn-phase-spec-runtime-parity.md)
- [RFC-0116 — KCR fallback cap mechanism parity — explicit counter at spec ↔ visited-list at runtime](RFC-0116-kcr-fallback-cap-mechanism-parity.md)
- [RFC-0117 — KCR item-health representation parity — typed Degraded variant + spec cooldown action + PerKeeperIsolation correction](RFC-0117-kcr-health-state-representation-parity.md)
- [RFC-0118 — KCT NoTerminalRuntime S1 — typed Result at select_runtime boundary + Zombie mapping correction](RFC-0118-kct-terminal-runtime-contract.md)
- [RFC-0119 — Observer spec mapping table drift lint — guard-marker validator for OCaml↔TLA+ collapse projections](RFC-0119-observer-spec-mapping-table-drift-lint.md)
- [RFC-0122 — Keeper disk pressure — process-local fleet failure mode beyond FD](RFC-0122-keeper-disk-pressure.md)
- [RFC-0123 — Briefing last_event fabrication — option-typed write boundary](RFC-0123-briefing-last-event-fabrication-write-boundary.md)
- [RFC-0126 — Silent fallback discipline (typed split for option/result wildcard arms)](RFC-0126-silent-fallback-discipline.md)
- [RFC-0129 — Runtime attempt idle-cap: kill the reserve_fraction band-aid](RFC-0129-http-idle-timeout-and-streaming-progress.md)
- [RFC-0131 — Shell Command Gate facade — multi-caller IR-first validation](RFC-0131-shell-command-gate-facade.md)
- [RFC-0132 — Redaction SSOT — `runtime` boundary-label private type](RFC-0132-redaction-ssot.md)
- [RFC-0133 — Keeper Phase Casing SSOT Consolidation](RFC-0133-keeper-phase-casing-ssot-consolidation.md)
- [RFC-0135 — Dashboard Keeper Operational Surface — Typed SSOT](RFC-0135-dashboard-keeper-operational-ssot.md)
- [RFC-0136 — Keeper Unified Turn — Stage Decomposition of run_keeper_cycle](RFC-0136-keeper-unified-turn-decomposition.md)
- [RFC-0138 — dashboard snapshot lock free architecture](RFC-0138-dashboard-snapshot-lock-free-architecture.md)
- [RFC-0140 — Dashboard Wire-Format Codec Layer](RFC-0140-dashboard-wire-codec-layer.md)
- [RFC-0148 — Typed `tool_error` Variant for LLM-Facing Tool Failure Surface](RFC-0148-typed-tool-error-variant.md)
- [RFC-0149 — audit telemetry as fix sunset](RFC-0149-audit-telemetry-as-fix-sunset.md)
- [RFC-0151 — 4-metric monotone-decrease ratchet for code-smell metrics](RFC-0151-code-smell-monotone-ratchet.md)
- [RFC-0153 — Runtime Backpressure & Tier Admission](RFC-0153-runtime-backpressure-and-admission.md)
- [RFC-0154 — System_error_class typed SSOT — close substring-classifier loop across backend + telemetry + dashboard](RFC-0154-system-error-class-typed-ssot.md)
- [RFC-0155 — System_log_category Typed SSOT — emit-side closed sum for ops log taxonomy](RFC-0155-system-log-category-typed-ssot.md)

### Superseded

- RFC-0055 — Runtime Fallback Chain Capability-Tier Routing (file missing; superseded_by 0058 per table above)
