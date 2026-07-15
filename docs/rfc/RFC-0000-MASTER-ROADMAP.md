# RFC-0000 — MASC × OAS Consolidated Master Design (SSOT)

> Status: **Draft / Candidate SSOT** — `main` 병합 전에는 정본이 아님
> Consolidates: ~65 design/audit sources (see §10 Evidence Source Index); 이 PR은 원문을 archive하지 않음
> Last-updated: **2026-07-15**
> OAS pin snapshot: **agent_sdk 0.212.0**. 값의 정본은 `scripts/oas-agent-sdk-pin.sh`와 lockfile이며 이 문서가 아님. See §2.6.
> Scope: MASC (Multi-Agent Streaming Coordination) + OAS (OCaml Agent SDK) product line.

---

## Table of Contents

- [0. Meta — how agents use this doc](#0-meta)
- [1. North Star & Non-Goals](#1-north-star--non-goals)
- [2. The Boundary Law (+ crossover findings)](#2-the-boundary-law)
- [2.6 OAS Version Pin & Pending 0.213 Contract](#26-oas-version-pin)
- [3. Subsystem cards (direction + audited snapshot)](#3-subsystem-ssot)
  - [3.1 Board](#31-board) · [3.2 Legacy Goal (retired)](#32-goal) · [3.3 Task](#33-task) · [3.4 Effect Permission Boundary](#34-hitlgate) · [3.5 Scheduler](#35-scheduler) · [3.6 Connector](#36-connector) · [3.7 Fusion](#37-fusion) · [3.8 Keeper (Lane-Per-Keeper)](#38-keeper-lane-per-keeper) · [3.9 Memory](#39-memory) · [3.10 Runtime (Provider/Model catalog)](#310-runtime-providermodel-catalog) · [3.11 Dashboard-Chat](#311-dashboard-chat)
  - [3.12 OAS Internals (pure library)](#312-oas-internals) · [3.13 Keeper-as-a-Tool (cross-model invocation)](#313-keeper-as-a-tool) · [3.14 IDE Observation Plane v2](#314-ide-observation-plane-v2)
- [4. Candidate Execution Roadmap (12 goals)](#4-execution-roadmap)
  - [4.13 Crossover finding details (CF-1..CF-6)](#413-migration-debt-goals)
  - [4.14 Deferred candidate specs (DS-1..DS-8)](#414-deferred-subsystem-goals)
- [5. Orthogonality Matrix](#5-orthogonality-matrix)
- [6. Blast Radius Matrix](#6-blast-radius-matrix)
- [7. Benchmark Lens](#7-benchmark-lens)
- [8. Recovered / Deferred Idea Inventory](#8-recovered--deferred-ideas)
- [9. Anti-patterns to Refuse](#9-anti-patterns-to-refuse)
- [10. Evidence Source Index](#10-source-index)
- [11. Open Decisions Ledger (NEEDS_DECISION)](#11-open-decisions-ledger)

---

<a name="0-meta"></a>
## 0. Meta — how agents use this doc

이 문서는 MASC/OAS 제품 방향의 **candidate SSOT**다. 병합 뒤에도 소유 범위는 장기 경계와 불변식이다. OAS public API, 현재 코드, pin, PR/CI/live 상태는 각각의 정본을 따른다. 이 문서 밖의 자료를 blanket-stale로 선언하거나 OAS upstream 문서를 supersede하지 않는다.

**읽는 순서 (Haiku급 에이전트 기준):**

1. §1 North Star & Non-Goals — 무엇을 만들고 무엇을 안 만드는가. 스코프 크리프 방지.
2. §2 Boundary Law — MASC↔OAS 경계. 여기 위반하면 어떤 코드도 머지 금지.
3. §3 해당 subsystem 카드 — 방향은 규범적, `현재 상태`는 작성 시점 감사 snapshot.
4. §4 candidate goal — 구현 전 GitHub live 상태와 현재 코드를 다시 검증.
5. §9 Anti-patterns — 작성 *전* self-check (워크어라운드 시그니처).
6. §8 Deferred Inventory — 과거에 이름이 있었다는 이유로 착수하지 말고 fresh evidence가 있는지 확인.

**규칙:**

- 이 문서와 코드가 충돌하면 **현재 동작의 정본은 코드**, 장기 방향의 정본은 병합된 이 RFC다. 충돌을 숨기지 말고 RFC 위반 또는 RFC 개정으로 명시한다.
- release/pin/PR/CI/live 수치는 이 문서의 정본이 아니다. 인용할 때 commit·명령·확인 시각을 붙인다.
- 완료 기준은 "동작 개선"이 아니라 **기계로 판정 가능한 상태**다: grep 카운트, HTTP status, 테스트 통과, 렌더 여부. 주관적 "좋아짐" 배제.
- Draft PR가 로컬 focused check를 통과해도 그것은 production-ready의 *후보*이지 검증 자체가 아니다. **CI = typed behavior, live smoke = deployed behavior**. 보고서는 둘을 분리한다.
- OCaml 하한은 실제로 dune-project 기준 **≥5.5** (CI가 5.5에서 authoritative). "5.4 원칙"은 lower-bound 참조일 뿐.

### 0.1 Adversarial survival verdict

| 판정 | 내용 |
|---|---|
| **KEEP** | OAS의 작은 provider/model-call SDK, Lane Per Keeper, typed yield/error/checkpoint, MASC-owned context, Board/Task/connector, durable state와 exact observability |
| **REWRITE** | version/PR/progress snapshot, 중복 goal 상태, provider/model telemetry 표면, effect permission — 정본 링크와 기계 판정으로만 유지 |
| **KILL** | Legacy Goal runtime, generic governance hierarchy, `Context_reducer`, implicit sampling/timeout/turn/token defaults, string/score/count가 semantic·lifecycle·effect 결정을 대신하는 heuristic, stub/synthetic ToolResult, migration/backfill/dual-read, producer·consumer 없는 타입 |

`KILL` 항목은 deferred idea가 아니다. 옛 데이터를 살리기 위한 migration 없이 production path·fixture·compatibility branch를 함께 제거한다. 아래의 상세 inventory는 삭제 전 근거를 보존하기 위한 것이며, 이름이 있다는 이유로 구현 권한을 얻지 않는다.

### 0.2 Fact-check snapshot (2026-07-15, HEAD `f84ff7ea53`)

이 문서의 `현재 상태`·코드 참조를 7-에이전트 적대 검증 + 독립 fresh-grep으로 재확인했다(masc 워크트리 `f84ff7ea53`, oas pin `b02bc16f`). 36개 claim을 코드에 맞게 교정했다:

- **존재하지 않는 심볼/파일 11** — 예: `Provider.config`는 record이고 4-variant sum은 `Provider.provider`; `Keeper_runtime_engine.guard_keeper_hot_path`·`EffectIntent`/`ContinuationRef`·`block_tokens`·`governance_pipeline.ml`·`KeeperOASAdvanced.tla`/`CancelledNeverAbsorbed` 전부 HEAD 부재(실제 TLA spec은 `specs/keeper-turn-fsm/KeeperTurnFSM.tla`, invariant `StopSignalRespected`).
- **추출 후 stale해진 `현재 상태` 13** — fleet이 착지·삭제해 사실이 바뀐 항목: provider failover machinery(존재+테스트) · fusion wake(RFC-0266) · raw_trace 배선 · agent_timeline #23540 · keeper.tool_exec · council staged preset · FORGET machinery · verification 삭제(RFC-0220 §11) · Slack gateway(RFC-0317 PR-3) · deliverable SSOT 병합. 방향 텍스트는 유지하되 `현재 상태`를 HEAD로 갱신하고 해당 open-goal에 `[LANDED]`/`[STALE-verify]`를 표기했다.
- **라인/카운트 드리프트 9** · **RFC 상태 오기 3**(RFC-0026 부재→0192 단독; RFC-0323 = Withdrawn; RFC-0334 = Superseded).

방법·전체 판정 로그는 이 PR 설명을 참조한다. 이 절 자체도 확인 시점 snapshot이며, 구현 전 §3 preamble대로 fresh grep으로 재검증한다.

---

<a name="1-north-star--non-goals"></a>
## 1. North Star & Non-Goals

### 1.1 Product thesis

**MASC**는 다수의 **자율·영속 Keeper**를 조율하는 **멀티-repo coordination server**다. 서버 프로세스는 하나의 `base_path`(`.masc` 런타임/설정 루트)에 앵커되지만, 조율 대상은 `repositories.toml`에 등록된 **여러 독립 repo**다(`repo_store`: 각 repo는 `url`+`local_path`, `.masc` 밖 절대경로 가능). Keeper는 `.masc/playground/<keeper>/repos/<repo>`의 **per-keeper clone**에서 작업한다(`playground_repo_readiness.ml`가 `Repo_git.clone` 호출, 경로는 `config/playground_paths.ml`; 공유 checkout 아님). 단 playground repos는 filesystem 관측 대상이지 access verdict가 아니다(`keeper_sandbox_control.ml:433`). *server-local ≠ work-repo-local* — 서버가 한 checkout에서 도는 것과 조율 대상이 한 repo에 갇히는 것은 별개이며, MASC는 전자이되 후자가 아니다. 각 Keeper는 자기 persona(`MASC_PERSONAS_DIR/<name>/profile.json` = identity·role·traits, 선택적 sibling `AGENT.md` = 자유 텍스트; `keeper_schema.ml`)로 공유 MASC world에 상주하는 자율 에이전트다 — repo를 다루는 코딩일 수도, Board 토론·투표·Discord/Slack 대화·Voice·역할극일 수도 있다(repo 바인딩 없는 Keeper도 1급; keeper↔repo 매핑은 `policy_mode=advisory` 기본값이지 authorization 경계가 아님). *[설계 배경: RFC-0213/0324/0338 — 모두 Draft, 근거는 위 코드]*

MASC가 최적화하는 것은 단일 턴 지연이 아니라 **fleet 수준 재현성(receipt-before-side-effect)**, **provider-agnostic 라우팅(OAS 소유·MASC 소비)**, **lane별 격리와 연속성**이다. 경계는 트레이드오프가 아니다:
- **결정론/비결정론 경계를 명확히** 둔다 — 의미 판단(완료·승인·관련성)은 LLM Auto Judge에 위임하고, typed-input·path-jail·sandbox 불변식은 각 execution boundary에서 결정론적으로 강제한다. ("속도보다 결정론"을 *선택*하는 게 아니라, 무엇을 경계 어느 쪽에 두느냐의 문제.)
- **자율과 관측은 직교**한다 — cost/token/turn은 stop/pause 권한이 아니라 **관측**이다(`KEEPER-CAPABILITY-MATRIX.md:176`). 전부 관측하되 자율을 제약하지 않는다. ("자율보다 가시성"은 트레이드오프가 아님.)
- 운영자 권한은 **두 개의 다른 축**으로 좁게 한정된다(RFC-0341 Accepted; RFC-0318/0319/0337이 hierarchical/risk-band 승인 폐기):
  - **request 축**(개별 *요청*이 진행될지) — Manual HITL · Auto Judge · Always-allowed 규칙. 비차단(decide-then-wake).
  - **lifecycle 축**(한 *keeper*가 살아있을지) — typed 명령 Stop/Boot/Delete, 그리고 죽은 keeper의 `Dead_tombstone`(terminal lifecycle latch, `keeper_lifecycle_admission.mli`)은 explicit operator 부활로만 복귀(`keeper_dead_revival_transaction`). **HITL(request)과 tombstone(lifecycle)은 다른 축** — 전자는 액션 승인, 후자는 생사.
- Keeper는 **두 lane**에서 돈다: `Autonomous`(heartbeat 스케줄이 구동) · `Chat`(operator/connector 메시지; `direct` stream 등은 그 transport). 이 둘 사이의 유일한 게이트는 `keeper_turn_admission`의 **single-flight**뿐 — 한 keeper가 동시에 2턴을 돌려 checkpoint를 손상시키지 않게 직렬화만 한다(busy면 Autonomous=skip→다음 heartbeat 재시도, Chat=queue). **정책·용량 거부는 없다**(capacity/wait admission은 2026-07-13 폐기, RFC-0192 `Retired` — "retired admission-wait proposal", updated 2026-07-13). 즉 "idle/heartbeat/direct/autonomous"는 운영자가 풀어주는 신뢰 사다리가 **아니라** 서로 다른 층위의 이름(2 lane + 스케줄러 + transport + FSM phase)일 뿐이다. autonomy-first — `autoboot_enabled`/`proactive_enabled`가 켜지면 기본 자율 실행되고, autonomous 실행이 멈추는 건 오직 `Autonomous_paused`·`Dead_tombstone`(실제로 멈췄거나 죽은 keeper)뿐이다.

**OAS**는 순수 단일 에이전트 라이브러리다. 소유하는 실제 primitive는 provider 라우팅(4-variant sum은 `Provider.provider` = `Local|Anthropic|OpenAICompat|Custom_registered`; `Provider.config`는 이를 담는 record `{provider; model_id; api_key_env}` + `Backend_*`), checkpoint(`Checkpoint.t` v8 순수 값 + `Checkpoint_store`), tool-boundary cooperative yield(`Agent.Advanced.run_blocks`, `Continue|Yield`), reasoning replay(`Reasoning_replay_contract`/`Reasoning_history_projection`), wire observer(`Wire_observer`), stop reason(`Llm_provider.Types.stop_reason` 12-variant + `Stop_reason_wire`), sub-agent 위임(`Handoff.make_handoff_tool`), 6-stage turn pipeline(`Pipeline`)이다. OAS는 masc/keeper/board/persona/hitl/fusion 등 downstream coordinator의 도메인 어휘를 전혀 모른다(grep 실측 각 0건, §2.2).

### 1.2 The Four Laws (MASC 런타임 헌법)

| Law | 내용 |
|-----|------|
| **LAW 1 ACTIVITY FIRST** | budget·cost·turn·no-progress·approval·provider-failure는 Keeper 전체를 terminal 상태로 만들지 않는다. enabled Keeper는 항상 Active·Awaiting·Recovering·(서명된 operator 명령에 의한) Stopped 중 하나. No dead-end. |
| **LAW 2 DECISION BOUNDARY** | 의미 판단(완료·승격·관련성·semantic topology·source-needed)은 schema-valid Judge receipt를 통과한다. 반면 typed capability eligibility, declared candidate order, lane routing은 결정론이다. 문자열·점수·연속 횟수는 결정 권한이 없다. Judge unavailable → Inconclusive/PendingJudgment, 위험 effect commit 금지, **deterministic fallback approval 금지**, Keeper는 reversible work 계속. |
| **LAW 3 EVERYTHING OBSERVED** | Turn·provider/model·prompt/decode/cache token·Tok/s·tool·effect·approval·memory·Judge·cost를 causal ID로 결합. **Journal ≠ Trace**: append-only lifecycle journal은 recovery-correctness SSOT, OTel/log/dashboard은 projection. exporter loss가 recovery state를 바꾸지 못한다. |
| **LAW 4 HARD CUT** | 새 경계를 검증한 뒤 legacy를 **즉시** 삭제한다. compatibility parser·dual-write·숨은 fallback을 장기 유지하지 않는다. **Fiber ≠ Durable job**: Eio Switch는 lexical lifetime/cancellation scope. 장기 생존성은 store+dispatcher+receipt가 담당. |

### 1.3 Non-Goals (스코프 크리프 차단)

**MASC Non-Goals:**

- Custom PR system (`.masc/pulls/` — 취소). remote PR lifecycle 재발명 금지 (CASPER: "PR 시스템 재발명 금지").
- Commander/Worker 역할 계층 (BALTHASAR: "역할 구분은 인간중심적 함정"). capability-based 라우팅만.
- Auto-merge 정책. 최종 main 머지는 인간 승인 필수.
- 단일 턴 지연 최적화 / operator lifecycle 권한(Stop·Boot·Delete·HITL·Dead_tombstone)을 제거한 **무제약** 자율 / 최소 setup. (자율 자체는 non-goal이 아니다 — Keeper는 기본 autonomy-first이며, 좁은 typed lifecycle 명령만 operator가 보유.)
- 장기·일반 대화 메모리, cross-generation recall, active checkpoint window 밖 assistant reply recall, memory bank 부활.
- cost/token/turn/latency를 runtime gate로 사용 (측정·용량계획 전용). provider의 실제 context/output ceiling만 protocol-correctness 제약으로 보존.
- Qdrant 재도입 (Supabase pgvector only).
- Runtime storage selector (filesystem `.masc/` 단일 lane; Redis/PostgreSQL mode 은퇴).
- MASC를 AutoGPT/goal-decomposition loop로 보는 프레이밍, 또는 operator-governed phase-policy machine으로 보는 프레이밍. (둘 다 아니다: MASC는 keeper별 자율 lane substrate이며, 콘텐츠 판단=configured model / lifecycle 권한=operator로 분리된다. hierarchical phase-policy 승인은 RFC-0318/0319에서 폐기.)
- MASC가 Provider SDK를 대체한다는 프레이밍 (MASC는 SDK 호출을 provider attempt로 emit하는 router).

**OAS Non-Goals:**

- MASC/keeper/board/persona/hitl 도메인 개념을 public contract에 encode.
- `Agent.run`에 turn·idle-turn·tool-round·cost·token-budget stop gate 도입 (전부 telemetry-only; 호출자가 whole-run Eio cancellation/deadline 소유).
- approval orchestration 소유 / tool 실행 없이 성공 tool result 조작.
- ambient env catalog discovery (`OAS_MODEL_CATALOG`/`OAS_PROVIDER_CATALOG`/`OAS_CAPABILITY_MANIFEST` 제거; 명시적 override만).
- host/URL을 provider selector로 사용 (capability = serving-runtime × model, NOT host).
- telemetry-only 필드 추가 (모든 필드는 이름 붙은 소비자를 가진다).

**48h spec 명시적 Out-of-Scope (별도 follow-up):** TUI/CODE-IDE/Slack-Telegram sidecar; OAS `task_of_model_id` heuristic 제거 & Handoff 재설계; Memory OS env-config dedup; 신규 provider/model 추가.

**Anti-hype baseline:** "20-50 tasks는 Anthropic agent eval의 권장 시작점이지 MASC hard gate가 아니다"; "Fusion은 실험 arm이지 우월하다고 가정하지 않는다"(MultiAgentBench).

---

<a name="2-the-boundary-law"></a>
## 2. The Boundary Law

### 2.1 원칙

```
consumer ──▶ MASC (workspace collaboration / orchestration) ──depends on──▶ OAS (agent runtime)
                                                            OAS ──does NOT know──▶ MASC
```

**MASC knows OAS; OAS never knows MASC.** OAS의 변경은 모든 소비자에게 유익해야 하며, Workspace/Task/Goal/Board/Keeper/Gate 의미를 OAS public contract에 넣지 않는다.

### 2.2 감사로 확정된 사실 (w1x2k66z2, 다중 HEAD 재확인)

- OAS `lib/`에서 coordinator 어휘 `masc|keeper|persona|hitl|fusion` = **0건**. (`board`는 `event_bus.mli` doc 주석의 `dashboards` substring 1건 외 실 어휘 0 — 경계 자체는 유지.)
- MASC는 `Agent_sdk.*` / `Llm_provider.*`만 참조.
- 단방향(MASC→OAS) 유지. **0.212 breaking release가 경계를 올바르게 날카롭게 함** — boundary law 자체는 stale이 아니다. stale인 것은 version pin, roadmap 번호, 그리고 아래 6개 silent regression뿐.

### 2.3 강제 메커니즘 (3-layer drift honesty + 구조)

| Layer | 메커니즘 | 실패 조건 |
|-------|----------|-----------|
| repo 분리 | OAS는 별도 repo; MASC는 pin된 OAS를 소비 | — |
| **Layer 0** | SDK-independence gate — OAS 자체 스크립트에 vocab scan 위임 | OAS lib에 coordinator 어휘 등장 |
| **Layer 1** | fingerprint gate (`oas-drift-check.sh` vs `oas-api-surface.json`) | OAS API surface drift |
| **Layer 2** | MASC가 pinned OAS public `.mli`를 직접 소비하고 컴파일 실패로 drift를 받음. `lib/oas_compat/`는 crossover 종료 뒤 삭제 대상 | OAS API를 local compatibility type/parser로 재구현 |
| provider/model identity | exact catalog id는 operator-only receipt/diagnostic에서 관측 가능. MASC policy는 id 문자열에 branch하지 않고 metric label은 bounded projection만 사용; legacy `allowed_providers`/`models`는 TOML/meta parse 경계에서 reject | policy와 observability를 혼동하거나 unbounded identity를 public metric label로 노출 |

**Regenerate-before-fix와 compatibility shim은 안티패턴이다.** drift가 감지되면 current OAS public API를 직접 소비하도록 MASC caller를 고치고 옛 adapter를 삭제한다.

**진단 표면:** `keeper_runtime_attempt.ml enrich_sdk_error`가 OpenAI-compat 404에 model_id/base_url/request_path/endpoint를 포함하는 것은 operator-only 진단이다. metric label이나 외부/public telemetry로 투영하지 않는다.

### 2.4 Boundary Rule 4 (핵심)

> **"runtime path가 동작해도 핵심 semantics가 여전히 drop되면 migrated라고 주장하지 않는다."** — N-of-M / silent-drop 실패 클래스를 직접 지목.

### 2.5 0.212 crossover findings — survival ruling

이 6건은 migration을 보존하라는 명령이 아니다. 현재 제품 불변식에 비춰 다시 판정한 감사 기록이다. implicit default·watchdog heuristic·옛 row migration을 복원하지 않는다.

| # | 원 감사 증상 | 생존 판정 | 정정된 acceptance |
|---|---|---|---|
| **#24417** | compaction provider의 `temperature=0` fallback 삭제 | **KILL fallback** | sampling은 catalog/provider default 또는 명시 config만. MASC가 숨은 `0`을 재도입하지 않으며, 결정론이 필수인 별도 작업은 explicit config 부재를 typed error로 처리. |
| **#24386** | 기본 stream-idle/숫자 cap 삭제 | **KILL implicit limit** | whole-run lifetime은 caller-owned Eio scope. 명시 timeout만 적용하고, timeout 부재는 unbounded. watchdog가 LLM으로 lane을 임의 re-task하지 않음. |
| **#24448** | producer 0인 `TurnLimit/ExecTimeout/ExecIdle` 관측 variant | **KEEP deletion** | 실제 typed producer가 없는 variant와 consumer를 삭제. 삭제한 cap을 관측 명목으로 재도입하지 않음. cooperative yield/cancel/completion만 실제 OAS outcome에서 전달. |
| **#24510** | 0.212 content-block crossover의 behavioral 검증 공백 | **KEEP typed contract** | compilation 이전과 behavior를 분리. `ToolResult.content_blocks` round-trip과 typed receipt를 focused test로 검증하고 duplicate adapter를 두지 않음. |
| **#24442** | file-write-only turn visibility 축소 | **KEEP visibility** | file write의 commit/failure가 typed receipt에 남음. evidence가 없으면 성공으로 합성하지 않음. |
| **#24447** | 중요한 event가 `Drop_oldest`, publisher는 loss를 처리 불가 | **KEEP durability, reject telemetry-only fix** | typed drop signal만으로 완료 아님. durable preservation + retry/ack 또는 enqueue 실패 반환을 갖추고 saturation에서 source event loss 0을 증명. |

상세 근거는 §4.13에 보존한다. §4.13은 별도 first-class goal 묶음이 아니라 이 표의 설명 appendix다.

<a name="26-oas-version-pin"></a>
### 2.6 OAS Version Pin & Pending 0.213 Contract

MASC가 소비하는 OAS(agent_sdk) 버전을 **정확한 값**과 **핀 위치**로 고정한다. "0.212 breaking release"라는 서술은 pin 값이 아니다 — 아래가 pin 값이다 (전부 grep 확인).

| 위치 | 내용 | 의미 |
|------|------|------|
| `dune-project:62` | `(agent_sdk (>= 0.212.0))` | 빌드 제약(하한) |
| `masc.opam:33` | `"agent_sdk" {>= "0.212.0"}` | opam 제약(하한) |
| `masc.opam.locked:14` | `"agent_sdk" {= "0.212.0"}` | **정확 pin (= 0.212.0)** |
| `masc.opam.locked:220-221` | `agent_sdk.0.212.0` @ `git+https://github.com/jeong-sik/oas.git#b02bc16f57b18542abae17023e1a2b886cda7347` | 소스 SHA 고정 |
| `scripts/oas-agent-sdk-pin.sh` | pin SHA + rationale | **pin SSOT** (dune-project:60 주석이 이 스크립트를 정본으로 지목) |

- **현재 pinned = agent_sdk 0.212.0** (git SHA `b02bc16f`). 0.212.0이 최신 tagged release.
- **Pending 0.213 계약 (미tag, OAS `CHANGELOG.md` Unreleased):** agent-as-tool input 계약이 **정확히 하나의 required object 필드 `{"prompt": "..."}`**로 축소. `Agent_tool.config.input_parameters` 및 scalar-string invocation(`Tool.execute tool (\`String prompt)`) 제거. 근거: OAS `docs/migrations/0.213-agent-tool-input.md`, `CHANGELOG.md` Unreleased §Breaking. 0.213 pin bump 시 Goal 5(Keeper-as-a-Tool·Fusion tool 조립)와 §3.13이 이 단일-`prompt`-object 계약에 맞춰 재검증 대상 — MASC가 child agent에 넘기던 다중 필드는 `prompt`로 접거나 별도 typed tool로 분리해야 한다.
- 함께 Unreleased: 암묵적 60s/30s HTTP deadline 제거(명시 `timeout_s`만 적용, clock 없는 deadline은 typed `AcceptRejected`), hook `Skip`/`Override` 제거. 이 세 breaking은 §3.10 Runtime·§3.12 OAS internals·§3.4 effect permission 경계에 영향 — 0.213 bump는 별도 slice로 다룬다.

> [근거] `bash scripts/check-oas-pin.sh`와 `gh release list --repo jeong-sik/oas`; 2026-07-15 확인; 신뢰도 High. 이 절은 확인 시점 snapshot이며 이후 값은 pin script/release 상태가 정본이다.

---

<a name="3-subsystem-ssot"></a>
## 3. Subsystem cards (direction + audited snapshot)

각 카드의 책임·경계·불변식은 방향 계약이다. `현재 상태`와 수치는 작성 시점 inventory이며 구현 전 fresh grep/CI/live evidence로 재검증한다.

<a name="31-board"></a>
### 3.1 Board

- **책임:** 다중 Keeper가 공유하는 append-only 게시판 (post/comment/reaction/attachment). 약결합 satellite — non-blocking wake/enqueue로만 개입.
- **소유 타입:** `Board_types.post` (`meta_json:Yojson` carrier), `Board_attachment_meta` (Image|Video|Youtube|External_link, +Audio|File|Gallery 예정), reaction/mention.
- **경계 계약:** Board는 Task/effect-permission runtime을 import하지 않고 typed event만 소비한다. `Task_completion` 같은 domain decision을 string label로 재분류하지 않는다. rich rendering은 MASC-owned surface projection (`Board_render` — Discord embed/Slack block/plain-text fallback을 한 소스에서). OAS는 generic transport만.
- **불변식:** post body는 **비파괴적 append**. (방향 계약. 원 감사가 지목한 "50개 하드코딩 영어 키워드 substantive-vs-noise 판정 후 body `Hashtbl.replace` 파괴적 덮어쓰기"는 HEAD `lib/board/`에서 **미확인** — `Hashtbl.replace`는 comments/reactions/sub_boards store 갱신용이고 keyword classifier도 없음. 착수 전 `rg -n 'rollup|substantive' lib/`로 실 사이트를 재확정한다 → **STALE-verify**.)
- **결정론↔LLM:** substantive-vs-status 판정, proactive attention wake, 완료 주장 검증 = **LLM Judge 경계**. 표시 순서는 declared total order(`created_at`, stable id)만 쓰며 hot/confidence/karma score가 의미·품질 판정을 대신하지 않는다. attachment round-trip·id 검증(path traversal 거부)은 결정론.
- **현재 상태:** rich-text/multimedia meta는 저장되나 dashboard 미렌더; proactive attention candidate는 production-wired(`load_candidates` ← `resume_pending` `keeper_board_attention_candidate.ml:992` ← live loop `keeper_world_observation.ml:733`, producer `record_and_start` `keeper_keepalive_signal.ml:419` — `load_candidates`에 cross-module 직접 caller는 없으나 프로덕션 도달 가능, "dead scaffold" 아님); claim-evidence gate가 opt-in이라 free-text "task done" 완료주장이 검증 우회.
- **candidate work:** effect permission(Goal 9)·CI breadth(Goal 11)에 얹지 않는다. Board-owned 독립 slice로 substantive-vs-status LLM judge+비파괴 append, proactive candidate consumer 배선 또는 ledger+metric 삭제를 수행한다. `Board_render` 공유 fragment+nested comment-tree serializer+grapheme-aware limit도 별도 surface slice다.

<a name="32-goal"></a>
### 3.2 Legacy Goal — RETIRED / HARD DELETE

- **판정:** 장기 Goal FSM, stagnation counter, goal-loop scheduler/status는 살리지 않는다.
- **이유:** MASC는 AutoGPT식 goal-decomposition runtime이 아니다. 협업 실행 단위는 명시적 Task와 Keeper lane이다.
- **삭제 범위:** `lib/goal` runtime, workspace/keeper legacy goal field와 decode path, goal-loop dashboard/scripts/tests, migration/backfill/compatibility row.
- **acceptance:** production·fixture·dashboard에서 Legacy Goal dependency 0. 옛 persisted goal row를 읽기 위한 migration 없음.

<a name="33-task"></a>
### 3.3 Task

- **책임:** work graph의 task 단위 + verification FSM (Done-via-verification).
- **소유 타입:** task FSM (`AwaitingVerification` — verification sub-state가 `task_status`에 fold됨, RFC-0220 §3.1). (문서가 이전에 나열한 `MASC_VERIFICATION_DEFAULT_ON` flag·`check_timeouts`·`force_cancel_task_r`는 RFC-0220 §11 PR-3에서 **삭제** — HEAD 부재.)
- **경계 계약:** verification 제출은 non-empty summary 필수(`tool_task_args.ml:100,138` `transition_action_requires_summary`), evidence ref는 존재 시 blank만 reject(`:126`) — **evidence ref ≥1 강제는 방향 계약이며 현재 미배선**(direction: PR URL/file:///sha+branch/board post). verifier는 evidence를 읽고 line/file finding 게시, repo Read/Execute 접근 keeper에게만 라우팅.
- **불변식:** `AwaitingVerification` task의 장기 대기가 관측 가능해야 한다. **[LANDED, RFC-0220 §11 PR-3]** 옛 24h deadline rescue는 삭제됨 — `verification_protocol.ml:363-371`이 no-op `check_timeouts`, 그 위에 돌던 `verification_timeout` server fork, interval knob, caller-less `Workspace.force_cancel_task_r`를 모두 삭제. verification sub-state를 `task_status`에 fold(RFC-0220 §3.1)해 Todo+Pending drift를 unrepresentable로 만들고, 장기 대기 obligation은 poll-timer 아닌 **activity-event stream**에서 표면화. (문서의 옛 "check_timeouts spinning no-op / force_cancel caller 0"은 삭제 전 상태로 stale.)
- **결정론↔LLM:** deadline scan은 결정론, 완료/reject 판정은 LLM Judge (schema-valid receipt).
- **현재 상태:** `AwaitingVerification` FSM state는 존재하나, `MASC_VERIFICATION_DEFAULT_ON` flag는 **HEAD에 0건**(rg 확인) — 옛 "built but not ignited (default_on=false)" 서술은 stale. RFC-0220 §11이 poll-timer 경로를 삭제하고 obligation을 activity-event stream으로 옮김. verifier rework loop에 incentive 구조는 여전히 없음.
- **open goals:** Goal 11(verifier rework loop wake incentive; long-waiting obligation의 activity-event 표면화 회귀; G-2 deterministic probe green). **[REFRAME]** 옛 "default_on=true flip + check_timeouts past-deadline scan + force_cancel"은 해당 machinery가 삭제됐으므로 폐기 — 되살리지 않는다.

<a name="34-hitlgate"></a>
### 3.4 Effect Permission Boundary (generic governance 아님)

- **책임:** 정확한 외부 effect request의 permission 경계. 비차단 one-shot 판단. 범용 governance/risk hierarchy를 소유하지 않는다.
- **소유 타입:** request-local decision **SOURCE 3종**: Manual HITL, configured LLM Auto Judge, explicit operator-recorded Always Allowed. **실존 타입:** `continuation_channel` closed sum(`Keeper_continuation_channel.t` `keeper_invocation_types/keeper_continuation_channel.mli:17`, RFC-0320: `Dashboard{thread_id}|Discord{ch,user}|Slack{ch,user}|Unrouted{reason}`); tool capability = `Tool_capability.kind`(`tool_surface/tool_capability.mli:11` = `Read_only|Mcp_context_required|Idempotent`). **[DESIGN, 미구현 타입 — 이름 아닌 목표로만 인용]** sealed `EffectIntent`(args_hash + precondition + ContinuationRef)와 세분화된 effect capability floor(`Workspace_write|External_message|Money|Destructive|Credential|Unknown`)는 HEAD에 부재(grep 0). 착수 시 이 타입들을 신설한다.
- **경계 계약:** approval은 **정확한 effect만** 대기 (sealed args_hash). approval 요청은 durable commit + **Keeper lane 즉시 해제(lane-held time = 0)**. edited args는 approval 무효화(새 EffectIntent). `submit_and_await` production path 없음. Unrouted는 fail-closed. Tool manifest의 Missing/Unknown effect → 정확한 effect pending 유지. LLM Judge는 context/scope/intent 해석 가능하나 structural floor를 **낮출 수 없다**.
- **불변식:** 한 Keeper의 decision state가 다른 lane을 pause 못 함. Auto Judge failure는 explicit request-local unsettled state — silent approve/reject/global-stop 금지. 모든 decision이 source/request-id/model·operator-id/result/explanation 기록. **비-재도입 규칙:** default-deny boolean, unknown-risk bucket, global pause, pre-tool string classifier로 계층 승인 재생성 금지.
- **결정론↔LLM:** "무엇을 말할지" = LLM; "어디로 답할지" = deterministic typed channel-match. objective enforcement(typed-input/path-jail/sandbox-confinement)는 소유 execution 경계 — Gate decision 아님.
- **현재 상태 snapshot:** read model과 ApprovalsSurface route는 존재하나 wake/enqueue-on-resolution outcome은 재검증 필요. **[LANDED]** synchronous `submit_and_await`(현재 `submit_pending` `keeper_approval_queue.mli:167`)와 `governance_*` compatibility surface는 **이미 삭제됨**(HEAD grep 0, `governance_pipeline.ml` 부재) — 삭제 대상 아님. RFC-0305/0311/0318/0319/0337의 hierarchy는 부활시키지 않는다.
- **open goals:** Goal 9(decision resolved→wake/enqueue end-to-end 증명, 비차단, audit trail; Auto Judge failure path 적대 검증).

<a name="35-scheduler"></a>
### 3.5 Scheduler

- **책임:** cron이 아니라 **per-Keeper-lane waiting plane**. Fusion/HITL/background/connector completion/schedule-due가 모두 typed wake source.
- **소유 타입:** typed keeper wake bus (G6 Async ping completion plane). Wake variant(`keeper_event_queue.mli` stimulus): `Fusion_completed`·`Hitl_resolved`·`Bg_completed`·`Connector_attention`·`Schedule_due`(문서의 `Schedule_signal`은 오기 — 실제는 `Schedule_due of scheduled_wake`; `Schedule_signal`은 `Schedule_signal_decode_error`로만 존재). `Keeper_waiting_inventory` (per-lane read model). typed schedule payload registry (SSOT kind = `masc.board_post`). typed Corrupt ledger.
- **경계 계약:** schedule payload/tool 선택은 typed registry가 accept 전 validate (G3). 미지원 side-effecting payload는 생성 시 실패+visible product-gap(`masc_schedule_payload_unsupported_total`), 숨은 terminal data 금지. `keeper_wake`는 `Reminder_only`로 clamp(#23716이 self-wake approval deadlock 종료). at-most-once signal. per-tick crash isolation. tool-surface policy(G4): create/list/get/cancel=public+keeper-standard; approve/reject=operator-only; spawned-agent·local-worker=lane ownership contract 전까지 **EMPTY by policy**. cooperative yield(#20849): reservation은 lane을 globally block 안 함; owner-priority yield(`Yielded_to_chat_waiting`).
- **불변식:** OTel label은 bounded(kind/status/risk_class/keeper). unbounded id(schedule_id/execution_id/trace_id/payload_digest)는 span attribute/structured log — metric label 금지. occurrence identity + 저장 실패 재시도는 **동일 signal_id**. corrupt/unwritable seen-key ledger는 tick을 loud fail(silent re-fire 금지).
- **결정론↔LLM:** scheduler decision에 heuristic 없음. cron 5-field + daily fixed-offset은 결정론 구현.
- **현재 상태:** primary intent(time/condition→keeper wake) 경로는 코드상 배선됨(wired) — 단 **wired ≠ proven**: single-shot terminal(failed/expired) evidence만 있고 recurring operational proof는 없다(G2 live proof 48%: scheduled=0/succeeded=0/failed=2/expired=2). keeper_recurring task는 in-memory Hashtbl만 → 재시작 시 silent 소멸(RFC-0314 §3 open); `masc_recurring_add`가 typed closed action 대신 `Broadcast(label)` 하드코딩(`keeper_recurring.ml:9` `type action = Broadcast of string` 단일 variant); `keeper_wake` dispatch가 target keeper 존재를 hard-reject 안 함 — name **format**만 검증하고 unregistered는 `Deferred_unregistered`(logged) 후 `Ok(keeper_wake_enqueued)` 반환(`server_schedule_consumers.ml:300-380`), 즉 typo가 실패로 안 잡힘. (문서의 옛 "auto-disable+2×interval cooldown 증상억제"는 HEAD `keeper_recurring.ml`에 **부재** — `dispatch_due`는 error 시 `failure_count`만 증가, disable/cooldown 없음.) 배포 diverged runtime(source ≠ server HEAD)이 live proof 차단.
- **open goals:** Goal 6(legacy recurring 삭제, durable wake만; recurring을 `.masc/keeper/<name>/recurring.json` persist+reload; typed closed action variant; dispatch가 "keeper not registered"를 `Dispatch_failed`로; re-enable을 health signal에 gate), Goal 7(occurrence identity + 동일 signal_id 재시도). standing grant와 digest-equality 승인 우회는 삭제한다.

<a name="36-connector"></a>
### 3.6 Connector

- **책임:** 외부 채널(Discord/Slack) intake + reply. 약결합 satellite.
- **소유 타입:** `KNOWN_CONNECTOR_IDS` (정확히 4 id, known_ids-size 불변식 테스트). typed `Surface.t` sum. speaker identity `authority=Owner|External` (구조적 파생). `continuation_channel` (RFC-0320, request-local effect permission boundary와 공유). connector-facing turn_id = serialized `Ids.Turn_ref` (`<trace_id>#<absolute_turn>`, RFC-0233 §7).
- **경계 계약:** config 해석 순서 env > runtime TOML > field default; dashboard는 persistent TOML(`${MASC_BASE_PATH}/.gate/runtime/<name>/config.toml`) write, `.env` 아님. (0600은 **방향 목표**이며 현재 미충족 — writer `atomic_write_file`이 `open_out` default perms(~0644)로 쓰고 chmod 0600 안 함 `server_routes_http_routes_sidecar.ml:330-345`, credential-adjacent라 하드닝 필요.) Discord는 in-process(RFC-0203), sidecar 아님(#19393 삭제). rich rendering: turn lifecycle을 하나의 connector-facing event stream으로 정규화, rich block + fallback text 병행, per-connector capability manifest, visible degrade. push/pull: world prompt엔 작은 deterministic presence fact만, 대화 content는 `keeper_surface_read`(read, always-allowed)/`keeper_surface_post`(act, exact effect permission)로 on-demand pull. unknown/invalid origin은 typed `Unrouted{reason}`로 보존하고 reply/effect는 fail-closed한다. string `Gate{channel}` 합성 금지.
- **불변식:** UI = inline-action-over-menu, additive-never-destructive, DOM ID + scrollIntoView 배선(단방향 컴포넌트 그래프), single-SSOT-for-derived-state. 명시적 non-goal: Save 후 auto-restart 없음, hot-reload 없음, client-side token validation 없음, localStorage editor state 없음. channel stranger를 operator instruction으로 가중 금지.
- **결정론↔LLM:** channel-match(어디로) = deterministic; reply content(무엇을) = LLM. busy-defer 응답 = LLM judged.
- **현재 상태:** **[LANDED, RFC-0317 PR-3]** Slack inbound gateway 배선됨 — `Slack_socket_client.run`이 `server_slack_in_process_gateway.ml:492`(`start` :424)에서 호출되고 프로덕션 bootstrap `server_runtime_bootstrap.ml:1194`("RFC-0317 PR-3: in-process Slack Socket Mode gateway")가 기동(dead scaffold 아님, 헤더에 Python sidecar 주장 없음). busy-defer 전무(busy keeper가 inbound silent drop); connector-attention ambient wake는 Discord-only(named flag `MASC_CONNECTOR_AMBIENT_WAKE_ENABLED`는 **HEAD 부재** — Discord ambient arm은 `keeper_chat_store.mli` 참조, on/off 제어는 재확정 필요). speaker identity가 persistence 전 소멸.
- **open goals:** Goal 8(exact origin/channel/actor intake + lane-isolated requeue, Discord+Slack; ~~`Slack_socket_client.run` 배선~~ **[LANDED]** → Slack ambient user-line wake(RFC-0317 follow-up)만 잔여; busy-defer LLM judge turn; RFC-0223 speaker-persistence+presence round-trip; backend sidecar lifecycle+config-write(0600 하드닝)+JSON-schema endpoint).

<a name="37-fusion"></a>
### 3.7 Fusion

- **책임:** 다중 모델 심의(panel + judge). Async by design — keeper turn 비차단.
- **소유 타입:** named topology arm (`simple/refine/conditional/judge_of_judges/staged_judge_of_judges`, exhaustive dispatch, catch-all 금지). `panel_group list` (RFC-0277, 각 group이 system_prompt/web_tools/max_tool_calls/timeout_s 소유). `judge_pools` (RFC-0298, capability-filter 또는 explicit list). `Fusion_completed` wake variant (run_id/ok/resolved_answer/board_post_id). typed comment-preserving settings editor (RFC-0306).
- **경계 계약:** root switch fork + immediate delivery contract. escalation은 LLM typed decision(`Insufficient`) 읽기(heuristic 아님). gate fail-closed(disabled/unknown-preset/nested → Deny). model-ID 하드코딩 금지(`Config_dir_resolver` SSOT). registry append-only JSONL + orphan Running drop. JoJ: 기존 single judge가 meta-judge 재사용, `judges:judge_spec list`(default []), N first-round judge는 model/lens로 **차이** 필수(build_agent에 temperature 없음 → "same judge N samples" API-불가). `<2 judges` → runtime Error(simple-fallback 아님). heterogeneous: legacy flat `panel=[...]`가 length-1 group으로 desugar(byte-identical). strict reject: `Empty_panels`/`Conflicting_panel_grammar`/`Duplicate_panel_model`. `per_hour_budget`/`Fusion_budget` **완전 삭제**(#22051, cap ≠ backpressure). `ok=false`는 explicit failure path. Board post는 completion-only.
- **불변식:** comment preservation은 hard constraint(Otoml이 comment 폐기 → line-surgical text edit, 매 write마다 `Fusion_config.of_toml` + `Validated_preset.of_preset` 재파싱 검증). JoJ ≥2 invariant를 runtime→`of_preset`로 lift.
- **결정론↔LLM:** panel/judge 배치는 keeper runtime 판단; topology dispatch/validation은 결정론 exhaustive.
- **현재 상태:** topology dispatch/validation·heterogeneous panel desugar는 구현되어 exhaustive match로 컴파일 강제됨(가장 많은 arm이 배선된 satellite). 단 실행 관점 성숙도는 아직 낮다: **[LANDED]** staged JoJ 만족 preset은 이제 존재 — `council`(`config/runtime.toml:1149`, judge 6개 = staged_judge_group_size 3 × 2 group)이 옛 "0 preset dead option"을 해소(runtime.toml:1132-1135 주석이 명시). `Fusion_completed` wake는 배선됨(`fusion_sink.ml:315` `Fusion_completed` + `:320` `enqueue_durable_result`, RFC-0266)이나 continuation_channel은 아직 없음; dashboard HTTP fusion path가 topology `'simple'` 리터럴 하드코딩(`fusion_tool.ml`이 금지한 바로 그 안티패턴). **live proof는 failure-only(panels_unavailable)** — 성공 quorum row는 아직 관측되지 않음.
- **open goals:** Goal 5(Model/Agent/Keeper/Tool[]/Heterogeneous[] typed receipt 조립; ~~≥6-judge staged preset 추가~~ **[LANDED: council]**; fusion_request→completion→wake에 continuation_channel; `'simple'` 리터럴(`server_dashboard_http_keeper_api_post.ml:107`)→`Fusion_types.fusion_topology_to_string Simple`), RFC-0266 async wake **[Phase 1 wake LANDED]** + registry/status/dashboard(Phase 2-4 잔여), RFC-0306 typed editor.

<a name="38-keeper-lane-per-keeper"></a>
### 3.8 Keeper (Lane-Per-Keeper)

- **책임:** 런타임의 척추. 각 Keeper는 하나의 ordered lane에서 진행. logical continuity(immortal fiber 아님).
- **소유 타입:** typed `KeeperPresence` ADT = `Active|Awaiting|Recovering|ExplicitStopped(서명된 operator 명령)`. keeper turn FSM(`keeper_turn_fsm.mli`): `Idle→Phase_gating→Runtime_routing→Awaiting_provider→Streaming⇄Awaiting_tool_result→Completing→Done`, `Failed`(실제 `failure_reason` `turn_fsm/turn_fsm.mli:26`: `Failure_runtime_unavailable|Failure_no_capable_provider|Failure_provider_error|Failure_receipt_lost|Failure_runtime_error|Failure_unexpected_exception` — 문서의 `turn_livelock_blocked`/`completion_contract_violation`은 FSM variant 부재), `Cancelled`(supervisor_stop/provider_timeout/fleet_shutdown). 4-way file model: persona `profile.json`(identity, human-edited) / `keeper.toml`(deployment declaration, thin: persona_name + exceptional override) / `keeper.json`(system-owned durable snapshot) / `keeper/<name>/`(append-only artifact).
- **경계 계약:** OAS는 generic message/provider-turn/checkpoint primitive와 단일 run/tool loop를 소유한다. MASC는 active-context 선택·명시적 compaction·lifecycle FSM·lane position·task·board·effect permission·connector·scheduler·Fusion state·long-term recall을 소유한다. **Model-authored prose는 절대 state transport가 아니다** — parser/stripper/sidecar/dashboard-field/compat-reader가 assistant text를 runtime state로 승격 금지. 대화 history/summary는 input context only(task claim/effect resolve/connector ack/schedule 불가; 소유 typed API 필요). required typed transition 실패 시 typed error 표면화+event 보존(성공처럼 보이는 assistant message로 변환 금지, silent drop 금지). runtime/model 선택은 keeper.toml 필드가 **아님**(runtime.toml `[runtime.assignments]`; per-keeper model/models/allowed_models/active_model/allowed_providers/runtime_id 전부 load 시 hard-reject). per-keeper tool 계층(tool_access/tool_denylist/shard) 제거 — immutable flat catalog + execution-time exact EffectIntent permission만. keeper hot path는 provider fallback을 OAS internal runtime에 위임 안 함 — 이 사실은 receipt field `oas_dispatch_mode : string option`(`keeper_execution_receipt_types.mli:59`, `keeper_agent_run_receipt.ml:138`에서 `Some "single_provider_agent_run"`)로 **기록**된다. (문서가 이전에 명시한 typed variant `Single_provider_agent_run`과 enforce 모듈 `Keeper_runtime_engine.guard_keeper_hot_path`·pin 테스트는 **HEAD 부재**(docs에만 잔존) — "강제(enforce)"로 인용 금지. 컴파일-강제 enforcement는 미구현 목표.)
- **불변식:** 한 lane 실패가 fleet를 pause 못 함(failed event 보존+error 표면화+무관 lane 계속). async work 완료는 **소유 lane만** wake. busy keeper는 현재 작업 유지, 새 event는 queued 또는 own domain path로 explicit ack. removed/unknown 필드는 hard-reject(fail loud). Pause는 실제 breakage에만.
- **결정론↔LLM:** turn admission은 source domain이 emit한 closed typed actionable signal만 소비한다. 자유문 prose를 다시 분류하지 않으며 `String_util.contains_substring_ci`와 `Keeper_contract_classifier` semantic classifier는 삭제한다. parallel old/new 판정이나 dual-emit 없음.
- **현재 상태:** turn FSM ADT 존재하나 `Awaiting_provider→Streaming`·`Streaming⇄Awaiting_tool_result` emit_transition 미배선; `safe_emit_turn_end` catch-all이 `Cancelled_*`를 FSM에서 삼킴(#24448 orphan과 연결); Pause 원칙 3중 위반(restart budget→Dead, auto-compact retry→Paused, overflow-pause shadow); state 어휘 중첩(#40-42, `Stopped`=`Operator_pause` #24034-37).
- **open goals:** Goal 4(Lane Per Keeper drain + partial/question/final wake 비차단 완성; typed KeeperPresence exhaustive match, 중첩 label 0; FSM streaming/tool-result emit 배선; `Switch.on_release`로 Cancelled_* FSM 도달, TLA+ `StopSignalRespected`(`specs/keeper-turn-fsm/KeeperTurnFSM.tla`); backpressure/yield replacement RFC가 3 count-budget→Paused/Dead path purge 선행 #24059).

<a name="39-memory"></a>
### 3.9 Memory

- **책임:** store/retain/forget 3축. raw episode vs derived claim은 **DISTINCT type**.
- **소유 타입:** closed-sum category/relation/lifecycle (no `_` catch-all). `Ephemeral` category arm(구조적 non-promotable). typed slot `(entity, attribute)` (supersession key). claim_kind. protected never-decay class(Constraint/Lesson).
- **경계 계약:** **"Determinism = structure + cheap candidate generation. Judgment = the actual decision."**(RFC-0247 §-1). Scoring/graph/count은 decision authority가 아니며, typed evidence reference를 구성하는 데만 쓸 수 있다. count-promotion/TTL-decay/spreading-activation-as-ranker는 decision mechanism으로 reject. consolidation trigger는 explicit operator request, typed Task completion, user correction, typed provider overflow뿐이며 임의 N turn/token estimate가 아니다. Supabase pgvector only(Qdrant 재도입 금지, no embeddings — deterministic graph hop). PII 삭제는 blob/vector/OTel/cache/backup + crypto-shredding에 propagation receipt. forget은 typed supersession evidence+명시적 librarian verdict 기반이며 score/cutoff/clock으로 결정하지 않는다. blind TTL 금지. Judge/reflection은 self-observation에 contraindicated(external oracle 없음, retrieval이 읽는 것을 강화). asymmetric fail-safe toward retain. absent/invalid claim_kind → `self_observation_ttl` + eligible None→false로 clamp(permissive durable default 금지).
- **불변식:** ingest silent-zero 불가(typed Result). contradiction은 store 덮어쓰기 아닌 Board 표면화(TLA+ `ContradictionNeverSilentlyOverwrites`).
- **결정론↔LLM:** structure/candidate = 결정론; forget/promote 결정 = LLM librarian 경계.
- **현재 상태:** FORGET/decay machinery는 **존재하나 자동 사이클이 gated/dry-run** — `keeper_memory_os_gc.ml`(valid_until 만료 삭제, CLI `bin/main_eio.ml:1155`는 **dry-run** report), `keeper_memory_os_consolidation.mli:4`("which claims to merge and which to forget"), `keeper_memory_os_policy.ml:3`(LLM librarian forget), `prune_older_than`(recall/audit ledger). 단 consolidation은 default off(`env_config_keeper.ml consolidation_enabled_default=false`, #21244)라 3축이 실질 비활성 → 사실상 축적. (옛 "FORGET 축 전무"는 stale.) dead scaffold는 `chronicle_librarian.ml`(production caller 0)뿐 — `auto_recall.ml`·`procedural_memory` 모듈은 **HEAD 부재**(더 강한 형태). `stale_factor`는 dead field가 아니라 **삭제된 field**(`keeper_memory_os_types.mli:117` RFC-0247 purge 목록; 살아있는 `stale_factor`는 `dashboard_cache.ml:161`의 무관한 cache TTL 계수).
- **candidate work:** compaction/failover Goal 3에 얹지 않는다. Memory-owned 독립 slice에서 Librarian LLM-boundary explicit forget pipe(+consolidation gate on), claim_kind clamp, `chronicle_librarian` dead scaffold 삭제 또는 RFC-respec을 수행한다. sleep cycle 재활성(P0a typed category + Ephemeral non-promotable arm), Harness-First memory-quality eval(P-1, LLM-as-judge + hand-labeled calibration), action-stream self-reconciler도 같은 boundary에서만 승격한다.

<a name="310-runtime-providermodel-catalog"></a>
### 3.10 Runtime (Provider/Model catalog)

- **책임:** logical use → provider/model 라우팅 + fallback. MASC는 lane만 노출, OAS가 provider identity 소유.
- **소유 타입:** runtime.toml `[runtime.assignments]`(keeper-name keyed) + `[runtime].default`; `[runtime.lanes.<id>]`(candidates + strategy). `Runtime_attempt_fsm.decide` SSOT. OAS: immutable `agent_config`(`lib/base/types.mli`: provider/model/system/sampling/tools/schema/thinking/context/cache/seed serializable 필드), OAS `Contract`(`lib/contract.mli`)가 typed tool set 등을 first-class로 패키징. `Provider_config.provider_id`. `estimate_cost → Estimated|Incomplete`. embedded catalog.
- **경계 계약:** MASC policy code는 logical use/declared capability/profile order/health/capacity/receipt state로 라우팅 — vendor/model 리터럴에 branch 안 함. `max_tokens` synthesis 금지(oas 0.211.0 + #24098): override 없으면 omit, provider default 사용. capability = serving-runtime × model(WHAT), NOT host/URL(WHERE). unknown host/provider/model/label → Unknown/None/fail-closed. path→wire-protocol(Responses vs Chat)은 exact-string exhaustive match만. cache key는 FULL contract에서 재구성. 각 streaming retry attempt buffered, 정확히 하나의 committed attempt만 consumer에 visible. OAS pricing은 telemetry-only, execution gate 아님.
- **불변식:** provider failover는 ordered candidate lane. 첫 provider 500 → 두 번째 성공; 전부 소진 → typed "runtime lane exhausted" error; attempt당 manifest row 1개. unknown model pricing → typed Unknown/option(silent $0 금지).
- **결정론↔LLM:** 라우팅/failover는 전부 결정론(라우팅에 의미 판단 없음). whole-run lifetime은 caller-owned Eio scope이며 implicit watchdog·timeout·LLM re-task 예외를 만들지 않는다(§4.13 CF-2).
- **현재 상태:** provider failover machinery는 **존재+테스트됨**(문서의 "삭제/fallback 없음"은 오류) — `keeper_turn_driver.attempt_runtime_candidates`(`:122`, `run_named` `:504`에서 호출)가 `candidate::rest`를 순회하며 `Error` 시 다음 candidate 시도, 소진 시 `"runtime lane exhausted all candidates"`; 회귀 `test/test_keeper_turn_driver_failover.ml`(6 case). **단 SSOT 우회는 사실**: `Runtime_attempt_fsm.decide`는 0-caller이고 driver는 inline `should_try_next`를 씀. RFC-0153 saturation signal은 dead scaffold(producer 0); voice_bridge가 model/voice ID 하드코딩(`voice_bridge.ml:42/143/154/830` scribe_v2/Sarah/eleven_multilingual_v2, silent `Error _ ->` swallow); OAS `pricing_for_model`이 unknown model→$0(RFC-OAS-018 Phase 2 deferred).
- **open goals:** Goal 2(saturation emit 구현 또는 flag+variant+docs 삭제; driver의 inline try-next를 `Runtime_attempt_fsm.decide` SSOT 경유로 정합; voice choice를 catalog/config declaration+Result로 전환; unknown model pricing typed Unknown), Goal 3 **[REFRAME]**(failover는 이미 배선됨 → "복원"이 아니라 candidate loop를 `decide` SSOT로 통합 + `[runtime.lanes.<id>]` candidates/strategy='ordered' 선언 배선). Crossover는 §2.5 판정대로 CF-1/2를 폐기하고 CF-3 orphan을 삭제하며 CF-4 typed behavior만 검증한다.

<a name="311-dashboard-chat"></a>
### 3.11 Dashboard-Chat

- **책임:** operator↔keeper 직접 대화 surface. read model(canonical write path 아님).
- **소유 타입:** typed failure card, retry queue state, agent_timeline (tools_used/model/tool.called stream).
- **경계 계약:** dashboard surface는 read model. auth: `GET /dashboard/dev-token`은 loopback에서 unauthenticated Admin token mint 금지(RFC-0340 #69). judgement/wake decision/relevance/memory-value = explicit LLM/system 경계(UI math/heuristic 아님). No silent failure — unsupported/unavailable/auth-missing/stale/failed/unknown은 visible+typed.
- **불변식:** failed turn은 typed failure card + 명시적 retry transition으로 다루며 hidden auto-retry 금지. raw internal error는 typed attempt history와 함께 노출; request는 answer/cancel receipt 전까지 queued/degraded(terminal 아님). keeper-internal OAS tool 실행이 unified tool.called stream에 나타나야 함.
- **결정론↔LLM:** rendering/formatting은 결정론; substantive 판정은 LLM.
- **현재 상태 snapshot:** "Keeper request failed: <raw internal error>"가 answer slot 대체(24h 중 39/140 assistant row, 관측치). **[LANDED, #23540]** agent_timeline의 keeper in-turn tool 관측이 배선됨 — `keeper_run_tools_hooks.ml:270`이 `keeper.tool_exec` emit, `tool_agent_timeline.ml:294-295`가 `tool.called`+`keeper.tool_exec` 두 소스 소비(즉 keeper-internal tool이 stream에 도달, "external-MCP만/root-caused only"는 stale). 잔여는 field 없는 event용 `~default:"unknown"` 방어 fallback(`tool_agent_timeline.ml:391`). **[LANDED]** `deliverable_claims_completion`은 **단일 SSOT 정의**(`task_completion_claim.ml:9`; 소비 `tool_workspace.ml:225,310`, `verification_protocol.ml:42`) — "2모듈 byte-identical 중복/unmerged"는 오류(단 영어-only lowercase-prefix classifier라는 성격은 사실). telemetry_unified shadow-tool dedup이 magic 5.0s window. auth bypass(#69) 3-step curl 확인. 옛 dashboard subsystem percentage는 acceptance가 아니며 Legacy Goal 수치를 포함하므로 현재 방향 근거에서 제외한다.
- **open goals:** Goal 11(typed failure card + explicit retry transition; auth: `server_routes_http_dashboard_dev_token.ml` dev-token mint grep 0, unauth GET→404, unauth mutation 100%→401, dashboard.token role ≠ Admin; PR-KC1d server-side field verification), Goal 12(~~agent_timeline event-source 교체~~ **[LANDED #23540]** → 잔여 `~default:"unknown"` 제거; deliverable_claims를 string classifier→LLM 경계 전환(SSOT는 이미 단일); ~~keeper.tool_exec activity event~~ **[LANDED]**; correlation-id로 dedup exact화).

<a name="312-oas-internals"></a>
### 3.12 OAS Internals (pure library)

OAS repo 구현자를 위한 카드다. MASC consumer는 OAS 내부를 복제하거나 `oas_compat`를 영구 경계로 만들지 않고 public `.mli`만 소비한다.

- **책임:** provider 라우팅, 6-stage turn pipeline, checkpoint, tool-boundary cooperative yield, reasoning replay, wire observer, stop-reason 매핑, sub-agent 위임(handoff). downstream coordinator의 도메인 어휘를 모른다.
- **소유 타입:** provider 라우팅 = `Provider.provider`(4-variant sum `Local|Anthropic|OpenAICompat|Custom_registered`, `lib/provider.mli:6`) + record `Provider.config`(`{provider; model_id; api_key_env}` `:17`) + `Backend_*`(anthropic/openai/gemini/glm/ollama) + carrier `Provider_config.t`; 6-stage pipeline = `lib/pipeline/`(`pipeline.ml`/`pipeline_stage_prepare.ml`/`pipeline_stage_route.ml`); checkpoint = `Checkpoint.t`(v8 순수 값, serialize-only) + `Checkpoint_store`/`_codec`/`_delta`; tool-boundary yield = `Agent.Advanced.run_blocks`(`boundary_decision = Continue|Yield`, budget 미강제); reasoning replay = `Reasoning_replay_contract` + `Reasoning_history_projection`; wire observer = `Wire_observer`(@since 0.212, caller-owned redacted chunk); stop reason = `Types.stop_reason`(12-variant) + `Stop_reason_wire`(finish_reason 매핑 SSOT); handoff = `Handoff.make_handoff_tool`(서브에이전트 위임 도구); execution context = `lib/base/context.ml`; typed error = `lib/error_domain.mli`(`` `Internal of string ``). **삭제된 날조 용어(코드 실측 각 0건)**: "lossless ExecutionContract"→`Checkpoint.t`, "stream isolation"→caller-owned Eio switch(OAS는 isolation 객체 미소유), "stop semantics"→`Types.stop_reason`+`Stop_reason_wire`, "handoff fidelity"→`Handoff`(위임, fidelity 개념 없음).
- **경계 계약:** OAS lib에 MASC 어휘 0건(§2.2 grep 확정). pricing은 telemetry-only(execution gate 아님). `max_tokens` synthesis 금지(override 없으면 omit → provider default). capability = serving-runtime × model(WHAT), NOT host/URL(WHERE).
- **불변식:** 각 streaming retry attempt는 buffered, 정확히 하나의 committed attempt만 consumer에 visible. unknown host/provider/model → typed Unknown/None/fail-closed. **production `assert false`를 control flow로 쓰지 않는다** — unreachable proof arm에만 허용(OAS `.ci/hardening-baseline.json`이 assert false를 ratchet에서 제외하는 근거와 동일). control-flow용 실패는 `` `Internal `` 등 typed error로 반환.
- **결정론↔LLM:** **OAS는 순수 라이브러리 = 전부 결정론.** 유일한 LLM 호출은 provider adapter의 **opaque forward** — provider가 반환하는 바이트는 OAS에게 불투명하고, OAS는 그 내용에 판단을 하지 않는다(파싱/재직렬화만).
- **현재 상태:** Stdlib Mutex가 Eio fiber 경로에서 OS thread를 block(`lib/base/context.ml`·`lib/agent/agent_registry.ml`·`lib/llm_provider/provider_registry.ml`·`lib/llm_provider/metrics.ml`; extraction이 명명한 `content_replacement_state.ml`은 HEAD ls-files 미확인 → **NEEDS_LOCATION**). OAS lib 전체 `assert false` = 1건(`lib/error_domain.mli`), `lib/pipeline/` = 0건(extraction의 "pipeline stage assert-false" 사이트는 HEAD 미확인 → **NEEDS_LOCATION**; acceptance는 "control-flow assert false = 0 유지"). 0.213 Unreleased 계약(§2.6) 대기.
- **open goals:** DS-3(§4.14 OAS Eio-mutex + assert-false 하드닝), Goal 2(`pricing_for_model` unknown→typed Unknown, RFC-OAS-018 Phase 2).

<a name="313-keeper-as-a-tool"></a>
### 3.13 Keeper-as-a-Tool (cross-model invocation)

Goal 5의 별도 subsystem(현재 §3.7 Fusion 안에 암시만 됨). 한 keeper/모델을 다른 keeper의 typed 도구로 호출하는 경계.

- **책임:** typed target + capability로 keeper/model/agent/tool을 조립 호출. K2K messages·@mention·keeper_msg_requests는 live이나 first-class "call a keeper as a tool"은 부재.
- **소유 타입:** `CollaborationRequest`/`DurableRunRef`/`ResultContract`(미구축, Durable Intelligence C0-C4 unpromoted). `keeper.delegate/status`·`fusion.deliberate/status`가 run ref를 즉시 반환(nonblocking). Fusion 조립은 `lib/fusion/fusion_tool.ml`·`lib/fusion_core/fusion_run_registry.ml` 경유.
- **경계 계약:** typed target + declared capability로만 라우팅; **untyped agent-name 라우팅 판단 금지.** OAS 0.213 single-`prompt`-object 계약(§2.6) 준수 — delegate 입력은 typed tool 또는 `prompt` 단일 필드.
- **불변식:** delegate는 nonblocking(run ref 반환), 결과는 소유 lane wake로만 도달(다른 lane pause 금지). run registry는 append-only + orphan Running drop.
- **결정론↔LLM:** **typed target 선택 + capability routing = 결정론; delegated 모델의 출력 = LLM.** 어디로 위임할지는 판단이 아니라 typed 매칭이고, 위임받은 모델의 응답이 판단이다.
- **현재 상태:** first-class surface 미구축(Goal 5). K2K primitive만 live.
- **open goals:** Goal 5(typed receipt composition; §3.7 Fusion과 preset record 공유).

<a name="314-ide-observation-plane-v2"></a>
### 3.14 IDE Observation Plane v2

IDE/editor 관측을 흡수하는 **passive projection read model**. extraction cluster의 미착수 후속 corpus(§8.4).

- **책임:** IDE 관측(파일 편집/annotation/region)을 read model로 흡수해 dashboard/keeper world prompt에 projection. **keeper를 직접 wake하지 않는다.**
- **소유 타입:** `lib/ide/ide_bridge.ml`, `lib/ide/ide_ingest_queue.ml`(bounded ingestion, #23072 스택), `lib/ide/ide_event_types.ml`, `lib/ide/ide_region_tracker.ml`, `lib/ide/ide_annotations.ml`, `lib/ide/ide_annotation_types.ml`, `lib/ide/ide_paths.ml`.
- **경계 계약:** MASC → OAS 단방향(§2.2); OAS는 IDE 개념을 모른다. IDE ingestion은 main domain path를 블록하지 않는다(bounded queue).
- **불변식:** **passive projection read model — raw observation이 keeper를 직접 wake하면 경계 위반.** ingestion은 bounded.
- **결정론↔LLM:** ingestion/파티션/projection = 결정론; observation을 stimulus로 **승격**하는 판단(promote gate)은 LLM/system 경계이며 raw observation의 직접 wake는 금지.
- **현재 상태:** 기본 ingestion/bridge 배선(위 모듈 존재). **미착수 후속 축(§8.4, DS-1):** 성능 A4 SSE fan-out · A5 consumer-gate · A6 orphan 파티션 repo 귀속(#23072 위 스택); 교차 C2 latched_reason(#23058) · C4·C6 promote Done_action 게이트 + Verification_requested stimulus. 이 축의 심볼(`latched_reason`, `consumer_gate`, SSE fan-out 등)은 `lib/ide/` HEAD에 아직 없음(unbuilt → **NEEDS_LOCATION**, 구현 대상).
- **open goals:** DS-1(§4.14 IDE Observation Plane v2 후속 축).

---

<a name="4-execution-roadmap"></a>
## 4. Candidate Execution Roadmap (12 goals)

각 goal은 문서 안의 구현 후보 label일 뿐 제품의 Legacy Goal 타입·상태·runtime이 아니다. GitHub live queue의 상태를 복제하지 않는다. 구현 전 현재 코드에서 여전히 필요한지 재검증하고, 이미 착지했거나 방향이 폐기된 항목은 재구현하지 않고 DROP한다. 각 goal: **문제 / 결정론 vs LLM 경계 / touch할 modules·types / acceptance test / DoD.**

### Goal 1 — OAS 0.212 bootstrap [MERGED SURFACE, ACCEPTANCE UNVERIFIED]

- **문제:** typed cooperative yield + server runtime hard-cut을 400 churn 미만으로 병합.
- **경계:** yield는 성공 host outcome(SDK error 아님, budget 미소비, lifecycle Ready). callback은 agent fiber에서 synchronous(host state inspect only, no blocking).
- **touch:** OAS `Agent.Advanced.run_blocks/run_blocks_detailed`(`on_tool_boundary → Continue|Yield`, `run_outcome = Completed|Yielded{turn;checkpoint_stage;checkpoint}`); `Agent.run` stop gate 제거(#2590).
- **acceptance:** yield가 provider lease 해제 후 반환; Continue가 `on_resume` invoke; checkpoint는 Yield에서만 capture.
- **DoD/잔여 검증:** "done"은 **stacked-green 아닌 real-build integration proof 필요**. merged surface와 acceptance를 분리하며, §2.5 finding은 생존 판정에 따라 삭제 또는 focused behavior로 검증한다.

### Goal 2 — 삭제 잔재 숙청 (heuristic estimator / Context_reducer / limit·budget)

- **문제:** 삭제된 OAS 계약·heuristic estimator·Context_reducer 및 limit·budget 잔재를 stacked PR로 제거.
- **경계:** **string 분류기 제거지 추가 아님.** unknown→typed Unknown/None (permissive default 금지). N-of-M은 codemod로 일괄(개별 site 패치 금지).
- **touch:** RFC-0153 saturation signal(flag+variant+docs 삭제 또는 emit 구현); `Runtime_attempt_fsm.decide`(4 keeper driver의 inline try-next 라우팅); voice_bridge(catalog/config-declared voice choice + Result); OAS `pricing_for_model`(unknown→typed Unknown/option, RFC-OAS-018 Phase 2); `deliverable_claims_completion` SSOT 병합; keeper_recurring cap/cooldown 제거; OAS `Context_intent` heuristic classifier는 public owner가 없으면 삭제한다. MASC에는 이를 port하지 않고 MASC-owned explicit compaction request/typed overflow policy만 둔다.
- **acceptance:** 구현 PR마다 exact identifier·검색 경로·expected count를 명시한다(placeholder `rg <값>` 금지). caller 0인 saturation flag는 삭제; unknown model pricing은 $0 아닌 typed Unknown/None 반환.
- **DoD:** limit/heuristic purge target 전부 grep-0 또는 typed로 대체; 이미 통합된 것은 DROP.

### Goal 3 — MASC LLM compaction → configured trigger + typed provider overflow

- **문제:** compaction을 configured trigger + typed provider overflow에 연결, durable reinjection·before/after·failover 증명. **단일-gate compaction이 unseen transcript tail 유실할 수 있음(#23908/#23977).**
- **경계:** compaction은 MASC-owned 별도 state transition이다. trigger는 operator/config의 명시 요청 또는 typed provider overflow이며 임의 N turn/token estimate가 아니다. 최근 N개 보존, tool argument/output 절단, thinking 삭제, synthetic/stub ToolResult, overflow 뒤 동일 실행 hidden retry를 금지한다. reinjection ≠ re-observation(불변식).
- **touch:** compaction request가 MASC-owned explicit sampling config와 typed provider overflow를 운반; `[runtime.lanes.<id>]` candidates + strategy='ordered'(failover는 이미 `keeper_turn_driver.run_named`의 `attempt_runtime_candidates` candidate-list로 배선됨 → "복원"이 아니라 `Runtime_attempt_fsm.decide` SSOT 경유로 정합 + lanes 선언 배선).
- **acceptance:** hidden `temperature=0` fallback 없음. 결정론 설정이 요구되면 explicit config 부재가 typed error; 첫 provider 500→두 번째 성공, 전부 소진→typed "runtime lane exhausted", attempt당 manifest row 1개; before/after transcript durable.
- **DoD:** compaction durability + failover가 stacked-green이 아닌 live로 증명.

### Goal 4 — Lane Per Keeper drain + partial/question/final wake (비차단)

- **문제:** drain + partial/question/final wake를 비차단으로 완성. Pause 원칙 3중 위반 해소.
- **경계:** typed `KeeperPresence` ADT exhaustive match(overlapping label 0). string-based state 판정 금지.
- **touch:** keeper turn FSM(`Awaiting_provider→Streaming`·`Streaming⇄Awaiting_tool_result` emit_transition 배선 in `keeper_agent_run.run_turn`); `safe_emit_turn_end` catch-all → `Switch.on_release`(Cancelled_* FSM 도달, RISKY); source-domain closed actionable signal을 lane queue까지 직접 전달하고 `String_util.contains_substring_ci`/`Keeper_contract_classifier` turn-accept semantic classifier 삭제; 3 count-budget→Paused/Dead path purge(#24059, backpressure/yield replacement RFC 선행).
- **acceptance:** FSM transition이 streaming/tool-result loop에서 emit(test 커버리지); `Cancelled_supervisor_stop/provider_timeout/fleet_shutdown`이 full turn_id receipt 생성; TLA+ `StopSignalRespected` invariant hold(`specs/keeper-turn-fsm/KeeperTurnFSM.tla`; clean cfg=no error, `KeeperTurnFSM-buggy.cfg` `SpecBuggy`=`StopSignalSwallowedAsDone` bug action이 invariant 위반); turn admission path의 prose classifier·parallel old/new path grep 0; source signal variant exhaustive match.
- **DoD:** 비차단 drain end-to-end; 한 lane 실패가 fleet pause 안 함.

### Goal 5 — Invocation composition (Model/Agent/Keeper/Tool[]/Heterogeneous[]) typed receipt

- **문제:** "Keeper as a Tool" first-class surface 부재; composition을 typed receipt로 완성(Durable Intelligence C0-C4 unpromoted).
- **경계:** typed target+capability(`CollaborationRequest`/`DurableRunRef`/`ResultContract`). untyped agent-name 라우팅 금지.
- **touch:** fusion panel+judge(RFC-0277 heterogeneous group, RFC-0283 JoJ+staged reducer, RFC-0298 judge pool runtime placement, `lib/fusion/fusion_tool.ml`·`lib/fusion_core/fusion_config.ml`·`fusion_run_registry.ml`); `keeper.delegate/status` + `fusion.deliberate/status`가 run ref 즉시 반환(nonblocking, §3.13 Keeper-as-a-Tool); 0.212 crossover(#24510: `lib/keeper/keeper_context_core_message_json.ml` ToolResult content_blocks 소비, 멀티모달 토큰 카운트 behavioral 테스트 — 실제 심볼은 `total_tokens`(`lib/inference_utils.ml`이 `Agent_sdk.Types.total_tokens` 위임)와 `dashboard_http_keeper_metrics`의 `input_tokens/output_tokens/total_tokens/context_tokens`; 문서의 `block_tokens`는 HEAD 부재); orphan stop-reason 삭제(§4.13 CF-3). **Cross-surface typed turn envelope(DESIGN-RICH §7 P0):** `Turn_requested/accepted/waiting/phase_changed/Tool_call_started/finished/Content_block/Turn_finished/Turn_failed/Poll_snapshot`을 runtime 경계에서 한 번만 emit — SSE/AG-UI adapter가 rich block을 drop하지 않도록. FSM 배선은 `lib/keeper/keeper_turn_fsm.ml`, emit은 `lib/keeper/keeper_agent_run.ml`(§3.8 Goal 4와 공유).
- **acceptance:** panel_group closed-record round-trip; single-group byte-identity derive pinned; JoJ <2 judges fail-closed; staged 9-judges/group-3 → 3×3, ragged fail-closed; usage가 all first-round + meta에 fold; ToolResult 멀티모달 undercount 0; **turn envelope의 각 variant가 runtime 경계에서 정확히 1회 emit(중복/유실 0)**; SSE/AG-UI adapter escaped-fallback downgrade(rich→plain) 카운트가 회귀 테스트에서 감소 assert(현재 값 **측정 필요**).
- **DoD:** typed receipt로 5종 composition(Model/Agent/Keeper/Tool[]/Heterogeneous[]) 완성; yield/cancel/failure와 정상 completion 구별 가능; turn envelope variant가 SSE와 dashboard 양쪽에서 동일 소스.

### Goal 6 — Scheduler legacy recurring 삭제, durable wake만

- **문제:** legacy recurring 계층 삭제, durable wake만 남김. effect permission은 Scheduler가 소유하지 않는다.
- **경계:** typed closed action variant(하드코딩 `Broadcast(label)` 아님). re-enable을 health signal에 gate(fixed cooldown 아님 — cap/cooldown 증상억제 제거).
- **touch:** recurring persist(`.masc/keeper/<name>/recurring.json` + init reload); `masc_recurring_add`(typed closed action); `keeper_wake` dispatch("keeper not registered" → `Dispatch_failed`); `has_current_approved_grant`와 digest-equality approval bypass 삭제.
- **acceptance:** 재시작 후 recurring reload; typo'd target이 Succeeded 아닌 Dispatch_failed; approval-required occurrence마다 fresh request-local EffectIntent와 decision record 생성. operator-recorded Always Allowed rule을 쓰면 exact capability/target/argument constraint+expiry+revocation을 typed로 저장하고, 각 occurrence가 rule match와 decision source를 새 audit row로 기록한다. digest equality만으로 승인하지 않는다. execution record가 dashboard에 projection; live-safe reservation smoke(create→due→dispatch→success→board post_id→dashboard/Otel proof, proof_check.sh --require-pass).
- **DoD:** recurring operational proof(현재 미증명); legacy row는 fake lifecycle event로 synthesize 안 함.

### Goal 7 — Schedule occurrence identity + 저장 실패 재시도 (동일 signal_id)

- **문제:** occurrence identity + 저장 실패 재시도를 동일 signal_id로 완성.
- **경계:** at-most-once. corrupt/unwritable seen-key ledger는 tick loud fail(silent re-fire 금지).
- **touch:** occurrence identity·signal_id 재사용은 `lib/schedule/schedule_runner.ml`(tick/dispatch)와 seen-key ledger `lib/schedule/schedule_store.ml`(+`.mli`)에 있다 — occurrence identity를 소유하는 모듈. seen-key 지속 실패가 runner tick을 explicit fail로 만든다(G6 부분 배선). policy는 `lib/server/server_schedule_runner_policy.ml`.
- **acceptance:** 실패 occurrence 재시도가 동일 signal_id 재사용(중복 wake 없음); corrupt/unwritable seen-key ledger가 silent re-fire 아닌 loud tick fail; 회귀 `test/test_schedule_runner.ml` + `test/test_schedule_store.ml` + `test/test_schedule_tool_wiring.ml`.
- **DoD:** 동일 signal_id 재시도 증명(중복 wake 0).

### Goal 8 — Multi-Connector exact origin/channel/actor intake + lane-isolated requeue

- **문제:** exact origin/channel/actor intake + lane-isolated requeue 완성 (Discord+Slack).
- **경계:** structured connector context(channel/workspace_id/user_id/name) end-to-end. unknown/invalid origin → typed `Unrouted{reason}` 후 reply/effect fail-closed; string `Gate{channel}` 합성 금지. busy-defer = LLM judged(silent drop 아님).
- **touch:** gate inbound(connector context carry + speaker identity persist, RFC-0223 P1/P2); `Slack_socket_client.run` 서버 bootstrap 배선(RFC-0317 PR-3) 또는 헤더 정정; busy-defer light response turn(LLM judge, RFC-0334 확장); backend sidecar lifecycle+config-write(0600 TOML)+JSON-schema endpoint; Slack ambient wake producer(현재 Discord-only).
- **acceptance:** persisted user line이 speaker id + real Discord name(snowflake 아님); bound keeper world prompt에 presence section; busy keeper가 busy-defer reply(silent drop 아님); Slack non-mention이 idle keeper wake(RFC-0320 ambient re-engagement, Slack producer).
- **DoD:** Discord+Slack 양쪽 lane-isolated requeue; RFC-0223 round-trip 테스트.

### Goal 9 — Exact EffectIntent permission 비차단 one-shot 판단 (적대 검증)

- **문제:** request-local exact external effect permission을 비차단 one-shot 판단으로 적대적 검증. 범용 governance·Board semantic 판단을 소유하지 않는다.
- **경계:** 3 decision SOURCE(Manual/Auto Judge/Always Allowed), risk level 아님. **암묵적 4번째 source(tool name/command string/provider brand/repo host/guessed irreversibility) 금지.** Auto Judge failure = explicit request-local unsettled(silent approve/reject/global-stop 금지). default-deny boolean/unknown-risk bucket/global pause/pre-tool string classifier 재도입 금지.
- **touch:** `keeper_gate.ml`/`keeper_tool_policy.ml`/`keeper_tool_dispatch_runtime.ml`에서 exact `EffectIntent` validation+decision만 남기고 generic risk/governance classifier와 Gate 0 compatibility surface 삭제; ApprovalsSurface(HITL resolution read model with wake/enqueue outcome column); operator-recorded Always Allowed rule은 exact scope/expiry/revocation typed record와 occurrence별 fresh audit decision으로 제한.
- **acceptance:** pending approval이 NO global pause + NO other-lane stall(outcome column이 wake vs enqueue); judge-unavailable 주입 테스트가 request unsettled + keeper other work 계속 + audit record; approve/deny/hold unit test.
- **DoD:** decision resolved→wake/enqueue end-to-end + explicit audit trail.

### Goal 10 — 1/100/1000 혼합 cardinality + lane/failure isolation 회귀

- **문제:** 혼합 cardinality + lane/failure isolation 회귀 추가 (현재 NO such regression).
- **경계:** deterministic pass in hermetic tier(live-absent surface green-wash 금지).
- **touch:** 회귀 harness dir = `test/`(OCaml, dune stanza 패턴 `test/stanzas/*.inc`). 기존 lane-isolation 테스트 `test/test_keeper_context_isolation.ml`(+`test/stanzas/test_keeper_context_isolation.inc`)를 확장해 mixed **1/100/1000** keeper cardinality를 행사; 인접 참조 테스트 `test/test_keeper_lane_mentions.ml`·`test/test_keeper_memory_lane.ml`·`test/test_boundary_redaction_runtime_lane.ml`. per-lane failure isolation proof(PR-L3), busy/deferral from runtime events(PR-L2)는 이 harness 안에서 새 테스트 파일로 추가.
- **acceptance:** 신규 회귀가 1/100/1000 혼합 cardinality 행사(테스트 파일 존재 + green); 한 lane의 failure/backpressure가 다른 lane stall 안 함; 한 blocked/failed keeper가 다른 lane 숨기거나 dashboard block 안 함; aggregate-only blocker 없음.
- **DoD:** deterministic hermetic 회귀 green(`test/` 하위 신규 파일, env-gate/manual 아님).

### Goal 11 — 전체 회귀 CI green

- **문제:** Board/Task/Scheduler/Connector/Memory/Runtime/Fusion/Keeper chat의 살아남은 경계 회귀 CI green.
- **경계:** hermetic-required 분리(env-gated/manual green-wash 금지). #24448 stop-reason/#24442 file-write visibility fold-in(§4.13). code-hygiene(solid-js/Eio-mutex/RFC-0071)은 §4.14로 분리.
- **touch (per-subsystem hermetic 테스트 매핑, grep 확인):**
  - Board → `test/test_board_sort.ml`·`test/test_board_author_identity_10297.ml`·`test/test_board_context_inference_resolution.ml` + status-rollup 비파괴 append 회귀
  - Task/verification → long-waiting `AwaitingVerification` obligation의 activity-event 표면화 회귀(RFC-0220 §11; 옛 `MASC_VERIFICATION_DEFAULT_ON`/`check_timeouts` poll-timer는 삭제됨, 되살리지 않음)
  - Scheduler → `test/test_schedule_runner.ml`·`test/test_schedule_store.ml`·`test/test_schedule_tool_wiring.ml`
  - Connector → `test/test_channel_gate.ml`·`test/test_channel_gate_metrics.ml`·`test/test_keeper_lane_mentions.ml`
  - Memory → `test/test_keeper_memory_lane.ml`; FORGET/claim_kind clamp는 별도 Memory-owned slice가 승격될 때 추가
  - Runtime → `test/test_runtime_attempt_fsm.ml` + failover(§4 Goal 3)
  - Fusion → `test/test_fusion_sink_meta.ml` + turn envelope(§4 Goal 5)
  - Keeper turn FSM → `test/stanzas/test_keeper_turn_fsm_tla_parity.inc`·`test/test_keeper_context_isolation.ml`; `test/test_keeper_contract_classifier_pure.ml`는 semantic classifier와 함께 삭제하고 source typed-signal acceptance test로 대체
  - Dashboard chat/observability → `test/test_tool_agent_timeline_build.ml`(#23540, Goal 12), event-bus `test/test_keeper_unified_turn_event_bus.ml`·`test/test_event_bus_subscription_contract.ml`
  - Dashboard auth(#69) → `lib/server/server_routes_http_dashboard_dev_token.ml` 강화
- **acceptance:** 위 살아남은 subsystem 테스트가 hermetic-required tier에서 green(env-gated/manual 아님); unauth GET /dashboard/dev-token→404, unauth mutation 100%→401; long-waiting `AwaitingVerification` obligation이 activity-event stream에서 표면화(옛 `check_timeouts`/`force_cancel_task_r` poll-timer는 RFC-0220 §11에서 삭제됨, 되살리지 않음); file-write-only turn이 typed receipt에서 visible(§4.13 CF-5); orphan cap stop-reason 0(§4.13 CF-3). §4.14 항목은 별도 승격 전 이 goal의 acceptance가 아님.
- **DoD:** 살아남은 subsystem CI green, env-gated/manual 분리. Legacy Goal 회귀는 삭제.

### Goal 12 — 실제 런타임 48h As-Is/To-Be + 100% 판정

- **문제:** 실제 런타임 48h As-Is/To-Be + dashboard/compaction/failover 관측으로 100% 판정.
- **경계:** production-ready는 정량 주장 — 4 gate 첨부(Release Artifact smoke; Keeper Turn Evidence Chain ≥18 keepers/≥54 terminal & success turns/≥3per keeper/100% receipt·checkpoint·event-bus·memory-injection·tool-log coverage/0 dangling attempt/≤600s span·turn; Performance SLO; OAS Pin & Boundary=MASC semantics in OAS 0). **Missing data는 blocker지 pass 아님.**
- **touch:** 48h live run; agent_timeline event-source 교체(#23540) — 관측 대상 모듈 = `lib/tool_agent_timeline.ml`(+`test/test_tool_agent_timeline_build.ml`); 현재 `tools_used=[]`·`model=unknown`을 emit하는 false-observation 소스. **#23540은 root-caused only** — 정확한 대체 event source(실제 tool 실행을 emit하는 emitter)는 아직 미지정 → **NEEDS_LOCATION**: `git -C masc grep -l 'keeper.tool_exec\|tool.called'`로 keeper.tool_exec activity event producer 후보 확정 후 착수. keeper.tool_exec activity event 신설; typed failure card + explicit retry transition(§3.11); failover/compaction 관측(Goal 3).
- **acceptance:** 48h live evidence + Evidence Chain gate 충족 + failover + compaction 관측 첨부; Turn/Tok·s/Tools 전부 observed; `lib/tool_agent_timeline.ml`가 실제 tool 실행에서 non-empty `tools_used`·구체 `model` emit(false observation 0).
- **DoD:** missing data = blocker; 100% verdict가 stacked-green 아닌 live.

---

<a name="413-migration-debt-goals"></a>
## 4.13 Crossover finding details (CF-1..CF-6)

§2.5의 감사 근거를 보존하는 appendix다. 별도 first-class goal이나 migration mandate가 아니며, `KILL` 판정은 구현하지 않는다.

### CF-1 — [KILL] Implicit determinism pin (#24417)
- **원 finding:** memory/compaction provider의 `temperature=0` fallback 삭제.
- **ruling:** fallback 복원 금지. sampling은 catalog/provider default 또는 explicit MASC config만 사용한다.
- **acceptance:** missing explicit determinism requirement를 `0`으로 보정하는 production branch 0. 별도 deterministic workflow가 필요하면 config 부재를 typed error로 검증한다.

### CF-2 — [KILL] Implicit runaway watchdog (#24386)
- **원 finding:** 기본 stream-idle/숫자 cap 제거 뒤 unbounded 실행.
- **ruling:** unbounded가 기본 계약이다. whole-run lifetime은 caller-owned Eio cancellation/deadline이고, 명시하지 않은 timeout이나 heuristic re-task를 만들지 않는다.
- **acceptance:** implicit numeric deadline 0; caller-supplied timeout은 해당 lane만 취소하고 다른 lane을 멈추지 않는 focused test.

### CF-3 — [KEEP AS DELETION] Observed-stop orphan (#24448)
- **문제:** Observed stop reason(TurnLimit/ExecTimeout/ExecIdle) producer 0 → orphan dead branch 7파일. cap도달 vs 정상완료 구별 불가.
- **결정론↔LLM:** typed-FSM terminal observability(LAW 3). 전부 결정론.
- **touch (grep 확인):** `lib/keeper/keeper_turn_fsm.ml`(FSM), `lib/agent_observation/agent_observation.ml`(stop_reason 관측).
- **acceptance:** 실제 OAS outcome producer가 없는 variant와 consumer 삭제. cooperative yield/cancel/completion만 typed receipt로 전달하고, cap producer를 재도입하지 않는다. TLA+ `StopSignalRespected` invariant 유지(`specs/keeper-turn-fsm/KeeperTurnFSM.tla` + `KeeperTurnFSM-buggy.cfg`; `test/stanzas/test_keeper_turn_fsm_tla_parity.inc`는 state-set parity만 검증하므로 invariant hold는 별도 TLC run).
- **DoD:** orphan branch grep 0. (§2.5 #24448 / Goal 12 + Goal 5)

### CF-4 — [KEEP] Crossover behavioral correctness (#24510)
- **문제:** 0.212 compilation migration은 완료됐지만 멀티모달 토큰(`total_tokens`)·ToolResult `content_blocks` behavior 증명이 남았다. (문서의 `block_tokens` 심볼은 HEAD 부재 — 실제는 `total_tokens`.)
- **결정론↔LLM:** 이미 완료된 compilation migration을 다시 N-of-M 작업으로 열지 않는다. 남은 named behavior만 검증한다.
- **touch (grep 확인):** `lib/keeper/keeper_context_core_message_json.ml`(content_blocks 소비), `lib/inference_utils.ml`(`total_tokens` = `Agent_sdk.Types.total_tokens` 위임) + `lib/dashboard/dashboard_http_keeper_metrics.ml`(`input_tokens/output_tokens/total_tokens/context_tokens`).
- **acceptance:** `lib/keeper/keeper_context_core_message_json.ml`의 ToolResult가 `content_blocks`를 소비해 멀티모달 undercount 0; `total_tokens`/dashboard token 필드 behavioral test; typed receipt가 멀티모달 토큰 카운트.
- **DoD:** named behavioral tests green. (§2.5 #24510 / Goal 5)
- **[근거, 2026-07-15]:** compilation migration은 merge commit `2938dd46556255ac46c46ae0df8cc70bc9ee15ab`(#24468) + `5b0680bce4ca87702ac3352e8bd0358d4f1cf2ed`(#24513)로 완료. **잔여(미검증):** 위 두 behavioral test. typecheck는 runtime behavior를 증명하지 않는다.

### CF-5 — [KEEP] File-write visibility (#24442)
- **문제:** file-write visibility 축소(evidence 없는 file-write-only turn이 visible→invisible).
- **결정론↔LLM:** No silent failure(LAW 3). 결정론.
- **touch (grep 확인):** `lib/keeper/keeper_execution_receipt.ml`(+`keeper_execution_receipt_types.ml`), `lib/keeper/keeper_agent_run_receipt.ml`.
- **acceptance:** file-write-only turn이 receipt/waiting surface에서 operator-visible; 회귀 테스트가 visibility assert.
- **DoD:** visibility 회귀 green. (§2.5 #24442 / Goal 12)

### CF-6 — [KEEP, ROOT FIX REQUIRED] Event-drop durability (#24447)
- **문제:** masc-domain never-drop(handoff/heartbeat/trust) → Drop_oldest(0.212가 Block 제거해 불가피). publisher가 drop을 unit으로만 받아 인지 못함.
- **결정론↔LLM:** never-drop / preserve-and-surface(KEEPER-STATE-OWNERSHIP). 결정론.
- **touch (grep 확인):** `lib/keeper_event_bus/keeper_event_bus.ml`, `lib/masc_event_bus/masc_event_bus.ml`, `lib/keeper/keeper_event_bridge.ml`, `lib/keeper/keeper_event_bus_drain_site.ml`.
- **acceptance:** handoff/heartbeat/trust source event를 durable store/outbox에 보존한 뒤 ack/retry하거나 enqueue 실패를 publisher에 typed error로 반환한다. full queue에서 source event loss 0을 증명(`test/test_event_bus_subscription_contract.ml`).
- **DoD:** preservation + caller handling + saturation 회귀 green. counter 또는 typed drop signal만 추가한 변경은 미완료. (§2.5 #24447)

<a name="414-deferred-subsystem-goals"></a>
## 4.14 Deferred candidate specs (DS-1..DS-8)

extraction에서 나온 상세 inventory다. first-class 실행 권한이 없으며, fresh evidence와 독립 issue/PR scope가 생긴 항목만 §4 goal로 승격한다. Goal 11은 이 목록 전체를 자동 소유하지 않는다.

### DS-1 — IDE Observation Plane v2 (§3.14)
- **문제:** 미착수 후속 축 — 성능 A4 SSE fan-out · A5 consumer-gate · A6 orphan 파티션 repo 귀속(bounded ingestion #23072 위 스택); 교차 C2 latched_reason(#23058) · C4·C6 promote Done_action 게이트 + Verification_requested stimulus.
- **결정론↔LLM:** ingestion/파티션/projection = 결정론; observation→stimulus 승격(promote gate)은 LLM/system 경계. **raw observation이 keeper를 직접 wake 금지(불변식).**
- **touch (grep 확인):** `lib/ide/ide_bridge.ml`, `lib/ide/ide_ingest_queue.ml`, `lib/ide/ide_event_types.ml`, `lib/ide/ide_region_tracker.ml`, `lib/ide/ide_annotations.ml`. 후속 축 심볼(`latched_reason`/`consumer_gate`/SSE fan-out/`Done_action` promote gate)은 `lib/ide/` HEAD에 미존재 → 신규 추가(**NEEDS_LOCATION for new symbols**, 구현 대상).
- **acceptance:** SSE fan-out/consumer-gate bounded; orphan 파티션이 repo에 귀속; raw observation의 keeper 직접 wake = 0(불변식 테스트); promote gate가 Done_action/Verification_requested stimulus를 명시 경로로.
- **DoD:** passive projection 불변식 유지 + bounded ingestion 회귀.

### DS-2 — Keeper replay provenance (F1 content detector rejected)
- **문제:** keeper 자기 출력이 provenance 없이 다음 input에 중복 삽입되는 정확한 replay 경로를 찾는다.
- **ruling:** n-gram/hash/score/LLM content-level 반복 detector(F1)는 오탐 기반 heuristic이라 **KILL**. 관측(O) 뒤 동일 source/turn/block identity의 재삽입을 typed provenance로 차단(F2 root fix)한다.
- **touch:** O = `raw_trace` wiring; F2 = `keeper_agent_run_finalize_response.ml` → `keeper_run_prompt.ml` replay path와 OAS structured message identity. content text를 분류하지 않는다.
- **acceptance:** 동일 typed source identity가 두 번 input에 들어가지 않는 revert-red test; 정상 반복 content는 그대로 보존.
- **DoD:** exact duplicate insertion 0, content detector 0.

### DS-3 — OAS Eio-mutex + assert-false 하드닝 (§3.12)
- **문제:** Stdlib Mutex가 Eio fiber 안에서 OS thread block; production `assert false`를 control flow로 사용(crash 대신 typed error 필요).
- **결정론↔LLM:** concurrency-correctness. 전부 결정론.
- **touch (grep 확인):** OAS `lib/base/context.ml`, `lib/agent/agent_registry.ml`, `lib/llm_provider/provider_registry.ml`, `lib/llm_provider/metrics.ml`; typed error = `lib/error_domain.mli`(`` `Internal of string ``). **NEEDS_LOCATION:** `content_replacement_state.ml`은 HEAD 미확인(CHANGELOG에만); "pipeline stage assert-false" 사이트는 OAS lib `assert false`=1(error_domain.mli), pipeline=0 → 사이트 재확인 필요.
- **acceptance:** Eio-only mutex(`create_sync`는 test 전용); production `assert false`를 `` `Internal `` typed value로 교체, control-flow `assert false`=0 유지; full OAS suite green; Eio-fiber 동시 registry ops 통과.
- **DoD:** OAS suite green + Eio-fiber concurrency 테스트 통과.

### DS-4 — solid-js / dead-code hygiene
- **문제:** solid-js 참조 잔존(vitest config), gRPC/LSP dead-code 판정(#70), tool surface masc_*/keeper_* typed-separation(#57), dead-test 제거.
- **결정론↔LLM:** 코드 위생. behavior-only.
- **touch (grep 확인):** `dashboard/vitest.config.ts`(solid-js 참조), `dashboard/design-system/headless-core/`(extraction의 "headless-solid"는 실제 `headless-core`), `dashboard/design-system/RFC/0017-solidjs-migration.md`. **NEEDS_LOCATION:** `git grep '"solid-js"'`(package.json dependency)=0 at HEAD — "dependency 잔존"의 package.json 근거 미확인(vitest config 참조만 확인); extraction의 "2 vitest configs"는 `vitest.config.ts`+`vitest-setup.ts`.
- **acceptance:** **solid-js deps=0, vitest config=1**; gRPC/LSP caller grep→0이면 제거(§11); typed `tool_profile` boundary(exposed vs internal); dead test 제거 시 per-test rationale.
- **DoD:** solid-js grep 0 + vitest config 1.

### DS-5 — Config-ownership canonical read-only snapshot (#3364/#3365/#3363)
- **문제:** config introspection read 계약이 `masc_config` / `/api/v1/dashboard/config`에 중복·분산.
- **결정론↔LLM:** config = MASC runtime 계약 SSOT(runtime.toml). read 계약은 결정론.
- **touch (grep 확인):** `lib/env_config_introspect.ml`(+.mli), `lib/config/env_config_snapshot.ml`.
- **acceptance:** single canonical read-only config snapshot endpoint; 중복 read path 제거(grep 0).
- **DoD:** 중복 read path grep 0.

### DS-6 — Structured runtime-health probe
- **문제:** 좁은 boolean `resource_check` callback을 structured runtime-health probe로 교체(Open Structural Gap + Candidate Upstream Work).
- **결정론↔LLM:** health probe = 결정론 관측.
- **touch:** **NEEDS_LOCATION** — `resource_check`는 `docs/OAS-MASC-BOUNDARY.md`(문서)에만 확인되고 lib 심볼 미확인. 착수 전 `git -C masc grep -l resource_check`로 실제 callback 사이트 확정.
- **acceptance:** structured probe callback lands; boolean `resource_check` retired(grep 0).
- **DoD:** boolean callback 제거 + structured probe 회귀.

### DS-7 — RFC-0071 §3.4 warning-4 fragile pattern matching
- **문제:** warning 4(fragile pattern matching)를 module-by-module 활성화; Cat-3 variant→variant `_ -> default` 사이트를 ~100→<20으로.
- **결정론↔LLM:** 컴파일러 강제(exhaustive match). 결정론.
- **touch:** repo-wide(module-by-module dune `flags`); 새 variant 추가 시 컴파일 타임 누락 감지.
- **acceptance:** warning 4 active repo-wide; variant→variant wildcard count **<20**(baseline **~100 est.** — extraction 추정치, **실측 필요**).
- **DoD:** warning 4 활성 + wildcard <20.

### DS-8 — Transport-health-truth + non-local auth (product-positioning blockers)
- **문제:** (a) non-local operation auth hardening + REST/SSE 계약 versioning + error-shape discipline(Advanced-Path blocker); (b) transport/health read-model이 reachable runtime state와 일치(Front-Door blocker).
- **결정론↔LLM:** auth·transport-health = 결정론(reachability는 관측, 판단 아님).
- **touch (grep 확인):** dashboard auth = `lib/server/server_routes_http_dashboard_dev_token.ml`(§4 Goal 11 #69와 결합). **NEEDS_LOCATION:** transport-health read-model 사이트 — `git -C masc grep -l 'transport.*health\|reachable'`로 확정.
- **acceptance:** non-loopback bind auth default hardened; REST 계약 versioned + crisp error shape; transport health가 runtime unreachable인데 reachable로 보고 불가.
- **DoD:** auth default + transport truth 회귀.

---

<a name="5-orthogonality-matrix"></a>
## 5. Orthogonality Matrix

기존 프레임워크 계승: **직교 = 축이 코드로 존재하지 않고 다른 축과 겹치지 않음.** 직교 → fix가 안 겹침 → 병렬 가능. 단 **blast radius는 축과 무관하게 반경 결정**(같은 축 ≠ 같은 반경 — OAS 검증=1곳 수렴 저blast vs 직렬화=5-backend 산포 고blast).

| 항목 A | 항목 B | 관계 | 근거 |
|--------|--------|------|------|
| Boundary law | OCaml quality(mli/Effect/GADT) | **독립(병렬)** | boundary semantics 안 건드림 |
| Keeper FSM(Goal 4) | Scheduler G1-G8(Goal 6/7) | **결합(약)** | typed wake bus(enqueue/consume Result) 경계만 공유 → 안정 시 병렬 |
| Runtime assignment(runtime.toml) | keeper.toml/persona | **독립** | provider/model 변경이 identity 파일 안 건드림 |
| Goal 9(exact effect permission) / Goal 10(cardinality) / Goal 11(CI breadth) | Goal 12(48h) | **결합** | Goal 12가 9-11의 green evidence + observability 선행 필요 |
| O 관측계측 / typed replay provenance | F1 content-level detector | **분리 후 F1 폐기** | O로 exact replay path를 찾고 typed source identity로 수정; content detector는 heuristic이라 KILL |
| #24448 orphan stop variants | #24386 implicit watchdog | **독립 삭제** | 실제 producer 없는 stop variant와 implicit watchdog를 각각 삭제; 서로를 살리는 근거로 사용 금지 |
| #24447(drop policy) | #24442(file-write visibility) | **결합(테마)** | 둘 다 "no silent drop" 위반 → 한 슬라이스 |
| Config centralization / transport-health truth / non-local auth | 서로 | **독립(병렬), 공통 gate** | 3 Track-C 독립이나 "front-door truth first"에 gate |
| Fusion RFC 0277/0283/0298/0306 | 서로 | **layered, 독립 머지** | preset record 단일 generation point 공유(컴파일 강제 ripple) |
| Memory RFC-0247 phases | 서로 | **additive 독립** | α=0/lifecycle-default Live로 byte-identical; 단 P0a가 P0b sleep 재활성 gate |
| RFC-0320 5 wake family(Hitl/Connector/Bg/Fusion/Schedule) | 서로 | **결합(공유 fix)** | 하나의 continuation_channel 구조 변경(per-family patch 아님) |
| 6 memory axis / OAS boundary owner split | MASC vs OAS 작업 | **독립(병렬)** | MASC=lifecycle/work-graph/store/approval/keeper-as-tool/fusion/basepath/memory/judge; OAS=agent_config/provider-routing/yield/stop-reason/handoff/checkpoint |
| Judge(J) axis | Memory(M)/Work(X) | **독립** | Judge는 decision-only, memory/work persist 안 함; P vs T는 EffectIntent+receipt id로만 결합 |
| Roadmap renumbering | 모든 코드 | **독립(doc-only)** | 단 release honesty gate block |
| 6 crossover findings | 서로 | **독립 판정** | CF-1/2는 KILL, CF-3은 deletion, CF-4/5/6만 살아남은 behavior/durability 작업 |
| Wave 의존(Durable Intelligence) | — | **순서 결합** | W0(Evidence+BasePath)+W1(Activity kernel) 선행 → W2(approval+collab, W1 DurableRun/outbox 필요) → W3(OAS 재현 정합성/reasoning replay, frozen `agent_config`/`Contract` 필요) → W4(Judge+memory, W1+evidence 필요) → W5(real eval, all L0-L3 필요) |
| 48h Resilience PR-A(failover)+PR-B(HITL async) | PR-C(OAS Eio)+PR-D(fusion persist) | **순서 결합** | A/B 선행 unblock, A/B interface 안정 후 C/D 병렬 |
| Gap 3 그룹 | 서로 | **독립** | (1)reply-channel 비균일 (2)built-but-not-ignited (3)social/creator 미착수 |
| OAS Eio-mutex/assert-false(DS-3) | Boundary law / MASC 작업 | **독립(병렬)** | OAS internal concurrency-correctness; MASC↔OAS 계약·redaction 안 건드림. 단 OAS pin bump와만 조율 |
| solid-js/dead-code hygiene(DS-4) | 모든 코드 | **독립(병렬)** | dashboard build 위생; runtime semantics 무변 |
| IDE Observation Plane v2(DS-1) | Keeper FSM / Connector / Board | **독립(약결합)** | passive projection read model — raw observation이 keeper 직접 wake 금지가 유일한 경계(위반 시 결합). ingestion이 main domain path 블록 안 함 |
| DS-2 typed replay provenance(O/F2) | Boundary law | **독립** | typed source/turn/block identity 경계만 MASC에서 수정. F1 content classifier는 KILL이며 OAS 계약 무변 |

---

<a name="6-blast-radius-matrix"></a>
## 6. Blast Radius Matrix

3-tier: 낮음·축복(단일 CHOKE) / 중 / 높음·저주(N-산포 RIPPLE). rollback은 revert 단위.

| 변경 | 영향 모듈/subsystem | risk | rollback |
|------|---------------------|------|----------|
| Exact EffectIntent permission(Goal 9) | keeper_gate.ml, keeper_tool_policy.ml, keeper_tool_dispatch_runtime.ml, ApprovalsSurface | **높음** — 계층 classifier 재도입 시 전 lane liveness 회귀 | exact request-local decision slice revert |
| Capability registry projection | 4 surface(public_mcp/spawned_agent/local_worker/keeper) 동시 | **중** — SSOT choke이나 4 surface fan-out | registry 단일 revert |
| Provider failover SSOT 정합(PR-A, Goal 3) | keeper_turn_driver.run_named `attempt_runtime_candidates`(이미 candidate-list) → `Runtime_attempt_fsm.decide` 경유 + `[runtime.lanes.*]` TOML; RFC-0265 modality reroute 상호작용 | **높음** — core turn path, 18h; 기존 `[runtime.assignments]`=one-candidate lane 유지 필요 | decide-경유 feature flag |
| Implicit runaway watchdog(#24386) | keeper_supervisor + keeper_keepalive + orphan stop-reason | **KILL** — 삭제한 cap/heuristic supervision 재도입 | caller-owned explicit Eio lifetime만 유지 |
| Step 5 Switch.on_release(Goal 4) | keeper_agent_run.ml/keeper_unified_turn.ml cancellation finalizer(`keeper_unified_turn.ml:534-555` Cancelled 삼킴 지점) | **높음** — 매 turn terminal path; `KeeperTurnFSM.tla` `StopSignalRespected` invariant 검증 필수(bug action `StopSignalSwallowedAsDone`) | catch-all 복귀 |
| Source typed actionable signal direct cut | turn admission(keeper가 turn 실행하는 source event 집합) | **높음** — source variant 누락이 fleet activity 변경 | prose classifier 복구 금지; typed variant 누락 시 fail-closed+event 보존 |
| #24447 durable event preservation | publisher/queue 경계(handoff/heartbeat/trust), oas_event_bridge | **높음** — silent loss가 fleet desync | durable outbox slice revert 또는 enqueue fail-closed; `Drop_oldest` 복귀 금지 |
| Memory claim_kind clamp | types.ml(no-TTL) + recall.ml(visible) + consolidator.ml(promotable) 3 site 동시 | **중~높음** — 셋 다 flip 안 하면 mis-tagged fact이 durable+recall-visible+cross-keeper-promotable | 3-site 원자 revert |
| RFC-0320 continuation | keeper_approval_queue, keeper_event_queue(payload→exhaustive match ripple), keeper_heartbeat_stimulus_intake, server_bootstrap_loops | **중** — optional field + Unrouted default=backward-compat; RFC-gated subsystem | optional field 무해 |
| RFC-0266 async wake | keeper_event_queue(4th variant→exhaustive match), fusion_sink.emit, fusion_tool, fusion_run_registry | **중** — 컴파일 강제 | variant 제거 |
| Rich rendering(DESIGN-RICH) | ~40파일: lib/keeper(chat_blocks/events/discord/slack), lib/gate, sidecar(slack/telegram/imessage/cli), dashboard, bin TUI | **높음** — 가장 넓음; keeper_chat_blocks 어휘 확장이 dashboard schema+전 connector renderer ripple | connector별 단계 |
| Fusion preset type(0277/0283/0298) | fusion_config.ml 단일 generation point + bin/fusion_run.ml + sink/judge byte-identity derive | **중** — 컴파일 강제 ripple | 단일 point revert |
| OAS Eio mutex(PR-C, DS-3) | OAS lib/base/context.ml, lib/agent/agent_registry.ml, lib/llm_provider/provider_registry.ml, lib/llm_provider/metrics.ml(4/5 grep 확인) + `content_replacement_state.ml`(**NEEDS_LOCATION**, HEAD 미확인) + pipeline assert-false site(**NEEDS_LOCATION**, lib assert false=1 in error_domain.mli) | **높음** — concurrency-correctness across OAS runtime; full OAS suite + Eio-fiber test 필요 | 모듈별 |
| Board status-rollup fix | lib/board/board_core.ml + lib/board/board_core_persist.ml + lib/board/board_moderation.ml(현재 Hashtbl.replace 파괴적 덮어쓰기; grep 확인. draft의 board_core_status_rollup.ml은 HEAD 미존재) | **중** — prior content 보존 필수; Board+Dashboard Chat 결합 | append-only 전환 |
| runtime.toml `[runtime].default` 변경 | 전 unassigned keeper fan-out(per-keeper escape hatch 없음, hard-reject) | **높음** — single default가 fleet 전체 | default revert |
| Dashboard auth(#69) | server_dashboard_http, mint_dashboard_dev_token, operator/action | **높음** — credential/identity RFC-gated subsystem, security-blocking | route별 401 |
| Env knob 변경 | docs/runtime-tunables.md(bin/env_knob_catalog.exe drift gate) | **낮음** — 같은 PR에서 재생성 안 하면 CI fail | catalog 재생성 |
| Verification FSM ignition(default_on flip) | 매 task Done transition + verifier rework loop + G-2 probe | **높음** — solo-room guard 없이 flip 시 production permanent wake-loop | flag false |
| lib/schedule(Goal 6) | import/dependency edge 0 유지 필요(현재 `schedule_supported_kinds.{ml,mli}`에 `Keeper_wake_*` enum label 14건은 있으나 import edge 아님; Fusion/Board/OAS 0). "coupling grep 0"은 enum label 제외 시 성립 | **낮음** — 격리; 단 CI boundary gate real OAS checkout 필요 | — |
| Scheduler live proof(G0/G2/G4) | 배포 diverged runtime(source ≠ server HEAD) | **proof-only** — 코드 blast 아님; 모든 G* live-proof가 deploy identity 선행 | infra |
| Tool discovery defer_loading | schema_registry(`tool/tool_dispatch.ml:298` 선언, register :304 단일 choke) | **낮음·축복** — 도구 정의 메타만, dispatch 로직 무변 | flag off |
| OAS 직렬화 5-backend 추출 | backend_openai/ollama/gemini/anthropic + openai_serialize(산포) | **높음·저주** — 한 곳 누락=silent-ignore 재발; codemod 일괄 필수 | 함수 추출 단일 |
| Typed replay provenance(DS-2) | lib/keeper/keeper_agent_run_finalize_response.ml + lib/keeper/keeper_run_prompt.ml + OAS structured message identity | **중** — exact duplicate insertion 경로만 | source-id change revert; content detector는 도입하지 않음 |
| Memory-owned FORGET librarian pipe(Goal 3과 독립) | lib/keeper/keeper_memory_policy.ml + lib/keeper/keeper_memory_os_gc.ml + keeper_memory_os_consolidation.ml + keeper_memory_os_types.ml(claim_kind clamp) | **중~높음** — 3축 중 부재 축 신설; asymmetric fail-safe toward retain 위반 시 데이터 유실 | LLM-boundary forget pipe flag off; retain-only |
| Busy-defer connector reply(Goal 8) | lib/gate_keeper_backend.ml(inbound reply path) + lib/gate/slack_socket_client.ml + lib/gate/discord_gateway_client.ml | **중** — connector reply turn 신설; busy keeper의 inbound silent drop 제거 | busy-defer turn off(현상태=silent drop) |
| Config-ownership snapshot(DS-5) | lib/env_config_introspect.ml + lib/config/env_config_snapshot.ml | **낮음·축복** — read 계약 단일화, write path 무변 | 중복 read path 복구 |
| Transport-health-truth(DS-8b) | **NEEDS_LOCATION**(transport health read-model 사이트 미확정) | **중** — Front-Door blocker; reachability 오보고가 운영자 오도 | read-model revert |
| Non-local auth(DS-8a, #69) | lib/server/server_routes_http_dashboard_dev_token.ml | **높음** — credential/identity RFC-gated, security-blocking | route별 401 |
| IDE Observation Plane v2(DS-1) | lib/ide/ide_bridge.ml + ide_ingest_queue.ml + ide_event_types.ml + ide_region_tracker.ml(신규 축 심볼 NEEDS_LOCATION) | **중** — passive projection; raw-wake 불변식 위반 시 keeper 스퓨리어스 wake | ingestion flag off |
| solid-js/dead-code hygiene(DS-4) | dashboard/vitest.config.ts + dashboard/design-system/headless-core/ | **낮음·축복** — dashboard build만; runtime 무변 | config revert |
| VERSIONED-ROADMAP rewrite | doc-only(zero code) | **낮음** — 단 stale v2.87-v2.93가 planning agent 오도 | doc |

---

<a name="7-benchmark-lens"></a>
## 7. Benchmark Lens (non-normative snapshot)

비교·측정 후보를 보존하는 inventory다. source artifact/commit/명령이 없는 수치는 사실 주장이나 merge gate로 사용하지 않는다.

- **Resilience:** MASC는 receipt-before-side-effect + typed FSM terminal state를 목표로 한다. provider failover는 배선+테스트됨(`attempt_runtime_candidates`, `test_keeper_turn_driver_failover.ml`)이나 `Runtime_attempt_fsm.decide` SSOT를 우회한다(문서의 옛 "failover 회귀/turn 종료"는 오류). Hermes-Agent는 Docker + approval을 sandbox 레벨에서 강제하고, claude-code는 sandbox 파일이 압도적(perm/limit 대비). MASC의 차별점은 fleet-level 재현성 지향이지 단일 턴 회복이 아니다.
- **Harness:** MASC eval은 현재 static-fixture self-grading(exact claim/path membership로 자가 채점, metrics_json=null). L4(real-worktree paired/chaos/differential + blinded independent Judge)는 미착수(W5 wave 미시작). claude-code/Anthropic agent eval은 20-50 task를 권장 시작점으로 두나 이는 MASC hard gate가 아니다.
- **정량 목표의 측정 상태(anti-hype):** dup_rate `17.4%`, wildcard `~100`, tool-search `55k/85%`, dashboard/scheduler/chat 비율은 원 extraction의 historical number이며 이 RFC에 재현 artifact가 없다. **전부 unverified**로 취급하고 재측정 전 인용·acceptance 사용 금지. 새 baseline은 command, input set, commit SHA, timestamp를 함께 기록한다.
- **Boundary:** MASC→OAS 단방향은 grep으로 확정(OAS lib에 masc/keeper/persona/hitl/fusion 각 0; `board`는 `event_bus.mli` doc 주석의 `dashboards` substring 1건 외 실 어휘 0). 이 owner split(OAS=provider-routing/pipeline/checkpoint/yield/reasoning-replay/stop-reason/handoff; MASC=lifecycle/work-graph/board/HITL/fusion)은 SDK-runner 계열(claude-code-style)과 workspace/memory-graph 계열(OpenClaw/Hermes/DAW) 사이에서 **keeper별 자율 lane substrate + provider-agnostic router** 포지션이다 — 콘텐츠 판단=configured model, lifecycle 권한=operator로 분리(RFC-0318/0319에서 hierarchical supervisor 폐기).
- **Lane isolation:** MASC는 lane-per-keeper를 척추로 두나 dashboard Lane surface는 43%(busy/deferred/wake-on-complete/per-lane failure isolation UI 미완). 1/100/1000 혼합 cardinality 회귀는 아직 없음(Goal 10). 진짜 하네스 보호는 sandbox+permission이며 turn/cost limit은 theater — 격리된 무한 루프는 무해(토큰 낭비, observation이 잡음), 자원 runaway는 cgroup/PID(sandbox)로 봉쇄.

---

<a name="8-recovered--deferred-ideas"></a>
## 8. Recovered / Deferred Idea Inventory

과거 논의의 provenance를 잃지 않기 위한 inventory다. **모두 기본값은 inactive**이며, 살아남는다는 뜻이 아니다. 현재 코드 근거, 독립 owner, 기계 acceptance가 있는 항목만 §4 또는 GitHub issue로 승격한다. `KILL` 판정과 충돌하는 아이디어는 revival 금지다.

### 8.1 High revival

| Idea | 왜 밀렸나 | Blast radius | Revival 조건 |
|------|-----------|--------------|--------------|
| Verifier rework-loop incentive (verification obligation 표면화) | `MASC_VERIFICATION_DEFAULT_ON` flag는 HEAD 부재; RFC-0323은 `Withdrawn`("Withdraw mandatory cross-verifier completion", 문서의 "coded/landed but off"는 오기); RFC-0220 §11이 poll-timer 삭제·obligation을 activity-event로 이동 | 중(verifier loop + activity-event 표면화) | rework loop wake incentive 설계(옛 default_on flip/check_timeouts 되살리지 않음) |
| busy-defer ("지금 바쁘니 이따 답할게") | Never started(MISSING); social spec feature 미착수. (문서의 "RFC-0334 확장"은 오인용 — RFC-0334는 `Superseded`, 주제=Board signals as durable Keeper input이지 connector busy-defer 아님) | 중(connector reply turn) | LLM-judged light defer reply turn |
| FORGET / memory decay 축 | rg로 no decay/prune/FORGET 확인; #24071 durable-ingest CLOSED unmerged. 무한 축적 잔여 | 중(keeper_memory_os_*) | Librarian LLM-boundary explicit forget/decay pipe |
| HITL deterministic re-execution of approved gh commands | 07-08 audit defer, MISSING confirmed; RFC-0320 W3c "re-execution" half 미착지(delivery=reply-TEXT only) | 중(Hitl_resolved wake payload) | approve가 typed re-exec work item(원본 IR/action_key) enqueue |
| Full Durable Intelligence 12-axis × 5-ring rebuild (60 coord, W0-W5) | Plan-only(no impl/PR/task); "ρ0=retro-guess-score 안 함". 최대 deferred corpus | 매우 높음 | 새 ledger 착수 결정 |
| Real-worktree eval harness(L4) + adversarial promotion ledger | 전 L4 unpromoted; W5 미시작; 현재 static-fixture self-grading | 높음 | blinded/order-swapped independent Judge + real live-task evidence |
| submit_and_await production path purge | **[LANDED]** `submit_and_await`는 HEAD lib에서 0건(제거 완료), 현재 `submit_pending`(`keeper_approval_queue.mli:167`); 문서가 인용한 `governance_pipeline.ml:550`은 **파일 부재** | 높음(keeper fiber lifecycle) | 완료 — nonblocking submit_pending+wake로 수렴됨 |
| Supervision Tree (historical OneForOne/OneForAll/RestForOne) | fan-in 0으로 삭제된 구조; implicit watchdog의 재도입 명분이 됨 | 높음 | **KILL — current lane-local typed recovery가 증명하지 못하는 새 요구가 생기기 전 revival 금지** |
| Related/proactive board wake via LLM/Fusion judgment | deterministic stigmergy + 키워드 scoring(+5 score/50 cap) 의도적 삭제; "real LLM/Fusion boundary 나올 때까지 absent" | 중~높음 | LLM/Fusion judgment producer |
| Additional typed schedule payload variants (masc.board_post 외) | masc.board_post만 구현; 나머지는 unsupported terminal; "registry 통해서만 추가" | 중(schedule registry) | registry validator+dispatcher+dashboard+Otel kind mapping |
| Recurring schedule operational proof | "still not proven"; single-shot terminal(failed/expired) evidence만; Goal 6가 삭제-대체할 legacy | 높음 | live recurrence evidence |
| Re-enable sleep/consolidation fiber(#21237 merged, #21244 killed) | 6017-fact dry-run이 ≥2-keeper 주장=coordination boilerplate; P0a producer typed-category fix 대기 | 중(keeper_memory_os_* + sleep fiber) | Ephemeral 구조적 non-promotable 후 |
| Action-stream self-reconciler (keeper_memory_os_self_reconcile) | RFC-0285 §7이 "internal state deterministic oracle 없음" 오판; research 반전(High confidence)이나 UNBUILT | 중 | task-claim event가 "no tasks" retract(re-read 없이) |
| L0 recall routing (self-obs를 episodic/audit log에 default, recall store 아님) | RFC-0285가 여전히 self-obs를 recall inject(horizon만); "re-injection ≠ re-observation" 불변식 미코드화 | 중 | audit-log-by-default 불변식 |
| Fusion completion wake actively starts turn (Fusion_completed stimulus) + run_registry + status tool + dashboard | **[Phase 1 wake LANDED]** `fusion_sink.ml:315` `Fusion_completed` stimulus + `:320` `enqueue_durable_result`(RFC-0266) — 문서의 "call 0/polling"은 stale. 잔여=continuation_channel + Phase 2-4 visibility | 중(keeper_event_queue variant) | Phase 2-4 registry/status/dashboard visibility |
| Judge-of-judges + staged reducer fan-out + judge pool decoupling | RFC-0283/0298 코드 있으나 preset static(hand-edit runtime.toml=hardcoded); dashboard form 미배선 | 중 | judge pool 런타임 배치 + settings form |
| RFC-OAS-024 canonical_tool.ml typed tool-call contract | 2 SIGN-OFF 미결; id_origin 제거 권고; in-repo consumer commit 전까지 spec-level(fan-in 0 dead code 회피) | 높음(tool call↔result 상관) | in-repo consumer commit |
| RFC-OAS-029 dialect gap(GLM/MiniMax) + thinking builder 통합 | Draft; #2228이 통합 대신 양 builder에 preserve axis 추가(N-of-M); GLM-ness가 String.starts_with 'glm-' 재파생 | 높음(2×/3× drift builder) | 단일 canonical thinking_request_fields + drift test |
| drift 결함 3종 즉시 기록 (default_capabilities N-site 재구현; Ollama host allow-list 하드코딩; 직렬화 5-backend 미추출) | "옳은 동작이나 SSOT 부재" — Issue Discovery로 기록만 | 높음(직렬화=저주) | SSOT 추출 + codemod |
| raw_trace wiring | **[LANDED]** 이미 배선됨 — `?raw_trace`는 `keeper_turn_driver.ml:277`(문서의 :94는 오기), `call_run_named`(`keeper_agent_run.ml:599`)가 `run_named`로 전달(`:610`)하고 call site `:654`가 `raw_trace_for_dispatch ~config ~meta`(실 sink resolve + `RawTraceSinkDegraded` counter) 공급 | 낮음 | 완료 |
| Discovery/tool-search defer_loading flag (도구 전량 front-load 대신 지연 로드) | 유일 저비용 신규 직교축이나 측정 선행 필수("55k/85%절감"은 수백 MCP 기준, MASC ~60-80 내부도구는 규모 다름) | 낮음·축복(단일 choke) | Tool_dispatch.registered_count × 평균 스키마 토큰 상한 추정 후 |
| Layer 3-A verbatim replay + Layer 2 OAS history channel 완화 (prose echo loop) | continuity 채널만 부분 완화(`keeper_memory_policy.ml` — 문서의 :477-483은 파일이 163줄이라 out-of-range, 정확 라인 재확정 필요); Layer 3-A(finalize_response 축자 replay)+Layer 2(OAS `backend_openai_serialize.ml` 재직렬화, off-snapshot) 미완화 | 높음(finalize 경로) | 지배 채널 관측 확정 후 |

### 8.2 Medium revival

| Idea | 왜 밀렸나 | Blast radius | Revival 조건 |
|------|-----------|--------------|--------------|
| Staged Judge-of-Judges (≥6-judge) fusion preset | schema 노출·0 만족 preset(trio=1/quorum=2); 항상 config error(RFC-0283) | 중 | ≥6-judge staged preset 또는 tool schema에서 숨김 |
| Board proactive participation via attention LLM judge | producer-only dead scaffold(load_candidates reader 0); RFC-0334 W3 direction-decided only | 중 | LLM judge consumer 배선 |
| Image creator axis (keeper image-gen tool + Board image upload) | MISSING(#62/#63); modality catalog에 image-gen provider 없음. Never started | 중 | provider + keeper tool + Board upload |
| procedural_memory crystallization (decision-log→procedure) | consumer 매 post-turn read(limit=8), production writer 0(save_procedure grep=0); always-empty | 중 | production writer 또는 삭제 |
| keeper_recurring persistence (recurring.json + reload) | RFC-0314 §3 open question; in-memory Hashtbl 재시작 소멸 | 중 | Goal 6에서 착지 |
| shared-promotion measured outcome | design-plan only(`is_outcome_positive_for_shared_promotion` 심볼은 lib에 0건 — RFC-0247/purge-plan 문서에만 "temporary category proxy pending #22447"); category proxy가 real outcome evaluator 대체 | 중 | recall-injection ledger outcome을 fact metadata join |
| RFC-OAS-018 Phase 2 fail-closed pricing (unknown model → option/typed Unknown) | provider.ml 주석 "Phase 2 deferred"; $0 collapse가 production-dead wrapper에 생존 | 중 | Goal 2에서 typed Unknown |
| Board karma visibility(D5); quality-score ranking은 KILL | Partial(#23933 reactions/mention만). hot/confidence/karma score가 substantive·quality authority가 되는 formula는 heuristic이라 부활 금지 | 중 | visibility는 D5에서만 결정; 표시는 stable declared total order |
| RFC-0271 §4.5 MaxTokens truncation continuation + dead #23648 arm cleanup | P2, max_tokens chain 병합 후 frequency 하락 de-prioritized | 중 | continuation + mutating-turn protection |
| Board fixture-voter write-boundary fix (cast time typed voter identity) | self-documented workaround(#9921, `fs_compat.ml:46` write-boundary guard); read-time quarantine(문서의 `MASC_BOARD_VOTE_QUARANTINE` flag는 코드 부재 — RFC-0000에만 등장) | 중 | write-path typed voter |
| Judge calibration ledger (J3/J4, blind identity+order swap+cross-family) | 전 J-axis unpromoted; W4 미시작; single uncalibrated self-review만 | 중 | W4 착수 |
| SourceNeededJudge + durable primary-source reading job | Design-only(W4-06); numeric cutoff 대체 미구축 | 중 | Needs_primary_source verdict가 source job 생성 |
| OAS task_of_model_id heuristic 제거 + Handoff redesign | 48h spec Out-of-Scope; P1 heuristic/stub pair parked | 중 | model-id substring inference 제거 |
| Advisor intra-turn planning ("개입 시점" sub-axis) | DEFER·RFC 필요; native advisor는 Anthropic 전용(GLM/kimi keeper 불가); 자체구현=라우팅 7-site+~120파일 | 중 | RFC 후 |
| Circuit Breaker (Closed/Open/HalfOpen) | Phase 2.2 P1 sketch 미배선; 0.212 cap-removal과 긴장(breaker=bounded counter) | 중 | provider-local-timeout 대체와 조율 |
| Auto Recovery exponential backoff (1s→60s) | Phase 2.1 sketch 미구현; keeper_supervisor sweep가 piecemeal 대체하나 통합 backoff ladder 없음 | 중 | 통합 backoff-escalation |
| Graceful Shutdown phase machine (StopAccepting→Drain→Cleanup→SaveState→Exit) | Phase 1.3 sketch; MASC_SHUTDOWN_* knob(untyped)만; lane-drain vs server-drain 혼동 | 중 | typed phase FSM |
| Legacy GOAL LOOP OODA cadence scheduler | Legacy Goal runtime과 함께 **KILL**. `scripts/goal_loop_scheduler.py` 및 관련 dashboard/test/config 삭제 | 중 | revival 금지; 명시적 Task+Keeper lane+typed Scheduler wake 사용 |
| Automatic verification evidence from gh pr create + git-delta visibility | task-execution visibility audit "missing teeth"; tool_access naming vs semantics mismatch | 중 | 2026-06-04 audit 참조 |
| Capability matching algorithm (masc_bind → routing) | MASC-V2-DESIGN "Should Have" 미체크; 4 Must-Have primitive만 배송 | 중 | matching 알고리즘 구현 |
| Capability Honesty (실적 기반 anti-exaggeration) | "(목표)"로 강등; aspirational | 중 | track record 검증 |
| OCaml 5.x Effect Handlers pilot (logging/config Reader/authz) | 양 codebase 0 usage(Tier 2 D); Effect maturity risk | 중 | single logging-effect pilot |
| GADT expansion (tool schema/event FSM/verification protocol) | ~2 GADT site(target 12+); "illegal states unrepresentable" 미적용 | 중 | AwaitingVerification unrepresentable-illegal-state |
| 3C Stdlib.Mutex→Eio.Mutex (`server_dashboard_http_runtime_info.ml` — 실측 `Stdlib.Mutex.create` **2건**(:130,:207), 문서의 "7 lock"은 오기; `worktree_live_context.ml`은 **파일 부재**) | 3A/3B 확인, 3C/3D "미확인"; high-ROI dead-lock-risk 미검증 | 중(low file, high correctness) | Eio fiber 검증; 실 mutex 사이트 재확정 |
| Candidate upstream primitives (harness case/result/verdict; swarm agent_entry metadata; generic provider manifest) | "upstream 제안 가능" 제안됨, 미upstream | 중 | upstream PR |
| Product Portfolio Trim (TRPG/Voice/MDAL/RISC keep/graduate/archive) | Milestone 6(frozen legacy counter); roadmap stale로 orphan | 중 | roadmap 재번호 후 |
| Memory associative-graph brain (typed closed-sum edge, spreading-activation) | 문서의 "P2a DONE but α=0"은 **미확인/likely-stale** — `lib/keeper/keeper_memory_os_*`에 spreading-activation/associative-graph/α-writer/edge 코드 부재(RFC-0247 design 문서에만 존재); causal label(diagnoses/derives/verifies) 의도적 부재(LLM classifier 필요) | 중 | deterministic producer 존재 시(설계 재확정 선행) |
| keeper_surface digest mode / ambient recording / unread cursors / person-note | RFC-0223 §5 명시적 deferral(digest 비결정론, cursor per-lane state) | 중 | fact-retention harness |
| Board multimedia + AI vision (attachment/OCR/ALT/moderation) | RFC-0037 4 user open-question 대기; Phase B vision commitment deferred | 중 | §6 질문 해소 후 A0 |
| Board_render module + nested comment-tree serializer | DESIGN-RICH §5.6 P3 최저 우선; attachment meta 저장되나 미렌더 | 중 | — |
| MMR-over-Jaccard diversity re-rank + earned-promotion gate | RFC-0247 §2.6/P2b; additive default-off, eval gate | 중 | eval 후 |
| Contradiction→Board surfacing (silent overwrite 대신 Board post) | RFC-0247 P2b; consolidation 재활성+eval 뒤 | 중 | TLA+ ContradictionNeverSilentlyOverwrites |
| Runtime host-driven continuation-boundary input policy (Before/After boundaries, queued|applied|interrupted|ignored) | design note, Advanced.run_blocks yield surface와 end-to-end 미배선 | 중 | Pending_input_updated ↔ Continue|Yield 조율 |
| RFC-OAS-018 catalog externalization Phase 2-4 (240 model literal/85 port/35 dispatcher→models.toml) | Draft; 240 site 일괄 rewrite non-goal(N-of-M bar); 0.212가 partial win | 중 | source-level literal leak 배수 |
| RFC-OAS-034 residual (B4' host→output_schema; B5 discovery inference hard-cut; §5 ratchet) | #2590 supersede; B4' design change 대기; ratchet가 host→capability 재발(#2374/#2408) 방지 | 중 | CI ratchet |
| Lane failure isolation proof (PR-L3) + busy/deferral (PR-L2) | Lane 43%; live health(fibers/paused/ledger)만, UI lane contract 부재 | 중 | Goal 10 |
| Server-side generated Keeper Config field verification (PR-KC1d) | 다음 honest slice 미구축; per-row metadata만(fake-field risk) | 중 | Goal 11 |
| Live async Fusion quorum success + JoJ parity (PR-F2d/PR-F3) | live proof failure-only(panels_unavailable); PR-F3=backend field 대기 | 중 | live server success row |

### 8.3 Low revival

| Idea | 왜 밀렸나 | Blast radius | Revival 조건 |
|------|-----------|--------------|--------------|
| Board admin/janitor resident LLM agent (#64) | MISSING, never started; keeper와 구별되는 resident cleanup agent | 낮음 | 결정 필요 |
| chronicle_librarian Responder + Proactive Summary (RFC-0035 PR-6+) | CHANGELOG "PR-6+ deferred"; PR-5 lib-only slice stalled(false precedent) | 낮음 | half-wired lib 삭제 또는 완성 |
| auto_recall (File_context recall, score-based) | `auto_recall.ml` 모듈은 **HEAD 부재**(문서의 "dead scaffold"보다 강한 형태 — 파일 없음); 과거 hand-tuned float score가 RFC-0247 SSOT와 모순됐던 설계 | 낮음 | RFC-respec만(재도입 시 score 금지) |
| RFC-0314 typed closed 'action' variant | merge 시 scope 축소(Broadcast(label) 하드코딩); RFC Draft | 낮음 | Goal 6 |
| Voice provider freedom (ElevenLabs 외 typed selection) | TODO/P3; voice_bridge 하드코딩 silent Error-swallow | 낮음 | provider 추상화 |
| Repo-mapping UI/policy + GitHub App device flow | 결정 권한과 옵션은 **D2만**. 이 inventory 행은 독립 결정이 아님 | 낮음 | D2 참조 |
| RFC-0303 R2b self-cadence wake-tombstone | 의도적 supersede(Phase2/3 blind cadence 삭제, tombstone input 유실) | 낮음 | design evolution 기록 |
| gRPC transport + LSP subsystem(#70) | hard-cut: exact public/runtime consumer 0이면 삭제. 제품 방향 선택으로 보류하지 않음 | 낮음 | §11 hard-cut 참조 |
| F3 librarian empty root fix | DEMOTE; keeper_memory_os_types.ml:382-388이 이미 persist 전 거부; 재구현 충돌(telemetry-as-fix 회피) | 낮음 | — |
| keeper_turn_driver_backpressure dedup/cooldown 반복가드 | DO-NOT: caller 0 dead module; dedup/cooldown=workaround(DROP); root=재입력 필터 | 낮음 | 금지(guardrail) |
| MASC Interactive Install Wizard | 결정 권한과 옵션은 **D1만**. 이 inventory 행은 독립 결정이 아님 | 낮음 | D1 참조 |
| Multiple Workspaces per Cluster ('frontend-team' 등) | "Future 예정"; Workspace ID 'default' 하드코딩 | 낮음 | — |
| OCaml 5.4 quick wins (Gc.ramp_up 1줄, [@atomic], Iarray, Pqueue) | 권장/Tier-3 미착지 | 낮음 | — |
| Deferred product tracks (package extraction, broad Eio cleanup, cluster mode) | PRODUCT-OPERATING-PLAN "Keep visible, but defer" | 낮음 | — |
| Keeper continuity productization (masc_keeper_msg same-trace) | "If productized" 조건부; long-term memory 약속 금지 | 낮음 | bounded 검증 |
| Original approval-queue-stall problem statement | RFC-0318/0319 rationale; fixed-risk-ladder 철회, 문제 유지 | 낮음 | — |
| Heuristic lexical-similarity memory write-boundary dedup | RFC-0332 REJECTED; 임의 score가 durable memory merge 금지 | 낮음 | 금지(guardrail, 재제안 방지) |
| Preset CRUD from fusion settings UI + per-block comment | RFC-0306 §4/§7 edit-existing-only; per-judge inner comment lost accepted | 낮음 | — |
| Fusion meta-judge graceful-degrade target + markdown vault | RFC-0283 §5.1 open(v1 "first success + warn"); RFC-0247 §3 markdown vault deferred | 낮음 | link-traversing navigator |
| Edge-explosion controls (out-degree cap, weight-floor, GC prune) | RFC-0247 §6/P2a; measured-trigger slice; α>0 opt-in만 | 낮음 | activation fleet opt-in |
| Fusion turn_ref correlation (fusion post ↔ triggering turn) | fusion_sink.ml documented deferral(turn_ref=None) | 낮음 | — |
| Hot Reload / Cluster Mode(Raft) / Chaos Engineering | Phase 3 P2 "later, no estimate"; chaos가 runaway 검증기이나 미착수 | 낮음 | — |
| Health Check System (typed component-criticality, critical death→terminate) | Phase 1.2 sketch; /health + scorer ad-hoc 대체, typed criticality 미구축 | 낮음 | — |
| OAS-side Continue-only budget observation (retain, don't re-add stop-gate) | NOT lost — 의도적 observation-only 유지; MASC가 stop-gate 재추가 금지 | 낮음 | 금지(guardrail) |

### 8.4 감사 파생 / cross-cutting 미착수 축 (2026-07-15 확정, 7-cluster extraction 커버리지 보강)

§8.1-8.3에서 누락됐던 extraction deferred-idea를 보강한다. **각 idea는 revival_value 표기.**

| Idea | 왜 밀렸나 | Blast radius | Revival 조건 | revival_value |
|------|-----------|--------------|--------------|---------------|
| IDE Observation Plane v2 미착수 후속 축 (A4 SSE fan-out · A5 consumer-gate · A6 orphan 파티션 repo 귀속 on bounded-ingestion #23072; C2 latched_reason #23058 · C4·C6 promote Done_action gate + Verification_requested stimulus) | v1 passive projection까지만 배선; 성능/교차 후속 축 corpus 미착수. §3.14 카드·DS-1 goal 신설 | 중(lib/ide/*; raw-wake 불변식) | passive projection 유지 + raw observation의 keeper 직접 wake 금지 확정 후 DS-1 | high |
| Spawned-agent / local-worker schedule tool surfaces (lane ownership contract 뒤 EMPTY by policy) | "lane ownership contract 존재 시에만 노출" 정책 — 그 **계약 자체가 unwritten**인 deferred design prerequisite가 whole surface 차단 | 중(schedule tool-surface policy G4) | lane ownership contract 문서화 후 registry에 surface 추가 | medium |
| Observability integrity — keeper-internal tool 실행 stream 관측 | **[LANDED #23540]** `keeper.tool_exec` emit(`keeper_run_tools_hooks.ml:270`) + `tool_agent_timeline.ml:294-295`가 `tool.called`+`keeper.tool_exec` 소비(문서의 "부재/external-MCP only"는 stale). 잔여=correlation-id dedup exact화 + `~default:"unknown"` 제거 | 중(observability, Goal 12) | correlation-id dedup exact화 | medium |
| Config-ownership canonical read-only snapshot (#3364/#3365/#3363) | config introspection read가 masc_config / /api/v1/dashboard/config에 중복·분산 | 낮음·축복(env_config_introspect.ml/env_config_snapshot.ml) | DS-5 | medium |
| Structured runtime-health probe (boolean resource_check 대체) | Open Structural Gap + Candidate Upstream Work 양쪽 등재; lib 심볼 미확인 | 중(NEEDS_LOCATION) | DS-6, resource_check 사이트 확정 후 | medium |
| Non-local auth hardening + REST/SSE contract versioning + error-shape discipline | Advanced-Path blocker; auth default가 trusted-network 가정 | 높음(credential/identity RFC-gated) | DS-8a | medium |
| Transport/health read-model = reachable runtime state 일치 | Front-Door blocker; multi-transport matrix에서 보고 상태가 실 reachability와 divergence | 중(NEEDS_LOCATION) | DS-8b | medium |
| RFC-0071 §3.4 warning-4 fragile pattern matching (Cat-3 `_ -> default` ~100→<20) | gate-able 목표이나 §4/§8 미등재였음; baseline ~100=est. 실측 필요 | 중(repo-wide, 컴파일러 강제) | DS-7 | medium |
| Token budget drift #22893 (MASC 내부 자원회계 한정) | 진행보고서 인용 타 P0(timeout=∞ #22968, None→fn #22866, pin-drift)는 해소, 실측 OPEN은 이것뿐 | 중(MASC 자원회계; OAS는 이 개념 몰라야 함, 단방향) | #22893 CLOSED, 단방향 유지 | medium |
| F1 content-level 반복 detector (historical) | arbitrary text similarity가 정상 반복을 오판하는 heuristic | 높음·저주(finalize_response.ml/keeper_run_prompt.ml/backend_openai_serialize.ml) | **KILL — revival 금지; DS-2 typed provenance만** | none |
| SSOT audit ~30 findings 재검증·통합 | org spend limit 429로 항목별 검증 미완 | 중 | Goal 2, `rg <값> lib/` count≥2 확인 후 SSOT 상수 추출(이미 통합된 것은 DROP) | medium |

> **커버리지 노트:** §8.1-8.4는 7-cluster extraction의 97개 deferred_lost_idea를 dedup 후 전수 반영한다. OAS 직렬화 5-backend 추출은 §8.1 "drift 결함 3종"에 포함(중복 회피). raw_trace(O 관측) wiring도 §8.1에 존재.

---

<a name="9-anti-patterns-to-refuse"></a>
## 9. Anti-patterns to Refuse

CLAUDE.md 워크어라운드 거부 기준. **코드 작성 *전* self-check.** 해당하면 작성 거부하고 RFC로 escalate. 워크어라운드가 main에 들어가는 순간 AI가 그 패턴을 합리적 선례로 학습해 누적한다.

### 즉시 reject 시그니처 3종

1. **텔레메트리-as-fix (Counter-as-Fix):** PR이 silent failure를 visible로 만들지만 fix 안 함. 신호="make data loss visible", "count drops", "instrument X failure". counter는 alarm이지 fix 아님. → 근본: `Result.t` 반환 + 호출자 처리 강제, append-only WAL, write-time typed schema.
2. **String/Substring 분류기 보강:** typed variant 가능한 자리에 string match 추가/잠금. 신호="literal substring match", "starts_with ~prefix", "drift-guard tests" on substring. → 근본: closed sum type, GADT, exhaustive match.
3. **N-of-M 패치:** "PR #X only fixed M/N sites" 자인. 신호="complete the migration", "finish int->int option", "mirror that PR's one-line activation". → 근본: 변환 함수 추출, type-level invariant(private/phantom type), codemod.

### Symptom 억제 (강한 의심 — Override 조건 필수)

| 패턴 | 신호 | Root |
|------|------|------|
| Cap/Cooldown | "force a turn after the cap", "saturation pre-skip cap" | Backpressure(token bucket/semaphore) |
| Log Dedup/Demote | "1h DEBUG demote of repeated WARN", magic 5.0s dedup window | 반복 자체의 root |
| Fallback Resolution | "Falls back to meta.name when no resolved persona" | typed 분리 필요 |
| Repair/Sanitize | "UTF-8 repair", "JSON normalize on read" | write에서 validate, read에서 reject |

### 머지 거부 체크리스트 (하나라도 해당 → RFC로 흡수)

1. "makes X visible"/"instrument Y"만 (fix 없음)
2. string/substring/prefix 분류기 추가 (제거 아닌 추가)
3. "PR #N only fixed K of M sites" 자인
4. catch-all `_ ->` 추가 (제거 아닌 추가)
5. cap/cooldown/dedup/repair로 symptom 억제 (대체 RFC 링크 없음)
6. test backdoor (`set_X_for_test`/`reset_for_test`) 노출
7. 같은 typo/off-by-one을 N개 site에서 N번 fix (codemod 미수행)

### FSM 특칙

FSM 전이 매트릭스는 `_ -> false` catch-all 금지 — 모든 쌍 명시. OCaml exhaustive match로 새 variant 추가 시 컴파일 타임 누락 감지. 각 쌍에 실행 경로 주석(`via set_turn_*` / `bypassed: direct update in <함수>`).

### Override 조건 (production이 *지금* 깨질 때만)

- PR body에 `WORKAROUND: production-blocking, deprecated path`
- 대체 RFC 번호 명시 (없으면 동시 작성)
- `removal target: <date or RFC merge>` 기록

3-Try Rule과 병행: 동일 영역에서 워크어라운드 시그니처 PR이 2회 등장하면 3회차는 RFC 강제(직접 PR 금지).

### TLA+ Bug Model (상태 머신/동시성 검증)

`BugAction` + `SafetyInvariant` + clean `Next` + `NextBuggy = Next \/ BugAction`. 양쪽 cfg 통과해야 spec 유효(clean=no error, buggy=invariant violated). 예: `specs/keeper-turn-fsm/KeeperTurnFSM.tla`의 `StopSignalSwallowedAsDone` bug action + `StopSignalRespected` invariant(cancel/stop 삼킴 검증; `KeeperTurnFSM.cfg`=Spec/no error, `KeeperTurnFSM-buggy.cfg`=SpecBuggy/invariant violated). (문서가 이전에 참조한 `KeeperOASAdvanced.tla`·`CancelledNeverAbsorbed`는 HEAD 부재.)

---

<a name="10-source-index"></a>
## 10. Evidence Source Index

이 문서를 구성할 때 사용한 evidence/provenance 목록이다. 이 PR은 아래 파일을 archive하거나 OAS upstream 계약을 supersede하지 않는다. MASC 방향이 충돌하면 병합된 RFC-0000의 장기 경계를 따르되, 현재 구현 사실은 코드와 live evidence로 재검증한다.

### Doc-spine (North Star / Boundary / Positioning)
- NORTH-STAR-OCAML.md · OAS-MASC-BOUNDARY.md · MASC-V2-DESIGN.md · **PRODUCT-OPERATING-PLAN.md** *(⚠ STALE worldview: "repo-local … one repository"·"supervised" — RFC-0318/0319/0322/0329/0337/0341이 폐기; §1.1 정본)* · PRODUCT-REVIEW.md · **external-comparison-and-positioning.md** *(⚠ STALE worldview: "operator-governed supervisor"·"supervised cycles not self-driven loops"·"autonomy bounded by phase policy" — 폐기; §1.1/§7 정본)* · VERSIONED-ROADMAP.md *(stale v2.87-v2.93; renumber 필요)* · sdk-independence-principle.md

### Keeper / Runtime / Scheduler
- KEEPER-STATE-OWNERSHIP.md · KEEPER-FILE-MODEL.md · KEEPER-CAPABILITY-MATRIX.md · keeper-turn-lifecycle.md · KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md · KEEPER-SANDBOX-BOUNDARY-POLICY.md · IMMORTAL-SERVER-ROADMAP.md · GOAL-LOOP-RUNTIME-SCHEDULER.md · runtime-tunables.md · SUPERVISOR-MODE.md · Keeper Scheduler _ Waiting Goal Matrix - 2026-07-04.html

### Connector / Board / Fusion / Memory
- CONNECTOR-CONFIG-SCHEMA.md · CONNECTOR-UI-DESIGN.md · DESIGN-RICH-CONNECTOR-RENDERING.md · Keeper Connector-Aware Continuation — Goal Matrix.html (RFC-0320) · RFC-0223-typed-connector-surfaces-presence-pull-speaker.md · RFC-0283-fusion-judge-of-judges.md · RFC-0277-fusion-heterogeneous-panels.md · RFC-0298-fusion-judge-pool.md · RFC-0266-fusion-async-completion-wake-and-visibility.md · RFC-0306-fusion-settings-typed-editor.md · RFC-0037-board-multimedia-vision-adapted.md · 2026-06-24-fusion-dashboard-wiring-rich-text-design.md · RFC-0247-memory-os-associative-graph-forgetting-brain.md · 2026-06-23-what-to-forget-keeper-memory-forgetting-policy.md · RFC-0332-memory-write-boundary-dedup.md (REJECTED)

### Effect permission / Capability / Observability / CI
- CAPABILITY-REGISTRY-SSOT.md · PRODUCTION-READINESS-GATES.md · VERIFICATION-MATRIX.md · verification-pipeline-policy.md · MASC Keeper v2 Dashboard Adversarial Goal Matrix.html · RFC-0318-operator-overlay-llm-approval-resolver.md (Withdrawn) · RFC-0319-operator-approval-mode.md (Withdrawn) · RFC-0305-safety-gate-failclosed-default.md (Withdrawn) · RFC-0311-typed-evidence-gate.md (Withdrawn) · RFC-0337-evidence-gate-semantics.md (Withdrawn) · RFC-0303-stimulus-gated-keeper-wake.md

### OAS 0.212 downstream contract
- README.md · CHANGELOG.md (0.212 #2590/#2592/#2596/#2597/#2602) · RFC-OAS-034-endpoint-capability-boundary.md · RFC-OAS-029-tools-thinking-reasoning-multiturn-standard.md · RFC-OAS-018-provider-model-catalog-externalization.md · RFC-OAS-035-openai-compat-thinking-token-and-empty-completion-failclose.md · runtime-continuation-boundaries.md · RFC-canonical-tool-contract.md (RFC-OAS-024) · api-stability.md · agent.mli · hooks.mli · durable_event.mli · checkpoint.mli

### Orthogonality / Blast-radius method
- masc-oas-anthropic-tools-orthogonal-blastradius-2026-07-04.html · MASC Keeper Degenerate Repetition — 원인 규명 · Blast Radius · 목표 설계도.html · masc-oas-adversarial-distillation.html

### Aggregator matrices
- MASC 70-Goal Matrix — 잔여 작업 감사 및 실행 보드.html · MASC × OAS Durable Intelligence Matrix — 2026-07-11.html · MASC 기능 지도 — 의도 vs 구현 Gap (2026-07-11).html · MASC · OAS 완성도 감사 — 남은 작업 콘솔.html · MASC_OAS 48시간 병합 감사.html · MASC_OAS Resilience & Concurrency — 48h Implementation Spec.html

### Direction audit
- direction-audit-w1x2k66z2 (6 silent regression: #24417/#24386/#24448/#24510/#24442/#24447 → §2.5)

---

<a name="11-open-decisions-ledger"></a>
## 11. Open Decisions Ledger (NEEDS_DECISION)

§8.3에 흩어져 있던 미결 항목을 **운영자가 실제로 결정할 수 있는 단일 목록**으로 모은다. 이들은 코드 버그가 아니라 **방향 결정**이 필요한 항목 — 결정 없이 착수 금지. 각 항목: 결정 필요 사항 / 옵션 / 결정 시 blast-radius.

| # | 결정 필요 사항 | 옵션 | 결정 시 blast-radius | 출처 |
|---|----------------|------|----------------------|------|
| **D1** | MASC Interactive Install Wizard 를 만들 것인가 | (a) wizard 구축 (b) 무기한 defer (c) drop | 낮음 — dashboard onboarding surface 신규, runtime 코드 무변 | §8.3 |
| **D2** | existing multi-repo substrate와 별개인 keeper-repo-mapping UI/policy layer를 유지할 것인가 + plain-text credential 입력을 GitHub App device flow로 대체할 것인가 | (a) typed device flow로 유지 (b) UI/policy layer 제거; plain-text 현상 유지는 선택지 아님 | **높음** — credential/identity RFC-gated(`lib/keeper/credential_*`·`lib/repo_manager/`) | RFC-0322/#23662, §8.3 |
| **D4** | Product Portfolio Trim — 실험 카테고리 TRPG/Voice/MDAL/RISC 각각 keep/graduate/archive | 각 track별 (a) keep (b) graduate(Tier-2) (c) archive | 중 — roadmap 재번호(VERSIONED-ROADMAP v2.87-v2.93 stale) 선행 시 orphan 해소; Milestone 6 frozen legacy counter | VERSIONED-ROADMAP, §8.2 |
| **D5** | Board karma 의 post-vote public visibility (표결 후 karma 공개 여부) | (a) 공개 (b) 비공개 (c) operator-only. hot/confidence/karma quality-score ranking은 KILL이며 선택지 아님 | 중 — `lib/board/board_votes.ml`; Board+Dashboard 결합 | #58, #23933, §8.2 |
| **D6** | RFC-0037 Board multimedia/vision 의 4 user open-question(§6) 해소 — Phase A0 PR 착수 전 필수 | 4개 질문 각각 답(provider_adapter 확장 범위/vision 커밋/frontend ergonomics 순서/cloud storage) | 중 — provider_adapter 확장; Board multimedia; Phase B vision commitment은 PR-time Evidence Record | RFC-0037, §8.2 |

> 이 ledger의 항목은 §4 goal이 아니다 — 결정 전까지 구현 goal로 승격 금지. 결정되면 해당 행을 §4(신규 goal) 또는 §8(revival) 또는 Non-Goal(§1.3)로 이동하고 이 ledger에서 제거한다.

**Hard-cut으로 이미 결정된 항목:** legacy schedule row는 drop하며 backfill/migration을 만들지 않는다(구 D3). gRPC/LSP는 exact public/runtime consumer가 없으면 삭제한다(구 D7); caller-0 dead code는 제품 방향 결정 대상이 아니다.

---

*RFC-0000 끝. 장기 경계 변경은 이 문서를 개정하고, 현재 구현·pin·PR·CI·live 상태는 각 정본에서 확인한다.*
