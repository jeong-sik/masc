---
rfc: "librarian-gate-waits-on-the-destination-not-on-passes"
title: "판정 서버가 거절하면 gate 는 그 서버가 다시 받을 때까지 새 시도를 만들지 않는다"
status: Superseded
created: 2026-11-16
updated: 2026-11-23
author: vincent + claude
supersedes: []
superseded_by: "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
related: ["librarian-absorb-gate", "0484", "0433", "provider-path-rest"]
---

# 판정 서버가 거절하면 gate 는 새 시도를 만들지 않는다

## 0. 요약

- TypeSafe 크레딧이 떨어지자 Librarian 흡수 판정(gate)이 pass 마다 TypeSafe 에 다시 묻고, 물을 때마다 gate 기록을 하나 더 남겼다.
- pass 는 그 기록 사슬을 다시 검증한다. 기록이 늘수록 pass 가 느려졌고, 11-16 운영 서버는 CPU 400% 를 넘겼다.
- 원인은 두 가지다.
  - 판정 서버의 거절이 `string` 으로 바뀌어, 판정 실패와 구별되지 않는다.
  - 새 시도를 만드는 계기가 "앞 시도가 실패했다" 하나뿐이다.
- 이 RFC 는 두 가지를 정한다.
  - 실패한 판정의 원인을 문자열이 아니라 typed 평가 결과(`Typesafeai_client.failure`)에서 읽는다. 판정 서버 상태 때문의 거절은 따로 갈래를 갖는다.
  - 그런 거절 뒤의 새 시도는, 지금 설정이 물을 판정 서버 중 하나라도 거절 중이 아닐 때만 만든다. 모두 거절 중이면 아무것도 쓰지 않고 기다린다.
- 시도 기록과 transcript 는 지금 그대로다. 시간·횟수 상한, 문자열 분류, 새 동시 실행 제한은 쓰지 않는다.

## 1. 지금

### 1.1 11-16 운영 서버에서 잰 값

조건: 운영 서버 `0b295ab59550`(02:06Z 기동) → 재기동(02:08:55Z). 읽기만 했다.

- 이슈 #52382: 02:06~10:13Z 에 `typesafeai: HTTP 402 ... billing_error` 로그가 2,448줄이다. gate 기록은 약 820개(19+6 scope)였다. 그중 800개가 거절 뒤 다음 시도로 이어진 기록이다.
- 재기동 뒤 02:09~02:18Z 의 `durable Librarian inventory validated` 줄: gate 기록 15~71개인 Keeper 의 pass 하나가 50~303초 걸렸다. 예: `code-reviewer-uncle` 71개 303초, `context-reviewer` 53개 262초.
- 같은 시각 `sample` 5초: CPU 는 domain 작업 스레드의 `Keeper_librarian_original_gate` 사슬 복원(canonical JSON + sha256)에 몰렸다. 서버 RSS 는 약 27GB 였다.
- 같은 시각 배포 preflight(`deployment_preflight_helper.exe validate-stores`)는 13분 넘게 `lane-addon tool request owners` 검사에 머물렀다. 대상은 owner 기록 745개(51MB, 가장 큰 것 8.7MB)와 본문 910개(325MB)다.
- 02:15Z 쯤 운영자가 크레딧을 채웠다. 그 뒤 402 줄은 0 이다. 기록이 0개인 Keeper 의 pass 는 10~170ms 로 돌아왔다. masc CPU 는 62.7%, RSS 는 17GB 가 됐다. 이미 쌓인 사슬이 있는 Keeper 는 여전히 pass 마다 6~7초를 쓴다.

### 1.2 코드 (`origin/main` `706704b625a5`)

- TypeSafe 호출 실패는 typed 다. `Typesafeai_client.failure = { first_attempt; later_attempts }` 이고, 시도마다 `refusal` 을 가진다. `refusal_class` 는 `Payment_required | Credential_refused | Rate_limited | Server_error | Request_refused | Response_unusable | Transport` 로 닫혀 있다.
- 한 호출은 설정된 판정 서버를 차례로 묻는다. 모두 거절해야 `Error failure` 가 된다. 하나라도 답하면 `Ok` 다.
- gate 는 이 값을 문자열로 바꾼다. `lib/keeper/keeper_librarian_absorb_gate.ml` 의 `:811`, `:1282`, `:1665` 에서 `failure_to_string` 을 부른다(`:1303` 은 표시용 JSON). 결과는 `outcome = Failed of { reason : string; ... }` (`:259`) 다. 로컬 검증 실패(`validate_guidance`, `classify`)도 같은 `Failed` 다.
- 실패 여부는 `failure_detail : ... -> string option` (`:856`) 으로 읽는다. 이 함수를 6개 파일 16곳이 부른다. 새 시도를 만드는 자리는 셋이다.
  - `lib/keeper/keeper_librarian_admission_owner.ml:254~269` (`retry`)
  - `lib/keeper/keeper_librarian_floor_step_judgment.ml:107~113`
  - `lib/keeper/keeper_librarian_durable_commit.ml:361~367`
  - 셋 다 `Some _` 이고 `fresh_authority` 가 통과하면 `Journal.retain ~predecessor:(Some latest.request_id)` 로 새 시도를 만든다. 새 시도는 `Gate.resolve` 로 그때의 판정 서버 설정을 다시 잡는다.
- `fresh_authority` (`lib/keeper/keeper_librarian_durable_edge.ml:32`) 는 Keeper owner 와 Add-on 목적지 설정만 확인한다. 판정 서버가 지금 받는지는 보지 않는다.
- 한 시도의 transcript 는 바꿀 수 없다. 이미 답이 적힌 평가는 그대로여야 하고(`lib/keeper/keeper_librarian_original_gate.ml:194` "Gate completed prefix changed"), 시도는 처음 잡은 판정 서버 설정으로만 이어진다(`absorb_gate.ml:1724~1728`).
- 판정 서버의 최근 결과는 프로세스 메모리에 있다(`Typesafeai_client.outcomes`, `Answered | Refusing { since; last_at; last; last_answer_at }`, RFC-0484 §3.2). 답이 오면 `note_answer`(`typesafeai_client.ml:244`, 호출 `:279`)가 `Answered` 로 바꾼다. Board attention 도 같은 표를 채운다.
- 거절은 지금 어떤 깨우기도 만들지 않는다. admission 걸음은 `Waiting` 을 `Pending` 으로 바꾸고, `queue_refresh` 의 `Pending` 갈래는 `changed` 를 부르지 않는다. 그런데도 pass 는 다른 사건(턴 뒤 기억, Add-on 이벤트 등)으로 자주 깬다. 깰 때마다 세 자리가 새 시도를 만들었다.
- 서버가 뜨면 Librarian pass 가 한 번 돈다. 띄운 Keeper 는 자기 launch 에서, 띄우지 않은 Keeper 는 `submit_durable_for_unlaunched` 로 돈다.

## 2. 문제

판정 서버가 거절하면 아무것도 판정되지 않았다. 그런데 지금 gate 는 이것을 "판정을 시도했고 실패했다" 로 적는다. 그래서 pass 가 깰 때마다 새 시도를 만든다.

1. **기록이 외부 상태에 비례해 는다.** 크레딧이 없는 동안 pass 마다 durable 기록이 하나씩 생긴다. 끝이 없다.
2. **pass 비용이 기록에 비례해 는다.** pass 는 사슬을 다시 복원해서 검증한다. #52381 이 제곱 비용을 선형으로 줄이지만, 사슬이 계속 길어지는 문제는 남는다.

결과적으로 외부 결제 상태 하나가 서버 전체 CPU 를 정한다.

## 3. 결정

### 3.1 실패의 원인은 typed 평가 결과에서 읽는다

끝난 run 은 평가마다 `result : (evaluated, Typesafeai_client.failure) result` 를 이미 가진다. 새 시도 판단은 `Failed.reason : string` 을 읽지 않고 이 값을 읽는다.

```ocaml
(* Typesafeai_client *)
type refusal_owner =
  | Destination_state  (* Payment_required | Credential_refused | Rate_limited | Server_error | Transport *)
  | This_request       (* Request_refused | Response_unusable *)

(* Keeper_librarian_absorb_gate *)
type after_failure =
  | Retain_new_attempt
  | Wait_for_destination

val after_failure : live_authority -> run_result -> after_failure
```

- `refusal_owner` 는 `refusal_class` 를 빠짐없이 `match` 한다.
- 답을 못 받은 평가마다 원인을 읽는다.
  - `Error failure`: 모든 시도가 `Destination_state` 면 서버 상태 갈래, 하나라도 `This_request` 면 요청 갈래다.
  - `Ok` 인데 답이 decode 되지 않음: 요청 갈래다. 같은 요청에 같은 답이 온다.
- 원인이 하나도 없으면(가이드 검증 실패, 분류 실패, gate 를 쓸 수 없음) 지금처럼 새 시도를 만든다.
- 시도 기록, transcript, 시도가 끝나는 방식은 바꾸지 않는다. 거절로 끝난 시도는 지금처럼 끝난다.

### 3.2 모든 원인이 서버 상태이고, 물을 서버가 모두 아직 거절 중이면 기다린다

새 시도를 만드는 세 자리는 `failure_detail` 이 실패를 돌려줄 때 `after_failure` 를 부른다. 이 함수는 다음이 모두 참일 때만 `Wait_for_destination` 을 돌려준다.

| 조건 | 읽는 것 |
|---|---|
| 답을 못 받은 평가가 하나 이상 있고, 그 원인이 모두 서버 상태 갈래다 | run 의 `evaluations` |
| 지금 설정(`Gate.resolve`)이 물을 판정 서버가 모두 `Refusing` 이고, 마지막 거절이 서버 상태 갈래다 | `Typesafeai_client.destination_outcome` |

- `Wait_for_destination` 이면 새 시도를 만들지 않는다. 끝난 시도를 그대로 두고, 원본은 지금처럼 pending 으로 남는다. 아무것도 쓰지 않는다.
- 운영자가 목적지를 바꾸면 새 목적지는 이 프로세스가 아직 묻지 않은 서버다. 그래서 두 번째 조건이 거짓이 되고 새 시도를 만든다. 새 시도는 지금처럼 `Gate.resolve` 로 바뀐 설정을 잡는다.
- 판정 서버 표는 프로세스가 뜨면 빈다. 빈 표에서는 두 번째 조건이 거짓이라 새 시도를 한 번 만든다. 그 시도가 다시 거절되면 표가 `Refusing` 이 되고, 다시 기다린다.
- 요청 갈래 뒤의 새 시도 규칙은 이 RFC 가 바꾸지 않는다(§9).

이 절만으로 §2 의 1 과 2 가 멈춘다. 거절이 이어지는 동안 원본 하나의 gate 기록은 늘지 않는다.

### 3.3 판정 서버가 다시 답하면 기다리는 Keeper 를 한 번 깨운다

- `note_answer` 가 그 판정 서버의 결과를 `Refusing` 에서 `Answered` 로 바꿀 때, 그 한 번만 사건을 낸다. 이미 `Answered` 인 서버의 답은 사건을 내지 않는다.
- 이 사건은 Librarian 이 켜진 Keeper 마다 `Keeper_librarian_queue_signal.changed` 를 한 번 부른다. 깬 pass 는 §3.2 의 조건을 다시 읽는다.
- 깨울 Keeper 를 찾으려고 owner 기록 전체를 읽지 않는다. Add-on wake discovery 의 `Owner.fold_all_records` 는 쓰지 않는다(§9).
- 거절은 어떤 사건도 내지 않는다. 지금과 같다.
- Add-on 설정이 바뀌면 `Configuration_observed` 가 이미 Keeper 를 깨운다. 새 사건은 필요 없다.

## 4. 멈추지 않음의 논증

### 4.1 원본 하나의 gate 단계

| 앞 시도의 결과 | 지금 설정이 물을 서버 | 다음 | 기록 쓰기 |
|---|---|---|---|
| 판정 성공 | 상관없음 | 적용 | 지금 규칙 |
| 실패, 답 못 받은 평가 없음 | 상관없음 | 새 시도(지금 규칙) | 새 시도 기록 하나 |
| 실패, 원인에 요청 갈래가 있음 | 상관없음 | 새 시도(지금 규칙, §9) | 새 시도 기록 하나 |
| 실패, 원인이 모두 서버 상태 | 모두 서버 상태로 `Refusing` | 기다림 | 없음 |
| 실패, 원인이 모두 서버 상태 | 하나라도 `Answered` 이거나 묻지 않음 | 새 시도 | 새 시도 기록 하나 |

### 4.2 불변식

- **I1. 거절 구간마다 시도 하나:** 물을 판정 서버가 모두 `Refusing` 으로 머무는 동안, 원본 하나는 서버 상태 거절 뒤의 새 시도를 만들지 않는다. 새 시도는 서버가 답하거나, 설정이 바뀌거나, 프로세스가 새로 뜰 때만 생긴다.
- **I2. transcript 불변:** 이 RFC 는 시도 기록과 transcript 를 쓰는 방식을 바꾸지 않는다. 답은 한 번만 적히고, 끝난 앞부분은 바뀌지 않는다.
- **I3. 증거 유지:** 기다리는 원본의 마지막 시도는 `Typesafeai_client.failure` 를 담은 채 끝나 있다. 헌법 `failure_keeps_evidence` 와 같다.
- **I4. 새 게이트 없음:** 판정 서버로 가는 요청을 막거나 줄 세우는 장치를 더하지 않는다. §3.2 는 "새 시도 기록을 만들지 않는다" 만 정한다. 새 원본의 첫 시도는 이 조건을 받지 않는다.

### 4.3 진행

- **가정:** Keeper 턴이 계속 끝난다. 채팅 큐의 진행 조건과 같은 가정이다.
- 턴이 끝나면 새 기억이 생기고, 새 원본이 생긴다. 새 원본의 첫 시도는 §3.2 의 조건을 받지 않으므로 판정 서버에 묻는다.
- 판정 서버가 다시 받으면 그 첫 시도가 `Answered` 를 받는다. Board attention 의 판정도 같은 서버를 부르면 같은 일을 한다.
- `Refusing → Answered` 가 §3.3 의 사건을 내고, 기다리던 원본마다 pass 가 깬다. 각 원본은 새 시도를 하나 만든다.
- 판정 서버가 영영 거절하면 원본은 영영 기다린다. 이것은 멈춤이 아니라 외부 사실이다. `/health` 의 `operator_action_required` 가 그 사실을 보여 준다(RFC-0484).

### 4.4 대가

- 거절 구간에도 새 원본마다 요청이 하나씩 나간다. 그 수는 들어온 일의 양이다. pass 수가 아니다.
- 서버를 다시 띄우면 기다리던 원본마다 새 시도가 하나씩 생긴다. 재기동 수에 비례하고, 거절 시간에는 비례하지 않는다.
- 한가할 때 크레딧이 돌아오면, 기다리던 원본은 다음 사건까지 쉰다. 급한 일이 없는 시간이다.

## 5. 고르지 않은 길

- **시도를 끝내지 않고 같은 시도에서 다시 묻기:** 처음 안이었다. transcript 의 끝난 앞부분은 바꿀 수 없고(`original_gate.ml:194`), 거절 뒤에도 뒤 평가가 이어진다. 같은 시도는 처음 잡은 설정에 묶여서, 운영자가 설정을 고치면 영영 이어지지 못한다(`absorb_gate.ml:1724`).
- **거절 중인 판정 서버에 한 요청만 보내기:** 프로세스 전체의 새 게이트다. §3.2 만으로 기록이 늘지 않으니, durable 진실을 지키려고 필요한 장치가 아니다.
- **시간·횟수 상한, cooldown, maintenance pulse:** 헌법 `magic_number`·`budget_gate` 에 걸린다. #51655 의 11-15 댓글, #52382 와 같은 판단이다.
- **운영자의 "고쳤음" 확인 버튼:** 운영자는 이미 TypeSafe 에서 크레딧을 채웠다. 같은 사실을 masc 에 한 번 더 넣게 하는 일이다. RFC-0484 §3.4 도 확인(ack) 상태를 새 사실로 저장하지 않기로 했다.
- **로그 문장에서 402 를 찾기:** 문자열 분류다.
- **#52381 만으로 끝내기:** 사슬 하나를 읽는 비용은 줄지만 사슬이 계속 길어진다.

## 6. 층

1. **1층 — 기다림 조건**
   - `Typesafeai_client.refusal_owner`, `destination_outcome`.
   - `Gate.after_failure` 와 세 자리 연결(§3.1, §3.2).
   - 이 층만으로 거절 구간의 기록 증가가 멈춘다.
2. **2층 — 다시 답하면 깨우기**
   - §3.3 의 `Refusing → Answered` 사건과 깨우기.
3. **3층 — 결과 문자열 정리**
   - `Failed.reason : string` 과 `failure_detail : ... -> string option`(16곳)을 닫힌 합타입으로 바꾼다. 동작은 바뀌지 않는다.

RFC 를 맨 아래 층으로 두는 native stack 으로 쌓는다.

## 7. 검증

### 7.1 시험

가짜 판정 서버(402 를 돌려주다가 나중에 답하는 로컬 HTTP)로 Librarian 흡수를 돌린다. `feature_surface` 의 Librarian 기능 시험이다.

- 서버가 402 를 내는 동안 pass 를 여러 번 깨워도 원본의 gate 기록 수가 그대로다.
- 서버가 답하기 시작한 뒤 새 원본 하나가 판정을 받으면, 기다리던 원본이 새 시도를 하나 만들고 판정을 끝낸다.
- 거절 중에 판정 서버 설정을 바꾸면, 기다리던 원본이 바뀐 설정으로 새 시도를 만든다.
- 숫자·문구·snapshot 을 보는 시험은 만들지 않는다.

### 7.2 배포 뒤 측정

- 다음 거절 구간의 시작과 끝에 Keeper 마다 gate 기록 수를 센다. 그 사이 새로 생긴 원본 수만큼만 늘어야 한다.
- 같은 구간의 `durable Librarian inventory validated` 의 `elapsed_ms` 가 거절이 이어진 시간과 상관없이 거절 전 값과 같은 범위에 있다.

## 8. 바꾸는 문장

- RFC-0484 §3.2 의 "이 섹션은 아무것도 막지 않는다. 판정 경로는 지금과 똑같이 움직인다." → "Librarian gate 는 판정 서버 상태 때문에 거절된 시도 뒤의 새 시도를, 지금 설정이 물을 서버 중 하나라도 이 기록에서 거절 중이 아닐 때만 만든다(RFC-librarian-gate-waits-on-the-destination-not-on-passes §3.2). 판정 호출 자체는 이 기록으로 막지 않는다." 1층은 `Typesafeai_client.destination_outcomes` 의 문서 주석을 같은 뜻으로 고친다.
- RFC-librarian-absorb-gate §2 6항의 "판정이 실패하면 … 입력 범위를 남겨 재시도한다" 는 그대로 둔다. 판정 서버 상태 때문의 거절 뒤에 언제 다시 시도하는지는 이 RFC §3.2 가 정한다.

## 9. 열린 질문

- **`Request_refused` 뒤의 새 시도:** 지금 규칙은 같은 요청을 pass 마다 다시 만들 수 있다. 같은 요청은 같은 답을 받으므로, 이것도 기록을 늘릴 수 있다. 이 RFC 범위 밖이고, 2층 전에 실제로 그런지 확인해 이슈로 남긴다.
- **Add-on wake discovery 비용:** `Configuration_observed`·`Export_inventory_changed` 사건마다 `Owner.fold_all_records` 가 owner 기록 전체를 읽는다(`lib/server/server_librarian_addon_wake.ml:139~145`). #52389 에서 다룬다.
- **판정 서버 표의 키:** 키는 주소와 모델이고 계정은 없다. 402 는 계정의 크레딧 문제다. 같은 주소·모델을 다른 키로 바꾸면 §3.2 의 설정 조건이 잡는다. 키가 같고 계정만 다른 설정이 있는지는 2층에서 확인한다.
- 이미 검증한 gate 기록을 pass 마다 다시 검증하는 비용은 이 RFC 범위 밖이다. #51655·#51281 에서 다룬다.
