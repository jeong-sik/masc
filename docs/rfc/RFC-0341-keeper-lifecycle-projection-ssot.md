# RFC-0341: Keeper lifecycle projection SSOT — Stop/Latch 분리와 단일 배지 소스

- Status: Draft
- Author: Claude (70-bug campaign G02 — bugs #40/#41/#42, issue #24037)
- Date: 2026-07-11
- Related: #23918 (typed run_state, landed), RFC-0336 (in-flight registry), issue #24037, workflow wf_e047f03f 진단 (적대검증 CONFIRMED)
- Source baseline: `masc/main@2aee03b53bca298e8e703e0d25144e6aab9dc18a`

## 결정

Keeper 생명주기의 사용자 관측면을 **단일 닫힌 projection** 하나로 교체한다. 백엔드 FSM(13-phase, closed transition matrix)은 이미 올바르다 — 문제 전부가 projection/배선 층에 있으므로, FSM은 건드리지 않고 그 위의 wire 축 ~8개와 FE 파생기 6개를 철거한다.

핵심 결정 3개:

1. **`meta.paused` boolean을 해체한다.** 현재 3가지 의미(operator pause / auto-pause 안전 래치 / shutdown-pin)를 겸직하는 이 플래그를 typed 2필드로 분리한다:
   - `latch : { reason : Keeper_latched_reason.t; actor; at } option` — 자동 생산자 전용 (no_progress_loop, compact_retry_exhausted, livelock, supervisor). **operator는 latch를 만들 수 없다.**
   - `autoboot : bool` — shutdown pin의 유일한 승계자 (autoboot 제외 판정 전용).
2. **"종료"를 진짜 Stop으로 만든다.** 현재 dashboard shutdown은 `meta.paused=true` + FSM `Operator_pause`를 실행한다 (`keeper_turn_lifecycle.ml:57-104` retain 분기, `server_dashboard_http_keeper_api_lifecycle_post.ml:392-397`의 `persist_keeper_paused_state true` 후처리). FSM에 이미 존재하는 `Operator_stop` → `Draining` → `Stopped` 경로를 배선하고, pause-pin 후처리를 삭제한다.
3. **operator pause를 사용자 액션에서 제거한다.** 프로젝트 원칙("Pause는 진짜 아주 망가진 것 이외에는 하면 안 됨") 위반의 근원. `Paused` FSM phase는 자동 안전 래치(quarantine) 전용으로 남기고, 사용자에게는 latch가 있을 때만 보이는 `Release_latch(해제)` 단일 액션을 준다.

## 현재 구현에서 확인한 사실 (라이브 실측 + 코드 인용, wf_e047f03f)

- `lib/keeper/keeper_turn_lifecycle.ml:57` — dashboard shutdown(`masc_keeper_down`, remove_meta=false)이 pause로 구현됨: `meta.paused=true` + `latched_reason=Operator_paused` 기록 후 `Keeper_state_machine.Operator_pause` 디스패치(:104). `Operator_stop`은 결코 발화하지 않는다.
- `lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml:392` — HTTP shutdown 성공 후처리가 `persist_keeper_paused_state true`. FE의 paused-우선 파생 때문에 **종료된 keeper가 '일시정지'로 렌더**되고 재개+기동 버튼이 동시에 노출된다. resume이 stopped keeper를 boot한다(`ensure_registered_for_resume`) — resume ≈ boot의 물증.
- `lib/keeper/keeper_keepalive.ml:429` — wakeup directive가 (a) idle 턴 킥, (b) paused 자동 해제("Treat wakeup as a superset of resume"), (c) no_progress/livelock 래치 클리어 — 3의미 겸직. `process_directive`는 string match이고 unknown directive는 "logged and ignored" (silent 분기).
- `dashboard/src/lib/keeper-predicates.ts:47` — `isKeeperPaused`가 **6개 축을 OR** (paused, lifecycle_phase, phase, pipeline_stage, pause_state, status). `keeperCanWakeup`(:162)은 상수 true로 퇴화 — 실행 중 keeper에도 깨움 버튼이 뜨는 #40의 직접 원인 (자기 문서화 주석 :155-161).
- `dashboard/src/store.ts:143` — directive 하나의 낙관적 반영에 **5개 병렬 필드**(paused, phase, lifecycle_phase, pipeline_stage, status)를 써야 함 — 단일 배지 소스 부재의 물증.
- `dashboard/src/lib/keeper-runtime-display.ts:266,418-457` — 배지가 휴리스틱 파생: heartbeat 120s 임계, `generation>0||turn_count>0 ⇒ 'stopped'`, `isKeeperAutoRecoverPause`(:350)는 에러 문자열 substring('timeout','dns','tls')로 pause 원인 분류 — no-heuristics/no-string-classifier 기준 위반.
- `dashboard/src/keeper-store-normalize.ts:237` — `deriveLifecycleState`는 4번째 병렬 projection: metrics_series context-ratio 임계로 active/preparing/compacting을 발명, 시리즈가 비면 'idle' — Running vs Idle이 **metrics 존재 여부**로 결정된다.
- `dashboard/src/components/agent-roster.ts:262` — #23918의 typed `run_state`(In_turn|Waiting|Suspended)는 rosterPresenceDisplay **한 곳만** 소비. keeperDisplayStatus, deriveLifecycleState, monitoring-runtime band, keeper-detail 배지는 전부 무시.
- `dashboard/src/types/core.ts:1158` — `KEEPER_AUTOBOOT_EXCLUSION_REASONS`에 'paused' 포함 = paused의 3번째 의미(shutdown-pin). boot가 `resume_booted_keeper_if_needed`로 un-pause를 실행해야 하는 이유(lifecycle_post.ml:213-247).
- `lib/keeper_registry/keeper_state_machine_types.ml:105,294-419` — FSM 어휘는 이미 완비: `Operator_pause`/`Operator_resume`/`Operator_stop{remove_meta}`, `Draining→Stopped`, closed transition matrix. **비일관성은 전적으로 projection 층이다.**
- `dashboard/src/components/keeper-detail-lifecycle.ts:16` — detail 페이지는 roster와 또 다른 inline predicate 쌍 사용 (keeper-predicates.ts:128이 이미 'strict-subset duplication'으로 retired 선언한 `isOfflineStatus` + UI 전용 'working' 리터럴 배열) — 표면 간 버튼 가시성 불일치 가능.

## 설계

### 1. 백엔드 SSOT: `lib/keeper_registry/keeper_lifecycle_view.ml` (신규)

```ocaml
type lifecycle_view =
  | Offline                                   (* registry 미등록/프로세스 없음 *)
  | Stopped of { autoboot_pinned : bool }     (* Operator_stop 후. 데이터 보존 *)
  | Booting
  | Running of Run_state.t                    (* In_turn | Waiting | Suspended — #23918 재사용 *)
  | Latched of Keeper_latched_reason.t        (* 자동 안전 래치. operator 생산 불가 *)
  | Stopping                                  (* Draining *)

type action = Boot | Stop | Delete | Kick | Release_latch

val view : phase:Keeper_state_machine.phase -> run_state:Run_state.t option
  -> latch:latch option -> lifecycle_view
val allowed_actions : lifecycle_view -> action list  (* FSM matrix에서 파생 *)
```

- **단일 계산 지점.** keeper row·composite snapshot에 `lifecycle` object 하나로 방출.
- `allowed_actions`가 버튼 가시성의 유일한 소스 — FE는 판정하지 않고 렌더만 한다.
- `Kick`은 `Running Waiting`에서만 허용. 그 외에는 typed error로 거부(표면화) — silent no-op 금지.

### 2. 액션 시맨틱 재정의 (kill/keep 판정)

| 액션 | 판정 | 새 시맨틱 |
|---|---|---|
| 깨움(Kick) | KEEP·1의미 | "다음 턴 지금 킥". `Waiting`에서만. auto-resume/latch-clear 부수효과 삭제 |
| 종료(Stop) | KEEP·수리 | `Operator_stop` → Draining → Stopped + `autoboot=false` pin. pause 경유 금지 |
| 삭제(Delete) | KEEP·신규 노출 | `remove_meta=true`는 이미 존재(MCP 전용) — UI에 위험 버튼으로 노출해 종료/삭제 모호성 제거 |
| 일시정지(Pause) | **KILL** | 사용자 액션에서 제거. bulk pause/resume 포함. `Paused` phase는 자동 래치 전용 |
| 재개(Resume) | **KILL** | latched → `Release_latch`, stopped → `Boot`로 흡수 (오늘 이미 resume≈boot) |
| 기동(Boot) | KEEP | 무변경 |

- `process_directive`의 string match를 closed action variant로 교체. unknown = typed error (log-and-ignore 삭제).
- 신규 endpoint `POST /api/v1/keepers/:name/lifecycle {action}` 가 `/directive`·`/boot`·`/shutdown` 3개를 대체(삭제).

### 3. FE 컷오버 + 철거 목록

- 배지: 신규 `keeper-lifecycle-badge.ts` 하나가 closed union → label/tone 매핑. `Running Waiting`='대기', `Running (In_turn ...)`='실행중 · <wake_reason>' — Running vs Idle이 **모든 표면**에서 구분된다(#40 해소).
- 버튼: `allowed_actions`를 그대로 렌더.
- 낙관 반영: 단일 `lifecycle` 필드 patch (store.ts 5-필드 patch 삭제).
- **삭제 (전부 잔존 참조 0 증명 후):** keeper-predicates.ts OR-체인 일체(isKeeperPaused/isKeeperOffline/RUNNING_STATUS_TOKENS/keeperCanWakeup/keeperActionVisibility), keeperDisplayStatus+refineOfflineStatus 휴리스틱, isKeeperAutoRecoverPause string 분류기, deriveLifecycleState metrics 휴리스틱, keeper-classifiers isOfflineStatus, keeper-detail-lifecycle inline 체인, store.ts patchForDirective, pause/resume 버튼+bulk, monitoring-runtime 이중 PHASE_LABELS.

### 4. Wire 정리

- status bridge에서 `pause_state`, `lifecycle_phase`(phase 중복), `paused` boolean 방출 중단, `Keeper` 타입에서 제거.
- TLA+ bug model (software-development.md 패턴): `BugAction` = shutdown이 latch를 기록; `Invariant` = `Stopped ⇒ latch = None`. clean spec pass + buggy spec violate 쌍으로 Stop/Latch 분리를 기계 검증.

## 마이그레이션 (PR 3개)

1. **PR-1 백엔드**: `keeper_lifecycle_view` + paused 해체(latch/autoboot) + shutdown→Operator_stop + wakeup 부수효과 삭제 + `/lifecycle` endpoint + 구 3 endpoint 삭제. 영속 meta의 기존 `paused=true` 데이터는 부팅 시 1회 재분류: latched_reason이 auto-생산자면 `latch`, 아니면(operator/shutdown 계열) `Stopped+autoboot pin` — keeper_meta_canonicalize(#23982) 선례의 명시 목록 방식.
2. **PR-2 대시보드**: badge/버튼/patch 컷오버 + 파생기 철거.
3. **PR-3 wire 정리 + TLA+**: 중복 축 방출 중단 + bug-model 쌍.

## 완료 기준 (기계 판정, Goal Matrix G02)

- 깨움/종료/일시정지 = typed 상태전이 (catch-all 0, `rg "logged and ignored" lib/keeper/keeper_keepalive.ml` = 0)
- '실행중'과 'Idle'이 모든 표면에서 구분 (lifecycle_view 소비처 grep = 배지 컴포넌트 1곳)
- `rg "isKeeperPaused|keeperCanWakeup|deriveLifecycleState|isKeeperAutoRecoverPause" dashboard/src` = 0 hits
- `meta.paused` 필드 wire 방출 0 · FSM `Operator_stop` 디스패치 ≥1 (shutdown 경로 테스트)
- TLA+ clean/buggy 쌍 both-pass

## 기각한 대안

- **paused 의미별 enum 확장 (`paused_kind : Operator|Auto|Shutdown`)**: 한 필드의 겸직을 유지한 채 라벨만 늘림 — FE 6-축 OR 파생이 그대로 남는다. 근본은 필드가 아니라 projection 부재.
- **FE만 수리 (배지 통합, 백엔드 유지)**: `store.ts` 5-필드 patch가 증명하듯 wire 축이 8개인 한 FE 단일화는 불가능한 발명(파생 휴리스틱)을 다시 요구한다.
- **`/directive` 유지 + 신 action 추가**: string directive 채널의 "unknown = log-and-ignore" silent 분기를 존속시킴 — Silent Failure 금지 위반.

## 충돌/조정

- **#24014 (HTTP session/auth 대형)**: `/boot`·`/shutdown`·`/directive` 라우트의 auth wrapper를 건드림 — endpoint 통합은 그 PR 랜딩 후 rebase로 조정 (PR-1 착수 gate).
- #23918 run_state는 이 설계의 기반(랜딩 완료). #23982 meta canonicalize는 마이그레이션 재분류의 선례.
