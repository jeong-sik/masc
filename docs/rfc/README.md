# RFCs — masc-mcp

이 디렉토리는 masc-mcp 의 설계 RFC(Request for Comments) 를 보관한다. 새 RFC 를 작성하기 전 본 README 의 §정책 + §Frontmatter 표준 을 읽고 진행한다.

## 정책

- **번호 할당**: `bash scripts/rfc-allocate-next.sh` 호출. 이 명령은 ledger `docs/rfc/.next-number` 에서 다음 번호를 stdout 으로 출력하고 ledger 를 +1 로 갱신한다. 같은 commit 에 RFC 파일과 ledger 갱신을 함께 넣는다. CI workflow `rfc-number-collision-check` 가 PR 단계에서 origin/main 의 기존 RFC 번호와 충돌을 차단한다. Multi-phase RFC (같은 NNNN 의 추가 phase 문서) 는 PR body `RFC-EXTEND: NNNN` 라인 또는 frontmatter `extends: "NNNN"` 로 명시적 opt-in 한다. 상세는 [RFC-0078](RFC-0078-rfc-number-reservation-ledger.md). 누락 번호 (0010/0011/0014/0015/0016/0021/0060) 는 재사용 금지 — ledger 가 모노토닉.
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
| 0010 | ocamlformat config reconciliation | Draft | (this PR) | - |
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
| 0058 | Declarative Cascade Configuration (v2) | Active | (this PR) 2026-05-17 | RFC-0058-declarative-cascade-config.md (main) + RFC-0058-phase-5-erase-provider-variant.md + RFC-0058-terminal-fallback-capability-exemption.md (amendment) + RFC-0058-phase-8-cascade-catalog-partial-parse.md (catalog partial parse; phase 8.1/8.2 merged #15733/#15737; phase 8.1.5/8.3/8.4 pending per post-merge self-review) — Phase 0/1/4/5.2a/8.1/8.2/9.1 머지 |
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
| 0070 | Keeper Sandbox Runtime — Pure/Edge Separation | Draft | (pending #14714) | depends on RFC-0036 Phase A, extends RFC-0006 Phase B-2 |
| 0071 | Exhaustive Match Sweep Codemod — Eliminate N-of-M `_ -> false/None` Anti-Pattern | Draft | #14881 2026-05-12 | body written by this PR; lib/core/dune reference (#14888) realized. Related RFC-0042, RFC-0068. |
| 0072 | Type-encoded keeper sub-FSM transitions (cascade + turn_phase) | Draft | 2026-05-12 | follows PR #14887 + #14893 decision-axis precedent. |
| 0073 | Tool Readiness Probe — Typed Precondition + Runtime Gap Disclosure | Draft | (this PR) | Tool readiness package — RFC-0073/0074/0075/0076 coordinated. |
| 0074 | Sandbox & Credential Auto-provision per Keeper Preset | Draft | (this PR) | follows RFC-0073 probe — closes gap that probe diagnoses. |
| 0075 | Keeper Tools Smoke — Exhaustive Dispatch Coverage Regression Gate | Draft | (this PR) | follows RFC-0071/0072 exhaustive-match precedent for tool dispatch. |
| 0076 | Tool Readiness Notification Channel — Typed Event Ledger Surface | Draft | (this PR) | follows RFC-0073/0074 — streams readiness state transitions. |
| 0077 | Write-side silent failure — typed propagation | Draft | 2026-05-14 | symmetric counterpart to RFC-0044 (read-side); covers 20 grandfathered write/create sites in lib/keeper/. Originally claimed 0073, renumbered after #15064 0073-0076 package landed. |
| 0078 | RFC Number Reservation Ledger + CI Collision Guard | Draft | 2026-05-14 | introduces `docs/rfc/.next-number` ledger + `rfc-number-collision-check` workflow |
| 0079 | Log row typed encoder + silent-drop removal | Draft | 2026-05-14 | typed `Ring.entry` (level/source closed sums), `Entry_decode_error` raise, drops raw_level/normalized_level/legacy_classified/dropped_entries; supersedes #15170 |
| 0080 | Tool registry SSOT — collapse 15-fold OR membership into typed Tool_name boundary | Draft | 2026-05-14 | 540-warn/boot split-brain (88 distinct tool names); typed `resolve` at policy load boundary |
| 0081 | OAS Telemetry Envelope Context & Keeper/Goal Pivot Timeline | Draft | (this PR) 2026-05-14 | supersedes closed PR #15128 (RFC-0073) — emission-side carved out to RFC-OAS-019 (oas repo). Related RFC-0046, RFC-0049, RFC-0063 |
| 0086 | Keeper namespace bulk promotion to sub-library | Draft | (this PR) 2026-05-15 | strategic successor to RFC-0056 leaf-sweep — Phase 2.A rename 38 non-prefix files + Phase 2.B `(wrapped false)` bulk promotion. Renumbered from 0085 due to collision with parallel host_config workstream. Related RFC-0056, RFC-0042, RFC-0050 |
| 0087 | Tool Dispatch Path Unification + Legacy Purge | Implemented | (this PR) 2026-05-15 | 18-PR sprint post-RFC-0084: MCP `dispatch_by_tag` / internal_keeper_runtime 두 path가 5 typed observer (Tool_metrics / Tool_usage_log / Otel_dispatch_hook / Tool_output_validation / server_bootstrap_loops) 발화 통일 + 9 production /tmp 리터럴 박멸 + Env_config_core 6 path-related export 폭발 + env-var deprecation 메커니즘 7 entries 폭발 + 60+ underscore-prefix naming bug 박멸 + ~250 LOC dead code 삭제 + `Host_config.t` + `Dispatch_outcome.t` PPX deriving + `test_lib/ast_grep.ml` regression infra. Related RFC-0084, RFC-0056 |
| 0088 | Counter-as-Fix → Result Propagation (umbrella scoping) | Draft | (this PR) 2026-05-15 | Partitions 16-site bug-hunter audit (2026-05-15) into 4 owning families: auth Phase B flip-switch (3 sites), RFC-0044 read-side (2 sites already migrated), RFC-0077 write-side (13+ sites inventoried), Coord async-context-free drop (1 unowned counter — §4 Option A folds into RFC-0044). No new code; merge-reject bar consolidation. Related RFC-0042, RFC-0044, RFC-0062, RFC-0063, RFC-0077 |
| 0089 | String Classifier to Typed Variant — direct replacement, no lint | Draft | (this PR) 2026-05-15 | 2026-05-15 bug-hunter audit이 `String.starts_with ~prefix:"..."` 215 site (lib/) 식별. RFC-0042 잔존 사이트의 mop-up RFC — 도메인 단위 typed variant 직접 교체, lint/phrase list 도입 금지 (워크어라운드 #2 자기참조). scope-out: 외부 protocol/storage boundary. Inventory `inventory/RFC-0089-string-classifier-sites.md`. Related RFC-0042. Number reassigned from 0088 due to collision with parallel RFC-0088 Counter-as-Fix work (PR #15500) |
| 0090 | Write-side success-model attribution — finish N-of-M migration | Draft | (this PR) 2026-05-17 | PR #15578이 fix한 2 사이트 외에 `keeper_turn_driver.ml` L969 (`Cascade_fsm.Accept` unreachable branch, `outcome=Success`)가 `~selected_model_raw:None` 잔존 — N-of-M leak. PR #15564 read-side `"{cascade_name} (cascade)"` fallback은 §Symptom 억제 Fallback Resolution 시그니처. PR-1: L969 Some 변환 + 5 error site marker. PR-2: read-side fallback deprecation marker + hit counter. PR-3: 7-day 0-hit 후 read-side fallback 제거. Related RFC-0044, RFC-0077, RFC-0088 |
| 0091 | Keeper bash tool: cmd string → typed Argv schema (lexer/validator 박멸) | Draft | (this PR) 2026-05-17 | 24h log audit (`~/me/.masc/logs/`, 2026-05-16~17) Top 1 ERROR pattern `Path syntax blocked` 253건 (90 raw + 60 caller mirror + 59 retry + 44 registry recording) 의 single emission point `lib/worker_dev_tools.ml:613` 이 *string-as-protocol 워크어라운드 위에 string-classifier 워크어라운드가 누적된 자기참조 구조*. `worker_dev_tools.ml` 1718-LOC godfile 의 shell metachar lexer/parser stack 박멸 + `keeper_bash` 입력 schema 를 `{cmd: string}` 에서 `Exec / Pipeline` typed variant 로 전환. 4-phase migration. RFC-0089 §2 scope-out (외부 protocol boundary) 의 자매 RFC. Number reassigned from 0090 due to ledger race-loss against parallel `write-side success-model attribution` PR #15651 (merged first). Related RFC-0042, RFC-0084, RFC-0089 |
| 0092 | Keeper shell-bash typed validation via Shell_ir.parse | Draft | (this PR) 2026-05-17 | Replaces regex+substring shell validation in `keeper_shell_bash.ml` with typed `Shell_ir.parse` validation/advice. Related RFC-0054, RFC-0070, RFC-0084, RFC-0087, RFC-0089 |
| 0093 | Board persistence — path unification (snapshot vs append) | Draft | (this PR) 2026-05-17 | `board_posts.jsonl` 에 두 persistence path 공존: P1 (`board_votes.ml:923-925` dirty-flush `List.iter append_post`) + P2 (`board_votes.ml:840-848` `save_jsonl_snapshot rewrite_posts`). 2026-05-17 측정: 최근 100 posts 안 13 unique ids 가 최대 5× dup. 2026-05-16 board taxonomy 분석이 A1+D1 P0 로 "RFC 필요" 표시하고 9 iter 후 종결한 정확한 자리. Option D 권장 — snapshot rewrite 를 단일 writer 로, `append_post` 는 create-only fast path 로 좁히고 mutation/vote flush 를 snapshot 호출로 교체. Migration 1 줄 코드 변경. Related RFC-0077, RFC-0042, RFC-0062 |
| 0094 | Compact cooldown semantics split — typed write anchor vs check anchor | Draft | (this PR) 2026-05-17 | PR #15682 V01 fix가 `last_continuity_update_ts` 의 cooldown anchor 의미와 successful state write anchor 의미를 단일 필드에 합쳐버려, `keeper_world_observation.read_continuity_summary`/`keeper_heartbeat_snapshot` 두 reader 의 fallback summary 텍스트가 "stale [continuity_summary] + fresh ts" 거짓 신호를 노출. 본 RFC 는 두 의미를 별도 필드 (`last_compact_check_ts` 신설 + `last_continuity_update_ts` 의미 복원) 로 분리하는 3-phase migration 을 제안. 관련 telemetry counter `keeper_state_snapshot_skipped_no_state_total` 는 sidecar 로 유지 후 Phase 3 에서 제거. Related RFC-0088 (counter-as-fix), RFC-0089 (string classifier rejected alternative) |
| 0095 | OpenAI-compat provider streaming wire-up | Draft | (this PR) 2026-05-17 | `Custom_openai_compat` binding (runpod_mtp / local_mtp) 가 streaming chunk 를 emit 하지 않음 — 2026-05-17 Prometheus `provider="openai_compat"` count = 0 vs `provider="glm"` 5332 chunks. 4-layer pipeline (llama-server SSE / cascade transport `complete_stream` / OAS hooks / metric bridge) 모두 코드 정착됐으나 wire-up 누락. H1/H2/H3 hypothesis 3종 + Phase 0 진단 PR (production behavior 무변경) + Phase 1 fix + regression test. Related RFC-0047, RFC-0045, RFC-0033, RFC-0058 |
| 0097 | Keeper sandbox container reuse (long-running sandbox per keeper) | Draft | (this PR) 2026-05-17 | 2026-05-16 18:08-18:15 ENFILE storm 근본 fix. 매 keeper Bash 호출이 `docker run --rm` 신규 컨테이너를 띄우는 현 구조는 host FD 비용을 `O(active_keepers × inflight_calls)` 로 만들어 cascade-failure-storm 시 `kern.maxfiles` 491k 천장을 saturate 시킴. 이를 keeper 당 long-running 컨테이너 + `docker exec` 모델로 전환하여 비용을 `O(active_keepers)` 로 떨어뜨림. PR #15678 (autonomy_exec pipe leak fix) + PR #15727 (docker spawn throttle Layer A/B) 가 spawn *rate* 를 막은 후속 — 본 RFC 는 *cost* 자체를 제거. Phase 0(spec)→1(opt-in)→2(default flip)→3(legacy removal) 4-phase migration, env flag `MASC_KEEPER_SANDBOX_MODE`. Related RFC-0042 |
| 0098 | Typed JSON-RPC error envelope & production-code silent-failure lint | Implemented | (this PR) 2026-05-17 | IMPROVE-01 of the masc-mcp + oas improvement series (silent-failure / streaming / TTFT / FD / stability). Renumbered from 0094/0097 after ledger race-loss against #15716 / #15728 / #15722 / #15725 and the merged RFC-0097 sandbox-container spec. `server_mcp_transport_http_respond.ml` 의 4 hand-rolled JSON-RPC error site (-32001/-32002/-32603×2, literal integer 산재) → `Mcp_error_code` closed-sum + 단일 `respond_mcp_error` SSOT. `scripts/anti-fake-audit.sh --production-scan` 베이스라인: 13 E1/E2 + 3 T1 grandfather. Cycle: PR-1 #15759 (SSOT) → PR-2 #15776 (delegate) → sync #15784 #15789 → PR-3 #15793 (10 callers migrated, `git grep "(-326[0-9][0-9])" lib/server/` = 0) → PR-4 #15826 (legacy 3 factories + `[@@@alert "-deprecated"]` test suppression removed, −160 LoC). Originally-planned `Provider_timeout` / `Tool_dispatch_failure` / `Backpressure_shed` 외부 wirings는 callee가 이미 typed `Agent_sdk.Error.t`로 reframe됨 — `Agent_sdk.Error.t → Mcp_error_code.t` mapping은 follow-up audit (low priority). [[RFC-0077]] / [[RFC-0088]] / [[RFC-0089]] 직교. Related RFC-0077, RFC-0088, RFC-0089, RFC-0090, RFC-0062, RFC-0042 |
| 0099 | Session lifecycle — typed events, explicit eviction, resume backpressure | Active | (this PR) 2026-05-17 | IMPROVE-05 of the masc-mcp + oas improvement series. SSE/WS/gRPC/WebRTC 4 transport의 session lifecycle 통일. Progress: PR-2 #15810 (typed module inert) + PR-3 #15853 (SSE close frames + `stop_sse_session_evict` + publisher hook) MERGED. Pending: PR-4 (WS/gRPC/WebRTC fan-out) / PR-5 (keep-alive SSOT + CI lint) / PR-6 (Last-Event-ID resume). 신규 `lib/server/session_lifecycle_event.ml(i)` closed-sum 5-variant (Open/Upgrade/Resume/Evict/Close) typed event를 `Event_bus.Custom("session_lifecycle", ...)` 발행 + `evict_reason` 4-variant에 대응하는 explicit close frame (SSE `event: evicted` ✓, WS close code 4001-4099 pending, gRPC `Status=ABORTED` trailer pending, WebRTC datachannel close pending). [[RFC-0098]] sibling — RFC-0098이 response edge, 0099가 transport edge. `docs/TIMEOUT-MATRIX.md`와 보완 관계. Related RFC-0098 |
| 0100 | Streamable HTTP as default transport (MCP 2025-03-26) | Draft | (this PR) 2026-05-17 | IMPROVE-02 of the masc-mcp + oas improvement series. MCP 2025-03-26 spec deprecates legacy HTTP+SSE pair → Streamable HTTP (chunked POST + lazy SSE upgrade on same connection). 3 결함: (1) streaming opt-in via separate GET /sse, (2) session keying via query string leaks IDs/breaks L7 routing, (3) ALB/Cloudflare drops long-lived SSE GET 20/22 within 60s. 해결: `POST /mcp` chunked first-flush (≤50ms budget), auto-upgrade to SSE on tool/LLM streaming dispatch (same connection — `text/event-stream` content-type set lazily), `Mcp-Session-Id` HTTP header replaces query-string keying. 5-PR migration (PR-2 chunked first-flush → PR-3 auto-upgrade + Mcp-Session-Id → PR-4 Last-Event-ID delegation to RFC-0099 + Deprecation/Sunset headers on legacy GET /sse → PR-5 T+6mo removal). Resume/keepalive/lifecycle ALL delegated to [[RFC-0099]] (compose not duplicate). [[RFC-0098]] envelope shape unchanged. [[RFC-0095]] provider-side streaming orthogonal. Related RFC-0095, RFC-0098, RFC-0099, RFC-OAS-020 |
| 0101 | FD accountant — generic Eio.Pool extension to cover all spawn classes | Active | (this PR) 2026-05-17 | IMPROVE-03 of the masc-mcp + oas improvement series. Progress: prereq #15727 (`Docker_spawn_throttle` Layer A/B) + PR-2 #15816 (`Fd_accountant` 4-kind pool + Docker delegation) + PR-3 oas #1618 (`Fd_throttle_hook` injection at `Provider_throttle.with_permit_priority`) MERGED. Pending: PR-4 (Sandbox_exec + Log_writer wrap) / PR-5 (/metrics + dashboard) / PR-6 (RFC-0099 Backpressure compose). 신규 `lib/server/fd_accountant.ml(i)` 4-kind generic Eio.Semaphore pool (Docker_spawn / Provider_http / Sandbox_exec / Log_writer) + per-kind env knob cap (defaults 8/16/32/64=120 합) + Layer B shared FD-pressure mutex on `Keeper_fd_pressure.active ()`. `Docker_spawn_throttle.with_slot`은 `Fd_accountant.with_slot ~kind:Docker_spawn`로 delegate (public API preserved, RFC-0098 PR-2 패턴 재사용). PR-3는 oas 가 masc-mcp 의존 없이 동작 — `Fd_throttle_hook` identity-default Atomic 패턴으로 cross-repo DI. Related #15727, #13642, RFC-0097, RFC-0098, RFC-0099, RFC-0100 |

### 다음 번호

진실의 출처는 `docs/rfc/.next-number` 파일. 작성자는 `bash scripts/rfc-allocate-next.sh` 로 할당받고 같은 commit 에 ledger 갱신을 묶는다. 본 표는 사람이 직접 갱신하므로 ledger 와 일시 불일치 가능 — 충돌 검사는 CI 가 한다.

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
| 0102 | Pre-turn cascade availability gate — reuse, not new surface | Draft | (this PR) 2026-05-17 | Fourth *pre-turn* layer between RFC-0009 (pre-attempt ordering) and RFC-0022 (in-attempt liveness). **Adds zero new types / API / reason codes / broadcast paths / counters** — every typed atom needed already exists: `Failure_cascade_unavailable` (keeper_turn_fsm.ml:8), `No_providers_available` + `"cascade_exhausted_no_providers_available"` (keeper_meta_contract.ml + keeper_unified_turn_types.ml:107), `Cascade_health_filter.health_filter_rejection` typed sum, `Phase_gating → Done(Skipped)` template (4 existing arms in keeper_unified_turn.ml), `cascade_recovered` closure in keeper_stale_watchdog.ml:749-770. Change is (a) extract that closure into a named `Cascade_health_filter.current_availability` and (b) case-split the fail-open policy at keeper_turn_driver.ml:325-345 so `All_local_unhealthy` keeps fail-open but `All_missing_api_key` returns `No_providers_available` immediately. RFC-0088 self-check §6 — *first draft proposed 4 new surfaces and was rejected by its own N-of-M check in same-day amend*. Removes the N-keepers × M-turns/min WARN flood observed 2026-05-17 (memory: `project_cascade_tier_group_misroute_2026_05_17.md`). Related RFC-0009, RFC-0012, RFC-0022, RFC-0042, RFC-0072, RFC-0088 |
| 0103 | Log retention opt-in + volume-root anchoring | Draft | 9f7b4ce520 2026-05-17 | retroactive index entry — body merged via #15850 (5-PR sprint). Default-disabled retention with explicit opt-in env knob + log volume-root anchored archiver. |
| 0104 | Keeper task → default repo binding (sandbox cwd disambiguation) | Draft | (this PR) 2026-05-17 | 2026-05-17 08:33 prod observation: keeper `tech_glutton` `sandbox root cannot run git/gh: ... multiple sandbox repos exist` hard-fail. Root: task schema has no typed `default_repo` field, so sandbox cwd resolver can't disambiguate when ≥2 repos are mounted. Proposes `Masc_domain.repo_id` opaque type + `task.default_repo : repo_id option` with `resolve_default_cwd` typed function. 5-phase migration. Closes RFC-0006/0070/0097 gap (task↔repo binding). Related RFC-0006, RFC-0036, RFC-0070, RFC-0097. |
| 0105 | OpenAI-compat boundary: `Agent_sdk.Error.t` → HTTP status + typed envelope | Implemented | (this PR) 2026-05-17 | RFC-0098 closeout follow-up audit. RFC-0098 (Implemented #15828) cleared `server_mcp_transport_http` (0 literal codes, 9 typed `Mcp_error_code` sites). This RFC closes the sole remaining lossful boundary in `lib/server/`: `server_openai_compat.ml:125` `Agent_sdk.Error.to_string` typed→string compression, amplified by `route_cascade (_, string) result` signature and `handle_chat_completions` blanket 500 / `"server_error"` flattening. `Openai_compat_error_map.t` total mapping + widened Error tag + envelope `code` field population landed in #15899 (21/21 Alcotest PASS, exhaustive over 9 sdk_error top-level variants, no catch-all). `route_keeper` deeper site at `keeper_turn.ml:521-531` deferred to a separate RFC (larger scope). Related RFC-0098, RFC-0095. |
| 0106 | Cancel-safe try-with discipline (Eio.Cancel.Cancelled propagation) | Draft | (this PR) 2026-05-17 | Existing `scripts/lint-cancel-guard.sh` only matches single-arm `try X with exn -> Y`; multi-arm `try X with \| A -> a \| exn -> b` is invisible. iter 30 (#15883 bg_task drain) and iter 32 (#15887 keeper_post_turn on_compaction_started) were both silent Cancelled swallows that lint missed. Naive regex extension hits 3751 false-positives. Proposes `Cancel_safe.protect` helper combinator (SSOT) + ppxlib AST lint in Phase 2 + phased migration. Related RFC-0072, RFC-0097, RFC-0101. |
| 0107 | Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport | Draft | (this PR) 2026-05-17 | 2026-05-16 ENFILE storm 의 진짜 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant) 는 같은 사고의 transitional defense — 1/4 kind 만 wired, 3 kind dead branch. (1) cohttp-eio 6.1.1 socket-not-closed bug → `make_closing_client` 워크어라운드 (Eio issue #244 권고 위반); (2) connection pool 부재 (masc-mcp + oas); (3) `run_turn:196` ambient switch (turn-scoped FD boundary 없음); (4) subprocess-heavy Docker (`docker run/exec`, `/var/run/docker.sock` 미사용, RFC-0097 spec-only). 4-layer 설계: L1 Transport (Phase B spike → piaf default / cohttp-eio latest 검토), L2 `(host:port) → Client.t` keyed pool, L3 `run_turn` fresh `Eio.Switch.run`, L4 Docker UDS + RFC-0097 활성화. RFC-0101 은 머지 직후 transitional → Phase D + 30일 production soak gate 후 retire. PR #15881 (Sandbox_exec wrap) close. Prior Art: piaf, Tarides Ocsigen→Eio (2025-03), cohttp #85, Eio #244, Eio.Switch axiom. Related RFC-0097, RFC-0100, RFC-0101. |
