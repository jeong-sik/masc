---
rfc: "0500"
title: "서버가 멈춰 끊긴 Librarian 원본은 옮기고 다시 준비한다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["exact-outcome-unknown-names-its-cause", "librarian-history-settles-finished-originals"]
---

# RFC-0500: 서버가 멈춰 끊긴 Librarian 원본은 옮기고 다시 준비한다

- 상태: 초안
- 이슈: #48996
- 근거: §1 의 수치는 2026-11-06 07시(KST) 운영 workspace 에서 셌다. 기록은 구조만 읽었다. 사건 이름, 거절 증거의 `status`·`cause`, 시도 개수, 서버 로그의 줄 수다. 요청 본문과 판정 내용은 열지 않았다. §2 의 코드는 `origin/main` `f2d98655513` 이다.

## 0. 요약

Librarian 원본이 모델을 부르는 중에 서버가 멈추면, 호스트는 그 시도를 `outcome_unknown`(`cause=interrupted`)으로 끝낸다. 지금 Librarian 은 이 원본을 영원히 기다린다. admission 은 그 part 뒤의 후보를 하나도 커밋하지 못하고, history 는 그 범위를 다시 잡지 못한다.

이 RFC 는 `exact-outcome-unknown-names-its-cause` 가 Curator 에 둔 규칙을 Librarian 에 넓힌다.

- 거절 증거가 `interrupted` 인 원본만 다시 준비한다. `cut`·`raised` 와 다른 거절은 지금처럼 막는다.
- 다시 준비하는 방법은 원본을 settled 보관 위치로 옮기는 것이다. 다음 패스는 그 자리에 원본이 없는 상태를 보고 새 원본을 만든다.
- 1층은 admission, 2층은 history 다.

## 1. 문제

### 1.1 멈춘 Keeper

11-05(UTC) 서버 로그에 `Librarian explicit admission remains pending: Original host execution has no exclusive input-capacity proof` 가 1,463번 있다.

| 날짜(UTC) | 이 대기가 나온 Keeper | 서버 부팅 |
|---|---:|---:|
| 11-03 | 1 | 7 |
| 11-04 | 5 | 29 |
| 11-05 | 6 | 9 |

- 6명 모두 이 대기가 처음 나온 뒤로 `committed and acknowledged` 가 0번이다. 그 전에는 Keeper 마다 144~458번 있었다.
- 가장 오래 멈춘 Keeper 는 11-03 00:03Z 부터다.
- 멈춘 Keeper 도 깨어날 때마다 `run_queue` 가 `discover` 를 세 번 하고 같은 대기로 끝난다(#48912).

### 1.2 기록

`lane-addons/tool-request-owners` 의 owner 기록 가운데 마지막 사건이 `refused` 인 것은 29개다.

| scope | 개수 | 거절 증거 | 짝인 호스트 Exact 기록 |
|---|---:|---|---|
| `keeper-librarian-execution-*`(admission) | 6 | `stage=execution`, `{"status":"outcome_unknown","cause":"interrupted"}` | 시도 1번, `cause=interrupted` |
| `keeper-librarian-history-execution-*`(history) | 23 | 같음 | 같음 |

29개 모두 서버 프로세스가 호출 중에 멈춘 경우다. owner 기록의 거절 증거에 이미 `cause` 가 있다.

## 2. 지금 있는 것

### 2.1 admission

- `evaluate` 는 `Dispatch.resume` 이 `Refused` 를 돌려주면 `size_refused` 로 간다(`keeper_librarian_admission_owner.ml:256`).
- `size_refused` 는 크기 증거(`Parts.execution_size_evidence`)를 찾는다. 증거가 없으면 `Waiting "Original host execution has no exclusive input-capacity proof"` 를 돌려준다(`:166-169`).
- part 하나에는 원본 실행을 하나만 둘 수 있다. `discover` 가 둘째 실행을 거부한다(`:73`).
- 그래서 `interrupted` 로 끝난 실행을 가진 part 는 앞으로 나갈 길이 없다. 이 part 가 `Waiting` 을 돌려주면 walk 가 끝나므로 뒤 part 와 새 후보도 기다린다.
- admission 은 끝난 원본을 settled 위치로 옮기지 않는다. 11-06 의 settled 위치에는 admission scope 기록이 없다.

### 2.2 history

- `Submit.resume` 결과가 `Final (Refusal (Exact.Outcome_unknown, record))` 이면 `Pending (Worker_unknown, record)` 를 돌려준다(`keeper_librarian_durable_owner.ml:179`). 원인을 보지 않는다.
- 실행 단계의 다른 종단 거절은 `Refused` 다. `librarian-history-settles-finished-originals` §3.1 이 그 원본을 옮기고, 다음 패스가 같은 범위를 새 원본으로 다시 잡는다. 거절은 읽기 위치를 건드리지 않는다.

### 2.3 Curator

- `refusal_blocks`(`workspace_memory_execution_capture.ml:424`)가 거절 증거를 `Exact.retained_final_of_json` 으로 읽는다.
- `Retained_unknown Interrupted` 만 막지 않는다. `Cut`·`Raised` 와 호출 결과 거절은 막는다. 생성자를 모두 적는다.
- 막지 않는 원본의 사슬은 답을 받은 사슬처럼 옮긴다(`settled_chains`).

### 2.4 설계 문서와 앞선 RFC

- `docs/design/librarian-addon-execution.md:54` 는 "An unknown sent outcome does not authorize another model call." 이라고 적는다.
- `exact-outcome-unknown-names-its-cause` §3.7 은 Librarian 의 동작을 바꾸지 않았다. 그때 라이브에 Librarian 설치가 없었다.

## 3. 결정

### 3.1 원인은 owner 기록의 거절 증거에서 읽는다

원본이 다음 셋을 모두 만족할 때만 "다시 준비할 원본"이다.

1. 진행 단계가 `Rejected` 다.
2. 거절 단계가 `Execution` 이다.
3. 거절 증거를 `Exact.retained_final_of_json` 으로 읽은 값이 `Retained_unknown Interrupted` 다.

- 읽을 때 생성자를 모두 적는다. Curator 의 `refusal_blocks` 와 같은 모양이다.
- 증거를 읽지 못하면 오류다. 기다림으로 바꾸지 않는다.
- 호스트 Exact 기록은 읽지 않는다. owner 기록에 원인이 있다(§1.2).

`Retained_unknown (Cut | Raised)` 와 호출 결과 거절은 지금처럼 막는다. 다만 admission 의 대기 이유에 원인을 싣는다. 지금은 원인이 무엇이든 "input-capacity proof 가 없다"로만 보인다.

### 3.2 1층: admission 은 끊긴 실행을 옮긴다

`evaluate` 의 `Refused` 갈래(`:256`)에서 옮긴다.

- `Rejected {stage = Execution; _}` 인 기록은 패스마다 `Submit.resume` 에서 `Final` 로, `Dispatch.resume` 에서 `Refused` 로 돌아온다(`lane_addon_submit_once.ml:187-196`). 그래서 이미 멈춘 실행과 이번 패스가 처음 거절을 쓴 실행이 같은 갈래로 온다.
- 대상: 그 갈래의 기록 가운데 §3.1 을 만족하는 실행. 나머지는 지금처럼 `size_refused` 로 간다.
- 옮기기 전에 그 실행을 가리키는 기록이 없는지 본다.
  - gate: 판정 전에 끊긴 실행이라 gate 가 없어야 한다. gate 가 있으면 오류다.
  - partition: partition 은 크기 증거가 있는 실행만 가리킨다. 가리키는 partition 이 있으면 오류다.
- 옮기는 날짜는 그 실행 요청 ID 의 uuid v7 날짜다. history 의 `minted_on` 과 같은 방법이다.
- 옮긴 뒤 walk 는 같은 part 로 돌아간다. 다음 `discover` 는 그 part 를 실행이 없는 part 로 본다. `evaluate` 는 `new_capture` 로 새 요청 ID 의 실행을 만든다.
- 같은 패스 안에서 다시 돌지 않는다. 새 실행이 이 프로세스 안에서 끊기면 `cut` 이라 옮기지 않는다.
- 새 실행은 그 순간의 Memory 를 다시 캡처한다. 설계 문서의 "fresh Memory capture at the moment each sibling is actually evaluated" 와 같다.
- 옮긴 실행 하나마다 `Log.Keeper.info` 한 줄을 남긴다. 요청 ID 와 원인을 적는다.

"Complete discovery precedes every local repair" 는 그대로다. walk 는 part 마다 `discover` 로 전체를 검증한 뒤 `evaluate` 한다. 옮기기는 그 뒤의 수리다.

### 3.3 2층: history 는 끊긴 원본을 종단 거절로 다룬다

- `Final (Refusal (Exact.Outcome_unknown, record))` 에서 §3.1 을 만족하면 `Refused` 를 돌려준다. 그 밖의 `Outcome_unknown` 은 지금처럼 `Pending (Worker_unknown, _)` 이다.
- 그다음은 기존 경로다. `librarian-history-settles-finished-originals` §3.1 이 원본을 옮기고, 다음 패스가 같은 범위를 새 원본으로 잡는다.
- 2층 PR 은 replacement intent, gate, predecessor 사슬과 겹치는 경우를 확인한다. 1층이 그것을 정하지 않는다.

### 3.4 설계 문서를 고친다

`docs/design/librarian-addon-execution.md:54` 의 문장을 이렇게 바꾼다.

> An unknown sent outcome does not authorize another model call, except when the host retained `interrupted`: the process that started the attempt stopped before it ended. That original settles and the next pass prepares it again.

### 3.5 되풀이

- `interrupted` 는 시도를 시작한 프로세스가 멈췄을 때만 생긴다. 같은 프로세스 안에서 끊기면 `cut` 이고, 그것은 막는다.
- 그래서 같은 원본이 다시 `interrupted` 로 끝나려면 그때마다 서버가 멈춰야 한다.
- 입력이 서버를 죽이는 경우에는 부팅마다 한 번씩 다시 부른다. 이 RFC 는 횟수 상한을 두지 않는다.
  - 옮길 때마다 남는 로그 줄로 같은 part 의 되풀이를 센다.
  - 되풀이가 보이면 그때 따로 정한다.

### 3.6 하드컷과 migration 은 없다

- 29개 원본 모두 거절 증거에 `cause` 가 있다(§1.2). 새 코드가 다음 패스에서 그대로 읽는다.
- 원인 없는 옛 `outcome_unknown` 증거가 남아 있으면 §3.1 이 읽지 못해 오류가 난다. 배포 직전에 다시 세고, 있으면 그 owner 의 scope 를 `exact-outcome-unknown-names-its-cause` §3.8-3 대로 옮긴다. 11-06 에는 0개였다.

## 4. 다른 방법

| 방법 | 받지 않는 까닭 |
|---|---|
| 같은 part 에 후속 실행을 두고 `predecessor` 로 잇는다 | "part 당 실행 하나"가 깨진다. `for_part`, gate 의 `execution_id`, forest 검증, 복구 경로를 모두 다시 증명해야 한다 |
| `interrupted` 를 크기 거절로 다룬다 | 크기 증거가 아니다. 쪼개면 끊긴 까닭과 상관없는 입력 분할이 생긴다 |
| 원인과 상관없이 `outcome_unknown` 을 모두 다시 준비한다 | `cut`·`raised` 는 같은 입력에서 다시 날 수 있다. 막는 장치가 없어진다 |
| 운영자가 지우고 설치한다 | 서버가 멈출 때마다 또 생긴다. 11-03~11-05 에 부팅이 45번 있었다 |

## 5. 층

1. RFC(이 문서)
2. 1층: admission. §3.1 의 읽기, §3.2 의 옮기기, 대기 이유의 원인.
3. 2층: history. §3.3.

설계 문서 문장(§3.4)은 1층 PR 이 고친다.

## 6. 검증

### 6.1 시험

- admission: 호스트 Exact 기록에 다른 프로세스가 남긴 시작 표시(`{"started": <다른 incarnation>}`)를 둔다. 서버가 호출 중에 멈춘 뒤 남는 모양이다. `run_queue` 를 돌리면 그 실행이 settled 위치로 가고, 같은 part 에 새 요청 ID 의 실행이 생겨 후보가 커밋된다.
- admission: 거절 증거가 `cut`·`raised` 이면 실행이 그대로 남고, 대기 이유에 그 원인이 나온다.
- admission: 끊긴 실행을 gate 나 partition 이 가리키면 옮기지 않고 오류로 끝난다.
- history(2층): `interrupted` 원본이 종단 거절로 옮겨지고, 다음 패스가 같은 범위를 새 원본으로 잡는다.

### 6.2 운영

- 1층 배포 뒤 첫 패스에서 admission 원본 6개가 옮겨진다. 6명의 `committed and acknowledged` 가 다시 나온다.
- "no exclusive input-capacity proof" 대기는 실제 크기 거절일 때만 남는다.
- 2층 배포 뒤 history 원본 23개가 옮겨지고 그 범위가 다시 잡힌다.

## 7. 열린 질문

- 옮긴 원본은 RFC-0498 이 정하는 settled 보관 규칙을 따른다. 그 규칙이 본문을 지우면, 되풀이를 세는 근거는 로그 줄만 남는다.
