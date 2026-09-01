# RFCs — masc

이 디렉토리는 masc 의 설계 RFC(Request for Comments) 를 보관한다. 새 RFC 를 작성하기 전 본 README 의 §정책 + §Frontmatter 표준 을 읽고 진행한다.

## 정책

- **파일명**: 신규 RFC 는 `RFC-<slug>.md` (예: `RFC-keeper-background-wait-tool.md`). slug 는 소문자/숫자/하이픈이다.
- **삭제 정합성**: RFC 파일을 삭제할 때는 인덱스 행, frontmatter 관계, 본문 cross-reference를 같은 변경에서 함께 삭제한다.
- **Multi-phase RFC**: 한 설계를 여러 문서로 나눌 때는 같은 slug prefix를 사용하고 본문에서 현재 main spec을 직접 참조한다.
- **상태 동기화**: frontmatter 상태를 바꾸면 생성 인덱스를 같은 변경에서 갱신한다.
- **인덱스 갱신**: `python3 scripts/rfc-generate-index.py --update` 로 frontmatter 기반 자동 생성. 신규 RFC 작성 / Status 이행 후 실행. CI에서 `--check` 로 검증.

## Frontmatter 표준 (신규 RFC 부터 강제)

새 RFC 는 본문 1번째 `#` 헤더 위에 다음 YAML frontmatter 를 둔다.

```yaml
---
rfc: "keeper-background-wait-tool" # 파일명의 slug와 일치
title: "Short Imperative Title"
status: Draft                      # 생성 인덱스에 표시할 현재 상태
created: 2026-05-12                # ISO date
updated: 2026-05-12                # 본문 의미 변경 시 갱신, typo 수정은 생략 가능
author: <github-handle 또는 vincent>
related: []                        # 직접 참조하는 현재 RFC slug. 없으면 빈 배열
---
```

### Status 정의

| 값 | 의미 |
|---|---|
| `Draft` | 작성 중. 본문/PR 변경 가능. 구현 시작 전 또는 spec 합의 미완. |
| `Active` | spec 머지 완료, 구현이 진행 중인 RFC. 일부 Phase 가 main 에 들어갔으나 전체 closeout 미완. |
| `Implemented` | 모든 Phase 가 main 에 머지 완료. 명시적 `docs(rfc): ... closeout` commit 또는 본문 *Implementation summary* 섹션이 있어야 한다. |
| `Superseded` | 다른 RFC 가 이 자리를 대신한다. `superseded_by` 에 그 slug 를 적는다 — 비워두면 읽는 사람이 대신할 것을 찾을 데가 없다. |
| `Dropped` | 하지 않기로 했다. 본문에 왜인지 적는다. 대신할 것이 없으므로 `superseded_by` 는 비운다. |

`Dropped` 가 있어야 하는 이유: 이 값이 없으면 포기한 RFC 가 `Draft` 로 남는다.
`Draft` 는 "아직 안 썼다" 이고 포기는 "안 쓴다" 인데, 인덱스에서 둘이 같은
글자로 보인다. 2026-08-25 에 그 혼동으로 계획 하나가 잘못 쓰였다 — 살아있는
RFC 를 죽은 것으로 읽었고, 되돌리는 데 한 라운드가 들었다.

## RFC 목록

이 표는 RFC 파일의 frontmatter와 제목에서 결정적으로 생성한다. 병합 방식에 따라
바뀌는 commit SHA나 날짜는 저장하지 않는다. Status 컬럼은 명시적 closeout
commit 이 있는 RFC 만 Implemented 로 표기한다 — RFC body 머지는 spec
implementation 머지가 아니므로 다수 RFC 가 `Draft` 로 남아있다.

| RFC | Title | Status | Sub-docs |
|---|---|---|---|
| 0004 | Keep OCaml and TypeScript wire contracts exact | Active | - |
| 0009 | Runtime Trust Phase 2: Operator Recommendations + Opt-in Persist | Implemented | - |
| 0010 | ocamlformat config reconciliation | Implemented | - |
| 0012 | Mid-Turn Progress Probe | Draft | - |
| 0029 | Dashboard Fiber-Batched Aggregation | Active | - |
| 0032 | Environment Knob Unification | Draft | - |
| 0036 | Multi-Keeper Docker Orchestration & Lifecycle Cleanup | Draft | - |
| 0037 | Board Multimedia & Vision — Eio/File-Based Adaptation (`RFC-0037-board-multimedia-vision-adapted.md`)<br>Local-first Keeper Enablement: Harness/User Boundary (`RFC-0037-local-first-keeper-enablement-boundary.md`) | Draft<br>Active | - |
| 0038 | Opaque Identifier Types for Provider, Runtime, Model | Draft | - |
| 0043 | Distribute legacy metrics backend metric ownership to domain modules | Active | - |
| 0044 | Typed persistence read-drop reason + Result-based reads | Active | - |
| 0046 | Keeper Detail FSM Hub as SSOT | Active | - |
| 0049 | Dashboard Surface Telemetry Foundation | Draft | - |
| 0050 | Dashboard Component Ownership Decomposition | Active | - |
| 0051 | run_named closure decomposition | Active | - |
| 0052 | Boot-time Required Invariants (typed) | Implemented | - |
| 0056 | Incremental Sub-Library Extraction from Flat masc Library | Active | - |
| 0057 | Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation | Draft | - |
| 0062 | Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class (Reverse-Engineered Initi... | Implemented | - |
| 0063 | Telemetry Feedback Loop & Cooperative Scheduling Safety | Active | - |
| 0064 | Capacity Probe Adapter | Active | - |
| 0067 | Goal-Scope Observation→Claim Atomicity | Active | - |
| 0070 | Keeper Sandbox Runtime — Pure/Edge Separation | Active | - |
| 0071 | Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern | Implemented | - |
| 0072 | Type-encoded keeper sub-FSM transitions (runtime + turn_phase) | Implemented | - |
| 0077 | Write-side silent failure — typed propagation | Implemented | - |
| 0079 | Log row typed encoder + silent-drop removal | Implemented | - |
| 0080 | Registered descriptors are the tool-surface SSOT | Implemented | - |
| 0083 | Dashboard system-actor convention typed unification | Implemented | - |
| 0084 | Tool dispatch handler and observation unification | Implemented | - |
| 0086 | Keeper namespace bulk promotion to sub-library | Implemented | - |
| 0088 | Counter-as-Fix → Result Propagation (umbrella scoping) | Active | - |
| 0089 | String Classifier to Typed Variant — direct replacement, no lint | Implemented | - |
| 0090 | Write-side success-model attribution — finish N-of-M migration | Implemented | - |
| 0091 | Execute tool: cmd string → typed Argv schema (lexer/validator 박멸) | Implemented | - |
| 0093 | Board persistence identity and atomic snapshot | Implemented | - |
| 0095 | Provider-D-compat provider streaming wire-up | Implemented | - |
| 0097 | Keeper sandbox container reuse (long-running sandbox per keeper) | Active | - |
| 0098 | Typed JSON-RPC error envelope & production-code silent-failure lint | Implemented | - |
| 0099 | Session lifecycle — typed events, explicit eviction, resume backpressure | Active | - |
| 0100 | Streamable HTTP as default transport (MCP 2025-03-26) | Active | - |
| 0101 | FD accountant — observation across process resource classes | Active | - |
| 0103 | Log retention opt-in + JSONL volume root reduction | Draft | - |
| 0105 | OpenAI-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope | Implemented | - |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Active | - |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker ... | Active | Phase C.0 — `Eio_context.get_switch_opt` global access audit (`RFC-0107-eio-context-switch-audit.md`, Evidence)<br>Phase D — Connection pool design (interface-first) (`RFC-0107-phase-d-pool-design.md`, Active) |
| 0108 | Atomic JSONL Append (in-process) (`RFC-0108-atomic-jsonl-append.md`)<br>PR / Worktree Operation Safety Gates (`RFC-0108-pr-worktree-operation-safety-gates.md`) | Active<br>Implemented | - |
| 0112 | Typed JSON parse boundary — eliminate silent-drop fallback across read sites | Implemented | - |
| 0115 | KTC turn_phase spec ← runtime parity — backfill spec for Turn_routing / Turn_... | Implemented | - |
| 0121 | Config-dir resolution — single active root, no implicit fallback | Active | - |
| 0122 | Keeper disk pressure — process-local fleet failure mode beyond FD | Implemented | - |
| 0123 | Briefing last_event fabrication — option-typed write boundary | Implemented | - |
| 0126 | Silent fallback discipline (typed split for option/result wildcard arms) | Implemented | - |
| 0127 | Runtime Fast-Fail (Provider Health Phase 3) + Fiber Termination Provenance | Active | - |
| 0129 | Runtime attempt idle-cap: kill the reserve_fraction band-aid | Implemented | - |
| 0132 | Redaction SSOT — `runtime` boundary-label private type | Implemented | - |
| 0133 | Keeper Phase Casing SSOT Consolidation | Implemented | - |
| 0134 | Persistence read-drop root fix (recovery story for RFC-0044) | Active | - |
| 0136 | Keeper Unified Turn — Stage Decomposition of run_keeper_cycle | Implemented | Keeper Unified Turn — Phase 4: Retry Loop Body Decomposition (`RFC-0136-phase-4-retry-loop.md`, Active) |
| 0138 | Dashboard Snapshot Lock-Free Immutable Architecture | Implemented | - |
| 0140 | Dashboard wire codec for source observations | Implemented | - |
| 0141 | TOML Field Resolution Typed Variant for repo_manager | Implemented | - |
| 0142 | runtime_error_classify Decomposition + Typed JSON-Extraction Variant | Active | - |
| 0143 | keeper_runtime_profile Typed Catalog Query Result | Active | - |
| 0145 | Permissive-Silent-Fallback Elimination | Active | - |
| 0148 | Typed `tool_error` Variant for LLM-Facing Tool Failure Surface | Implemented | - |
| 0149 | Audit-Driven Telemetry-as-Fix Sunset | Implemented | - |
| 0154 | System_error_class typed SSOT — close substring-classifier loop across backen... | Implemented | - |
| 0159 | Reason_internal_error typed split — close string-classifier catch-all | Draft | - |
| 0162 | JSONL Write-Path FD Pressure Root-Fix | Draft | - |
| 0174 | Dashboard substring classifier to typed — TypeScript | Draft | - |
| 0175 | Godfile decomposition Wave D — keeper core 5-file split | Draft | - |
| 0178 | Types Sub-library Extraction with `_intf.ml` mli-only Surface (typed-SSOT) | Draft | - |
| 0179 | ToolDescriptor Ecosystem Coverage Extension to Workspace Tools | Draft | - |
| 0180 | 24h Runtime ERROR 7-Pattern Sweep Roadmap | Draft | - |
| 0182 | masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation | Draft | - |
| 0189 | Typed Tool_result.result variant — eliminating boolean blindness in tool disp... | Draft | - |
| 0190 | Descriptor as Visibility/Metadata SSOT — Surface Projection from descriptor.p... | Draft | - |
| 0200 | Time constants 를 leaf library 로 분리 | Draft | - |
| 0201 | Activity events wait-free snapshot (RFC-0138 extension, file-base preserved) | Draft | - |
| 0203 | In-process Discord connector | Implemented (Phase 3 cutover landed 2026-05-29) | - |
| 0204 | Dashboard Read Serving Isolation from Fleet Compute | Draft | - |
| 0205 | Keeper Module Consolidation — Eliminate Facade Anti-Pattern | Draft | - |
| 0206 | Runtime 개념 — runtime→Runtime 재탄생 | Draft | - |
| 0207 | Per-keeper LLM runtime routing | Draft | - |
| 0210 | Keeper Playground Repo Currency (fetch + fast-forward, work-preserving) | Draft | - |
| 0213 | Keeper sandbox/playground isolation model (fix sandbox_repo_not_ready + macOS... | Draft | - |
| 0214 | OTel GenAI Semantic Convention Migration | Draft | - |
| 0215 | Keeper sub-library extraction campaign — sequence and per-PR gates | Draft | - |
| 0216 | Per-Keeper Decline Memory (orphan-task churn root fix) | Draft | - |
| 0221 | Atomic verification submission — task_status as the sole outcome authority | Implemented (steps 1-3 merged #20613/#20617; steps 4-5 measured then dropped, §3.3/§3.4) | - |
| 0223 | Typed connector surfaces: presence in world prompt, pull-based lane context, ... | Draft | - |
| 0225 | Per-keeper turn single-flight admission | Draft | - |
| 0226 | Ambient lane recording: record-vs-trigger decouple for connector surfaces | Draft | - |
| 0228 | Paged lane pull + fact-retention harness: digest without a summarizer | Draft | - |
| 0229 | Keeper person notes: deliberate per-speaker memory beyond the log window | Draft | - |
| 0230 | Keeper mention/scope reactivity: cursor-free salience to complement pull-base... | Draft | - |
| 0232 | Typed lane event model: parse at the write boundary, never re-derive by strin... | Draft | - |
| 0233 | Typed turn observability: TurnRecord prompt-block provenance + canonical tool... | Draft | - |
| 0235 | Stale-base revert guard: block PRs that silently revert recently-merged work (`RFC-0235-stale-base-revert-guard.md`)<br>Voice output transport: browser-addressed audio delivery with device-routed p... (`RFC-0235-voice-output-browser-transport-device-routing.md`) | Draft<br>Draft | - |
| 0236 | Voice input transport: browser-captured speech-to-text for the dashboard comp... | Draft | - |
| 0239 | Concurrency ownership model (per-site mutex/atomic → protection by construction) | Draft | - |
| 0240 | Tool-pair invariant enforced at write-time (eliminate repair-on-read) | Implemented | - |
| 0247 | Memory OS as a brain: typed associative graph, spreading-activation recall, s... | Draft | - |
| 0251 | Memory OS: record well, do not value — remove the scoring layer | Draft | - |
| 0252 | Fusion: 패널+심판(panel+judge) 심의 루프 (MASC 내장) | Draft | - |
| 0253 | Dashboard keeper-v2 surfaces: canonical spacing/radius token scale + off-scal... | Draft | - |
| 0257 | Per-Keeper memory execution lane | Draft | - |
| 0261 | gRPC LSP failed-initialize FD/process teardown | Draft | - |
| 0266 | Fusion async-completion wake + in-progress 가시성 | Draft | - |
| 0267 | Make task↔goal links visible and explicitly assignable | Implemented | - |
| 0269 | Process Critic Loop for Keeper Work Traces | Draft | - |
| 0270 | CI Gate merge guard: block merges on a non-success CI Gate and trip on red main | Draft | - |
| 0274 | Workspace base_path SSOT — retire env runtime read, thread Workspace.config | Draft | - |
| 0277 | Fusion: 이종 패널 그룹(heterogeneous panel groups) + 발동 예산 제거 | Draft | - |
| 0278 | Fusion: 같은 model을 다른 prompt로 (same-model panels via panel labels) | Draft | - |
| 0280 | Fusion: validated preset type (Parse, don't validate) | Draft | - |
| 0281 | WebSocket transport SSOT — separate upgrade-attachment from session-protocol,... | Draft | - |
| 0282 | Keeper authored content is ordinary instructions | Implemented | - |
| 0283 | Fusion: judge-of-judges 위상 (flat/staged reducer) | Implemented | - |
| 0284 | Fusion 심판 실행 관측 record (judge observation record) | Implemented | - |
| 0287 | ws-direct — a single masc-owned WebSocket stack for server and client | Draft | - |
| 0289 | Extract progress-classification into its own library for a single substantive... | Draft | - |
| 0290 | Generic keeper background-work tool (spawn → wake-on-completion) | Draft | - |
| 0292 | Complete lib/auth de-duplication — remove drifted Masc.Auth* test copies | Draft | - |
| 0294 | Remove workspace Goal horizon | Implemented | - |
| 0296 | CI skip-gate main-push safety-net: always run Build and Test on non-PR events | Draft | - |
| 0298 | fusion judge pool — judge 모델을 preset에서 분리 | Draft | - |
| 0299 | RFC-0299 — Typed-Boundary Sweep (string-classifier → closed-sum, dead SSOT re... | Draft | - |
| 0300 | RFC-0300 — Dashboard design-token scope consolidation (radius / shadow / type... | Draft | - |
| 0301 | Keeper 생성 미디어(이미지/오디오) 대시보드 노출 | Draft | - |
| 0302 | Keeper 메모리 파일 I/O off-main-domain 오프로드 (HOL fix) | Draft | - |
| 0303 | Keeper wake without progress heuristics | Implemented | - |
| 0306 | Typed, comment-preserving fusion settings editor | Draft | - |
| 0307 | Mid-turn advisor consult for keepers — evaluation and deferral | Draft | - |
| 0312 | Keeper repo mappings are advisory default scope, not access caps | Accepted | - |
| 0315 | Typed wake-turn context and self-directed work lane | Active | - |
| 0317 | In-process Slack connector (Socket Mode) | Implemented | - |
| 0320 | Keeper connector-aware continuation: carry the originating channel through wa... | Draft | - |
| 0324 | keeper repo 경로를 filesystem 진실로 (catalog 거짓 주입 제거) | Draft | - |
| 0333 | Deterministic cost↔success frontier join for the eval harness | Draft | - |
| 0335 | TOML as the Single Settings Source | Draft | - |
| 0338 | Lane-per-keeper durable persistence isolation | Draft | - |
| 0340 | Loopback dashboard token-only auth | Active | - |
| 0341 | Keeper lifecycle projection SSOT | Draft | - |
| 0342 | Capability catalog overlay, deployment capability declarations, and boot posture | Draft | - |
| 0343 | Repo location SSOT (collapse dual-authority, attribute by git-remote) | Draft | - |
| 0345 | Streaming idle-timeout fail-safe floor (#25128) | Draft | - |
| 0348 | Bounded lane acquisition for durable keeper_msg writes (#25398) | Draft | - |
| 0350 | Unbounded request-fiber admission (durable queue + lifecycle-sibling worker +... | Draft | - |
| 0352 | Legacy Goal: RFC-0000 §3.2 ↔ §3.15 자기모순 해소 (결정 요청) | Implemented | - |
| 0353 | 실패 분류가 모듈 경계에서 소실되는 결함 (결정 요청) | Draft | - |
| 0356 | Approval owns the effect (replay the approved payload, do not require byte-id... | Draft | - |
| 0358 | 자율턴 신원과 exact raw-trace run을 turn record가 소유한다 | Implemented | - |
| 0360 | Task actor provenance | Draft | - |
| 0361 | 완료 권한의 관측과 조회 | Draft | - |
| 0362 | Goal owner and the intake contract | Draft | - |
| 0363 | Historical tool-result demotion in the bounded transmission view | Draft | - |
| 0365 | handoff_context must survive the ownership boundary | Draft | - |
| 0366 | 운영자가 다음 턴의 컨텍스트에 한 문장을 넣는다 | Draft | - |
| 0368 | 판단 없는 recovery는 keeper의 다음 claim이 스스로 해제한다 | Draft | - |
| 0370 | Provider profile SSOT, quota-as-state, rotation eligibility for Internal-carr... | Draft | - |
| 0371 | Effect 경계 회복 — 이펙트는 경계로, 코어는 순수 로직으로 | Draft | - |
| 0372 | Request-scoped resource budget — bound what one read may consume | Draft | - |
| 0373 | Keeper turn-lane admission | Draft | - |
| 0374 | Keeper Capability Probe Lane | Draft | - |
| 0375 | Closed day-file projection cache — stop replaying the ledger per read | Draft (not recommended as written — see §8) | - |
| 0376 | 출력 목적지는 Keeper 가 판단한다 | Draft | - |
| 0377 | 같은 대화의 밀린 메시지는 한 턴이 함께 본다 (Conversation-Batched Stimulus Intake) | Draft | - |
| 0378 | Code fact 는 태어날 때 주소를 받는다 — typed address, code-fact 전용 store, anchor 계약 통일 | Implemented | - |
| 0379 | Keeper Monitor: 조건 전이가 Keeper 를 깨운다 (Event-Driven Wake) | Draft | - |
| 0380 | 대기 나이는 홀더의 사이클을 알아야 한다 — work liveness 판정 축 정정 | Draft | - |
| 0381 | 웹 검색은 폴백이 있는 척한다 — provider 계약 정정과 토큰 예산 도입 | Draft | - |
| 0382 | 런타임별 KV/prompt cache 재사용과 reasoning 연속성 | Draft | - |
| 0383 | 웹 아티팩트는 쌓이기만 한다 — 오프로드 파일을 재질의 가능한 코퍼스로 | Draft | - |
| 0384 | In-process Telegram connector (long polling) | Proposed | - |
| 0385 | 자율턴은 대화가 아니다 | Active | - |
| 0386 | 툴 종류(tool kind)는 닫힌 합타입으로 선언한다 | Draft | - |
| 0387 | Goal verifier 게이트 — 성공조건 필수화, 생성 시 실재성 검증, 완료의 2단계 증명 | Draft | - |
| 0388 | awaiting_tool 대기의 liveness — 취소 도달과 시간 기반 만료 | Draft | - |
| 0390 | Official client 네이티브 도구를 keeper 별로 켜고 끈다 | Draft | - |
| 0391 | Shell IR 세미콜론(;) 순차 실행 커맨드 체이닝 지원 | Draft | - |
| 0392 | Keeper 신원을 provider 로 매개변수화 — provider 추가가 OCaml 을 늘리지 않는다 | Draft | - |
| 0393 | 이름 안에 인코딩된 keeper 신원을 제거한다 — 관계는 데이터로, 이름은 하나로 | Draft | - |
| 0394 | Local playground fail-closed; execution relocates off-host (SSH, then microVM) | Draft | - |
| 0395 | Pinned OpenSSH is the Phase 1 remote execution lane | Draft | - |
| 0396 | Keeper coding capability: wire a coding-outcome eval from existing parts, the... | Draft | - |
| 0397 | Librarian wire contract states changes, not the whole roster | Draft | - |
| 0398 | Edit addresses lines and proves freshness; the substring search goes away | Draft | - |
| 0399 | Build output leaves the virtiofs share | Draft | - |
| RFC-a-language-server-the-keeper-can-ask | A language server the Keeper can ask | Draft | - |
| RFC-async-log-sink-durable-append-offload | Offload the structured-log durable append off the emitting fiber | Draft | - |
| RFC-attached-service-tool-scoping | 도구 스키마를 매 턴 전량 싣는 것을 그만둔다 | Accepted | - |
| RFC-chat-references-are-recorded-not-guessed | 대화의 명시 참조와 해석된 언급을 구분해 기록한다 | Draft | - |
| RFC-checkpoint-pinned-root-containment | Immutable boot-pinned root capability for checkpoint containment | Draft | - |
| RFC-claude-code-context-overflow-bounded-restart | Admit Claude Code bootstrap input without replaying rejected episodes | Draft | - |
| RFC-claude-setting-sources-opt-in | Claude Code settings layers as a keeper-profile opt-in | Implemented | - |
| RFC-cli-runtimes-as-lane-slots | CLI runtimes as lane slots | Draft | - |
| RFC-connector-ambient-attention-wake | Connector ambient attention wake: drive an idle keeper turn from external-att... | Draft | - |
| RFC-dashboard-dev-token-configured-role | Loopback dashboard dev-token issues Admin | Draft | - |
| RFC-event-queue-admit-all-ready | 이벤트 큐 — 준비된 자극은 한 턴이 전부 본다, 턴 실패는 자극을 버리지 않는다 | Draft | - |
| RFC-exact-lane-delivery-channel | exact 레인이 답을 받는 통로를 고른다 — 본문 JSON 이 후보를 절반 떨어뜨린다 | Draft | - |
| RFC-execute-boundary-is-the-sandbox | The subset judges; the sandbox contains | Draft | - |
| RFC-execute-subset-dispositions | Execute subset dispositions: resolve it, spawn it, or name the replacement | Draft | - |
| RFC-keeper-conversation-hitl-flow | Keeper conversation and non-blocking HITL | Implemented | - |
| RFC-keeper-external-tools-and-produced-artifacts | Keeper 외부 도구와 생성 이미지 증거를 선언형 계약으로 연결한다 | Draft | - |
| RFC-keeper-github-apps | keeper별 GitHub App 신원 — 공유 봇 계정을 App installation 토큰으로 교체 | Draft | - |
| RFC-keeper-runtime-context-observation-phase0 | Keeper runtime context observation Phase 0 | Draft | - |
| RFC-keeper-vision-delegation-tool | Vision-as-a-tool delegation (decouple multimodal input from conversation runt... | Draft | - |
| RFC-keeper-workspace-root-only | 시스템은 workspace root 만 정한다 (레이아웃 규정 폐기) | Draft | - |
| RFC-keeper-writes-own-compositions | Keeper가 자기 composition 카탈로그를 쓴다 — 제안은 staged, 반영은 승인 뒤 | Draft | - |
| RFC-memory-os-bounded-context-and-librarian-curator | Memory OS 2.0 — bounded working set 전송 계약과 librarian curator 계약 | Draft | - |
| RFC-one-provider-two-wires | One provider, two wires | Implemented | - |
| RFC-per-keeper-github-cli-identity | Keeper-specific GitHub CLI identity | Draft | - |
| RFC-prompts-and-tool-definitions-outside-ocaml | 프롬프트와 도구 정의를 OCaml 밖으로 — 모델이 읽는 모든 글은 config 파일이 소유한다 | Draft | - |
| RFC-runtime-note-field-and-dashboard-surfacing | Per-runtime note field & dashboard surfacing | Draft | - |
| RFC-schedule-history-and-outcome | # RFC — A schedule's past and its result | Draft | - |
| RFC-skills-as-tools | Skill 과 Tool 은 한 카탈로그의 두 표면 — SKILL.md 가 지시·합성·비동기를 선언한다 | Active | - |
| RFC-spawn-a-process-that-outlives-the-call | Spawn: a process that outlives the call | Draft | - |
| RFC-tui-operator-ia | TUI 정보 구조 재설계 — 18탭을 숫자 키 10개로 접고, Keeper 워크벤치를 중심 화면으로 | Draft | - |
| RFC-tui-server-lifecycle | TUI 안에서 서버를 켠다 — opt-in 온디맨드 서버 시작으로 TUI 를 기본 진입점으로 | Draft | - |
| RFC-turn-failure-visible-stop | 턴 실패를 숨기지 않고 상태로 보여준다 — 실패 면제와 예산 계정을 걷어낸다 | Implemented | - |
| RFC-virtual-project-missions | Virtual-project missions: RW24-RW30 from planned rows to judged runs | Draft | - |
| RFC-webmcp-capability-lanes | WebMCP 를 masc 능력으로 — credential 위임(C), 생태계 센서(D), 공유 화면·사람 승인(E) | Draft | - |
| RFC-webmcp-dashboard-agent-surface | 대시보드를 WebMCP 도구 표면으로 — 읽기 전용 MCP allowlist relay 와 CDP 소비 브리지 | Draft | - |
| RFC-webmcp-keeper-consumption | keeper 의 WebMCP 소비 — Yolo Bash 브리지 lane(지금)과 typed 도구 모듈 lane(트리거 뒤) | Active | - |

### 신규 RFC

신규 RFC 는 번호를 발급받지 않는다 (번호 allocator 제거됨 — 전역 카운터 TOCTOU 회피). 의미 있는 slug 파일명 `RFC-<slug>.md` 로 작성한다. 본 표는 기존 번호 RFC 와 신규 slug RFC 를 함께 추적한다.

## 검색 / 발견

- 단일 RFC: `cat docs/rfc/RFC-NNNN-*.md`
- 키워드 검색: `rg <keyword> docs/rfc/`
- 본 README 의 표로 RFC 발견 및 상태 확인. 최근 활동은 해당 RFC 파일의 `git log`로 확인
- PR 작성 시 RFC 발견 체크: `bash ~/me/scripts/pr-rfc-check.sh --pr-body /tmp/pr-body.md`
