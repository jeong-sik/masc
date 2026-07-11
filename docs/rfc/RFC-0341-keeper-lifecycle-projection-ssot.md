# RFC-0341: Keeper lifecycle projection SSOT — Stop/Latch 분리와 단일 배지 소스

- Status: Draft
- Author: Claude (70-bug campaign G02 — bugs #40/#41/#42, issue #24037)
- Date: 2026-07-11
- Related: #23918 (typed run_state, landed), RFC-0336 (in-flight registry), issue #24037, #24039 (dashboard auth contract), workflow wf_e047f03f 진단 (적대검증 CONFIRMED)
- Source baseline: `masc/main@2aee03b53bca298e8e703e0d25144e6aab9dc18a`

## 결정

Keeper 생명주기의 사용자 관측면을 **단일 닫힌 projection** 하나로 교체한다. 기존 FSM의 13-phase 어휘와 exhaustive matrix 구조는 재사용하되, 현재 lifecycle은 end-to-end로 건강하지 않으며 matrix/event set도 불변으로 간주하지 않는다. shutdown command가 `Operator_stop`을 통하지 않고 keepalive 부수효과를 먼저 실행한 뒤 terminal phase에 `Operator_pause`를 보내기 때문이다. 따라서 범위는 projection만이 아니라 **typed command orchestration → FSM event → keepalive completion → persistence → projection** 경계까지 포함한다. wire 축 ~8개와 FE 파생기 6개는 새 경계로 컷오버한 뒤 철거한다.

핵심 결정 3개:

1. **`meta.paused` boolean을 해체한다.** 현재 3가지 의미(operator pause / auto-pause 안전 래치 / shutdown-pin)를 겸직하는 이 플래그를 두 typed 축으로 분리한다:
   - `latch : Keeper_latch.t option` — reason/producer/at을 담는 명명된 record. 자동 생산자 전용이며 **operator는 latch를 만들 수 없다.**
   - `activation : Keeper_activation.t` — `Enabled of Keeper_start_policy.t | Operator_stopped of { resume_policy; actor; at } | Dead_tombstone`의 닫힌 합. `Keeper_start_policy.t = Auto_start | Manual_start`이며 raw autoboot boolean truth table을 내부로 전파하지 않는다. stop 여부와 stop 해제 뒤 복원할 start policy를 한 constructor가 함께 보존한다.
2. **"종료"를 진짜 Stop으로 만든다.** 현재 dashboard shutdown은 먼저 `stop_keepalive`를 호출해 `Stop_requested` + `Drain_complete`와 fiber-stop/gRPC-close 부수효과를 실행하고, retain 분기에서 다시 `meta.paused=true`를 저장한 뒤 terminal `Stopped`에 `Operator_pause`를 시도한다 (`keeper_turn_lifecycle.ml:37,68-104`, `keeper_keepalive.ml:712-735,1002-1036`). HTTP 후처리도 다시 `persist_keeper_paused_state true`를 수행한다 (`server_dashboard_http_keeper_api_lifecycle_post.ml:392-397`). 이를 단일 typed stop orchestrator가 `Operator_stop` → `Draining` → cooperative keepalive stop → `Drain_complete` → `Stopped` 순서로 소유하도록 바꾸고, pause-pin 후처리와 keepalive의 선행 상태전이를 삭제한다.
3. **operator pause를 사용자 액션과 FSM 어휘에서 제거한다.** 프로젝트 원칙("Pause는 진짜 아주 망가진 것 이외에는 하면 안 됨") 위반의 근원. `operator_paused` condition과 `Operator_pause`/`Operator_resume` event를 typed `Latch_engaged of Keeper_latch.t`/`Latch_released`로 교체한다. `Paused` phase는 자동 안전 래치(quarantine) 전용으로 남기고, 사용자에게는 latch가 있을 때만 보이는 `Release_latch(해제)` 단일 액션을 준다.

## 현재 구현에서 확인한 사실 (라이브 실측 + 코드 인용, wf_e047f03f)

- `lib/keeper/keeper_turn_lifecycle.ml:37,68-104` — dashboard shutdown(`masc_keeper_down`, remove_meta=false)은 `stop_keepalive`를 먼저 호출한 후 `meta.paused=true` + `latched_reason=Operator_paused`를 기록하고 `Operator_pause`를 디스패치한다. `lib/keeper/keeper_keepalive.ml:712-735,1002-1036`의 선행 호출은 이미 `Stop_requested` + `Drain_complete`를 디스패치하고 done promise/fiber-stop/gRPC-close를 변경한다. 그 뒤 `Stopped`에 도착한 `Operator_pause`는 terminal-state rejection이며 `dispatch_event_unit`은 이를 로그만 남기므로, 문제는 projection뿐 아니라 잘못된 event ownership과 side-effect ordering에도 있다. `Operator_stop`은 이 경로에서 발화하지 않는다.
- `lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml:392` — HTTP shutdown 성공 후처리가 다시 `persist_keeper_paused_state true`를 실행한다. FE의 paused-우선 파생 때문에 **종료된 keeper가 '일시정지'로 렌더**되고 재개+기동 버튼이 동시에 노출된다. resume이 registry 부재를 boot로 보충한다(`server_dashboard_http_keeper_api_post.ml:1048-1065`) — resume ≈ boot의 물증.
- `lib/keeper/keeper_keepalive.ml:429` — wakeup directive가 (a) idle 턴 킥, (b) paused 자동 해제("Treat wakeup as a superset of resume"), (c) no_progress/livelock 래치 클리어 — 3의미 겸직. `process_directive`는 string match이고 unknown directive는 "logged and ignored" (silent 분기).
- `dashboard/src/lib/keeper-predicates.ts:47` — `isKeeperPaused`가 **6개 축을 OR** (paused, lifecycle_phase, phase, pipeline_stage, pause_state, status). `keeperCanWakeup`(:162)은 상수 true로 퇴화 — 실행 중 keeper에도 깨움 버튼이 뜨는 #40의 직접 원인 (자기 문서화 주석 :155-161).
- `dashboard/src/store.ts:143` — directive 하나의 낙관적 반영에 **5개 병렬 필드**(paused, phase, lifecycle_phase, pipeline_stage, status)를 써야 함 — 단일 배지 소스 부재의 물증.
- `dashboard/src/lib/keeper-runtime-display.ts:266,418-457` — 배지가 휴리스틱 파생: heartbeat 120s 임계, `generation>0||turn_count>0 ⇒ 'stopped'`, `isKeeperAutoRecoverPause`(:350)는 에러 문자열 substring('timeout','dns','tls')로 pause 원인 분류 — no-heuristics/no-string-classifier 기준 위반.
- `dashboard/src/keeper-store-normalize.ts:237` — `deriveLifecycleState`는 4번째 병렬 projection: metrics_series context-ratio 임계로 active/preparing/compacting을 발명, 시리즈가 비면 'idle' — Running vs Idle이 **metrics 존재 여부**로 결정된다.
- `dashboard/src/components/agent-roster.ts:262` — #23918의 typed `run_state`(In_turn|Waiting|Suspended)는 rosterPresenceDisplay **한 곳만** 소비. keeperDisplayStatus, deriveLifecycleState, monitoring-runtime band, keeper-detail 배지는 전부 무시.
- `dashboard/src/types/core.ts:1158` — `KEEPER_AUTOBOOT_EXCLUSION_REASONS`에 'paused' 포함 = paused의 3번째 의미(shutdown-pin). boot가 `resume_booted_keeper_if_needed`로 un-pause를 실행해야 하는 이유(lifecycle_post.ml:213-247).
- `lib/keeper_registry/keeper_state_machine_types.ml:105-119,294-419` — FSM 어휘에는 `Operator_stop{remove_meta}`, `Draining→Stopped`와 closed transition matrix가 이미 있다. 그러나 `lib/keeper/keeper_registry_entry_action_dispatch.ml:38-46`에서 `Start_drain`/`Cleanup_and_unregister`는 현재 operational no-op이고, 실제 stop은 keepalive가 `Stop_requested`/`Drain_complete`를 직접 합성한다. 따라서 matrix는 재사용 가능하지만 lifecycle command/FSM/keepalive 통합은 수리 대상이다.
- `dashboard/src/components/keeper-detail-lifecycle.ts:16` — detail 페이지는 roster와 또 다른 inline predicate 쌍 사용 (keeper-predicates.ts:128이 이미 'strict-subset duplication'으로 retired 선언한 `isOfflineStatus` + UI 전용 'working' 리터럴 배열) — 표면 간 버튼 가시성 불일치 가능.

## 설계

### 1. 백엔드 SSOT: `lib/keeper_registry/keeper_lifecycle_view.ml` (신규)

```ocaml
module Keeper_start_policy : sig
  type t = Auto_start | Manual_start
end

module Keeper_activation : sig
  type t =
    | Enabled of Keeper_start_policy.t
    | Operator_stopped of
        { resume_policy : Keeper_start_policy.t
        ; actor : Keeper_operator_actor.t
        ; at : string
        }
    | Dead_tombstone
end

type keeper_definition =
  | Missing
  | Persisted of Keeper_activation.t

type offline_definition = Undefined | Defined of Keeper_start_policy.t

type recovery_view =
  | Health_failing
  | Context_overflow
  | Compacting
  | Handing_off
  | Crashed
  | Restarting

type terminal_view = Dead_terminal | Zombie_terminal | Dead_tombstone_terminal

type lifecycle_input =
  | Registration_absent of keeper_definition
  | Registration_present of
      { phase : Keeper_state_machine.phase
      ; run_state : Run_state.t option
      ; latch : Keeper_latch.t option
      ; activation : Keeper_activation.t
      }

type lifecycle_view =
  | Offline of offline_definition             (* registry 부재, stop/dead intent 없음 *)
  | Stopped of { resume_policy : Keeper_start_policy.t }
  | Booting                                   (* registered phase Offline/Restarting *)
  | Running of Run_state.t                    (* In_turn | Waiting | Suspended — #23918 재사용 *)
  | Latched of Keeper_latch.t                 (* 자동 안전 래치. operator 생산 불가 *)
  | Stopping                                  (* Draining *)
  | Recovering of recovery_view
  | Terminal of terminal_view

type projection_error =
  | Missing_run_state
  | Phase_latch_mismatch of Keeper_state_machine.phase
  | Phase_activation_mismatch of Keeper_state_machine.phase

type action = Boot | Stop | Delete | Kick | Release_latch

val view : lifecycle_input -> (lifecycle_view, projection_error) result
val allowed_actions : lifecycle_view -> action list
```

- **단일 계산 지점.** keeper row·composite snapshot에 `lifecycle` object 하나로 방출. Registry에 entry가 없으면 phase 자체가 없으므로, `Registration_absent`가 typed input이어야 `Offline` 또는 persisted `Stopped`/`Terminal Dead_tombstone_terminal`을 만들 수 있다. 반대로 registry의 FSM `Offline`은 pre-start registration이므로 `Booting`으로 projection한다. 13개 phase는 `Running`/`Latched`/`Stopping`/`Recovering`/`Terminal`에 exhaustive mapping하며, 서로 모순되는 phase/latch/activation 조합은 `projection_error`로 표면화하고 임의 fallback label을 만들지 않는다.
- `allowed_actions`가 버튼 가시성의 유일한 소스 — FE는 판정하지 않고 렌더만 한다. 단, 이를 “FSM matrix에서 전부 파생”한다고 주장하지 않는다. Stop/Release_latch는 FSM transition과 대조하고, Boot/Kick/Delete는 registration·run-state·resource precondition을 포함한 exhaustive backend policy로 정의한다.
- `Kick`은 `Running Waiting`에서만 허용. 그 외에는 typed error로 거부(표면화) — silent no-op 금지.

[근거] [OCaml 5.4 type declarations](https://ocaml.org/manual/5.4/typedecl.html) — record/variant는 명명된 type declaration으로 두고 closed variant를 exhaustive match하는 API 형태 확인, 2026-07-11 KST, 신뢰도 High.

### 2. 액션 시맨틱 재정의 (kill/keep 판정)

| 액션 | 판정 | 새 시맨틱 |
|---|---|---|
| 깨움(Kick) | KEEP·1의미 | "다음 턴 지금 킥". `Waiting`에서만. auto-resume/latch-clear 부수효과 삭제 |
| 종료(Stop) | KEEP·수리 | `Operator_stop` → Draining → Stopped + `activation=Operator_stopped {resume_policy; ...}`. pause 경유 금지 |
| 삭제(Delete) | KEEP·신규 노출 | `remove_meta=true`는 이미 존재(MCP 전용) — UI에 위험 버튼으로 노출해 종료/삭제 모호성 제거 |
| 일시정지(Pause) | **KILL** | 사용자 액션에서 제거. bulk pause/resume 포함. `Paused` phase는 자동 래치 전용 |
| 재개(Resume) | **KILL** | latched → `Release_latch`, stopped → `Boot`로 흡수 (오늘 이미 resume≈boot) |
| 기동(Boot) | KEEP | explicit start. `Operator_stopped`를 `Enabled resume_policy`로 바꾼 뒤 현재 1회 기동 |

- Stop의 순서는 하나의 orchestrator가 소유한다: durable desired activation `Operator_stopped` 저장 → `Operator_stop` 디스패치 → `Start_drain` entry action이 cooperative fiber-stop/gRPC-close 요청 → loop 종료자가 `Drain_complete` 디스패치. activation은 desired state이므로 phase가 아직 terminal이 아니면 projection은 `Stopping`이며 reconciler가 같은 command id로 수렴을 재시도한다. `stop_keepalive`는 더 이상 `Stop_requested`/`Drain_complete`를 합성하지 않으며, 각 단계 실패는 typed stage error와 idempotent receipt로 반환한다.
- JSON/gRPC의 action 문자열은 transport boundary decoder가 **정확히 한 번** closed variant로 바꾼다. 예: `Keeper_lifecycle_action.of_yojson : Yojson.Safe.t -> (action, lifecycle_error) result`, `Keeper_directive.of_wire : string -> (Keeper_directive.t, directive_error) result`. 내부 handler와 `process_directive`는 string이 아니라 variant만 받고, claim payload도 `Claim of Keeper_id.Task_id.t`로 전달한다. unknown wire는 typed 4xx/error receipt이며 log-and-ignore와 내부 `String.equal`/prefix match는 0이다.
- 신규 endpoint `POST /api/v1/keepers/:name/lifecycle {action}`가 최종적으로 `/directive`·`/boot`·`/shutdown` 3개를 대체한다. 구 route 삭제는 신규 endpoint와 dashboard 소비자가 같은 change-set에서 연결된 뒤 수행해 중간 broken deployment를 만들지 않는다.

### 3. FE 컷오버 + 철거 목록

- 배지: 신규 `keeper-lifecycle-badge.ts` 하나가 closed union → label/tone 매핑. `Running Waiting`='대기', `Running (In_turn ...)`='실행중 · <wake_reason>' — Running vs Idle이 **모든 표면**에서 구분된다(#40 해소).
- 버튼: `allowed_actions`를 그대로 렌더.
- 낙관 반영: 단일 `lifecycle` 필드 patch (store.ts 5-필드 patch 삭제).
- **삭제 (전부 잔존 참조 0 증명 후):** keeper-predicates.ts OR-체인 일체(isKeeperPaused/isKeeperOffline/RUNNING_STATUS_TOKENS/keeperCanWakeup/keeperActionVisibility), keeperDisplayStatus+refineOfflineStatus 휴리스틱, isKeeperAutoRecoverPause string 분류기, deriveLifecycleState metrics 휴리스틱, keeper-classifiers isOfflineStatus, keeper-detail-lifecycle inline 체인, store.ts patchForDirective, pause/resume 버튼+bulk, monitoring-runtime 이중 PHASE_LABELS.

### 4. Wire 정리

- status bridge에서 `pause_state`, `lifecycle_phase`(phase 중복), `paused` boolean 방출 중단, `Keeper` 타입에서 제거.
- TLA+ bug model (software-development.md 패턴): `BugAction` = shutdown이 latch를 기록; `Invariant` = `Stopped ⇒ latch = None`. clean spec pass + buggy spec violate 쌍으로 Stop/Latch 분리를 기계 검증.

## 마이그레이션 (PR 3개)

영속 meta는 versioned decoder에서 아래 표대로 **typed constructor를 exhaustive match**해 canonicalize한다. `autoboot_enabled=true|false`는 각각 `Auto_start|Manual_start`로 기계 변환하며 reason wire 문자열을 재분류하지 않는다. `Operator_stopped` 자체가 autoboot를 막고, explicit Boot 때만 보존된 `resume_policy`를 `Enabled`로 복원한다.

| legacy `paused` | legacy `latched_reason` | canonical 결과 |
|---|---|---|
| `false` | `None` | `latch=None`; `activation=Enabled(decoded_start_policy)` |
| `true` | `Some` auto reason (`No_progress_loop`, `Completion_contract_violation`, `Idle_detected`, `Runtime_exhausted`, `Turn_budget_exhausted`, `Stale_storm`, `Provider_timeout_loop`) | 동일 typed reason의 `latch=Some`; `activation=Enabled(decoded_start_policy)` |
| `true` | `Some (Operator_paused _)` | `latch=None`; `activation=Operator_stopped {resume_policy=decoded_start_policy; ...}` |
| `true` | `Some Dead_tombstone` | `latch=None`; `activation=Dead_tombstone` — `Stopped`로 완화하지 않음 |
| `true` | `None` | `latch=None`; `activation=Operator_stopped {resume_policy=decoded_start_policy; ...}`; audit=`Legacy_paused_without_reason` (정보가 없으므로 추정하지 않는 명시 정책) |
| `false` | `Some _` | `Error (Inconsistent_legacy_pause ...)`; 해당 keeper만 autoboot 제외하고 operator remediation을 표면화 |

현재 `compact_retry_exhausted`는 FSM condition/event에는 있지만 persisted `Keeper_latched_reason.t` constructor에는 없다. 이를 legacy 문자열에서 추론하지 않고, 새 producer가 `Latch_engaged (Compact_retry_exhausted {...})`를 만들 때부터 typed latch로 기록한다.

새 `Keeper_latched_reason.t` constructor가 추가되면 이 match가 컴파일 실패해야 한다. canonical schema version을 meta에 기록해 재시작마다 재분류하지 않으며, 한 keeper의 migration error가 fleet 전체를 멈추지 않는다.

1. **PR-1 백엔드 도메인**: `Keeper_start_policy`/`Keeper_activation`/`Keeper_latch`/`keeper_lifecycle_view` + versioned migration + typed stop orchestrator + wakeup 부수효과 삭제. 신규 `/lifecycle` endpoint를 typed decoder/`CanAdmin` auth 뒤에 추가하되 구 route는 중복 로직 없이 같은 typed command를 호출하는 임시 adapter로만 둔다. PR-1/PR-2 사이 release는 하지 않는다.
2. **PR-2 atomic cutover**: dashboard badge/버튼/patch를 신규 projection/endpoint로 교체하고, 같은 change-set에서 `/directive`·`/boot`·`/shutdown`, bulk pause/resume, 임시 adapter와 FE 파생기를 삭제한다.
3. **PR-3 wire 정리 + TLA+**: 중복 축 방출 중단 + bug-model 쌍.

## 완료 기준 (기계 판정, Goal Matrix G02)

- Kick/Stop/Release_latch = typed command/result (transport decoder 외 action string match 0, catch-all 0, `rg "logged and ignored" lib/keeper/keeper_keepalive.ml` = 0)
- '실행중'과 'Idle'이 모든 표면에서 구분 (lifecycle_view 소비처 grep = 배지 컴포넌트 1곳)
- `rg "isKeeperPaused|keeperCanWakeup|deriveLifecycleState|isKeeperAutoRecoverPause" dashboard/src` = 0 hits
- `meta.paused`/raw autoboot boolean 내부 소비 0 · shutdown 경로는 `Operator_stop` 1회, `Drain_complete` 1회이며 `Operator_pause`/`Stop_requested` 합성 0
- legacy migration truth-table 전 행 + inconsistent pair의 per-keeper typed failure 테스트
- TLA+ clean/buggy 쌍 both-pass

## 기각한 대안

- **paused 의미별 enum 확장 (`paused_kind : Operator|Auto|Shutdown`)**: 한 필드의 겸직을 유지한 채 라벨만 늘림 — FE 6-축 OR 파생이 그대로 남는다. 근본은 필드가 아니라 projection 부재.
- **FE만 수리 (배지 통합, 백엔드 유지)**: `store.ts` 5-필드 patch가 증명하듯 wire 축이 8개인 한 FE 단일화는 불가능한 발명(파생 휴리스틱)을 다시 요구한다.
- **`/directive` 유지 + 신 action 추가**: string directive 채널의 "unknown = log-and-ignore" silent 분기를 존속시킴 — Silent Failure 금지 위반.

## 충돌/조정

- **#24014는 2026-07-11 기준 closed/unmerged이므로 gate가 아니다.** PR-1의 domain type/projection/migration/stop orchestrator는 auth PR과 독립적으로 착수한다.
- **#24039 (현재 open draft auth contract)**: 현 route도 `server_routes_http_routes_dashboard.ml:1706-1746`에서 lifecycle mutation을 `with_token_permission_auth ~permission:CanAdmin`으로 감싼다. 신규 `/lifecycle`도 이 권한을 낮추지 않고, #24039의 fail-closed dashboard token/typed permission 계약 위에 rebase한다. 구현 순서는 domain command → boundary decoder → `CanAdmin` route → dashboard atomic cutover → 구 route 삭제이며, #24039와 route 파일이 겹칠 때만 landing order를 조정한다.
- #23918 run_state는 이 설계의 기반(랜딩 완료). #23982 meta canonicalize는 마이그레이션 재분류의 선례.

[근거] `gh pr view 24014/24039 --json state,isDraft,mergedAt,closedAt,headRefOid` + source baseline의 route auth 확인, 2026-07-11 KST, 신뢰도 High.
