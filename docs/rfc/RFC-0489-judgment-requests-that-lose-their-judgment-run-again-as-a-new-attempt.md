---
rfc: "0489"
title: "Goal 검증이 판정 없이 끝나면 새 시도로 다시 판정한다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0387"]
---

# RFC-0489 — 판정을 잃은 Goal 검증은 새 시도로 다시 판정한다

## 0. 요약

- 11-04 08:55:28Z 에 wkbl 1.0.0 Goal 이 완료를 요청했다. 검토는 08:59:29Z 의 SIGTERM 에 241초 만에 취소됐다.
- 그 뒤 25시간 동안 검사가 21번 이 줄만 남겼다: `goal verifier deferred ... gate=Original_pending reason=Goal reviewer may have dispatched; no automatic replay`.
- Goal 은 `verifying` 에 머물렀고 알림은 없었다. 11-05 10:25Z 에 운영자가 Reopen 하고 다시 요청하자 5분 만에 판정이 나왔다.
- 같은 모양이 10-30~11-01 에 `goal-1790248232808-05fe959c` 에서 26번 있었다.
- 횟수는 `rg -c "goal verifier deferred goal_id=goal-[0-9]+-<id 끝 8자>" ~/me/.masc/logs/` 로 셌다. 로그는 10-29~11-05 의 8일치만 남아 있다.
- Goal 검증은 판정만 한다. 판정은 같은 프로세스 안의 콜백으로만 들어오고, 저장한 뒤 커밋으로만 기록에 들어간다.
- 그런데 Goal 검증은 부작용이 있는 요청의 규칙을 따른다. "결과를 모르면 다시 보내지 않는다."
- 이 RFC 는 세 가지를 바꾼다.
  1. 호출이 돌아온 제공자 실패는 결과가 정해진 실패로 본다. 같은 시도 안에서 다음 검토자 slot 으로 넘어간다.
  2. 판정 없이 끝난 실행은 그 사실을 거절로 기록하고 다음 시도(attempt+1)를 만든다.
  3. 다음 시도는 부모 원본을 복사하지 않고 지금 권한으로 새로 만든다.
- 새 Goal 상태와 Gate 는 없다. 공용 진행 규약은 한 곳을 넓힌다(2.5).

## 1. 지금

좌표는 main `f272869591e` 에서 읽었다. 파일 이름 없이 적은 줄 번호는 바로 앞에 적은 파일의 줄이다.

### 1.1 Goal 검증이 멈추는 길

| 들어오는 길 | 남는 기록 | 다음 검사 |
| --- | --- | --- |
| 재시작·Drop·Reopen 으로 검토 fiber 가 취소됨 | `goal_verifier_worker.ml:704-715` 가 `Outcome_unknown {cause="review_cancelled"}` 를 쓴다 | `:630` 이 `Dispatch_pending _` 를 보고 "no automatic replay" 로 끝낸다 |
| 검토 fiber 밖으로 예외가 나옴 | 같은 처리기가 `cause="review_raised"` 를 쓴다(`:705`) | `:630` 과 같다 |
| 보낸 뒤 제공자 실패(timeout, 네트워크, parse 오류, 내부 오류) | `anti_rationalization.ml:604-620` 이 결과 모름으로 분류한다. `:834` 가 failover 를 멈추고 `:930` 이 남은 slot 을 비운다. 그다음 `goal_verifier_worker.ml:673` 이 결과 모름을 쓴다 | `goal_verifier_worker.ml:691` 이 `Execution_pending` 을 돌려준다 |
| 판정 저장 실패(`Retention_failed`) | 아무것도 안 쓴다. 보통 `Dispatch_pending None` 이 남는다. 저장이 `Unconfirmed` 로 끝났으면 `Judged` 가 이미 저장됐을 수 있다 | `:630` 과 같다 |
| SIGKILL·OOM·강제 종료 | 처리기가 돌지 못한다. `Dispatch_pending None` 이 남는다 | `:630` 과 같다 |
| 배포 뒤의 다음 시도 | 다음 시도는 부모 원본에서 attempt 만 바꿔 복사한다(`goal_verifier_original.ml:157-159`). `restore_child` 는 그 복사본과 바이트가 같은지 본다(`goal_verifier_worker.ml:516-521`) | 배포가 Goal 조회 도구의 설명이나 schema 를 바꾸면 `lookup_binding`(`verification_authority_tools.ml:860-872`)이 달라진다. `run` 이 `Authority_changed` 로 거절한다(`goal_verifier_worker.ml:633-637`) |

- 제공자 실패 갈래에는 결정적 실패도 들어 있다. 검토자 안에서 난 예외는 `Internal` 로 바뀌어(`anti_rationalization.ml:845-850`) 결과 모름이 된다. slot 1 이 매번 parse 오류를 내면 slot 2 는 한 번도 불리지 않는다.
- `goal_verification_agent.ml:515-521` 은 이 결과를 `Not_reviewed {gate="Original_pending"; retryable_runtimes=[]}` 나 `Proof_lookup_unavailable` 로 바꾼다.
- `schedule_retry`(`:737`)는 재시도할 런타임이 있을 때만 타이머를 건다. 두 결과 모두 타이머가 없다(`:779`). 실패한 일은 스스로 큐에 다시 들어가지 않는다(`:798-800`).
- 운영자나 Keeper 가 다시 요청해도 `request_retry`(`goal_verifier_worker.ml:606-609`)가 거절한다.
- #48000 이 정체를 알리던 Board 글을 지웠다. 남는 신호는 WARN 줄과 실행 원장 행뿐이다.
- 시험 `test/test_goal_verifier_worker.ml:336-348` 은 취소된 원본을 다시 돌리지 않는다고 단언한다.

### 1.2 지금 규칙이 지키는 것

- 공용 규약 `lane_addon_request_progress.mli:63-64` 는 대기·결과 모름·worker 없음이면 같은 원본을 다시 보내지 않게 한다. 보낸 요청이 바깥에 효과를 냈을 수 있는 경우에 맞는 규칙이다.
- #47530 은 Goal 재요청을 막으며 이유를 적었다. "pending 기록만으로는 이전 실행이 끝났다는 걸 알 수 없다."

### 1.3 Goal 검증에서 맞는 사실

- Goal 판정은 같은 프로세스 안의 콜백 하나로만 들어온다(`goal_verifier_worker.ml:684-685` 의 `~on_verdict:retain_reply`).
- Goal 검토는 실행 기록(execution journal)을 쓰지 않는다. `run_retained`(`anti_rationalization.ml:1078-1084`)는 `execution_owner` 를 받지 않는다. 늦게 도착한 판정을 다시 읽는 길이 없다.
- 그래서 검토 호출이 돌아왔는데 판정이 없으면, 판정이 오지 않은 것은 정해진 사실이다. Goal 조회 도구는 읽기만 한다.
- 판정을 저장하지 못한 원본은 커밋할 수 없다. 규약은 `Dispatch_pending` 에서만 `Judged` 로 가게 한다(`lane_addon_request_progress.ml:158-161`).
- 규약은 `Dispatch_pending` 에서 `Rejected` 로 가는 실행 거절을 허용한다(`:187`).
- base path 는 프로세스 하나만 쥔다(`server_startup_takeover.mli:117`).
  - 서버와 stdio 는 같은 lease 를 쥐고 Goal 검토를 돌린다(`bin/main_stdio_eio.ml:55`, `:157`, `server_runtime_bootstrap.ml:1436-1438`).
  - `bin/deployment_preflight_helper.ml:443` 과 `bin/masc_checkpoint_purge.ml:315` 는 lease 를 쥐지만 Goal 검토는 돌리지 않는다.
- 한 프로세스 안에서 Goal 검토 runtime 은 하나다(`goal_verification_agent.ml:969` 의 CAS).
- constitution 은 비용을 문제 삼지 않고(`cost_and_observability`) 하드 게이팅을 기본으로 두지 않는다(`gates`).

## 2. 제안

### 2.1 돌아온 제공자 실패는 정해진 실패다

- `run_retained` 는 `Retained_original` 대신 `Ordinary_review` 정책으로 돈다. 보낸 뒤 실패해도 `attempt_continuation`(`anti_rationalization.ml:834-836`)이 `Next_may_dispatch` 를 돌려준다. 남은 slot 도 비우지 않는다(`:930`).
- 재시도 여부는 기존 분류 `candidate_failure`(`:582-590`)가 정한다. `Reviews_again` 이면 타이머가 걸린다. `Producer_must_act` 와 `Model_absent` 면 걸리지 않는다.
- Goal worker 는 `unknown` 표시를 지운다(`goal_verifier_worker.ml:640`, `:653`, `:673`, `:691`). 실패 관찰은 지금처럼 증거로 남긴다.
- `Retained_original` 은 실행 기록이 있는 Task 검증(`review_rendered`, `anti_rationalization.ml:1072-1076`)만 쓴다.
- 결과: slot 1 이 parse 오류를 내도 slot 2 가 판정한다. 모든 slot 이 실패하면 기존 `Refused {stage=Execution}` 경로로 간다.

### 2.2 판정 없이 끝난 실행

`interruption = Cancelled | Raised`(`goal_verifier_worker.ml:22-27`)를 아래 합으로 바꾼다. 둘을 함께 두지 않는다.

```ocaml
type run_end =
  | Cancelled
  | Raised
  | Retention_failed

type refusal =
  | Reviewer_refused of reviewer_refusal
      (* 지금 goal_verifier_refusal/v1 이 담는 것 *)
  | Run_ended of
      { cause : run_end
      ; run : run_identity
      ; tools : Verification_run_registry.tool_observation list
      ; observations : Yojson.Safe.t list }
  | Owner_exited of { run : run_identity }
  | Authority_moved of { detail : string }
```

- `run` 이 `Dispatch_intended` 를 쓴 뒤 판정을 저장하지 않고 끝나면, 원본을 다시 읽는다. 아직 `Dispatch_pending` 이면 `Refused {stage=Execution; evidence=Run_ended ...}` 를 쓴다.
- 다시 읽었을 때 `Judged` 이면(`Unconfirmed` 저장이 실제로는 된 경우) 거절을 쓰지 않는다. 다음 검사가 커밋으로 간다.
- `Run_ended` 는 지금 `Outcome_unknown` 이 담던 run, tools, observations 를 그대로 담는다(`:673-675`, `:710-714`).
- 거절을 쓴 뒤 검사를 한 번 요청한다(`request_scan`). 실패한 일이 스스로 큐에 들어가지 않는 문제(`goal_verification_agent.ml:798-800`)를 이 요청이 메운다.

### 2.3 거절 증거는 Goal 쪽 phase 보기로만 읽는다

- 공용 규약의 `refusal.evidence` 는 Yojson 이다(`lane_addon_request_progress.mli:7`). 타입이 Goal 의 읽는 자리를 강제하지 못한다.
- Goal 모듈 하나(`Goal_verifier_refusal`)가 Progress phase 를 Goal 쪽 phase 로 바꾼다. 이 phase 의 `Rejected`·`Subdividing`·`Subdivided` 는 Yojson 대신 위 `refusal` 을 담는다.
- worker, host, agent 는 이 Goal 쪽 phase 만 match 한다. Progress phase 를 직접 match 하는 자리는 이 모듈 안에만 남는다.
- 지금 거절 증거를 읽는 자리는 약 10곳이다. 예: `goal_verifier_worker.ml:477-486`, `:508-515`, `:590-593`. 1층에서 `rg 'evidence' lib/keeper/goal_verifier_*.ml lib/goal_verification_agent.ml` 로 전부 옮긴다.
- 한 곳이라도 새 증거를 거절하면 `recover` 가 `Commit_refused` 를 돌려주고(`goal_verification_agent.ml:562-563`) Goal 이 다른 모양으로 다시 멈춘다. 이 보기가 그 경우를 컴파일 단계에서 없앤다.

### 2.4 다음 시도는 지금 권한으로 만든다

- 자동 시도와 명시 재요청 모두 `V.successor`(부모 복사) 대신 `Original.prepare ~attempt:(n+1) ~authority` 로 만든다. `authority` 는 지금 읽은 Goal 검토 권한이다.
- `restore_child` 는 바이트 비교 대신 이것을 본다.
  - subject(goal_id, request_id, criterion)가 부모와 같다.
  - attempt 가 부모보다 1 크다.
  - run 이 부모와 다르다.
- 권한이 맞는지는 지금처럼 `run` 이 `V.matches_authority` 로 본다(`goal_verifier_worker.ml:633-637`).
- subject 가 달라졌으면(Reopen, Drop, 기준 변경) 그 원본은 지금 요청의 것이 아니다. 새 시도를 만들지 않는다.

### 2.5 보내기 전에 권한이 바뀐 원본

- `Captured` 나 `Admission_wait` 원본이 배포를 지나면 subject 는 같고 조회 권한만 다를 수 있다. 지금은 `Authority_changed` → `Proof_lookup_unavailable` 로 영구히 멈춘다.
- 이 원본은 `Refused {stage=Before_dispatch; evidence=Authority_moved}` 로 끝낸다. 보낸 적이 없으므로 규약상 맞는 거절이다(`lane_addon_request_progress.ml:187`).
- 공용 규약은 지금 `Rejected {stage=Execution}` 뒤에만 `Successor_intended` 를 허용한다(`:191-195`). 이것을 `Rejected {stage=Before_dispatch}` 뒤에도 허용한다.
  - 근거: 보내기 전에 거절된 원본은 바깥에 효과를 낼 수 없다. 다음 시도가 효과를 겹치게 할 수 없다.
  - 이 규칙은 durable truth 를 지키지 않는 Gate 다. constitution `gates` 에 따라 넓힌다.
- 같은 원본을 다시 보내지 않는다는 규칙(`lane_addon_request_progress.mli:63-64`)은 그대로다.

### 2.6 주인 없는 `Dispatch_pending`

- `Worker.run` 이 자기 `Dispatch_intended` 를 쓰기 전에 원본이 이미 `Dispatch_pending` 이면, `Execution_pending` 대신 `Refused {stage=Execution; evidence=Owner_exited}` 를 쓴다(지금 `goal_verifier_worker.ml:630` 자리). 그리고 검사를 한 번 요청한다.
- 근거:
  - Goal 검토는 claim 아래에서만 돈다. 한 Goal 의 claim 은 한 번에 하나다(`goal_verification_agent.ml:658-661`).
  - claim 은 검토 fiber 가 돌아오거나, 취소된 fiber 가 처리기를 마친 뒤에 풀린다(`:803-811`).
  - 이 프로세스는 lease 를 쥐고 있고, Goal 검토 runtime 은 하나다(1.3).
  - 그러니 지금 claim 이 자기 실행을 시작하기 전에 본 `Dispatch_pending` 은 이미 끝난 실행이 남긴 것이다.
- 서버가 뜬 뒤 첫 검사도 같은 자리를 지난다. 시작 때만 도는 단계를 따로 두지 않는다.
- 이 규칙 하나로 세 경우가 풀린다.
  - SIGKILL
  - 2.2 의 거절 쓰기가 실패한 경우
  - 이미 멈춘 옛 원본(`Outcome_unknown` 을 담은 것 포함)
- 옛 기록을 옮기는 코드는 따로 쓰지 않는다.

### 2.7 언제 새 시도를 만드는가

| 거절 증거 | 다음 시도 |
| --- | --- |
| `Reviewer_refused` | 지금 규칙(`retryable_refusal`, `goal_verifier_worker.ml:477-486`)을 따른다 |
| `Run_ended Cancelled` | 자동 |
| `Run_ended Retention_failed` | 자동 |
| `Run_ended Raised` | 명시 재요청(`request_complete`)만 |
| `Owner_exited` | 자동 |
| `Authority_moved` | 자동 |

- `Raised` 만 자동에서 뺀다. 같은 입력에서 같은 예외가 나면 검사마다 같은 실패를 되풀이한다. 검토자 안의 예외는 `Internal` 로 돌아오므로(1.1) 2.1 의 분류를 따른다. `Raised` 는 그 밖에서 난 예외다.
- 자동 시도는 `select_frontier ~automatic:true` 의 기존 후속 시도 경로를 쓴다.

### 2.8 시험

기능 단위로 본다.

- Goal 검토 중 취소 → 다음 검사가 attempt 1 을 돌려 판정을 커밋한다. `test_goal_verifier_worker.ml:336-348` 의 단언을 이 동작으로 바꾼다.
- slot 1 이 parse 오류, slot 2 가 판정 → 같은 attempt 에서 slot 2 의 판정을 커밋한다.
- slot 하나가 보낸 뒤 timeout → `Reviews_again` 이면 타이머가 걸리고 attempt 1 이 돈다.
- `Raised` → 자동 시도가 없다. `request_complete` 로 다시 요청하면 attempt 1 이 돈다.
- 판정 저장이 `Unconfirmed` 였지만 `Judged` 가 저장됨 → 거절을 쓰지 않고 커밋한다.
- 서버 시작 뒤 첫 검사가 남은 `Dispatch_pending` 을 만남 → `Owner_exited` → attempt 1 이 돈다.
- 실행 중 거절 쓰기가 실패함 → 다음 검사가 `Owner_exited` 로 바꾸고 attempt 1 이 돈다.
- 같은 Goal 의 검토가 돌고 있는 동안 들어온 검사 → claim 을 얻지 못해 원본을 건드리지 않는다.
- 부모가 쓴 뒤 Goal 조회 도구 설명이 바뀜 → attempt 1 은 지금 권한으로 만들어져 돈다.
- `Admission_wait` 원본의 조회 권한이 바뀜 → `Authority_moved` → attempt 1 이 돈다.
- 판정을 잃은 원본은 커밋할 수 없다(`Rejected` 에서 `Judged` 로 못 간다).

## 3. 하지 않는 것

- 같은 원본을 다시 보내지 않는다는 공용 규칙은 바꾸지 않는다. 같은 원본이 아니라 다음 원본을 만든다.
- Task 검증(`verifier_review_worker.ml`, `completion_authority_agent.ml`)은 바꾸지 않는다. 실행 기록에서 늦게 도착한 판정을 다시 읽는다(`verifier_review_execution.ml:94-131`). "판정이 다시 오지 않는다"가 맞지 않는다.
- 시도 횟수 상한, cooldown, 정체 알림 글을 넣지 않는다.
- Goal 검증 말고 다른 판정 요청은 이 RFC 에서 바꾸지 않는다.

## 4. 고르지 않은 길

| 길 | 고르지 않은 이유 |
| --- | --- |
| 취소만 고친다 | 1.1 의 여섯 갈래 중 하나만 고친다. 나머지가 같은 정지를 남긴다 |
| 같은 원본을 다시 보낸다 | 공용 규약이 막는다. 판정을 잃은 원본은 `Judged` 로 갈 수도 없다 |
| 보낸 뒤 제공자 실패도 새 시도로 돌린다 | 이 RFC 의 첫 초안이었다. slot 1 의 결정적 실패가 attempt 마다 반복되고 slot 2 는 불리지 않는다. 기존 `candidate_failure` 분류도 무시한다 |
| 다음 시도를 지금처럼 부모에서 복사한다 | 같은 빌드로 재시작할 때만 풀린다. §0 의 원인은 배포 재시작이다 |
| 정체 알림 글을 되살린다 | 정체를 보이게만 하고 풀지 않는다 |

## 5. 층

1. Goal 쪽 phase 보기와 `refusal` 합. `interruption` 을 없애고 거절 증거를 읽는 자리를 모두 옮긴다. 동작은 바뀌지 않는다. 확인: CI Core type-check 와 `test_goal_verifier_worker`.
2. 돌아온 제공자 실패는 정해진 실패(2.1). 확인: slot failover 시험.
3. 판정 없이 끝난 실행 기록, 검사 요청, 주인 없는 `Dispatch_pending` 변환(2.2, 2.6). 확인: 취소·`Raised`·`Unconfirmed`·시작 시험.
4. 지금 권한으로 만드는 다음 시도, `Authority_moved`, 규약 확장(2.4, 2.5). 확인: 배포 시나리오 시험.
5. 배포 뒤 실측: 검토 중에 Goal 조회 도구 설명을 바꾼 빌드로 재시작한다. `goal-verification-runs.jsonl` 에 attempt 1 의 `committed` 가 남는지 본다.

## 6. 열린 질문

1. 2.5 의 규약 확장이 다른 사용처에 닿는가. `Successor_intended` 는 Task 검증, Librarian, workspace memory, original body inventory 도 쓴다. 그 코드가 `Subdividing` 의 refusal stage 를 `Execution` 으로 가정하는지 4층 전에 확인한다.
2. lease 디렉터리는 `MASC_BASE_PATH_LEASE_DIR` 가 없으면 TMPDIR 를 따른다(`host_config.ml:93-94`). TMPDIR 가 다른 두 프로세스는 같은 base path 의 lease 를 둘 다 쥘 수 있다. 그러면 2.6 이 다른 프로세스의 살아 있는 검토를 끊는다. 커밋이 두 번 나지는 않는다. 파일 잠금이 막고, `Rejected` 에서 `Judged` 로 갈 수 없기 때문이다. lease 위치는 이 RFC 밖에서 따로 다룬다.
3. Librarian admission, workspace memory curator, browser add-on 의 LLM 호출도 판정만 하는가. 그렇다면 같은 정지가 있는지 따로 본다.
4. 운영자 Drop·Reopen 도 검토 fiber 를 취소한다(`goal_verification_agent.ml:811`). 그 원본은 `Run_ended Cancelled` 로 남고, 요청이 바뀌어 새 시도는 생기지 않는다. 기록 이름이 사실과 맞는지만 확인한다.
