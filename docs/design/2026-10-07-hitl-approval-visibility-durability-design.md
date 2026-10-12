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
  "late_uncertain": int,            // consume/deliver 사이 결과 불명 창(§D2) + workspace
                                    // 교차 배분 거부분 — operator ack 필요
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

- 저장 권위(reviewer 경계 1 반영, 하나로 확정): **전역 저널 하나** — `keeper_gate_path.ml` 에
  `late_approval_log` 로 SSOT 를 추가하고 gate 루트 아래 단일 파일로 둔다. workspace별 파일은 채택하지
  않는다(기존 `shared ()` 싱글턴 구조를 바꾸지 않기 위해, 그리고 부팅 복원을 한 파일 읽기로 단순화하기
  위해). 대신 **모든 레코드와 모든 연산에 caller 의 인증된 workspace identity(`base_path`)를 결속**한다:
  레코드는 `{op, base_path, keeper, tool_call_id, tool, args_fingerprint, decision, actor, at}` 를
  가지고, `take` 배분 키는 `(base_path, keeper, tool_call_id)` 정확 일치 + `args_fingerprint` 동일
  확인이다. fingerprint 만 같은 다른 workspace 의 같은 식별자에는 결정을 배분하지 않고, 이 경우
  `late_uncertain` 로 분류해 operator 확인을 요구한다(§7 열린 질문에서 제거됨).
- 쓰기: `note_timed_out`(expired 기록)과 `remember_late`(remembered 확정) 시각에
  `{op, base_path, keeper, tool_call_id, tool, args_fingerprint, decision, actor, at}` 레코드를
  fsync append. 기존 `reap_locked` 는 메모리 view 만 걷고 저널은 지우지 않는다(크래시 안전, won-chik
  이 지적한 full-replace 위험을 처음부터 만들지 않는다).
- 복원: `create ()` 시점에 저널을 읽어 expired/remembered 를 재구성한다. 재시작 직후
  `take` 가 바로 동작하려면 이 복원이 부팅 동기 경로여야 한다(주석으로 근거 명시).
- 소비 시도 결속: 미출시 저널 schema는 `masc.late_approval.v2`다. `take`는 consume 전에
  고유 `consume_id`를 만들고 consume/deliver/ack는 같은 workspace·keeper·tool·fingerprint와
  그 ID 하나만 참조한다. 같은 입력의 다른 시도가 성공해도 앞선 불확실 시도는 닫히지 않는다.
  이는 승인 소비 identity이며 외부 실행 원장의 attempt identity와 동일하다는 주장은 하지 않는다.
- 실제 순서: consume append+fsync → 메모리 승인 제거 → deliver append 시도 → decision 반환.
  consume 실패는 decision을 반환하지 않는다. deliver 실패도 decision은 반환하므로 이후 caller가
  외부 효과를 만들 수 있다. 성공한 deliver 역시 외부 실행 완료 증거가 아니다. consume-only는
  결과 불명으로 보존하고 해당 ID의 operator ack만 경고를 닫는다. ack는 재인가가 아니다.
- 부팅 복원은 각 op의 필수 필드·schema·중복 consume ID·정확한 열린 시도의 closure를 검증한다.
  pre-ID/다른 schema/손상 저널은 typed 오류를 store에 보존하고 mutation을 거절한다. 이전 행을
  건너뛰거나 시간으로 결합하거나 자동 삭제·마이그레이션하지 않는다. health와 operator 조회는
  unavailable을 표시하므로 오류를 `late_uncertain=0`의 정상 상태로 표현하지 않는다.
- operator는 CanAdmin `GET /api/v1/keepers/hitl/late-approval-attempts`에서 인증된 workspace의
  정확한 keeper/tool/fingerprint/consume_id를 조회한다. 기존 recover의 `ack_uncertain` body에는
  `keeper_name`과 `consume_id`만 필수이며 그 시도 하나만 닫는다. tool/fingerprint는 저장된
  시도에서 읽으므로 재시작 후 원 args를 재구성할 필요가 없다. 승인 재사용 TTL은 미확정 증거에 적용하지 않는다.
- GET에서 받은 ID를 사용한 ack body 예: `{"action":"ack_uncertain","keeper_name":"keeper-a","consume_id":"<listed consume_id>"}`.
  기존 `POST /api/v1/keepers/hitl/approvals/<approval_id>/recover`의 응답도 닫힌 `consume_id`를 반환한다.
- append의 known-commit receipt는 cleanup 경고와 구분한다. commit 여부를 확인할 수 없는
  실제 I/O 오류는 store를 unavailable로 fence하며 명시적 재복원 전 새 mutation을 거절한다.
  테스트의 deliver 거절 seam은 쓰기 전 실패이므로 이 불확실 I/O를 재현한 증거가 아니다.
- 같은 store의 mutex 획득과 I/O 전체를 worker에서 실행하여 scheduler가 blocking lock을
  기다리며 writer의 worker 복귀를 막는 교착을 피한다.
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
  `POST /api/v1/keepers/hitl/approvals/:id/recover`. 전제조건을 typed 로 강제한다
  (2026-10-09 운영자 P2 반영으로 축소): `Exact_restart_quarantined` 은 재시작이 절대
  dispatch 를 다시 실행하지 않게 하는 install-only terminal projection 이므로 operator
  rearm 도 받지 않고, CAS 가 실제로 수용하는 유일 조합 — `summary_attempt_disposition
  = persistence_uncertain` × `exact_attempt.status = Exact_released_recovery_required`
  → `Exact_unbound` — 만 HTTP 입구에서도 받는다. 그 조합 하나뿐임의 근거는
  `reserve_summary_attempt_retry` 서술어의 `_ -> None` (keeper_approval_queue.ml)다.
  rules_types.mli 주석("Only explicit operator recovery")이 가정한 바로 그 경로다.
  rearm 은 queue CAS 를 직접 부르지 않고 `Keeper_gate.retry_blocked_auto_judge_typed`
  (모드 검사 #31321 → row 조회 → exact CAS → drain → 실패 시 durable re-block)에
  위임한다 — HTTP rearm 이 어떤 worker 도 받지 않을 summary reservation 을 만들 수
  없다.
- (reviewer 경계 3 반영) 복구 계약을 더 좁힌다:
  - **CAS**: recover 는 `expected_revision` 을 요구하고 row revision 과 attempt identity 에 대해
    compare-and-swap 한다. 두 요청이 같은 revision 을 겨냥하면 정확히 하나만 적용되고 나머지는
    `status_conflict` 로 거절된다(테스트 §5-3).
  - **재실행 범위**: rearm 은 **summary(auto judge) 생성을 다시 시작하는 것**뿐이다 — 외부 tool 이나
    이전 attempt 의 dispatch 를 재실행하지 않는다. 이전 dispatch 결과가 불명한 row 는 자동 재실행되지
    않고, 이전 attempt 의 실행 원장 readback(확정 결과·비실행 증거·효과 불명)을 health/responses 로
    그대로 노출해 operator 가 수동 처분을 결정하게 둔다. 즉 recover = 새 판단 생성 재개이지
    효과 재실행이 아니다.
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

## 4b. 숫자 정책과 task 계약의 구분 (reviewer D3 지적 반영)

현재 task-1665 계약이 요구하는 것은 180초의 "typed 조건 또는 측정 근거"다. 아래 숫자들은 그 외의
새 정책이므로 계약 범위와 근거를 이렇게 갈라 둔다:

| 수 | 분류 | 이번 설계에서의 근거 |
|---|---|---|
| 180.0 (timeout 기본값) | task 계약 대상 | 측정 부재를 주석으로 명시(현 요구의 셋째 길). config 이동만 함 |
| 900.0 (late TTL) | 기존 설계 유지 | 이번에 새로 만드는 정책이 아니다 — 기존 인가 상계 논리를 보존 |
| clamp 5.0–3600.0 | 새 정책(보호 한계) | 측정 근거 없음. 오용 방지 한계로만 명시하고 근거 부재를 주석에 적는다 |
| attention 임계 timeout×2 | 새 정책(표시 임계) | 근거 없음. §7 의 열린 질문으로 남기고 카운터가 모이면 재조정 |
| answered/timed_out 카운터 | 측정 도구 | task 계약이 요구하는 근거 수집기 자체. §D3 참조 |

카운터는 **프로세스 수명 동안만** 유효하다(등록부가 메모리 구조). 재시작을 넘어 지속하는 카운터를
만들지 않는 이유는, 지속 카운터가 곧 또 하나의 저널이 되어 D2 와 동일한 내구성 문제를 끌어오기
때문이다. 대신 health 섹션에 `measured_since`(프로세스 부팅 시각)를 함께 내보내 전후 비교 가능성을
보장한다. 재시작 지속 측정이 필요해지면 그때 별도 근거와 함께 확장한다.

## 5. 테스트 계획 (완료 기준과 1:1)

1. **재시작 뒤 늦은 승인 적용(필수)** — `note_timed_out` → `remember_late` → 저널 기록 →
   새 `t` 를 저널에서 복원 → `take` 가 같은 decision 을 되돌려주는 단위 테스트.
   `deliver` 레코드까지 남으면 복원되지 않는 부정 케이스 포함.
2. **health 섹션** — registry stub + queue fixture 로 `approvals_open`/`oldest`/summary 카운트
   정확성, `status="attention"` 전환 조건 테스트. `/health?full=1` 롤업에 섹션이 등장하는지
   routes 테스트. `measured_since` 가 부팅 시각과 같은지 확인.
3. **저널 경계(reviewer 표 반영)** —
   - consume append/fsync 실패: decision 미반환, 미확정 실제 I/O 오류는 mutation 차단. 명시적 재복원에서 consume 유무를 확인한 뒤에만 재사용 여부를 결정한다.
   - consume 후 caller 반환 전 중단: 주입 지점에서는 dispatch가 없었음을 확인하되, 복원은
     `late_uncertain`으로 분류하고 자동 재적용하지 않는다. 기록만으로 미전달을 판정하지 않는다.
   - 실제 deliver append 실패 seam 뒤 decision 반환, 같은 입력의 새 consume/deliver 성공,
     재시작 뒤 첫 consume_id가 계속 uncertain인지 검사한다. 같은 시각이어도 ID로 분리하며
     승인 TTL 이후에도 불확실 증거를 보존한다.
   - consume/deliver/readback의 attempt 결속: 같은 workspace·call·fingerprint라도 다른
     attempt의 결과는 거절하며, 원래 attempt의 기록 부재만으로 비실행을 확정하지 않는다.
   - deliver 기록 후 dispatch 전 중단: deliver 가 전달 기록이지 tool 실행 완료 증거가 아님을
     확인하고, 이후 처분은 실행 원장 readback 으로 간다.
   - `ack` 는 재인가가 아님: 실행 원장의 결과·비실행 증거 없는 ack 뒤 새 attempt 허가가 없음을
     stub 수준에서 확인.
   - workspace 교차: 같은 keeper/call/fingerprint 의 A·B 결정이 서로 적용되지 않음(배분 키에
     base_path 포함).
4. **recover 엔드포인트** — typed 전제 충족 row 만 rearm 되고, `Exact_completed` 등은
   거절(status_conflict)인 테스트. 같은 revision 을 겨냥한 두 요청 중 하나만 적용(CAS).
   미인증 caller 거절(task-1662 경계 재사용). rearm 이 외부 tool 을 재실행하지 않음을
   stub 수준에서 확인.
5. **회귀** — 기존 `classify_auto_judge_entry`·부팅 resume 테스트는 그대로 통과해야 한다
   (요구 4의 "이미 있는 경로"를 부수지 않았음을 증명).


## 6. 순서와 범위

1. D1 health 섹션(가장 작고 독립) → 2. D2 durable late approval(저널) → 3. D4 recover
   엔드포인트 → 4. D3 상수 config 이동·주석. 각각 독립 PR 로 쪼개 stack 하고, D2·D4 는
   마이그레이션(저널 부재=빈 상태로 시작)이므로 하위 호환이 자연스럽다.

## 7. 열린 질문 (구현 전 답이 필요한 것)

- ~~D2 저널의 위치: workspace별 vs 전역~~ → §D2 에서 **전역 저널 + base_path 결속**으로 확정함
  (context-reviewer 경계 1 반영, 2026-10-07 리뷰).
- D1 `oldest` 임계(attention 전환)의 초기값: `timeout_sec * 2`(360s) 제안 — 근거는 없고, D3 카운터가
  쌓인 뒤 재조정한다. 상수의 근거 부재를 숨기지 않기 위해 주석에 동일하게 명시한다(§4b 표 참조).
- `late_uncertain`(consume/deliver 사이 결과 불명)의 operator `ack` 표면을 dashboard 어디에 둘지 —
  D1 health 섹션에 카운트로 먼저 노출하고, ack 엔드포인트는 D4 recover 와 같은 PR 에 넣는다. ack 의
  의미는 §D2 에서 경고 확인(재인가 아님)으로 확정했다.

## 8. 개정 이력

- 2026-10-07 초기안(9249fed570): §0~§7.
- 2026-10-07 개정(anyang-keepers COMMENTED 리뷰 반영, head eaf9fbb669+): D2 저장 권위 확정(전역+
  base_path 결속), consume/deliver 성공 경계와 late_uncertain 계약, D4 CAS+재실행 범위 명시,
  §4b 숫자 정책의 계약 범위 구분, 테스트 계획에 저널 경계 4케이스 추가.
- 2026-10-08 개정(code-reviewer FAIL P2 + context-reviewer 2차 지적 반영): consume-only 꼬리를
  "미전달·무효과"에서 "전달·실행 결과 불명"으로 재분류(반환 후 dispatch 뒤 deliver 기록 전 중단에서
  저널과 효과가 공존 가능), 무효과 단정을 consume 내구화 후 caller 반환 전 창으로 한정, ack 를
  경고 확인으로 확정(재인가 아님, 원장 증거 없는 재인가 금지), 쓰기 레코드 예시에 base_path 정렬,
  테스트 계획을 중단 지점 4케이스+ack 재인가 부정으로 보강.
- 2026-10-09 개정(task-1665 운영자 P2 3건 반영): §D4 rearm 전제를 CAS 가 수용하는 유일 조합으로
  축소(`Exact_restart_quarantined` 제외, 이유 문서화), rearm 을 `Keeper_gate` 위임으로(직접 CAS
  금지), late approval 테스트의 `For_testing.fail_next_deliver` seam 제거(저널 직접 기록으로 대체).
- 2026-10-10 추가(task-2237, late-approval 저널 fence 의 정의된 출구): §D4a 신설.

### D4a — 늦은 승인 저널의 fence 출구와 부팅 읽기 상한 (task-2237)

착지 뒤 소스 직독(#41768, main 36db387f3f)으로 확인된 빈틈: 저널 오류의 fence 는 안전하지만
나오는 길이 없었다. `Journal_unavailable` 은 서버 재시작뿐(`bind_to_journal` 호출부가
`server_bootstrap_loops.ml` 하나), `Corrupt_journal` 은 재시작해도 같은 줄에서 다시 fence.
health 는 `operator_action_required=true` 만 주고 무엇을 해야 하는지는 어디에도 없었다.

**결정 1 — `Journal_unavailable` 의 출구는 CanAdmin 복원 엔드포인트.**
`POST /api/v1/keepers/hitl/late-approval-restore`(CanAdmin, body 없음)가 부팅 경로와 같은
동기 재bind·재복원(`Keeper_late_approval.restore`)을 실행한다. 성공은 200 `ok:true` 로
`journal_error = None` 복귀, 저장소가 아직 못 읽히면 503 `journal_unavailable` 에 원문 오류.
fence 의 안전성(기억된 답 미기록·쓰기·ack 거절)은 그대로고, 재시작 요건만 사라진다.

**결정 2 — `Corrupt_journal` 의 운영자 절차 (문서로 고정, 자동 수리 금지 유지).**
라이브러리는 줄을 건너뛰거나 고치지 않는다(§D2 재확인). 절차:
1. health 의 `status_reasons` 원문 오류로 손상 위치를 확인한다(재시작 뒤에도 동일).
2. 복원 엔드포인트는 503 `journal_corrupt` 로 계속 실패한다 — 이것이 정상 동작이다.
3. 저널 파일을 통째로 옮겨 둔다(`late-approval.jsonl` → `late-approval.jsonl.corrupt.<date>`).
   잃는 것: 그 파일에 있던 기억된 답(TTL 900s 안의 것), 미확정 consume 의 경고 목록,
   닫힌 시도의 증거. 옮기기 전 `GET /api/v1/keepers/hitl/late-approval-attempts` 로
   미확정 consume_id 를 따로 적어 둔다(ack 재제출 근거).
4. 복원 엔드포인트를 다시 부르면 빈 저널에서 `journal_error = None` 로 돌아온다.
fence 사이의 같은 호출은 다시 물어본다(안전 방향), 15분 안의 기억된 답만 사라진다.

**결정 3 — 부팅 읽기 상한: 이번 범위는 자동 정리 없음 + 크기 관측값.**
닫힌 시도(consume+deliver/ack 완결)와 TTL 지난 note/remember 줄은 재생해도 아무 상태를
만들지 않지만, 부팅 동기 읽기는 전체 파일을 검증한다. 세대 파일·압축은 새 파일 회전과
크래시 경계를 만드는 확장이라 이번 범위에서 하지 않는다(§D2 "the journal is never cleaned"
유지). 대신 health `keeper_hitl_gate` 섹션에 `late_approval_journal_bytes`(파일 크기)와
`late_approval_journal_rows`(줄 수)를 내보내 방치 성장을 관측 가능하게 하고, 실측으로 부팅
시간이 문제되는 워크로드가 확인되면 그때 세대 파일 설계를 연다.

**AC 대응**: fence 원인별 행동은 health `operator_action_reasons` 에 reason 문자열로
적혀 있고(복원 엔드포인트·이관 절차), `Journal_unavailable` → 복원 출구 통과 테스트,
`Corrupt_journal` → 재시작 뒤에도 남음(고정) + 이관 뒤 복원으로 해소 테스트가
`test/test_keeper_late_approval.ml` 에 있다.
