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
| 0001 | Det/NonDet Boundary Hardening, Emotional Recovery Loop, and Adversarial Harness | Draft | b188e7845a 2026-07-10 | - |
| 0002 | Keeper 11-State Machine + Det/NonDet Boundary Formalization | reference | b188e7845a 2026-07-10 | - |
| 0003 | Keeper Composite Lifecycle Observer | reference | b188e7845a 2026-07-10 | - |
| 0004 | OCaml ↔ TypeScript shared contract — SSE + gRPC-web | Active | 03d5feaf25 2026-07-08 | - |
| 0005 | Typed Capability Substrate for Local Exec Core | Draft | 03d5feaf25 2026-07-08 | - |
| 0006 | Keeper Surface And Sandbox | Draft | 03d5feaf25 2026-07-08 | - |
| 0008 | Keeper Credential Provider | Draft | 03d5feaf25 2026-07-08 | - |
| 0009 | Runtime Trust Phase 2: Operator Recommendations + Opt-in Persist | Draft | 03d5feaf25 2026-07-08 | - |
| 0010 | ocamlformat config reconciliation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0012 | Mid-Turn Progress Probe | Draft | 03d5feaf25 2026-07-08 | - |
| 0019 | Keeper Credential Unification | Draft | 03d5feaf25 2026-07-08 | - |
| 0020 | Keeper heartbeat — Event Layer / Policy Layer separation | Active | 03d5feaf25 2026-07-08 | - |
| 0022 | Runtime Attempt Liveness Contract | Draft | 03d5feaf25 2026-07-08 | - |
| 0024 | Ollama Runtime Integration + KV Cache Optimization | Draft | 03d5feaf25 2026-07-08 | - |
| 0025 | Tiered Small-Model Runtime (4B → 9B → 70B+) | Draft | 03d5feaf25 2026-07-08 | - |
| 0027 | Retired tension and meta-cognition draft | Superseded | bb4f12fde1 2026-07-10 | - |
| 0029 | Dashboard Fiber-Batched Aggregation | Active | 03d5feaf25 2026-07-08 | - |
| 0032 | Environment Knob Unification | Draft | 03d5feaf25 2026-07-08 | - |
| 0034 | d — release_stale_claims agent-side sync | Draft | 03d5feaf25 2026-07-08 | - |
| 0035 | Cognitive IDE Master Plan Integration | Draft | 03d5feaf25 2026-07-08 | - |
| 0036 | oas Cognitive Mapping (companion to RFC-0035) | Draft | 03d5feaf25 2026-07-08 | - |
| 0037 | Local-first Keeper Enablement: Harness/User Boundary | Draft | 03d5feaf25 2026-07-08 | - |
| 0038 | Runtime Routing Intent Preservation | Draft | b188e7845a 2026-07-10 | RFC-0038-phase-2-keeper-identity-canonical.md |
| 0041 | Runtime Routing Architecture — Group/Item Hierarchy with Health-Aware Fallback | Draft | 03d5feaf25 2026-07-08 | - |
| 0042 | Closed sum type for keeper turn terminal code | Active | 03d5feaf25 2026-07-08 | - |
| 0043 | Distribute legacy metrics backend metric ownership to domain modules | Active | 03d5feaf25 2026-07-08 | - |
| 0044 | Typed persistence read-drop reason + Result-based reads | Active | 03d5feaf25 2026-07-08 | - |
| 0045 | SDK turn boundary alignment with MASC keeper FSM | Draft | 03d5feaf25 2026-07-08 | - |
| 0046 | Keeper Detail FSM Hub as SSOT | Active | 03d5feaf25 2026-07-08 | - |
| 0047 | `oas_*` adapter family decomposition (consumer-only OAS boundary) | Draft | 03d5feaf25 2026-07-08 | - |
| 0049 | Dashboard Surface Telemetry Foundation | Draft | 03d5feaf25 2026-07-08 | - |
| 0050 | Dashboard Component Ownership Decomposition | Active | 03d5feaf25 2026-07-08 | - |
| 0051 | run_named closure decomposition | Active | 03d5feaf25 2026-07-08 | - |
| 0052 | Boot-time Required Invariants (typed) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0053 | Tool Dispatch Session-Local Handles | Implemented | 03d5feaf25 2026-07-08 | - |
| 0054 | PPX for Typed Capability Substrate Phase 2 (codegen track) | Active | 03d5feaf25 2026-07-08 | - |
| 0056 | Incremental Sub-Library Extraction from Flat masc Library | Active | 03d5feaf25 2026-07-08 | - |
| 0057 | Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation | Draft | 03d5feaf25 2026-07-08 | - |
| 0058 | Terminal Fallback Capability Exemption | Draft | 03d5feaf25 2026-07-08 | RFC-0058-phase-5-erase-provider-variant.md |
| 0062 | Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class (Reverse-Engineered Initi... | Draft | 03d5feaf25 2026-07-08 | - |
| 0063 | Telemetry Feedback Loop & Cooperative Scheduling Safety | Draft | 03d5feaf25 2026-07-08 | - |
| 0064 | Descriptor-Owned Tool Surface | Superseded | 03d5feaf25 2026-07-08 | - |
| 0065 | Keeper Tool Selection Lifecycle - TLA+ Coverage Extension | Active | 03d5feaf25 2026-07-08 | - |
| 0067 | Goal-Scope Observation→Claim Atomicity | Draft | 03d5feaf25 2026-07-08 | - |
| 0068 | Typed `Keeper_turn_disposition` (operator-facing closed sum) | Draft | 03d5feaf25 2026-07-08 | - |
| 0069 | Awareness Channel Split | Active | 03d5feaf25 2026-07-08 | - |
| 0070 | Keeper Sandbox Runtime — Pure/Edge Separation | Active | 03d5feaf25 2026-07-08 | - |
| 0071 | Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern | Implemented | 03d5feaf25 2026-07-08 | - |
| 0072 | Type-encoded keeper sub-FSM transitions (runtime + turn_phase) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0073 | Tool Readiness Probe — Typed Precondition + Runtime Gap Disclosure | Implemented | 03d5feaf25 2026-07-08 | - |
| 0074 | Sandbox Credential Auto-provision | Retired | 03d5feaf25 2026-07-08 | - |
| 0075 | Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate | Implemented | 03d5feaf25 2026-07-08 | - |
| 0076 | Tool Readiness Notification Channel | Retired | 03d5feaf25 2026-07-08 | - |
| 0077 | Write-side silent failure — typed propagation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0079 | Log row typed encoder + silent-drop removal | Implemented | 03d5feaf25 2026-07-08 | - |
| 0080 | Tool registry SSOT — collapse multi-source membership into typed Keeper resol... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0081 | OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline | Implemented | 03d5feaf25 2026-07-08 | - |
| 0082 | Keeper `last_blocker` auto-clear + runtime recovery escalation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0083 | Dashboard system-actor convention typed unification | Implemented | 03d5feaf25 2026-07-08 | - |
| 0084 | Keeper→Tool Dispatch Unification + 100% Trace/Telemetry | Implemented | 03d5feaf25 2026-07-08 | - |
| 0086 | Keeper namespace bulk promotion to sub-library | Implemented | 03d5feaf25 2026-07-08 | - |
| 0087 | Tool Dispatch Path Unification + Legacy Purge | Implemented | 03d5feaf25 2026-07-08 | - |
| 0088 | Counter-as-Fix → Result Propagation (umbrella scoping) | Active | 03d5feaf25 2026-07-08 | - |
| 0089 | String Classifier to Typed Variant — direct replacement, no lint | Implemented | 03d5feaf25 2026-07-08 | - |
| 0090 | Write-side success-model attribution — finish N-of-M migration | Implemented | 03d5feaf25 2026-07-08 | - |
| 0091 | Execute tool: cmd string → typed Argv schema (lexer/validator 박멸) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0093 | Board persistence — path unification (snapshot vs append) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0094 | Compact cooldown semantics split decision record | Superseded | bb4f12fde1 2026-07-10 | - |
| 0095 | Provider-D-compat provider streaming wire-up | Implemented | 03d5feaf25 2026-07-08 | - |
| 0096 | Keeper Turn Contract — multi-turn reasoning + runtime SPOF root-fix | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0097 | Keeper sandbox container reuse (long-running sandbox per keeper) | Active | 03d5feaf25 2026-07-08 | - |
| 0098 | Typed JSON-RPC error envelope & production-code silent-failure lint | Implemented | b188e7845a 2026-07-10 | - |
| 0099 | Session lifecycle — typed events, explicit eviction, resume backpressure | Active | 03d5feaf25 2026-07-08 | - |
| 0100 | Streamable HTTP as default transport (MCP 2025-03-26) | Active | 03d5feaf25 2026-07-08 | - |
| 0101 | FD accountant — generic Eio.Pool extension to cover all spawn classes | Active | 03d5feaf25 2026-07-08 | - |
| 0102 | Pre-turn runtime availability gate — reuse, not new surface | Implemented | 03d5feaf25 2026-07-08 | - |
| 0103 | Log retention opt-in + JSONL volume root reduction | Draft | 03d5feaf25 2026-07-08 | - |
| 0104 | Keeper task → default repo binding (sandbox cwd disambiguation) | Draft | 03d5feaf25 2026-07-08 | - |
| 0105 | OpenAI-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope | Implemented | 03d5feaf25 2026-07-08 | - |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | 03d5feaf25 2026-07-08 | - |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker ... | Active | 03d5feaf25 2026-07-08 | - |
| 0108 | PR / Worktree Operation Safety Gates | Implemented | 03d5feaf25 2026-07-08 | - |
| 0109 | Cdal_evidence_gate — typed verdict consultation | Active | 03d5feaf25 2026-07-08 | - |
| 0110 | Tool-pair atomicity at write boundary — sunset compaction repair fabrication | Implemented | 03d5feaf25 2026-07-08 | - |
| 0111 | Goal mint atomicity — auto-goal uniqueness invariant at write boundary | Implemented | b188e7845a 2026-07-10 | - |
| 0112 | Typed JSON parse boundary — eliminate silent-drop fallback across read sites | Implemented | 03d5feaf25 2026-07-08 | - |
| 0113 | KeeperReactionLiveness L1–L5 runtime — phased OCaml mirror of TLA+ design ground | Implemented | b188e7845a 2026-07-10 | - |
| 0114 | KSM event precondition enforcement at apply_event boundary | Implemented | 03d5feaf25 2026-07-08 | - |
| 0116 | KCR fallback cap mechanism parity — explicit counter at spec ↔ visited-list a... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0117 | KCR item-health representation parity — typed Degraded variant + spec cooldow... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0118 | KCT NoTerminalRuntime S1 — typed Result at select_runtime boundary + Zombie m... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0119 | Observer spec mapping table drift lint — guard-marker validator for OCaml↔TLA... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0120 | Cross-spec set-name divergence — 3-class classification framework (STALE / DE... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0121 | Config-dir resolution — single active root, no implicit fallback | Active | 03d5feaf25 2026-07-08 | - |
| 0122 | Keeper disk pressure — process-local fleet failure mode beyond FD | Implemented | 03d5feaf25 2026-07-08 | - |
| 0123 | Briefing last_event fabrication — option-typed write boundary | Implemented | 03d5feaf25 2026-07-08 | - |
| 0124 | Keeper Admission Denial Boundary | Draft | 03d5feaf25 2026-07-08 | - |
| 0125 | Bounded subprocess discipline: per-call Switch scope + Fiber.first timeout race | Active | 03d5feaf25 2026-07-08 | - |
| 0126 | Silent fallback discipline (typed split for option/result wildcard arms) | Implemented | 03d5feaf25 2026-07-08 | - |
| 0127 | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | 03d5feaf25 2026-07-08 | - |
| 0129 | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | 03d5feaf25 2026-07-08 | - |
| 0131 | Shell Command Gate facade — multi-caller IR-first validation | Implemented | 03d5feaf25 2026-07-08 | - |
| 0132 | Redaction SSOT — `runtime` boundary-label private type | Implemented | 03d5feaf25 2026-07-08 | - |
| 0134 | Persistence read-drop root fix (recovery story for RFC-0044) | Active | b188e7845a 2026-07-10 | - |
| 0135 | Dashboard Keeper Operational Surface — Typed SSOT | Implemented | b188e7845a 2026-07-10 | - |
| 0136 | Keeper Unified Turn — Stage Decomposition of run_keeper_cycle | Implemented | 03d5feaf25 2026-07-08 | - |
| 0137 | Host FD pressure → Keeper pause (safety-net for Docker VM FD accumulation) | Active | 03d5feaf25 2026-07-08 | - |
| 0138 | Dashboard Snapshot Lock-Free Immutable Architecture | Implemented | 03d5feaf25 2026-07-08 | - |
| 0139 | Agent Status Vocabulary SSOT | Active | 03d5feaf25 2026-07-08 | - |
| 0140 | Dashboard Wire-Format Codec Layer | Implemented | 03d5feaf25 2026-07-08 | - |
| 0141 | TOML Field Resolution Typed Variant for repo_manager | Implemented | 03d5feaf25 2026-07-08 | - |
| 0142 | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | 03d5feaf25 2026-07-08 | - |
| 0143 | keeper_runtime_profile Typed Catalog Query Result | Active | 03d5feaf25 2026-07-08 | - |
| 0144 | Workaround Sunset Tracking for Keeper Dedup Carryovers | Active | 03d5feaf25 2026-07-08 | - |
| 0145 | Permissive-Silent-Fallback Elimination | Active | 03d5feaf25 2026-07-08 | - |
| 0147 | Keeper Agent Run — Stage Decomposition of run_turn Step 8 | Draft | b188e7845a 2026-07-10 | - |
| 0148 | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | 03d5feaf25 2026-07-08 | - |
| 0149 | Audit-Driven Telemetry-as-Fix Sunset | Implemented | 03d5feaf25 2026-07-08 | - |
| 0150 | Keeper Attention Signal — backend 단일 typed wire envelope | Implemented | b188e7845a 2026-07-10 | - |
| 0151 | 4-metric monotone-decrease ratchet for code-smell metrics | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0152 | Keeper Auto-Resume for All Pause Paths | Active | 03d5feaf25 2026-07-08 | - |
| 0153 | Runtime Backpressure & Tier Admission | Implemented | 03d5feaf25 2026-07-08 | - |
| 0154 | System_error_class typed SSOT — close substring-classifier loop across backen... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0155 | System_log_category Typed SSOT — emit-side closed sum for ops log taxonomy | Active | 03d5feaf25 2026-07-08 | - |
| 0156 | OAS total timeout 제거 — turn timeout + stream idle 두 layer로 단순화 | Implemented | 03d5feaf25 2026-07-08 | - |
| 0157 | Runtime pre-turn required-tool filter — provider capability boundary | Active | 03d5feaf25 2026-07-08 | - |
| 0158 | OAS retry-admission typed error — split server timeout from didn't-try | Draft | 03d5feaf25 2026-07-08 | - |
| 0159 | Reason_internal_error typed split — close string-classifier catch-all | Draft | 03d5feaf25 2026-07-08 | - |
| 0160 | Shell IR 1급 승격 — single-source decision substrate across producer/classifier/... | Implemented | 03d5feaf25 2026-07-08 | - |
| 0161 | Tool Error Hint Symmetry Enforcement | Draft | 03d5feaf25 2026-07-08 | - |
| 0162 | JSONL Write-Path FD Pressure Root-Fix | Draft | 03d5feaf25 2026-07-08 | - |
| 0163 | Tier-group capability profile route canonicalization — typed dedup and bypass... | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0164 | Voice tool abstraction integrity — keeper voice-flag deletion + runtime bound... | Draft | 03d5feaf25 2026-07-08 | - |
| 0167 | CLI-Tool-B omission-dedup + Llama endpoint-discovery feature-path purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0168 | Dashboard upstream-LLM-provider color palette purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0169 | Dashboard common/* MCP-client attribution header purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0170 | Dashboard provider-b palette closure (RFC-0168 N-of-M follow-up) | Draft | 03d5feaf25 2026-07-08 | - |
| 0171 | Design-canvas + ui_kits mock data vendor purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0172 | Big-bang vendor purge across docs, audits, RFCs, design-system, tests | Draft | 03d5feaf25 2026-07-08 | - |
| 0173 | OCaml lib/bin/test vendor purge (identifier + string literal) | Draft | 03d5feaf25 2026-07-08 | - |
| 0174 | Dashboard substring classifier to typed — TypeScript | Draft | 03d5feaf25 2026-07-08 | - |
| 0175 | Godfile decomposition Wave D — keeper core 5-file split | Draft | 03d5feaf25 2026-07-08 | - |
| 0176 | OAS vendor-purge migration — consume agent_sdk 0.198.0 | Implemented | 03d5feaf25 2026-07-08 | - |
| 0177 | Phonebook internal vendor-coupled enum purge | Draft | 03d5feaf25 2026-07-08 | - |
| 0178 | Types Sub-library Extraction with `_intf.ml` mli-only Surface (typed-SSOT) | Draft | 03d5feaf25 2026-07-08 | - |
| 0179 | ToolDescriptor Ecosystem Coverage Extension to Workspace Tools | Draft | 03d5feaf25 2026-07-08 | - |
| 0180 | 24h Runtime ERROR 7-Pattern Sweep Roadmap | Draft | 03d5feaf25 2026-07-08 | - |
| 0181 | Capability/intent-based runtime SSOT | Draft | 03d5feaf25 2026-07-08 | - |
| 0182 | masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation | Draft | 03d5feaf25 2026-07-08 | - |
| 0184 | Runtime phonebook typed roundtrip for protocol/flavor/provider identifiers | Draft (Deferred) | 03d5feaf25 2026-07-08 | - |
| 0189 | Typed Tool_result.result variant — eliminating boolean blindness in tool disp... | Draft | 03d5feaf25 2026-07-08 | - |
| 0190 | Descriptor as Visibility/Metadata SSOT — Surface Projection from descriptor.p... | Draft | 03d5feaf25 2026-07-08 | - |
| 0191 | Descriptor as Policy SSOT — Consolidate keeper_tool_policy axes onto descript... | Draft | 03d5feaf25 2026-07-08 | - |
| 0192 | Runtime Deadline Propagation — Cumulative budget invariant for runtime tier-wait | Draft | 03d5feaf25 2026-07-08 | - |
| 0194 | Tool Surface Semantic SSOT — Guiding Principles | Draft | 03d5feaf25 2026-07-08 | - |
| 0197 | Runtime Attempt Watchdog — Per-Candidate Wrap + Shared Deadline | Draft | 03d5feaf25 2026-07-08 | - |
| 0198 | Execute Typed Redirection (Shell IR Syntax Leakage Closure) | Draft | 03d5feaf25 2026-07-08 | - |
| 0199 | Evidence-Driven Auto-Approval for Deterministic Verification Tasks | Draft | b188e7845a 2026-07-10 | - |
| 0200 | Time constants 를 leaf library 로 분리 | Draft | 03d5feaf25 2026-07-08 | - |
| 0201 | Activity Events Wait-Free Snapshot | Draft | 03d5feaf25 2026-07-08 | - |
| 0203 | In-process Discord connector | Implemented (Phase 3 cutover landed 2026-05-29) | 03d5feaf25 2026-07-08 | - |
| 0204 | Dashboard Read Serving Isolation from Fleet Compute | Draft | 03d5feaf25 2026-07-08 | - |
| 0205 | Keeper Module Consolidation — Eliminate Facade Anti-Pattern | Draft | 03d5feaf25 2026-07-08 | - |
| 0206 | Runtime 개념 — runtime→Runtime 재탄생 | Draft | 03d5feaf25 2026-07-08 | - |
| 0207 | Per-keeper LLM runtime routing | Draft | 03d5feaf25 2026-07-08 | - |
| 0208 | Typed Domain Classification — String Convention → Variant | Draft | 03d5feaf25 2026-07-08 | - |
| 0210 | Keeper Playground Repo Currency (fetch + fast-forward, work-preserving) | Draft | 03d5feaf25 2026-07-08 | - |
| 0211 | Persona ⊥ {model, runtime}, opaque runtime id, runtime.toml keeper-assignment... | Draft | 03d5feaf25 2026-07-08 | - |
| 0212 | Separate keeper-exposure policy from the Tool-dispatch routing tag (module_ta... | Draft | 03d5feaf25 2026-07-08 | - |
| 0213 | Keeper sandbox/playground isolation model (fix sandbox_repo_not_ready + macOS... | Draft | 03d5feaf25 2026-07-08 | - |
| 0214 | OTel GenAI Semantic Convention Migration | Draft | 03d5feaf25 2026-07-08 | - |
| 0215 | Keeper sub-library extraction campaign — sequence and per-PR gates | Draft | 03d5feaf25 2026-07-08 | - |
| 0216 | Per-Keeper Decline Memory (orphan-task churn root fix) | Draft | 03d5feaf25 2026-07-08 | - |
| 0217 | Telemetry Backend Otel 단일화 (Retired Backend Purge) | Draft | 03d5feaf25 2026-07-08 | - |
| 0218 | Keeper tool-surface coherence + web-tooling roadmap — phases and per-phase gates | Draft | 03d5feaf25 2026-07-08 | - |
| 0219 | Remove Sandbox Repo Patrol Gates | Draft | 03d5feaf25 2026-07-08 | - |
| 0220 | Decouple keeper liveness from verification state + guaranteed satisfier for e... | Draft | 03d5feaf25 2026-07-08 | - |
| 0221 | Atomic verification submission — task_status as the sole outcome authority | Implemented (steps 1-3 merged #20613/#20617; steps 4-5 measured then dropped, §3.3/§3.4) | 03d5feaf25 2026-07-08 | - |
| 0222 | Typed acceptance criterion + harness-driven completion for checkable tasks | Draft | 03d5feaf25 2026-07-08 | - |
| 0223 | Typed connector surfaces: presence in world prompt, pull-based lane context, ... | Draft | 03d5feaf25 2026-07-08 | - |
| 0224 | Structured completion report for free-text contract items | Draft | 03d5feaf25 2026-07-08 | - |
| 0225 | Per-keeper turn single-flight admission | Draft | 03d5feaf25 2026-07-08 | - |
| 0226 | Ambient lane recording: record-vs-trigger decouple for connector surfaces | Draft | 03d5feaf25 2026-07-08 | - |
| 0227 | Keeper benchmark canary: wire verify -> gated promote -> rollback for per-kee... | Draft | 03d5feaf25 2026-07-08 | - |
| 0228 | Paged lane pull + fact-retention harness: digest without a summarizer | Draft | 03d5feaf25 2026-07-08 | - |
| 0229 | Keeper person notes: deliberate per-speaker memory beyond the log window | Draft | 03d5feaf25 2026-07-08 | - |
| 0230 | Keeper mention/scope reactivity: cursor-free salience to complement pull-base... | Draft | 03d5feaf25 2026-07-08 | - |
| 0232 | Typed lane event model: parse at the write boundary, never re-derive by strin... | Draft | 03d5feaf25 2026-07-08 | - |
| 0233 | Typed turn observability: TurnRecord prompt-block provenance + canonical tool... | Draft | b188e7845a 2026-07-10 | - |
| 0234 | Scheduled internal automation with separate execution approval | Draft | 03d5feaf25 2026-07-08 | - |
| 0235 | Voice output transport: browser-addressed audio delivery with device-routed p... | Draft | 03d5feaf25 2026-07-08 | - |
| 0236 | Voice input transport: browser-captured speech-to-text for the dashboard comp... | Draft | 03d5feaf25 2026-07-08 | - |
| 0237 | Eliminate the write_meta ~force escape hatch (route snapshot writes through C... | Draft | b188e7845a 2026-07-10 | - |
| 0239 | Semantic-identity guards for keeper memory and anti-thrash | Draft | b188e7845a 2026-07-10 | - |
| 0240 | Tool-pair invariant enforced at write-time (eliminate repair-on-read) | Draft | 03d5feaf25 2026-07-08 | - |
| 0241 | external-attention store lifecycle: read-side bound, retention, and typed tai... | Draft | 03d5feaf25 2026-07-08 | - |
| 0242 | Retired continuity prose-filter draft | Superseded | bb4f12fde1 2026-07-10 | - |
| 0243 | Memory OS confidence mutability via write-side fact upsert | Draft | 03d5feaf25 2026-07-08 | - |
| 0244 | Memory OS recall: turn-seeded deterministic lexical retrieval, with provenanc... | Draft | 03d5feaf25 2026-07-08 | - |
| 0245 | Exempt goalless tasks from the per-goal WIP claim cap | Withdrawn | 03d5feaf25 2026-07-08 | - |
| 0246 | Wake-cascade Recovery Tombstone | Draft | 03d5feaf25 2026-07-08 | - |
| 0247 | Memory OS purge + LLM-judgment rebuild — implementation plan (phase of RFC-0247) | Draft | 03d5feaf25 2026-07-08 | - |
| 0248 | Announce-as-data — typed observation provenance for board activity | Draft | b188e7845a 2026-07-10 | - |
| 0249 | Remove the dead `stale_factor` field (execute RFC-0239/0243/0244/0247) | Draft | 03d5feaf25 2026-07-08 | - |
| 0250 | Stale-run window — give the closed `Idle_turn` variant its first producer | Draft | 03d5feaf25 2026-07-08 | - |
| 0251 | Memory OS: record well, do not value — remove the scoring layer | Draft | 03d5feaf25 2026-07-08 | - |
| 0252 | Fusion: 패널+심판(panel+judge) 심의 루프 (MASC 내장) | Draft | 03d5feaf25 2026-07-08 | - |
| 0253 | Dashboard keeper-v2 surfaces: canonical spacing/radius token scale + off-scal... | Draft | 03d5feaf25 2026-07-08 | - |
| 0254 | Shell IR Approval Gate — Autonomous Production Policy | Draft | 03d5feaf25 2026-07-08 | - |
| 0255 | Shell-IR Path Policy — Typed Path-Scope, Read/Write Asymmetry, and Catastroph... | Draft | 03d5feaf25 2026-07-08 | - |
| 0256 | Migrate hand-rolled Mutex lock/protect/unlock to Mutex.protect | Draft | 03d5feaf25 2026-07-08 | - |
| 0257 | Per-keeper memory execution lane | Draft | b188e7845a 2026-07-10 | - |
| 0258 | Adversarial Review — Grounded Verdict & Unified Verdict→Action Routing | Draft | 03d5feaf25 2026-07-08 | - |
| 0259 | Memory OS — Volatile Claim Grounding, Retraction & Decay | Draft | 03d5feaf25 2026-07-08 | - |
| 0260 | Provider health gate and audited failover | Draft | 03d5feaf25 2026-07-08 | - |
| 0261 | gRPC LSP failed-initialize FD/process teardown | Draft | 03d5feaf25 2026-07-08 | - |
| 0262 | Completion authority typing — closing the force-bypass and framing completion... | Draft | 03d5feaf25 2026-07-08 | - |
| 0263 | Owner-priority cooperative preemption of in-flight autonomous turns | Draft | 03d5feaf25 2026-07-08 | - |
| 0264 | Memory OS recall outcome-anchored eval harness | Draft | 03d5feaf25 2026-07-08 | - |
| 0265 | Capability-driven proactive runtime reroute (modality-gated) | Draft | 03d5feaf25 2026-07-08 | - |
| 0266 | Fusion async-completion wake + in-progress 가시성 | Draft | 03d5feaf25 2026-07-08 | - |
| 0267 | Make task↔goal links visible and explicitly assignable | Draft | 03d5feaf25 2026-07-08 | - |
| 0268 | Prompt ↔ Closed-sum Variant Sync Gate | Draft | 03d5feaf25 2026-07-08 | - |
| 0269 | Process Critic Loop for Keeper Work Traces | Draft | 03d5feaf25 2026-07-08 | - |
| 0270 | CI Gate merge guard: block merges on a non-success CI Gate and trip on red main | Draft | 03d5feaf25 2026-07-08 | - |
| 0271 | accept-rejected (No_usable_progress) 키퍼 턴의 in-turn recovery arm + thinking-bu... | Draft | 03d5feaf25 2026-07-08 | - |
| 0272 | Memory OS — Episode Log Retention (bounded append for events.jsonl / episodes) | Draft | 03d5feaf25 2026-07-08 | - |
| 0273 | Dashboard-driven keeper config & runtime persistence | Draft | b188e7845a 2026-07-10 | - |
| 0274 | Workspace base_path SSOT — retire env runtime read, thread Workspace.config | Draft | 03d5feaf25 2026-07-08 | - |
| 0275 | Retired cognitive-triple removal record | Implemented | bb4f12fde1 2026-07-10 | - |
| 0276 | Remove Keeper social-model self-report protocol | Implemented | bb4f12fde1 2026-07-10 | - |
| 0277 | Fusion: 이종 패널 그룹(heterogeneous panel groups) + 발동 예산 제거 | Draft | 03d5feaf25 2026-07-08 | - |
| 0278 | Fusion: 같은 model을 다른 prompt로 (same-model panels via panel labels) | Draft | 03d5feaf25 2026-07-08 | - |
| 0279 | Typed completion-contract reason — structured backend emit replacing colon-co... | Draft | 03d5feaf25 2026-07-08 | - |
| 0280 | Fusion: validated preset type (Parse, don't validate) | Draft | 03d5feaf25 2026-07-08 | - |
| 0281 | WebSocket transport SSOT — separate upgrade-attachment from session-protocol,... | Draft | 03d5feaf25 2026-07-08 | - |
| 0282 | Reduce Keeper persona to ordinary instructions | Implemented | bb4f12fde1 2026-07-10 | - |
| 0283 | Fusion: judge-of-judges 위상 (flat/staged reducer) | Draft | 03d5feaf25 2026-07-08 | - |
| 0284 | Keeper Guidance Visibility-Leg Drift Guard | Draft | 1306478509 2026-07-10 | - |
| 0285 | Memory OS — Self-Observation Claim Volatility (closing RFC-0259's internal-st... | Draft | b188e7845a 2026-07-10 | - |
| 0286 | exec/keeper 스택: redirect & turn-termination 경계 소유권 | Draft | 03d5feaf25 2026-07-08 | - |
| 0287 | ws-direct — a single masc-owned WebSocket stack for server and client | Draft | 03d5feaf25 2026-07-08 | - |
| 0288 | Remove per-Keeper goal-horizon fields | Implemented | bb4f12fde1 2026-07-10 | - |
| 0289 | Extract progress-classification into its own library for a single substantive... | Draft | 03d5feaf25 2026-07-08 | - |
| 0290 | Generic keeper background-work tool (spawn → wake-on-completion) | Draft | 03d5feaf25 2026-07-08 | - |
| 0291 | Closed SSE event-type sum + typed broadcast — RFC-0004 Phase A0 Wave 2 increment | Draft | 03d5feaf25 2026-07-08 | - |
| 0292 | Complete lib/auth de-duplication — remove drifted Masc.Auth* test copies | Draft | 03d5feaf25 2026-07-08 | - |
| 0293 | Keeper execution-endpoint backend (host / ephemeral-docker / persistent-docke... | Draft | 03d5feaf25 2026-07-08 | - |
| 0294 | Remove workspace Goal horizon | Implemented | bb4f12fde1 2026-07-10 | - |
| 0295 | Fleet RuntimeBand 5th value — transient (busy tone dead-branch recovery) | Draft | 03d5feaf25 2026-07-08 | - |
| 0296 | CI skip-gate main-push safety-net: always run Build and Test on non-PR events | Draft | 03d5feaf25 2026-07-08 | - |
| 0297 | Keeper lifecycle gate consistency & observability | Draft | b188e7845a 2026-07-10 | - |
| 0298 | fusion judge pool — judge 모델을 preset에서 분리 | Draft | 03d5feaf25 2026-07-08 | - |
| 0299 | RFC-0299 — Typed-Boundary Sweep (string-classifier → closed-sum, dead SSOT re... | Draft | 03d5feaf25 2026-07-08 | - |
| 0300 | RFC-0300 — Dashboard design-token scope consolidation (radius / shadow / type... | Draft | 03d5feaf25 2026-07-08 | - |
| 0301 | Keeper 생성 미디어(이미지/오디오) 대시보드 노출 | Draft | 03d5feaf25 2026-07-08 | - |
| 0302 | Keeper 메모리 파일 I/O off-main-domain 오프로드 (HOL fix) | Draft | 03d5feaf25 2026-07-08 | - |
| 0303 | Stimulus-gated Keeper Wake (retire self-cadence no-progress detect/pause/tomb... | Draft | 03d5feaf25 2026-07-08 | - |
| 0304 | HITL Critical Bounded Escalation (typed `Escalated` phase, fiber-free suspens... | Draft | 03d5feaf25 2026-07-08 | - |
| 0305 | Safety and governance gates fail closed by default | Draft | 03d5feaf25 2026-07-08 | - |
| 0306 | Typed, comment-preserving fusion settings editor | Draft | 03d5feaf25 2026-07-08 | - |
| 0307 | Mid-turn advisor consult for keepers — evaluation and deferral | Draft | 03d5feaf25 2026-07-08 | - |
| 0308 | Verification-required done guard — route verifier-bound tasks through submit_... | Draft | 03d5feaf25 2026-07-08 | - |
| 0309 | Typed gh capability gating — active repo/discussion surfaces behind non-block... | Draft | 03d5feaf25 2026-07-08 | - |
| 0310 | Goal convergence loop — typed metric contract, LLM evaluator boundary, audite... | Draft | b188e7845a 2026-07-10 | - |
| 0311 | Typed evidence gate — retire the substring incantation, judgment to the LLM b... | Accepted | 03d5feaf25 2026-07-08 | - |
| 0312 | Keeper repo mappings are advisory default scope, not access caps | Accepted | 03d5feaf25 2026-07-08 | - |
| 0313 | Keeper Existence Invariance (failure modulates pacing and routing, never exis... | Draft | 03d5feaf25 2026-07-08 | - |
| 0314 | Keeper Recurring Producer (register the autonomous-repeat tasks the runtime a... | Draft | 03d5feaf25 2026-07-08 | - |
| 0315 | Typed wake-turn context and self-directed work lane | Active | bb4f12fde1 2026-07-10 | - |
| 0316 | Merge gating convergence: enforce_admins=true + live Branch Protection Watchdog | Draft | 03d5feaf25 2026-07-08 | - |
| 0317 | In-process Slack connector (Socket Mode) | In progress (PR-1/PR-2 landed; PR-3 implemented; PR-4 sidecar removal pending) | d72c574d8f 2026-07-09 | - |
| 0318 | Operator-overlay LLM approval resolver for non-critical keeper HITL | Draft | 03d5feaf25 2026-07-08 | - |
| 0319 | Operator Approval Mode (AUTO 승인 모드) with separation-of-duties invariant | Draft | 03d5feaf25 2026-07-08 | - |
| 0320 | Keeper connector-aware continuation: carry the originating channel through wa... | Draft | b188e7845a 2026-07-10 | - |
| 0321 | hard_forbidden 거부 위장(is_error=false) — agent_sdk `Block` variant | Draft | b188e7845a 2026-07-10 | - |
| 0322 | Keeper self-registration of own-sandbox repos: stop keepers blocking on opera... | Draft | 03d5feaf25 2026-07-08 | - |
| 0323 | Done via verification + linked re-run tasks (retire Done-reclaim) | Draft | 03d5feaf25 2026-07-08 | - |
| 0324 | keeper repo 경로를 filesystem 진실로 (catalog 거짓 주입 제거) | Draft | 03d5feaf25 2026-07-08 | - |
| 0325 | Sandbox-aware build-tool floor (dune) + actionable host redirect | Draft | 247f5b759f 2026-07-09 | - |
| 0326 | Typed keeper failure classification — eliminate the path-error substring/pref... | Draft | 03d5feaf25 2026-07-08 | - |
| 0327 | compaction LLM — provider-무관 structured output + 활성화/계측/가시화 | Draft | acd910998f 2026-07-09 | - |
| 0328 | Keeper perseveration: grounding-gated memory promotion, active residue purge,... | Draft | b188e7845a 2026-07-10 | - |
| 0329 | Excise the payload-blind Execute governance gate: typed Shell-IR risk with fa... | Draft | 626afed7b7 2026-07-10 | - |
| 0331 | Typed tool effect class (retire the `read_only_patterns` string classifier) | Draft | 7662c42bb3 2026-07-09 | - |
| 0332 | Rejected heuristic memory write dedup draft | Rejected | bb4f12fde1 2026-07-10 | - |
| 0333 | Deterministic cost↔success frontier join for the eval harness | Draft | ae027bed8f 2026-07-09 | - |
| 0334 | Board wake as mailbox delivery: enqueue-always, cap only the wake, one digest... | Draft | 2b0141503c 2026-07-10 | - |
| 0335 | TOML as the Single Settings Source | Draft | e5e4c44f2b 2026-07-09 | - |
| 0336 | Keeper Tool-Call In-Flight Observation (G4 of the autonomous-background goal ... | Draft | 71a6a26f87 2026-07-10 | - |
| 0337 | Evidence Gate Semantics SSOT (rev 2) | Draft | 642aa5ce63 2026-07-10 | - |
| conn | Connector deferred reply: busy-path messages must drain through the chat queu... | Draft | 03d5feaf25 2026-07-08 | - |
| elim | Eliminate Substring Destructive Classifier in Favor of Typed Shell IR | Draft | 03d5feaf25 2026-07-08 | - |
| keep | Vision-as-a-tool delegation (decouple multimodal input from conversation runt... | Draft | 03d5feaf25 2026-07-08 | - |
| runt | Per-runtime note field & dashboard surfacing | Draft | 03d5feaf25 2026-07-08 | - |
| type | # Typed egress-resource capability — durable-remote creation beyond gh subcom... | Draft | 03d5feaf25 2026-07-08 | - |

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
| 0102 | Pre-turn runtime availability gate — reuse, not new surface | Draft | (this PR) 2026-05-17 | Fourth *pre-turn* layer between RFC-0009 (pre-attempt ordering) and RFC-0022 (in-attempt liveness). **Adds zero new types / API / reason codes / broadcast paths / counters** — every typed atom needed already exists: `Failure_runtime_unavailable` (keeper_turn_fsm.ml:8), `No_providers_available` + `"runtime_exhausted_no_providers_available"` (keeper_meta_contract.ml + keeper_unified_turn_types.ml:107), `Runtime_health_filter.health_filter_rejection` typed sum, `Phase_gating → Done(Skipped)` template (4 existing arms in keeper_unified_turn.ml), `runtime_recovered` closure in keeper_stale_watchdog.ml:749-770. Change is (a) extract that closure into a named `Runtime_health_filter.current_availability` and (b) case-split the fail-open policy at keeper_turn_driver.ml:325-345 so `All_local_unhealthy` keeps fail-open but `All_missing_api_key` returns `No_providers_available` immediately. RFC-0088 self-check §6 — *first draft proposed 4 new surfaces and was rejected by its own N-of-M check in same-day amend*. Removes the N-keepers × M-turns/min WARN flood observed 2026-05-17 (memory: `project_runtime_misroute_2026_05_17.md`). Related RFC-0009, RFC-0012, RFC-0022, RFC-0042, RFC-0072, RFC-0088 |
| 0103 | Log retention opt-in + volume-root anchoring | Draft | 9f7b4ce520 2026-05-17 | retroactive index entry — body merged via #15850 (5-PR sprint). Default-disabled retention with explicit opt-in env knob + log volume-root anchored archiver. |
| 0104 | Keeper task → default repo binding (sandbox cwd disambiguation) | Draft | (this PR) 2026-05-17 | 2026-05-17 08:33 prod observation: keeper `tech_glutton` `sandbox root cannot run git/gh: ... multiple sandbox repos exist` hard-fail. Root: task schema has no typed `default_repo` field, so sandbox cwd resolver can't disambiguate when ≥2 repos are mounted. Proposes `Masc_domain.repo_id` opaque type + `task.default_repo : repo_id option` with `resolve_default_cwd` typed function. 5-phase migration. Closes RFC-0006/0070/0097 gap (task↔repo binding). Related RFC-0006, RFC-0036, RFC-0070, RFC-0097. |
| 0105 | Provider-D-compat boundary: `Agent_sdk.Error.t` → HTTP status + typed envelope | Implemented | (this PR) 2026-05-17 | RFC-0098 closeout follow-up audit. RFC-0098 (Implemented #15828) cleared `server_mcp_transport_http` (0 literal codes, 9 typed `Mcp_error_code` sites). This RFC closes the sole remaining lossful boundary in `lib/server/`: `server_openai_compat.ml:125` `Agent_sdk.Error.to_string` typed→string compression, amplified by `route_runtime (_, string) result` signature and `handle_chat_completions` blanket 500 / `"server_error"` flattening. `Openai_compat_error_map.t` total mapping + widened Error tag + envelope `code` field population landed in #15899 (21/21 Alcotest PASS, exhaustive over 9 sdk_error top-level variants, no catch-all). `route_keeper` deeper site at `keeper_turn.ml:521-531` deferred to a separate RFC (larger scope). Related RFC-0098, RFC-0095. |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | (this PR) 2026-05-21 | Existing `scripts/lint-cancel-guard.sh` only matches single-arm `try X with exn -> Y`. **P0 (helper module) + P1 partial 머지**: 8 PR (#15894, 15904, 15917, 15919, 15920, 15925 initial P0+P1 batch + #16949 masc_http_client/pool + #16951 fd_accountant). `lib/cancel_safe/cancel_safe.{ml,mli}` SSOT 존재. **P2 (callbacks) / P3 (ppxlib AST lint) / P4 (regex lint deprecation) 미시작** — P3 가 RFC-0126 Phase 2b prereq. Status promoted Draft → Active. Related RFC-0072, RFC-0097, RFC-0101, RFC-0126. |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport | Draft | (this PR) 2026-05-17 | 2026-05-16 ENFILE storm 의 진짜 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant) 는 같은 사고의 transitional defense — 1/4 kind 만 wired, 3 kind dead branch. (1) cohttp-eio 6.1.1 socket-not-closed bug → `make_closing_client` 워크어라운드 (Eio issue #244 권고 위반); (2) connection pool 부재 (masc + oas); (3) `run_turn:196` ambient switch (turn-scoped FD boundary 없음); (4) subprocess-heavy Docker (`docker run/exec`, `/var/run/docker.sock` 미사용, RFC-0097 spec-only). 4-layer 설계: L1 Transport (Phase B spike → piaf default / cohttp-eio latest 검토), L2 `(host:port) → Client.t` keyed pool, L3 `run_turn` fresh `Eio.Switch.run`, L4 Docker UDS + RFC-0097 활성화. RFC-0101 은 머지 직후 transitional → Phase D + 30일 production soak gate 후 retire. PR #15881 (Sandbox_exec wrap) close. Prior Art: piaf, Tarides Ocsigen→Eio (2025-03), cohttp #85, Eio #244, Eio.Switch axiom. Related RFC-0097, RFC-0100, RFC-0101. |
| 0108 | Atomic JSONL Append (in-process) | Draft | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. 코드베이스에 **3 단계 동시성 보호 누적** (Tier-0: 없음 / Tier-1: `Stdlib.Mutex` + `Append_fd_cache` / Tier-2: `Eio.Mutex`) — 모든 tier 에서 손상 발생. 직접 원인 두 가지: (a) `output_string + flush` 가 두 syscall 이라 race window 존재, (b) record + '\n' 의 *직렬화 단계와 write 단계 분리*로 large record (PIPE_BUF 초과 trajectory prompt dump) 가 multiple `write(2)` 로 쪼개져 다른 writer 끼어듦. 새 `lib/jsonl_atomic/` 모듈 + Eio.Mutex per-path registry + single write(2) loop 으로 SSOT 수렴. 4 writer (`log.ml`, `trajectory.ml`, `dated_jsonl.ml`, → runtime_event_bridge / keeper_reaction_ledger 자동 fix) 마이그레이션. Cross-process flock + Stdlib.Mutex 전역 audit 는 명시적 비목표. 5-PR sprint (RFC → 모듈 → log → trajectory → dated_jsonl). Originally allocated as RFC-0107 but renumbered after RFC-0107 (outbound HTTP) merged first to main (#15900). Related RFC-0079, RFC-0088. |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport | Active | (this PR) 2026-05-17 | 2026-05-16 ENFILE storm 의 진짜 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant) 는 같은 사고의 transitional defense — 1/4 kind 만 wired, 3 kind dead branch. (1) cohttp-eio 6.1.1 socket-not-closed bug → `make_closing_client` 워크어라운드 (Eio issue #244 권고 위반); (2) connection pool 부재 (masc + oas); (3) `run_turn:196` ambient switch (turn-scoped FD boundary 없음); (4) subprocess-heavy Docker (`docker run/exec`, `/var/run/docker.sock` 미사용, RFC-0097 spec-only). 4-layer 설계: L1 Transport (Phase B spike → piaf default / cohttp-eio latest 검토), L2 `(host:port) → Client.t` keyed pool, L3 `run_turn` fresh `Eio.Switch.run`, L4 Docker UDS + RFC-0097 활성화. RFC-0101 은 머지 직후 transitional → Phase D + 30일 production soak gate 후 retire. PR #15881 (Sandbox_exec wrap) close. Prior Art: piaf, Tarides Ocsigen→Eio (2025-03), cohttp #85, Eio #244, Eio.Switch axiom. Related RFC-0097, RFC-0100, RFC-0101. |
| 0108 | Atomic JSONL Append (in-process) | Draft | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. 코드베이스에 **3 단계 동시성 보호 누적** (Tier-0: 없음 / Tier-1: `Stdlib.Mutex` + `Append_fd_cache` / Tier-2: `Eio.Mutex`) — 모든 tier 에서 손상 발생. 직접 원인 두 가지: (a) `output_string + flush` 가 두 syscall 이라 race window 존재, (b) record + '\n' 의 *직렬화 단계와 write 단계 분리*로 large record (PIPE_BUF 초과 trajectory prompt dump) 가 multiple `write(2)` 로 쪼개져 다른 writer 끼어듦. 새 `lib/jsonl_atomic/` 모듈 + Eio.Mutex per-path registry + single write(2) loop 으로 SSOT 수렴. 4 writer (`log.ml`, `trajectory.ml`, `dated_jsonl.ml`, → runtime_event_bridge / keeper_reaction_ledger 자동 fix) 마이그레이션. Cross-process flock + Stdlib.Mutex 전역 audit 는 명시적 비목표. 5-PR sprint (RFC → 모듈 → log → trajectory → dated_jsonl). Originally allocated as RFC-0107 but renumbered after RFC-0107 (outbound HTTP) merged first to main (#15900). Related RFC-0079, RFC-0088. |
| 0109 | CDAL × GOAL Integration Contract — verdict-carrying Goal phase | Draft | (this PR) 2026-05-17 | Bind CDAL verdict to Goal phase transition. Today the two subsystems are cleanly separated (RFC-0056 + RFC-OAS-011) but **structurally unconnected**: 70 live goals + 16 keepers (2026-05-17), 6 goals with `verifier_policy`, **0** with `active_verification_request_id` non-null — quorum infrastructure inert. 11 keepers `failure:run_error` while their `active_goal_ids` remain alive (two systems record the same incident). Three phases — A (typed `eval_criteria` replaces opaque `Yojson.Safe.t`), B (CDAL verdict → Goal phase auto-transition via new `Goal_phase_bridge`), C (`verifier_policy` enforcement triggers CDAL evaluator on `Request_complete`). Each phase independently revertible (`MASC_CDAL_GOAL_BRIDGE_ENABLED` / per-policy opt-in). 4 PR, ~4 weeks. Originally drafted as 0107; renumbered after 0107 landed on main and 0108 was allocated to atomic JSONL append. Closes V1/V3/V4 from jeong-sik/me PR #1130 research (`knowledge/research/2026-05-17-cdal-goal-separation-deep-dive.html`). Related RFC-0056, RFC-OAS-011, RFC-0067. |
| 0124 | Keeper admission denial boundary | Draft | (this PR) 2026-05-17 | `spawn_slots_available` boolean skip made launch denial look like a stopped keeper. Replaces the runtime gate with typed `spawn_slot_denial_reason`, emits `admission_denied` lifecycle events and `masc_keeper_spawn_slot_denied_total`, and flips FD/disk probe-unknown from Admit to block. Renumbered from 0109 (collision with merged CDAL × GOAL RFC). Related RFC-0026, RFC-0088, RFC-0097, RFC-0101, RFC-0106. |
| 0125 | Bounded subprocess discipline: per-call Switch scope + Fiber.first timeout race | Active | (this PR) 2026-05-21 | 2026-05-17 prod: keeper `failure:run_error` / stale turn symptoms exposed stuck long-running subprocess and socket lifetime boundaries. **4-of-5 phase 종결**: P1 ratchet (#15958 lint+workflow), P2 keeper_docker audit (no-action, 이미 bounded), P3 runtime socket budget (out of scope — Agent_sdk + RFC-0107 D.2c blocker), P4 supervisor watchdog (#15964 opt-in `MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC`). **P5 deprecation pending**: `force_release_holder_for` 제거 30-day soak (P4 #15964 머지 2026-05-17 → 최소 2026-06-16). PR #15958/#15964 commit subjects 가 RFC-0109 prefix 잔존 (renumber 직전 머지). Renumbered from 0109 after collision with merged CDAL × GOAL RFC. Status promoted Draft → Active. Related RFC-0072, RFC-0097, RFC-0101, RFC-0106, RFC-0107. |
| 0126 | Silent fallback discipline (typed split for option/result wildcard arms) | Active | (this PR) 2026-05-21 | 본 RFC body (#15959) + amendment (#16000) + Phase 1 PR-1 (#16019 runtime attempt provenance) + Phase 1 PR-2 (#16024 provider health probe loop) + Phase 1 cross-listed (#16189 RFC-0127 PR-1, §6.1.b absorbs into Phase 1 canary). Phase 2a (`scripts/lint/no-unknown-permissive-default.sh` grep-based) in place. **Phase 2b (ppxlib AST) / Phase 3 (codemod) / Phase 4 (CI hard-fail) 미시작** — Phase 2b 는 RFC-0106 §3.3 dependency. Phase 1 OAS upstream (C2/C3/V16 labels) 도 별도 OAS RFC 대기. Status promoted Draft → Active. Related RFC-0042, RFC-0088, RFC-0106, RFC-0127. |
| 0127 | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | (this PR) 2026-05-18 | 2026-05-17 ~13:00–13:30 UTC incident: RunPod pod `ur1wah58zebjov` 502 storm 30분 동안 10-keeper fleet `fiber_unresolved`, supervisor log 가 *어떤 provider 가 502 인지* 한 줄도 출력 안 함 (`fiber_terminated(fiber_unresolved)` 만). Two gaps: **(A)** `runtime.toml` 의 `[providers.X.healthcheck]` 블록은 parser 에 들어가지만 runtime 동작 0 (probe loop wiring 부재) → **RFC-0126 PR-2 (#16024)** 가 main 에 wiring 완료, RFC-0127 scope 와 implementation overlap. **(B)** `Fiber_terminated { outcome }` 가 `provider_id` / `http_status` 정보를 string-squash 으로 잃어버림 → **PR-1 (#16189 MERGED 2026-05-18)** 가 carrier widen + 5 caller propagation + display surface (event_to_string, JSON, failure_reason_to_string) + 7 carrier-preservation tests. **Remaining**: data-flow from `Provider_error.ServerError { code }` (already captured at `keeper_turn_driver.ml:364`) into the now-typed `Fiber_terminated` carrier so supervisor log shows `fiber_terminated(fiber_unresolved provider=runpod_mtp http=502)`. Originally PR-2/PR-3 spec'd as new module + integration test; PR-2 reduced to data-flow plumbing now that probe loop ships via RFC-0126. Related RFC-0024, RFC-0027, RFC-0058, RFC-0088, RFC-0126. |
| 0129 | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | (this PR) 2026-05-21 | 2026-05-18 incident: reserve_fraction band-aid 가 keeper-level workaround. **2-PR plan 완료**: PR-1 #16084 (piaf idle-timeout API + pool layer reference, RFC-0121 commit subject 와 dual-listed), PR-2 #16158 (`delete reserve_fraction band-aid` — fleet fix). §5 acceptance 24h soak 경과 (2026-05-19). Second audit-sweep RFC to land directly at Implemented (RFC-0132 #17187 다음). Related RFC-0107, RFC-0121 (#16084 dual-listing). |
| 0131 | Shell Command Gate facade — multi-caller IR-first validation | Active | (this PR) 2026-05-21 | Closed-sum verdict facade for shell command gate, multi-caller IR-first validation. **PR-1a/1b/1c 머지** (#16335 caller tag, #16340 nested pipeline reject, #16346 redirect_allowed policy), **PR-2 prep + PR-2 머지** (#16433 worker pass-through, #16527 agent_tool_execute_runtime adoption), **PR-3 머지** (#16532 telemetry counter), **PR-5 머지** (#16542 authority knob + parallel emit). §10 PR-4 (retired_file_write_tool adoption) + PR-6 (legacy purge) 미머지 — PR-6 prereq 는 PR-5 +7d 안정성 (≥2026-05-26). Status promoted Draft → Active. Related RFC-0054, RFC-0089, RFC-0091, RFC-0092, RFC-0126. |
| 0132 | Redaction SSOT — `runtime` boundary-label private type | Implemented | (this PR) 2026-05-21 | `lib/runtime/` 와 `lib/keeper/` 에 `"runtime"` 리터럴이 ~23 사이트 산재. **3-phase 완전 closure**: PR-1 #16531 (`Boundary_redaction` SSOT 모듈), PR-2 #16536 (23-site codemod), PR-3 #16537 (`scripts/lint/no-runtime-literal-outside-boundary-redaction.sh` + Fundamental Check workflow). `feedback_runtime_lens_boundary_carve_out` (#15040/#15070/#15089) 회귀 root fix. Workaround Rejection Bar §AI 안티패턴 1 (Scattered Hardcoded Defaults). Status promoted Draft → Implemented. Related RFC-0085, RFC-0088, RFC-0089, RFC-0126, RFC-0131. |
| 0135 | Dashboard Keeper Operational Surface — Typed SSOT | Active | (this PR) 2026-05-21 | Dashboard 가 같은 keeper wire payload 를 3 화면에서 서로 다른 결론으로 표시하는 SSOT 위반. Typed sum `KeeperOperationalState` SSOT + `stateLabel`/`actionLabel` 분리 + backend `effective_blocker` post-conditioned 필드 + CI guard 의 9-PR phased rollout. **23 implementation_prs 머지 — audit-sweep 최대 lag**. 9-PR plan 가 *original scope 초과*: Goal-1 / Goal-2 / §13 attention axis sub-PR 다수 (#16763, #16772, #17075 등). 활발한 작업 sprint, `feature/RFC-0135-goal2-remaining-axes` worktree 진행 중. PR-9 CI guard `scripts/lint/dashboard-ssot-keeper-state.sh` wired. Phase→PR mapping 정확화 + 최종 closeout 은 sprint author 책임. Status promoted Draft → Active (Implemented 부적합 — Goal-2/§13 follow-ups 진행 중). Related RFC-0004, RFC-0029, RFC-0046, RFC-0088, RFC-0133, RFC-0139. |
| 0133 | Keeper Phase Casing SSOT Consolidation | Draft | (this PR) 2026-05-19 | PR-1 (#16312) closed 11 dead `snapshot.phase === '<PascalCase>'` compares but the structural duplication remains: backend emits lowercase + snake_case via `phase_to_string`, dashboard normalizes flat `keeper.phase` to PascalCase via 4 separate normalizers (`toKeeperPhase`, `normalizePhase`, `toPascalPhase`, `keeper-state-diagram` internal map), and `STATE_DISPLAY_NAMES` carries both casings as defensive double-keying. Single PR sweep flips canonical type to lowercase, deletes 4 normalizers + dual map keys, promotes schema to picklist + `{unknown}` carrier (RFC-0042 closed-sum). 사용자 절대 원칙: no transitional shims, legacy 박멸 in same PR. Renumbered from 0131 → 0133 after PR #16323 ledger-snapshot collision. Related RFC-0042, RFC-0046, RFC-0088. |
| 0108 | Atomic JSONL Append (in-process) | Active | (this PR) 2026-05-17 | 2026-05-17 `<base-path>/.masc/` 전수 스캔에서 4 카테고리 JSONL 출력에 **43 파일 / 379 라인 malformed** 발견. 손상은 `}{` concat (system_log, oas-events) + utf-8 multibyte 절단 (trajectories, reaction-ledger) 두 패턴. **§2.5 진단 evolution** (implementation 진행 중 갱신): 초기 가설 (Stdlib.Mutex multi-domain 무효) 은 부분만 맞았고, 실제 root cause 는 *OCaml `out_channel` buffer 가 도메인-safe 아님* — `Append_fd_cache` 의 cached channel 을 두 도메인이 공유하면 mutex critical section 안에서도 buffer corrupt. 결정적 fix = per-call open_out_gen + close (fresh fd, cache 우회). **Implementation 6 PR MERGED**: #15906 Eio SSOT 모듈, #15922 system_log in-line, #15926 trajectory in-line, #15928 dated_jsonl in-line, **#15936 `Fs_compat.append_jsonl` root-fix** (~30 caller 자동 안전), **#15949 `Fs_compat.append_file` root-fix + `Append_fd_cache` 모듈 완전 제거** (-91 LoC). #15953 cleanup Draft (inline 헬퍼 → library delegate, -109 LoC). 운영 실측: 5 malformed 정적 (3 tick 연속), 새 손상 0. Originally allocated as RFC-0107, renumbered after #15900 collision. Related RFC-0079, RFC-0088. |
| 0136 | Keeper Unified Turn — Stage Decomposition of `run_keeper_cycle` | Active | (this PR) 2026-05-19 | `lib/keeper/keeper_unified_turn.ml` 1943 LOC (5위 godfile, fundamental_roadmap.md Phase 5 명시 target) 의 단일 함수 `run_keeper_cycle` 을 stage-typed sub-module 로 분해. **PR-1 #16604 MERGED** (Phase Gate, -102), **PR-2 #16624 MERGED** (Runtime Resolution, -51), **PR-3 #16643 MERGED** (Pre-Dispatch, -48) — 누적 1943 → 1742 = **-201 LoC (10.3%)**. Phase 4 sub-doc (`RFC-0136-phase-4-retry-loop.md`) 으로 retry loop body (~1100 LOC) 5 sub-PR 분할 (PR-4-a outer setup, PR-4-b error marker, PR-4-c retry core, PR-4-d retry decision, PR-4-e final dispatch). 예상 최종 `keeper_unified_turn.ml` ~620 LOC (-68%). Workaround Rejection Bar 7-check: 모두 N/A. Related RFC-0051, RFC-0056, RFC-0085. |
| 0136 | Phase 4 — Retry Loop Body Decomposition | Draft | (this PR) 2026-05-19 | RFC-0136 main spec §4.2 PR-3 (deferred — *Retry loop body 별도 sub-doc 검토*) 의 구체 계획. `rec retry_loop` (L604, ~1100 LOC) 가 *single PR 불가* — 새 file 600 LOC cap 위반 + nested helpers (`mark_terminal_error` 9 callsites, `do_run`, `attempt_result`) 동시 추출 필요. 5 sub-PR 분할: PR-4-a outer setup (-167), PR-4-b mark_terminal_error (-53), PR-4-c retry core (-400), PR-4-d retry decision (-300), PR-4-e final dispatch (-180). Sequencing: PR-4-a/b parallel → PR-4-c (depends a+b) → PR-4-d/e parallel. typed `retry_setup` + `terminal_error_outcome` record 도입. Workaround Rejection Bar §3 (N-of-M migration) 경계선 — *해당 RFC closure 의 일부* 명시 + PR-4-final 마감 commit 필수. Related RFC-0051, RFC-0056. |
| 0137 | Host FD pressure → Keeper pause (safety-net for Docker VM FD accumulation) | Active | (this PR) 2026-05-21 | Out-of-process FD pressure trip path — host kernel FD table accumulation (Apple Virtualization VM XPC under Docker Desktop) 가 masc 자체 nofile 예산 안 적정해도 fleet 영향. **PR-1 머지 (#16665, RFC body + PR-1 implementation squashed)**: `keeper_fd_pressure.{ml,mli}` add `engage_external` + tests. **PR-2 (host_fd_pressure_poller 모듈 + server_bootstrap_loops 통합, ~120 LoC) + PR-3 (legacy metrics backend metric `host_fd_pressure_*`, optional ~30 LoC) 미시작**. Status promoted Draft → Active. Related RFC-0097, RFC-0101, RFC-0122 (process-local fleet failure mode sibling). |
| 0139 | Agent Status Vocabulary SSOT | Active | (this PR) 2026-05-21 | RFC-0135 closure 후속. `agent.status` 와 `keeper.status` 의 *parallel-but-overlapping* vocab. **Phase 1 완료**: PR-1a #16707 (agent-status 모듈), PR-1b #16708 (live-store), PR-1c #16711 (ide-presence-strip), PR-1d #16714 (agentBand), PR-2 #16755 (lint guard + isOfflineStatus retirement). **Phase 2 (judge-status 분리, governance.ts `'stale_visible'\|'backoff'`) + Phase 3 (judge-status lint mirror)** 미시작. Status promoted Draft → Active. Related RFC-0135. |
| 0141 | TOML Field Resolution Typed Variant for repo_manager | Implemented | (this PR) 2026-06-02 | `Field_resolution.t` keeps repository TOML defaults explicit while rejecting type mismatches. The deleted repository credential subsystem is no longer part of this RFC. Related RFC-0088, RFC-0126, RFC-0142, RFC-0148, RFC-0154. |
| 0142 | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | (this PR) 2026-05-21 | 2026-05-20 silent-failure audit Tier B1. `lib/runtime/runtime_error_classify.ml` 873→939 LoC + 33 catch-all godfile. 3-phase 분해. **Phase 1 부분 머지**: #16790 (Json_field 모듈), #16806 (telemetry_unified migration), #16894 (dashboard_http_helpers), #16899 (server_dashboard_http). 그러나 *origin 모듈 (runtime_error_classify.ml) 자체 migration 미완* — 4 Json_field usage / 33+ catch-all 잔존. Phase 2 (`runtime_internal_error` / `runtime_error_from_sdk` / `runtime_codex_preflight` split) 미시작. Phase 3 (reachability sweep) 미시작. Status promoted Draft → Active to signal partial landing. Related RFC-0085, RFC-0088, RFC-0148, RFC-0154. |
| 0143 | keeper_runtime_profile Typed Catalog Query Result | Active | (this PR) 2026-05-21 | 2026-05-20 silent-failure audit Tier A2. `catalog_query_result = Catalog_ok \| Catalog_unavailable of {reason; message}` 변형 + caller-side decision protocol. **PR-1 (bridge) 머지** (#16860 `catalog_metadata_query` typed bridge + Otoml string-error → typed translation, transitional). **PR-2~5 미머지** — PR-2 keeper_runtime_profile self (6 sites), PR-3 lib/keeper external batch (8 files), PR-4 lib/runtime + dashboard + server batch (5 files), PR-5 API deletion + ratchet regenerate. Status promoted Draft → Active. Related RFC-0088, RFC-0141, RFC-0142, RFC-0148, RFC-0154. |
| 0144 | Workaround Sunset Tracking for Keeper Dedup Carryovers | Active | (this PR) 2026-05-21 | 2026-05-20 PR audit 가 Cluster E (cap/dedup/demote/repair) 워크어라운드 머지 2건 (#16389, #16470) 가 AGENT-LLM-A.md "Override 조건" 위반 (no `WORKAROUND:` 라벨, no replacement RFC linked) 식별. 본 RFC 가 사후 추적 트레일 — sunset criteria + 대체 RFC linking + workaround inventory. Markdown header + meta list 형식 (frontmatter YAML 미사용 — pre-frontmatter standardization era). Status: Active. Predecessors #16389, #16470. |
| 0145 | Permissive-Silent-Fallback Elimination | Draft | (this PR) 2026-05-21 | 2026-05-20 PR audit Cluster A 워크어라운드 7건 root-fix 우산. `lib/parse_outcome/` (stdlib + Eio only, no Yojson dep) 가 `try f s with _ -> None/[]/default` 패턴을 typed `('a, [`Json_parse_error of string \| `Other of exn]) result` 로 교체. Cancellation 은 re-raise (Eio rules). 7 predecessor PR (#15820/15840/15866/15883/15980/15781/15954) 코드 그대로 유지, 사이트별 별도 PR 로 migration; counter 는 §Override exemption 으로 transitional. Demo: `tool_keeper.cache_ttl_seconds` (#15954 site). Sunset = 6/7 사이트 마이그레이션 + counter 제거 + CI grep gate. Body PR #16780, renumber from 0144 (#16779, collision recovery). Related RFC-0088, RFC-0109, RFC-0144. |
| 0148 | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | (this PR) 2026-05-21 | LLM 이 호출하는 tool 들의 *실패 분류* 가 `Failure msg` (catch-all 문자열) 으로 ~30 사이트 분산. closed sum type `tool_error` 7 variant (`Not_found \| Permission_denied \| Invalid_input \| Resource_exhausted \| Timeout \| Cancelled \| Internal_error`) 로 root-fix — 새 실패 클래스 추가 시 컴파일 강제 exhaustive match. Same-day closure: PR-1 #16948 (module + 7 Alcotest), PR-2 #16958 (6 LLM-facing site codemod + RFC §1.1 hallucination 정정 — audit 인용 8 사이트 → 실측 6 사이트). RFC-0154 (operator-facing System_error_class) 의 LLM-facing 자매. JSON wire `{"kind":"...","detail":"..."}`, `Internal_error.exn` 은 in-process debug 전용 (wire 노출 안 함). Related RFC-0088, RFC-0091, RFC-0105, RFC-0154. |
| 0151 | 4-metric monotone-decrease ratchet for code-smell metrics | Draft | (this PR, renumbered from 0149 due to race w/ PR #16930) 2026-05-20 | PR #16833 ("DIRTY + CI/RFC surface" CLOSED) 의 3-split 첫 번째 step. 4 metric (`godfile_loc_1000plus`=51, `catch_all_arms`=3843, `contains_substring_defs`=29→28, `ignore_no_comment`=113; baseline 2026-05-20) 을 CI 에서 monotone-decrease ratchet 으로 enforce. 절대 임계치 (`legacy metrics backend module` LoC cap 같은 evasion 유도 패턴, legacy metrics backend extraction feedback 참조) 가 아닌 *방향성* gate. `RATCHET-WAIVED: <metric_id> <RFC-NNNN reason>` escape hatch + Override 3-요건 (split-evasion 차단, deprecated path 명시, hard_cap 금지). 본 PR 은 docs-only; `scripts/code-smell/measure.{ml,sh}` + `ci/code-smell-baseline.json` + GH Actions step 은 별도 narrow follow-up 2 PR. Related RFC-0085, RFC-0088, RFC-0126. |
| 0155 | System_log_category Typed SSOT — emit-side closed sum for ops log taxonomy | Draft | (this PR) 2026-05-21 | `Log.warn`/`Log.error` emit boundary 에 *category* 가 untyped — 분류는 외부 도구 `memory/masc-oas-log-reduction-measure.py:76 system_category(message: str)` 의 post-hoc substring match 로만. `other` bucket **12,160 events / 72h** (21% of 57,947) 누적, error-warn-reduction-goal-2026-05-18 Pass-1 목표 (<20,000) 구조적 차단. RFC-0089 inventory gap (system_log 키워드 0 hit) 을 보완하는 자매 RFC. `lib/system_log/system_log_category.ml{,i}` closed-sum 14 variant (measure.py 14 카테고리 1-to-1 mapping, `Other_boundary_unclassified of {hint:string}` 외부 boundary 전용) + `Log.warn ~category:t` named-required API + JSONL envelope `category` field. Wave A scout / Wave B sweep / Wave C legacy purge 3-PR runtime. Workaround Rejection Bar §1 (telemetry-as-fix, *counter 추가 아닌 emit boundary parse-don't-validate*), §2 (substring 분류기 *제거*), §3 (N-of-M, optional → required 승격으로 컴파일러 강제) 모두 회피. Related RFC-0088, RFC-0089, RFC-0148, RFC-0149, RFC-0154. |
| 0153 | Runtime Backpressure & Tier Admission | Active | (this PR) 2026-05-21 | 3-phase (A.1 + A.2 + B.1) 머지 후 frontmatter `status: Draft` 잔존 — `audit-rfc-closeout-lag.sh` (#17123) 으로 surfaced. **Phase A.1 #16965** (typed `Runtime_saturation_signal`), **Phase A.2 #16988** (wire emission), **Phase B.1 #16991** (`runtime_tier_admission` module + tests). `implementation_prs` freeform string ("#16965 (Phase A.1, …)") 가 README 표준 (bare integer list) 으로 normalize. Phase B.2+ (runtime path wiring) / Phase C (caller backpressure) / soak window 미시작. Status promoted Draft → Active. Related RFC-0009, RFC-0022, RFC-0042, RFC-0082, RFC-0088, RFC-0102, RFC-0127, RFC-0152. |
| 0154 | System_error_class typed SSOT — close substring-classifier loop across backend + telemetry + dashboard | Implemented | (this PR) 2026-05-21 | 5-PR sprint #17015~#17051 (Tool Monitor dashboard UX) 후속. OS-level 실패 분류가 backend 4 substring matcher (`keeper_fd_pressure.ml:97`, `keeper_disk_pressure.ml:55`, `workspace_utils_ops.ml:410`, `keeper_stale_watchdog.ml:203`) 로 분산 + `Telemetry_coverage_gap.record ~error:string` 의 13 caller 가 `Printexc.to_string exn` 으로 압축 + dashboard `classifyCoverageError` 가 *같은 substring vocab 으로 재분류* 하는 정보 손실 cycle. `lib/core/system_error_class.ml` closed-sum SSOT (`Fd_exhaustion \| Disk_exhaustion \| Permission_denied \| Connection_refused \| Timeout \| Other of string`) + wire `error_class` typed tag + dashboard typed-first cascading lookup. 4-PR phased rollout 24h 안 closure: PR-1 #17064 (모듈), PR-3 #17073 (dashboard lookup), PR-4 #17072 (cutover runbook), PR-2 #17078 (wire + 4 matcher 통폐합). Workaround Rejection Bar 시그니처 #2 (substring 분류기) + #3 (N-of-M, PR #17051 disk_exhaustion 가 2-of-M 누적 시작) root fix. Related RFC-0042, RFC-0088, RFC-0097, RFC-0105, RFC-0122, RFC-0142, RFC-0148, RFC-0149. |
| 0160 | Shell IR 1급 승격 — single-source decision substrate | Active | (this PR) 2026-05-23 | Post-P9/P13a inventory: Shell IR가 transit-only envelope에 머무름 (real consumption ~64%, transit ~36%). 5 drift signal — 병렬 파싱 (`Bash.parse_string` + `Bash_words.stages` 동일 입력 2회), 병렬 typed shape (`Shell_ir.simple` vs retired standalone `gh` typed argv), decision-by-string (`agent_tool_execute_runtime.ml:109,121` IR 만들기 전 classify), stamp-less IR (risk/reversibility 미포함), producer 비대칭 (typed→IR caller 1개). 7-phase plan G1-G7 KPI 정량화 (`scripts/audit-shell-ir-consumption.sh`): G1 parse_string≤3, G2 classifier sig IR-only, G3 gate_typed 4+ keeper ops, G4 risk-stamped IR, G5 path validator universal, G6 TLA+ spec, G7 parallel parser refs=0. **S0 #17873 (measurement script) + S1 #17884 (mutation classifier IR-only, G2 hit) 머지**. S2 typed `gh` IR lift / S3 risk stamp (record vs phantom envelope) / S4 parser entry consolidation / S5 universal gate / S6 cleanup / S7 spec+ratchet TBD. Workaround Rejection Bar §1/§2/§3 모두 회피 (structural root-fix, substring 제거, N-of-M explicit retire phase). Related RFC-0042, RFC-0086, RFC-0088, RFC-0091, RFC-0107, RFC-0142, RFC-0154. |
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
- [RFC-0113 — KeeperReactionLiveness L1–L5 runtime — phased OCaml mirror of TLA+ design ground](RFC-0113-keeper-reaction-liveness-runtime.md)
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
