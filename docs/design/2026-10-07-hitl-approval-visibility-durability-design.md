# HITL 승인 가시성·내구성 설계 — 열린 승인 health 노출, 늦은 승인 durable 화, 재시작 잔여 복구

- 날짜: 2026-10-07
- 작성: polisher (task-1665 설계 선행 산출, 구현 전 검토 대기)
- 판독 head: `e7818a4d3a` (origin/main, 2026-10-07). 아래 좌표는 모두 이 head 직독값이다.
- 관련: task-710, task-713, task-958, task-1653 / 증상 라이브 관측 2026-09-21 (polisher `identity_call` 163.4h)

## 0. 증상의 한 줄 원인 (task 본문이 요구한 "따라가서 한 줄")

**ask(tool 승인 대기)는 프로세스 메모리에만 살고 재시작에 사라지므로, 163시간 뒤 남은 것은
durable `pending_approval` entry 뿐이고, 그 entry 를 다시 건져 올릴 트리거는 수동 모드 keeper 에게
존재하지 않는다 — `Summary_not_requested` 는 방치의 시간이지 유실이 아니다.**

근거 사슬 (전부 직독):

1. live wait 는 registry 가 죽으면 함께 사라진다 — `Keeper_tool_approval_registry` 는
   "a call whose waiter is gone is not held for later"(`lib/keeper/keeper_late_approval.ml:3~9` 주석,
   registry.mli 동일 논리). 서버 재시작 = wait 소멸, `gate/pending.json` row 만 잔존.
2. 늦은 답변 기억(`Keeper_late_approval.shared ()`)도 메모리이고 TTL 900초
   (`keeper_late_approval.ml:81 let ttl_sec = 900.0`)이라 163h 뒤엔 reap 이 이미 지웠다.
3. summary(auto judge) 기동 트리거는 네 곳뿐이다: operator 가 gate mode 를 Auto_judge 로 전환할 때의
   `request_operator_auto_judge_recovery`(`keeper_gate.ml:1872`, dashboard 라우트
   `server_routes_http_routes_dashboard.ml:1560`), keeper 턴의 `defer ~reason:Judge_requested`
   (`keeper_gate.ml:1917~1201`), 같은 owner worker 완료 후의 on_finish drain(`keeper_gate.ml:1024`),
   부팅 resume(`server_runtime_bootstrap.ml:1524`) — 그런데 부팅 resume 은 owner 의 **effective mode 가
   Auto_judge 일 때만** owner 를 인정한다(`keeper_gate.ml:1512~1552`, #31321 주석).
4. 승인 대기가 생기는 keeper 는 gate/manual 모드(승인이 필요하다는 뜻)이므로, 재시작 뒤 부팅 resume 은
   이 entry 를 인정하지 않고, 위 트리거 중 어느 것도 자동으로 오지 않는다.
   → `summary_status = Summary_not_requested`(`keeper_approval_queue.ml:1137`)가 영구 방치된다.

즉 "163시간 동안 왜 요약이 안 시작됐나"의 답은 **재시작이 잃어버린 것은 ask 가 아니라
"요약을 요청하는" 트리거이며, 수동 모드 entry 에는 트리거가 애초에 없다**는 것이다.

## 1. 현 상태 좌표 (e7818a4d3a 직독)

| 항목 | 위치 | 내용 |
|---|---|---|
| 180초 상수 | `lib/server/server_routes_http_keeper_stream.ml:300` | `let keeper_tool_approval_timeout_sec = 180.0`, 소비 `:2094` |
| gate 생성 조건 | 같은 파일 `:2087~2096` | operator 가 시작한 stream 턴에만 gate(`approval_gate` 주석: "autonomous cycle gets none") |
| timeout 동작 | `lib/keeper/keeper_tool_approval_gate.ml:100~107` | `Late.note_timed_out` 후 `Timed_out` — 그 tool call 만 blocked, 턴 계속 |
| 늦은 승인 저장 | `lib/keeper/keeper_late_approval.ml` | 메모리 `shared_store`, `expired`+`remembered` 목록, TTL 900s, 모든 연산 시 reap |
| 늦은 답변 접수 | `server_routes_http_keeper_stream.ml:379` | `remember_late ~actor`(task-1662 인증 경계) |
| 목록 표면 | 같은 파일 `:407 handle_keeper_tool_approvals_list` | `GET /api/v1/keepers/tool-approvals` — live wait projection(keeper·tool·question·asked_at·timeout_sec) |
| TUI 소비 | `bin/masc_tui_loader.ml:1381`, `lib/tui_decode.ml:379` | `load_keeper_tool_approvals` → `keeper_tool_approval` 레코드 → approvals 창 |
| health rollup | `lib/server/server_health_rollup.ml:1~46` | `/health?full=1` 섹션 목록 — **열린 승인 관련 섹션 없음** |
| reaction ledger 섹션 | `server_routes_http_runtime.ml:465~467` | `hitl_resolved` 집계만 있고 열린 승인 수·최고령 없음(증상과 일치) |
| 재시작 분류 | `lib/keeper/keeper_gate.ml:695~729 classify_auto_judge_entry` | not_requested/pending_unbound/finalizable/ineligible 4 분기 |
| 부팅 복구 | `keeper_gate.ml:1512 recovered_work_for_base_path` → `:1852 resume_persisted_auto_judges_with` | owner effective Auto_judge 만 인정; not_requested·pending_unbound → Activate_worker, 완성된 요약 → Finalize |
| 고아 예약 회수 | `keeper_gate.ml:1469 reclaim_orphaned_start_reservation` | `Summary_pre_worker_start_reserved` 재시작 시 ready 로 복귀 |
| exact latch | `lib/keeper_contract/keeper_approval_queue_rules_types.mli:36~46` | `Exact_released_recovery_required` = "Only explicit operator recovery may return this identity to Exact_unbound" |
| 잔여→재bind 되돌림 | `lib/keeper/keeper_approval_queue.ml:1697~1723` | `persistence_uncertain + Exact_released_recovery_required → Exact_unbound`(reserve 단계에서만) |

## 2. 빈틈 정리 (설계가 메우는 것)

- **B1 (요구 1)** `/health?full=1` 에 열린 승인 수·최고령·요약 대기 상태가 없다. 목록 API 와 TUI 창은
  이미 있으므로 "요약 지표"만 health 에 타입 있이 얹으면 된다.
- **B2 (요구 2)** 늦은 승인(150초~15분 창의 인간 결정)이 메모리에만 있다. 서버가 그 사이 재시작되면
  연산자가 이미 내린 결정이 사라져 같은 call 을 다시 묻는다. 하루 25회 재시작 환경에서 이 창은
  사실상 매번 닫힌다.
- **B3 (요구 4 전반)** 재시작 잔여 중 `not_requested`·`pending_unbound` 는 이미 복구된다(확인).
  반면 **`Summary_attempt_in_flight` + `Exact_bound { Exact_dispatch_uncertain }`** 는 classify 에서
  `Auto_judge_ineligible` 이고, operator 복구 API 도 없어 영구 정체한다 — 요구 4의 남은 빈틈.
- **B4 (요구 3)** 180초 상수는 측정 근거 없이 하드코딩돼 있고, 조건("운영자 화면이 붙어 있는 동안만
  기다림")으로의 교체 여부를 판단할 관측값도 없다.

## 3. 설계

### D1 — health 에 `keeper_hitl_gate` 섹션 (요구 1)

`server_routes_http_runtime.ml` 에 기존 섹션 규약(`compute_section`)으로 한 섹션을 더한다.

```
"keeper_hitl_gate": {
  "status": "ok" | "attention",
  "approvals_open": int,            // registry.live wait 수 (GET tool-approvals 와 동일 소스)
  "oldest": null | { keeper, tool, asked_at, age_sec, timeout_sec },
  "summary_not_requested": int,     // queue 전체 pending entries 집계
  "summary_pending": int,
  "exact_bound_residual": int,      // B3 잔여(ineligible) 카운트 — operator 볼 수 있게
  "operator_action_required": bool,
  "reason": "..."                   // approvals_open>0 && age_sec > timeout_sec*2 등
}
```

- 소스는 두 개: live wait 는 `Keeper_tool_approval_registry.pending`, durable 집계는
  `Keeper_approval_queue.list_pending_entries_for_workspace`. 합산 로직은
  `lib/keeper/keeper_hitl_gate_health.ml`(신설)에 두고 서버와 테스트가 같은 함수를 쓴다.
- TUI·dashboard 는 **이미 같은 값(`tool-approvals` 목록)을 각자 그린다** — 새 프로토콜 없이
  approvals 창 헤더에 `approvals_open`/`oldest age` 를 같은 디코딩(`tui_decode.ml`)에서 얹는다.
  task-1653 의 dashboard 작업과 같은 소스를 읽도록 하는 것이 완료 기준이다.
- `status`/`reason` 판정은 문자열 비교가 아니라 위 카운트로만 계산한다(금지 조항 준수).

### D2 — 늦은 승인의 durable 화 (요구 2)

`Keeper_late_approval` 을 메모리 구조는 유지한 채 뒤에 append-only 저널을 붙인다.

- 저장: `gate/late_approval.log.jsonl`(workspace base_path 아래, `gate/pending.json` 옆 —
  경로 SSOT 는 `keeper_gate_path.ml` 에 `late_approval_log` 로 추가).
- 쓰기: `note_timed_out`(expired 기록)과 `remember_late`(remembered 확정) 시각에
  `{op, keeper, tool_call_id, tool, args_fingerprint, decision, actor, at}` 레코드를 fsync append.
  기존 `reap_locked` 는 메모리 view 만 걷고 저널은 지우지 않는다(크래시 안전, won-chik 이 지적한
  full-replace 위험을 처음부터 만들지 않는다).
- 복원: `create ()` 시점에 저널을 읽어 expired/remembered 를 재구성한다. 재시작 직후
  `take` 가 바로 동작하려면 이 복원이 부팅 동기 경로여야 한다(주석으로 근거 명시).
- 소비: `take` 성공 시 tombstone 레코드(`op=consume`)를 append — 재시작 뒤 같은 결정이 두 번
  쓰이는 것을 막는다. 메모리 목록은 지금처럼 즉시 뽑아낸다.
- TTL 900s 는 **유지**한다. 이것은 wall-clock 자동 만료(금지)가 아니라 "인간 결정 하나가 인가할 수 있는
  시간"의 안전 상계이고, 기존 주석(`keeper_late_approval.ml:60~79`)의 논리 — yolo 전환 시 과거 기억
  발화 차단 포함 — 가 그대로 성립하기 때문이다. TTL 이 "만료"가 아니라 "인가 상계"임을 주석에
  유지하는 것이 이 설계의 일부다.
- 인자 원문(what was asked)은 저널에 fingerprint 로만 넣는다 — 원문 args 는 `pending.json` 이 이미
  들고 있고, 저널은 결정 배분용 identity 만 필요로 한다(`expired_ask` 필드 재사용).

### D3 — 180초 상수: 조건 교체는 관측 뒤로, 상수는 설정으로 (요구 3)

선택: **typed 조건으로의 즉시 교체는 하지 않고, 측정 근거를 모은 뒤 다시 판단한다.**

- 상수를 `Keeper_config.keeper_tool_approval_timeout_sec ()` 로 옮겨 기본값 180.0 을 유지한다.
  환경변수 `MASC_KEEPER_TOOL_APPROVAL_TIMEOUT_SEC`(하한 5.0, 상한 3600.0 clamp).
- 상수 자리(`server_routes_http_keeper_stream.ml:300`)에 측정 부재를 명시하는 주석을 남긴다:
  "180.0 은 측정에 근거한 값이 아니며, health `keeper_hitl_gate` 섹션의 answered/timed_out 카운트가
  근거를 모은 뒤 조건화를 다시 판단한다"(현 요구의 셋째 길: "그대로 두되 주석에 측정 부재를 적는다").
- D1 섹션에 `answered_total`/`timed_out_total` 카운터를 함께 내보낸다(등록부 이벤트에서 합산).
  조건 교체안("operator pane 이 stream 에 붙어 있는 동안만 대기")은 registry 가 waiter 생존을 이미
  알고 있으므로 기술적으로 가능하지만, watcher 유실 즉시 대기가 끊기는 새 실패 모드를 만들므로
  이번 설계 범위에서 제외하고 후속 RFC 후보로만 남긴다.
- 자동 만료(금지)와 무관: 이 값은 대기 상한일 뿐 결정을 지우지 않는다(늦은 답은 D2 가 받는다).

### D4 — 재시작 잔여의 operator 복구 경로 (요구 4)

확인된 사실: `not_requested`/`pending_unbound` 는 이미 부팅 resume 이 Activate_worker 로 잡는다
(`keeper_gate.ml:1560~1562`). 요구의 "경로가 있는지 확인"은 **있다**. 없는 것은 잔여
`Exact_bound` 다. 설계:

- boot 시 `Exact_dispatch_uncertain` 은 이미 install-only latch
  (`Exact_restart_quarantined` 투영, `keeper_approval_queue_exact_transition.ml:44~46`)을 거친다 —
  이를 건드리지 않는다(안전 latch 유지).
- 대신 operator 전용 복구 엔드포인트를 dashboard 에 하나 둔다:
  `POST /api/v1/keepers/hitl/approvals/:id/recover` — 본문 `{ action: "rearm" }`.
  전제조건을 typed 로 강제한다: `exact_attempt.status ∈ { Exact_restart_quarantined,
  Exact_released_recovery_required }` 이고 `summary_attempt_disposition ∈ { in_flight,
  persistence_uncertain }` 일 때만 `Exact_unbound + Summary_attempt_ready` 로 되돌린다.
  rules_types.mli 주석("Only explicit operator recovery")이 가정한 바로 그 경로다.
- 재시작 자동 재시도는 만들지 않는다 — latch 의 존재 이유(dispatch 결과 불명)를 유지한다.
  operator 는 health 섹션의 `exact_bound_residual`(D1)로 이 정체를 발견하고 recover 로 푼다.
- polisher 163h 사례류의 수동 모드 방치 entry 는 자동 복구를 붙이지 않는다(모드 정책 #31321 존중).
  대신 D1 의 `summary_not_requested` 최고령이 operator 화면에 뜨므로, operator 가 gate mode 전환
  (기존 `request_operator_auto_judge_recovery`) 또는 recover 로 처리한다.

## 4. 금지 조항 준수 확인

- wall-clock 자동 만료: 없다. D2 TTL 은 승인 재사용의 인가 상계(기존 설계 논리 유지)이고, D4 복구는
  operator 명시 액션뿐이다. 승인 자체가 시간으로 사라지는 경로는 만들지 않는다.
- 문자열 상태 비교 흐름 제어: 없다. 모든 신규 분기는 `summary_status`/`exact_attempt_status`/
  `summary_attempt_disposition` 의 closed variant 에 exhaustive match 한다. health `reason`
  문자열은 표시용이고 판정 입력이 아니다.

## 5. 테스트 계획 (완료 기준과 1:1)

1. **재시작 뒤 늦은 승인 적용(필수)** — `note_timed_out` → `remember_late` → 저널 기록 →
   새 `t` 를 저널에서 복원 → `take` 가 같은 decision 을 되돌려주는 단위 테스트.
   tombstone 이 있으면 복원되지 않는 부정 케이스 포함.
2. **health 섹션** — registry stub + queue fixture 로 `approvals_open`/`oldest`/summary 카운트
   정확성, `status="attention"` 전환 조건 테스트. `/health?full=1` 롤업에 섹션이 등장하는지
   routes 테스트.
3. **recover 엔드포인트** — typed 전제 충족 row 만 rearm 되고, `Exact_completed` 등은
   거절(status_conflict)인 테스트. 미인증 caller 거절(task-1662 경계 재사용).
4. **회귀** — 기존 `classify_auto_judge_entry`·부팅 resume 테스트는 그대로 통과해야 한다
   (요구 4의 "이미 있는 경로"를 부수지 않았음을 증명).

## 6. 순서와 범위

1. D1 health 섹션(가장 작고 독립) → 2. D2 durable late approval(저널) → 3. D4 recover
   엔드포인트 → 4. D3 상수 config 이동·주석. 각각 독립 PR 로 쪼개 stack 하고, D2·D4 는
   마이그레이션(저널 부재=빈 상태로 시작)이므로 하위 호환이 자연스럽다.

## 7. 열린 질문 (구현 전 답이 필요한 것)

- D2 저널의 위치: workspace별(base_path 하위) vs 전역 단일 — 현재 `shared ()` 가 전역 싱글턴이라
  workspace 구분이 없다. 전역 저널 하나로 가되 레코드에 base_path 를 넣는 안을 기본으로 제안한다.
- D1 `oldest` 임계(attention 전환)의 초기값: `timeout_sec * 2`(360s) 제안 — 근거는 없고, D3 카운터가
  쌓인 뒤 재조정한다. 상수의 근거 부재를 숨기지 않기 위해 주석에 동일하게 명시한다.
