# Council & Governance

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `lib/council/` (sub-library, 4.8K LOC), `lib/operator/` (sub-library, 4.2K LOC), `lib/governance_pipeline.ml`, `lib/governance_registry.ml` |
| Dependencies | 03-room-coordination |
| LOC | ~9K combined |

---

## 1. 목적

Council & Governance 서브시스템은 다중 에이전트 환경에서의 의사결정, 위험 관리, 운영자 통제를 담당한다. 세 가지 독립적인 계층으로 구성된다.

1. **Council sub-library** -- 토론(Debate), 합의(Consensus), 라우팅(Router), 공정성(Balance), 대화(Conversation), 실행(Executor) 모듈의 통합 API
2. **Governance pipeline** -- 도구 호출 시 위험 수준 분류와 승인 게이트
3. **Operator control** -- 운영자의 실시간 감독, 조치, 판단(judgment) 인터페이스

---

## 2. Council Sub-library

### 2.1 모듈 구조

`lib/council/council.ml`이 통합 진입점(facade)이며 다음 모듈을 re-export한다.

| 모듈 | 파일 | 역할 |
|------|------|------|
| `Debate` | `debate.ml` | 구조화된 토론 (파일 기반 영속) |
| `Consensus` | `consensus.ml` | 투표/합의 (in-memory + 파일 write-through) |
| `Router` | `router.ml` | MoE 스타일 에이전트 라우팅 |
| `Balance` | `balance.ml` | 참여 공정성 정책 |
| `Conversation` | `conversation.ml`, `conversation.mli` | 영속적 대화 스레드 (파일 + Neo4j) |
| `Executor` | `executor.ml` | 투표 결과를 시스템 액션으로 전환 |
| `Governance_v2` | `governance_v2.ml`, `governance_v2_types.ml`, `governance_v2_serde.ml` | 청원/사건/판결/실행명령 거버넌스 모델 |
| `Loop_guard` | `loop_guard.ml` | 대화 무한 루프 방지 |
| `Thread_persist` | `thread_persist.ml` | 이중 스트림 영속 (파일 + Neo4j) |

### 2.2 Debate

에이전트 간 구조화된 토론을 관리한다. 저장소는 파일 기반(`.masc/debates/<debate-id>.json`).

**핵심 타입:**

```
position     = Support | Oppose | Neutral
debate_status = Open | Closed | Pending

argument = { agent; position; content; evidence; reply_to; mentions; archetype; created_at }
debate   = { id; topic; status; arguments; context; created_at; closed_at }
context_ref = { board_post_id; task_id; operation_id; team_session_id }
```

**주요 연산:**

- `start_debate` -- 새 토론 시작. `notify_fn` 콜백으로 관련 에이전트 알림
- `add_argument` -- 발언 추가. `reply_to`로 스레드 구조, `mentions`로 @멘션
- `close_debate` -- 토론 종료, `closed_at` 타임스탬프 기록
- `get_debate_status` -- Support/Oppose/Neutral 카운트 포함 요약 반환

**영속화:** 원자적 쓰기(temp file + rename). JSON 직렬화/역직렬화에서 `Eio.Cancel.Cancelled`는 항상 re-raise.

### 2.3 Consensus

투표 기반 합의 시스템. In-memory `Hashtbl` + 파일 write-through(`.masc/consensus/<session-id>.json`).

**핵심 타입:**

```
decision     = Approve | Reject | Abstain
voting_result = Unanimous of decision | Majority of int | Deadlock | Escalate
voting_state = Open | Closed | Cancelled

vote    = { agent; decision; reason; timestamp; archetype; weight }
session = { id; topic; initiator; votes; quorum; threshold; state; context }
error   = Session_not_found | Session_closed | Already_voted | Quorum_not_met | Invalid_threshold
```

**투표 로직:**

1. `start_voting` -- quorum(최소 투표 수), threshold(과반 기준 0.0-1.0) 설정
2. `cast_vote` -- 중복 투표 거부(`Already_voted`). weight 지원(MAGI archetype 가중치)
3. `get_result` -- quorum 미달 시 에러. Abstain은 투표 수에서 제외
4. `close_session` / `cancel_session` -- 상태 전이

**가중 투표:** `sum_weighted_by_decision`으로 weight 합산. 기본 weight = 1.0.

### 2.4 Router

MoE(Mixture of Experts) 스타일 에이전트 선택. 쿼리 분류 후 2-3개 에이전트를 sparse activation으로 선택한다.

**모델 계층:** Tiny < Small < Medium < Large < Giant (비용 기준 $0.10 ~ $15.00 / 1M tokens)

**쿼리 분류:** 6개 카테고리(Code, Analysis, Creative, Factual, Conversation, Complex). 키워드 매칭 기반 점수 계산 후 정규화.

**선택 전략:**

- 복잡도 0.7 이하: 2개 에이전트 (저비용 우선)
- 복잡도 0.7 초과: 최대 3개 에이전트 (Large/Giant 허용)
- 목표: 90% 쿼리는 Small/Medium, 10%만 Large/Giant

**환경변수 연동:** `MASC_DEFAULT_CASCADE` 또는 `MASC_DEFAULT_PROVIDER` + `MASC_DEFAULT_MODEL`에서 기본 Tiny 에이전트를 동적 구성.

### 2.5 Balance

에이전트 참여 공정성 정책. 지배(dominance) 감지와 소수 의견 보호.

**파라미터:**

- `max_consecutive_wins = 3` -- 연속 3회 승리 시 강제 교체
- `min_participation = 0.2` -- 참여율 20% 미달 시 강제 참여 (5라운드 이상부터)

**액션:** `ForcedRotation` (지배 방지) | `MandatoryParticipation` (저참여 방지) | `Clear` (조치 불필요)

**로테이션:** 승수 최소 -> 마지막 승리 시점 오래된 순으로 정렬하여 다음 에이전트 선택. 승리 없는 에이전트가 최우선.

### 2.6 Conversation

영속적 대화 스레드 시스템. SSJ(1974) 턴 테이킹 모델 기반.

**턴 타입:** Initiate | Respond | FollowUp | Conclude (adjacency pair 모델)

**스레드 상태:** Active -> Concluded | Stalled | Archived

**Loop Guard:** 3중 방어

1. `MaxTurnsReached` -- `max_turns`(기본 50) 초과 시 차단
2. `IdenticalPattern` -- 동일 발화자의 연속 동일 메시지 3회 이상 시 차단
3. `CooldownViolation` -- 동일 발화자 2초 내 재발언 차단

**이중 스트림 영속:** (Thread_persist)
- 파일 저장: 동기, 필수. 실패 시 연산 실패
- Neo4j 그래프: 비동기, best-effort. Thread/Turn/Agent 노드와 BELONGS_TO, REPLIED_TO, MENTIONS, PARTICIPATED_IN 관계
- 서버 시작 시 `sync_all`로 파일 -> Neo4j 일관성 복구

### 2.7 Executor

투표 결과를 시스템 액션으로 전환. 패턴 매칭 기반.

**액션 타입:**
- `ExecCommand` -- argv 기반 프로세스 실행 (no shell)
- `ConfigChange` -- `.masc/config/` JSON 파일 변경
- `Notification` -- `.masc/notifications.jsonl` 기록
- `GitHubAction` -- `gh` CLI를 통한 PR merge/close/approve, issue 생성
- `Custom` -- 확장 포인트

**안전장치:** `requires_unanimous`, `min_threshold`로 실행 조건 제한. `dry_run`으로 사전 검증.

---

## 3. Governance V2 (청원-사건-판결 모델)

법률 시스템 메타포를 차용한 거버넌스 모델. `.masc/governance_v2/` 하위에 4개 엔티티를 파일로 관리.

### 3.1 엔티티 계층

```
petition  ->  case_record  ->  ruling  ->  execution_order
(청원)        (사건)           (판결)      (실행 명령)
```

**case_status 상태 전이:**

```
Pending_ruling -> Ready_auto_execute -> Executed
               -> Needs_human_gate   -> Executed | Blocked | Closed
               -> Blocked
               -> Closed
```

**risk_class:** Low | High. High는 human gate 필요.

### 3.2 핵심 연산

- `submit_petition` -- 청원 제출. 정규화된 키(`normalized_key`)로 중복 감지(deduplication). 기존 사건이 있으면 merge. 파일 락(`_submit.lock`)으로 경합 방지.
- `submit_brief` -- 사건에 의견서(brief) 제출. stance = Support | Oppose | Neutral
- `save_ruling` -- 판결 저장. `auto_execution_state`에 따라 case_status 자동 전이. `Ready_auto_execute`이면 execution_order 자동 생성.
- `save_execution_order` -- 실행 명령 저장 및 case_status 반영

### 3.3 자동 정리

- `purge_stale_test_cases` -- 테스트 origin 사건 24시간 후 삭제
- `purge_stale_artifact_cases` -- 자동화 아티팩트 사건 12시간 후 삭제
- `list_cases` 호출 시 자동 purge 실행

---

## 4. Governance Pipeline

`Governance_pipeline` 모듈은 도구 호출 전 위험 기반 승인 게이트를 제공한다. `Tool_dispatch.pre_hook`으로 등록되어 모든 도구 호출에 적용된다.

### 4.1 위험 분류

도구 이름의 키워드 매칭으로 4단계 위험 수준을 분류한다.

| 위험 수준 | 패턴 키워드 |
|----------|------------|
| Critical | delete, remove, drop, force, reset, kill, destroy, purge |
| High | create, update, write, deploy, push, merge, send, spawn, modify |
| Medium | claim, join, leave, start, stop, pause, resume, confirm, approve |
| Low | 위 패턴에 해당하지 않는 모든 도구 |

### 4.2 거버넌스 레벨

| 레벨 | confirm 임계 | audit 임계 |
|------|-------------|-----------|
| paranoid | Medium 이상 | Low 이상 |
| enterprise | High 이상 | Low 이상 |
| production | Critical | Medium 이상 |
| development | 없음 | High 이상 |

### 4.3 결정 흐름

```
도구 호출 -> assess_risk(tool_name) -> decide(governance_level) ->
  Allow:           handler 실행
  Require_confirm: 대기 응답 반환 (trace_id 발급)
  Deny:            거부 응답 반환
```

감사(audit) 조건 충족 시 `Audit_log.log_governance_decision` 기록.

---

## 5. Governance Registry

`Governance_registry`는 런타임 파라미터의 거버넌 가능 표면(governable surface)을 선언한다. `Runtime_params` 모듈에 등록된 파라미터는 검증 범위 내에서만 변경 가능.

| Surface | 파라미터 | 위험 |
|---------|---------|------|
| autonomy_behavior | tick_interval(60-14400s), agents_per_tick(1-20), quiet_start/end(0-23h) | Low |
| autonomy_limits | max_daily_actions(1-100), max_posts_per_day(1-50) | Low |
| board_policy | message.max_count(10-10000) | Low |
| inference_config | default_model(1-100 chars), timeout(5-300s) | High |

---

## 6. Operator Control

`lib/operator/` sub-library는 운영자(human 또는 supervisor agent)의 제어 평면(control plane)을 구현한다.

### 6.1 모듈 구조

| 모듈 | 역할 |
|------|------|
| `operator_pending_confirm.ml/.mli` | 미확인 조치 큐. 토큰 기반 confirm/deny 흐름 |
| `operator_control.ml/.mli` | 통합 facade. snapshot, action, confirm, judgment |
| `operator_control_snapshot.ml` | 상태 스냅샷 조립 |
| `operator_control_action.ml` | 구조화된 조치 실행 |
| `operator_digest.ml/.mli` | 개입 지향 다이제스트 |
| `operator_digest_session.ml` | 팀 세션 다이제스트 |
| `operator_digest_event.ml` | 이벤트 기반 다이제스트 |
| `operator_digest_guidance.ml` | 추천 행동 생성 |
| `operator_digest_types.ml` | 다이제스트 타입 정의 |
| `operator_judgment.ml` | 운영 판단(operator judgment) 저장/조회 |
| `operator_approval.ml` | OAS Approval pipeline 연동 |

### 6.2 Pending Confirm 흐름

고위험 조치는 preview-confirm 2단계로 실행된다.

```
masc_operator_action(action_type=X) ->
  confirm_required=true ->
    pending_confirm 저장 (token, trace_id, expires_at) ->
      masc_operator_confirm(confirm_token, decision=confirm|deny) ->
        confirm: 실제 실행
        deny:    취소
```

**파일 영속:** `.masc/operator/pending_confirms.json`

### 6.3 Operator Action 타입

| action_type | target_type | confirm_required |
|------------|-------------|------------------|
| broadcast | room | No |
| room_pause / room_resume | room | Yes / No |
| social_sweep | room | No |
| team_note / team_broadcast | team_session | No |
| team_task_inject | team_session | Yes |
| team_worker_spawn_batch | team_session | Yes |
| team_stop | team_session | Yes |
| keeper_message / keeper_probe / keeper_recover | keeper | No / No / No |

### 6.4 Snapshot & Digest

- **Snapshot** (`masc_operator_snapshot`) -- 원시 상태 데이터. view 모드: summary, sessions, keepers, messages, full
- **Digest** (`masc_operator_digest`) -- 개입 지향 분석. 건강 상태, 주의 항목, 명령 평면 검색, microarch 신호, 추천 행동 포함

### 6.5 Operator Judgment

운영자 또는 keeper가 작성하는 지속적 판단 기록.

- surface: `command.intervene`, `command.governance`
- target_type: `room`, `team_session`
- 신선도(freshness) TTL, 신뢰도(confidence), 증거 참조 포함
- `masc_operator_judgment_write` / `masc_operator_judgment_latest` 도구로 접근

---

## 7. MCP Tool Surface

### 7.1 Council 도구 (Tool_council)

| 도구명 | 역할 |
|-------|------|
| `masc_petition_submit` | 거버넌스 청원 제출 |
| `masc_case_brief_submit` | 사건에 의견서 제출 (판결+실행명령 자동 생성) |
| `masc_cases` | 사건 목록 조회 (status 필터, include_test) |
| `masc_case_status` | 개별 사건 번들(petition+ruling+order) 조회 |
| `masc_ruling_status` | 판결 상세 조회 |
| `masc_governance_rule` | 명시적 판결(approve/deny/dismiss) 작성 |
| `masc_execution_orders` | 실행 명령 목록/상세/결정(confirm/deny) |
| `masc_governance_status` | 거버넌스 전체 현황 통계 |
| `masc_governance_feed` | 거버넌스 피드 |
| `masc_runtime_params` | 런타임 파라미터 조회 |
| `masc_set_param` | 런타임 파라미터 변경 (청원 자동 생성) |
| `masc_execute` | 토픽 매칭 기반 액션 실행 |
| `masc_execute_dry_run` | 실행 시뮬레이션 |

### 7.2 Operator 도구 (Tool_operator)

| 도구명 | 역할 |
|-------|------|
| `masc_operator_snapshot` | 제어 평면 통합 상태 조회 |
| `masc_operator_digest` | 개입 지향 다이제스트 조회 |
| `masc_operator_action` | 구조화된 조치 실행/미리보기 |
| `masc_operator_confirm` | 미확인 조치 승인/거부 |
| `masc_operator_judgment_write` | 상주 판단 저장 (내부 도구) |
| `masc_operator_judgment_latest` | 최신 판단 조회 (내부 도구) |

Remote 모드에서는 judgment_write/latest를 제외한 4개 도구만 노출.

### 7.3 Control 도구 (Tool_control)

| 도구명 | 역할 |
|-------|------|
| `masc_pause` / `masc_resume` | 룸 일시정지/재개 |
| `masc_pause_status` | 일시정지 상태 조회 |

---

## 8. 불변식 (Invariants)

1. **Debate 원자적 쓰기:** 모든 debate 파일 쓰기는 temp file + rename. 파일 손상 불가.
2. **Consensus 중복 투표 방지:** 동일 agent의 동일 session 투표는 `Already_voted` 에러.
3. **Router 90/10 목표:** 쿼리의 90%는 Tiny/Small/Medium, 10%만 Large/Giant. `Stats` 모듈로 추적.
4. **Balance 지배 방지:** 연속 3회 승리 시 ForcedRotation 발동.
5. **Loop Guard 3중 방어:** max_turns, identical_pattern, cooldown 중 하나라도 위반 시 발언 차단.
6. **Thread_persist 파일 우선:** 파일 쓰기 실패 = 연산 실패. Neo4j 실패 = 로그만 기록.
7. **Governance V2 중복 감지:** `normalized_key` + `source_refs`로 동일 사건 merge. 파일 락으로 경합 방지.
8. **Pipeline 위험 분류 결정론:** 동일 도구명은 항상 동일 위험 수준. 입력 값은 현재 무시(`input:_`).
9. **Pending confirm 만료:** 만료된 토큰은 자동 필터링. 만료 후 confirm 시도 시 실패.

---

## 9. 저장소 레이아웃

```
.masc/
  debates/               # Debate 파일 (debate-*.json)
  consensus/             # Consensus 세션 파일 (uuid.json)
  governance_v2/
    petitions/           # 청원 (petition-*.json)
    cases/               # 사건 (case-*.json) + _submit.lock
    rulings/             # 판결 (case-id.json)
    execution_orders/    # 실행 명령 (case-id.json)
  operator/
    pending_confirms.json
  config/                # Executor config 변경 기록
  notifications.jsonl    # Executor 알림 기록
```

---

## 10. 의존 관계

```
Tool_council, Tool_operator, Tool_control
         |              |
    Council (facade)    Operator_control (facade)
    /  |  |  \              |
Debate Consensus Router  Operator_pending_confirm
       Balance  Executor Operator_digest
   Conversation          Operator_judgment
   Governance_v2         Operator_approval (-> OAS)
   Loop_guard
   Thread_persist -----> Neo4j (best-effort)

Governance_pipeline ----> Tool_dispatch.pre_hook
Governance_registry ----> Runtime_params
```

---

## 11. 제한 사항 및 알려진 문제

- Router의 쿼리 분류는 키워드 매칭 기반이며 LLM 추론을 사용하지 않음. 복잡한 쿼리에서 분류 정확도가 낮을 수 있음.
- Governance V2 중복 감지는 `normalized_key` 문자열 비교에 의존하며, 의미적 중복은 감지하지 못함.
- Thread_persist의 Neo4j 동기화는 개별 Cypher 쿼리 순차 실행. 대규모 스레드에서 성능 저하 가능.
- Governance Pipeline의 위험 분류는 도구 이름만 사용하며 입력 인자를 검사하지 않음(`input:_`).
- Consensus 세션 저장소는 in-memory Hashtbl이 primary. 프로세스 재시작 시 파일에서 복원되나 쓰기 실패 시 데이터 유실 가능.
