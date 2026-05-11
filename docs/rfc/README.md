# RFCs — masc-mcp

이 디렉토리는 masc-mcp 의 설계 RFC(Request for Comments) 를 보관한다. 새 RFC 를 작성하기 전 본 README 의 §정책 + §Frontmatter 표준 을 읽고 진행한다.

## 정책

- **번호 할당**: 작성 시점에 사용 가능한 가장 작은 4자리 번호. `git fetch origin main && ls docs/rfc/` 로 race-check 후 commit. main 머지 시점에 다른 PR 이 같은 번호를 점유했다면 즉시 renumber 한다 (선례: #14672 RFC-0057 → RFC-0067, #14692 RFC-0047 → RFC-0068).
- **파일명**: `RFC-NNNN-kebab-case-title.md`. NNNN 은 zero-pad 4자리.
- **Multi-phase RFC**: 한 RFC 가 phase 별 sub-document 를 가질 수 있다 (예: `RFC-0058-declarative-cascade-config.md` + `RFC-0058-phase-5-erase-provider-variant.md`). 같은 번호를 공유하는 것은 *번호 충돌이 아니다* — 본문에서 main spec 을 cross-reference 하면 된다.
- **상태 이행**: Draft → (구현 중 작업 PR) → Implemented (Phase 별 closeout PR 머지 후) 또는 Withdrawn / Superseded. Status 갱신은 본문 frontmatter + (선택) 별도 closeout commit 으로 한다.
- **Superseded RFC**: 본문 상단에 `superseded_by: NNNN` 명시 + main spec 본문 §1 ~ §2 에 supersede 이유 1 단락 이상.
- **인덱스 갱신**: 신규 RFC 작성 / Status 이행 / Supersede 시 본 README 의 §RFC 목록 표를 같은 PR 에서 갱신한다. 자동화는 별도 RFC (frontmatter 보급률 80%+ 후 검토).

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
| 0001 | Det/NonDet Boundary Hardening, Emotional Recovery Loop, Adversarial Harness | Draft | 9faabfadf 2026-04-26 | - |
| 0002 | Keeper 11-State Machine + Det/NonDet Boundary Formalization | Draft | 9faabfadf 2026-04-26 | - |
| 0003 | Keeper Composite Lifecycle Observer | Draft | 9faabfadf 2026-04-26 | RFC-0003-keeper-composite-lifecycle.md (Phase 0) + RFC-0003-phase-2-turn-observation-lifecycle.md (Phase 2) |
| 0004 | OCaml ↔ TypeScript shared contract — SSE + gRPC-web | Draft | c781fbdfc 2026-04-27 | - |
| 0005 | Typed Capability Substrate for Local Exec Core | Active | f09e7b315 2026-05-09 | - |
| 0006 | Keeper Tool Surface Realignment & Symmetric Sandbox | Draft | 9faabfadf 2026-04-26 | - |
| 0007 | Pragmatic `keeper_shell op=gh` Hardening | Draft | f86daea20 2026-04-30 | - |
| 0008 | `CredentialProvider` Trait (Minimum Viable) | Draft | f86daea20 2026-04-30 | - |
| 0009 | Cascade Trust Phase 2: Operator Recommendations + Opt-in Persist | Draft | 9faabfadf 2026-04-26 | - |
| 0012 | Mid-Turn Progress Probe | Draft | 1dd75fd6b 2026-05-06 | - |
| 0013 | IO-wait Sampler (PR-0.2.E, deferred) | Draft | 5aeb2aab4 2026-04-29 | - |
| 0017 | OCaml↔CRDT Boundary | Draft | 6aef5b884 2026-04-29 | - |
| 0018 | Compile-time receipt enforcement at `run_turn` boundary | Draft | 54b91fd4e 2026-04-30 | - |
| 0019 | Keeper Credential Unification | Draft | fcbfe0983 2026-04-30 | - |
| 0020 | Keeper heartbeat — Event Layer / Policy Layer separation | Draft | b1797e570 2026-05-01 | - |
| 0022 | Cascade Attempt Liveness Contract | Draft | 1dd75fd6b 2026-05-06 | - |
| 0023 | Kimi Coding API Provider (3-way Split Completion) | Draft | 79358bfed 2026-05-03 | - |
| 0024 | Ollama Cascade Integration + KV Cache Optimization | Draft | 79358bfed 2026-05-03 | - |
| 0025 | Tiered Small-Model Cascade (4B → 9B → 70B+) | Draft | 79358bfed 2026-05-03 | - |
| 0026 | Work-Conserving Keeper Admission | Draft | 89b07fa37 2026-05-05 | - |
| 0027 | Capability-typed cascade catalog | Draft | 22d280694 2026-05-05 | RFC-0027-capability-typed-cascade.md + RFC-0027-tension-type-safety.md |
| 0028 | Bounded Token Prediction (Distribution-based) | Draft | faab23db8 2026-05-05 | - |
| 0029 | Dashboard Fiber-Batched Aggregation | Draft | 4657df07d 2026-05-05 | - |
| 0030 | `masc create` CLI / API for Keeper, Cascade, Persona | Draft | 4657df07d 2026-05-05 | - |
| 0031 | Three-Tier Config Disclosure (Basic / Advanced / Godmode) | Draft | 4657df07d 2026-05-05 | - |
| 0032 | Environment Knob Unification | Draft | 4657df07d 2026-05-05 | - |
| 0033 | Worktree Status SSE Channel | Draft | b26911589 2026-05-05 | - |
| 0034 | Per-Goal Cap to All Task-Creation Callers (post-#13981) | Draft | d2a28093e 2026-05-07 | RFC-0034-cap-all-callers.md + RFC-0034-task-oscillation-mitigation.md |
| 0035 | Cognitive IDE Master Plan Integration | Draft | afc2190a4 2026-05-07 | - |
| 0036 | Multi-Keeper Docker Orchestration & Lifecycle Cleanup | Draft | 6f919e7eb 2026-05-09 | RFC-0036-multi-keeper-docker-orchestration.md + RFC-0036-oas-cognitive-mapping.md |
| 0037 | Board Multimedia & Vision — Eio/File-Based Adaptation | Draft | b932150be 2026-05-09 | RFC-0037-board-multimedia-vision-adapted.md + RFC-0037-local-first-keeper-enablement-boundary.md |
| 0038 | Cascade Routing Intent Preservation | Draft | fe5519d79 2026-05-09 | RFC-0038-cascade-routing-intent-preservation.md + RFC-0038-opaque-identifier-types.md + RFC-0038-phase-2-keeper-identity-canonical.md |
| 0039 | Keeper Turn FSM — Streaming Escape & Cross-Axis Synchronization | Draft | 40e75e8ec 2026-05-09 | - |
| 0040 | Mention dedup at sender (broadcast-time) | Draft | cb67381a4 2026-05-07 | - |
| 0041 | Cascade Routing Architecture — Group/Item Hierarchy with Health-Aware Fallback | Draft | cde62900c 2026-05-08 | - |
| 0042 | Closed sum type for keeper turn terminal code | Active | cbba7c1e2 2026-05-09 | - |
| 0043 | Distribute Prometheus metric ownership to domain modules | Draft | bd2189ae4 2026-05-09 | - |
| 0044 | Typed persistence read-drop reason + Result-based reads | Draft | 781cb72ee 2026-05-08 | - |
| 0045 | SDK turn boundary alignment with MASC keeper FSM | Draft | 16d550ff4 2026-05-08 | - |
| 0046 | Keeper Detail FSM Hub as SSOT | Draft | fea59a84d 2026-05-08 | - |
| 0047 | `oas_*` adapter family decomposition (consumer-only OAS boundary) | Implemented | c211e3854 2026-05-09 | - (RFC-0047-caller-inventory.txt + RFC-0047-module-graph.dot 부속 자료) |
| 0048 | Dashboard Information Architecture Phase 2 | Draft | a52f79a0c 2026-05-08 | - |
| 0049 | Dashboard Surface Telemetry Foundation | Draft | a52f79a0c 2026-05-08 | - |
| 0050 | Dashboard Component Ownership Decomposition | Draft | 2abf3a5a8 2026-05-09 | - |
| 0051 | `run_named` closure decomposition | Draft | 7bbb7823e 2026-05-09 | - |
| 0052 | Boot-time Required Invariants (typed) | Draft | a9bfe564a 2026-05-09 | - |
| 0053 | Tool Dispatch Session-Local Handles | Draft | 597a4c999 2026-05-09 | - |
| 0054 | `[@@deriving shell_ir]` PPX for Typed Capability Substrate Phase 2 | Draft | e725a36c6 2026-05-09 | - |
| 0055 | Cascade Fallback Chain Capability-Tier Routing | Superseded | 340008ed7 2026-05-11 | superseded_by 0058 (per #14559 sweep) |
| 0056 | Incremental Sub-Library Extraction from Flat masc_mcp Library | Active | f003c7421 2026-05-09 | Phase 0 머지 #14384 |
| 0057 | Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation | Active | 6d11d2a67 2026-05-12 | Phase 0 머지 #14396 |
| 0058 | Declarative Cascade Configuration (v2) | Active | 39dfa59c4 2026-05-11 | RFC-0058-declarative-cascade-config.md (main) + RFC-0058-phase-5-erase-provider-variant.md + RFC-0058-terminal-fallback-capability-exemption.md (amendment) — Phase 0/1/4/5.2a/9.1 머지 |
| 0059 | IDE LSP Integration + Eio Domain/Actor Parallelism | Active | 340008ed7 2026-05-11 | Phase 2 PR-5/PR-6 closeout per #14559 |
| 0061 | Cache-invalidation broadcast envelope | Implemented | 2699965d1 2026-05-10 | #14424 |
| 0062 | Typed `Tool_result.t` + Typed `Sdk_*` Blocker Class | Active | 340008ed7 2026-05-11 | backfill per #14559 |
| 0063 | Telemetry Feedback Loop & Cooperative Scheduling Safety | Draft | b90415bfa 2026-05-11 | - |
| 0064 | Capacity Probe Adapter / Two-Surface Tool Alias | Active | 902590ce6 2026-05-11 | RFC-0064-capacity-probe-adapter.md + RFC-0064-two-surface-tool-alias.md — #14570/#14574 머지 |
| 0065 | Keeper Tool Selection Lifecycle: TLA+ Coverage Extension | Draft | edd1bbb33 2026-05-11 | - |
| 0066 | Legacy `*_models` Catalog Purge | Active | 9f1472b45 2026-05-11 | Phase 1/3/4a 머지 #14652 #14671 #14673 |
| 0067 | Goal-Scope Observation→Claim Atomicity | Draft | 44c383150 2026-05-11 | 구 RFC-0057 — collision 해결 (#14672) |
| 0068 | Typed `Keeper_turn_disposition` (operator-facing closed sum) | Draft | (pending #14692) | 구 RFC-0047 — collision 해결 |
| 0069 | Awareness Channel Split | Active | f762e88a2 2026-04-30 | 구 awareness-channel-split.md (PR-1.7) — PR-1.7a 머지 #12129, PR-1.7b/c 미완 |

### 사용 가능한 다음 번호

- 누락 번호 (이전 사용 후 해제됨): 0010, 0011, 0014, 0015, 0016, 0021, 0060.
- 다음 신규: **0070** (현재 가장 작은 사용 가능 번호는 0010 이지만, 누락 번호 재사용은 race-condition 위험 — 새 작성은 0070 이후 권장).

## 검색 / 발견

- 단일 RFC: `cat docs/rfc/RFC-NNNN-*.md`
- 키워드 검색: `rg <keyword> docs/rfc/`
- 본 README 의 표 + Last activity 컬럼으로 최근 활동 추적
- PR 작성 시 RFC 발견 체크: `bash ~/me/scripts/pr-rfc-check.sh --pr-body /tmp/pr-body.md`

## 비범위 (향후 별도 RFC)

- Frontmatter 자동 lint (CI hook)
- 기존 RFC retroactive frontmatter 통일
- 자동 인덱스 생성 (`scripts/rfc-index.sh` 또는 GitHub Action)
- Status sweep 전면 audit (Draft → Withdrawn 후보 식별)
