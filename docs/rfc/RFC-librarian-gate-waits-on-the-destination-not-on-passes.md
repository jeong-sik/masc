---
rfc: "librarian-gate-waits-on-the-destination-not-on-passes"
title: "판정 서버가 거절하면 gate 는 새 시도를 만들지 않고 그 서버의 상태가 바뀌길 기다린다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: vincent + claude
supersedes: []
superseded_by: null
related: ["librarian-absorb-gate", "0484", "0433", "provider-path-rest"]
---

# 판정 서버가 거절하면 gate 는 새 시도를 만들지 않는다

## 0. 요약

- TypeSafe 크레딧이 떨어지자 Librarian 흡수 판정(gate)이 pass 마다 TypeSafe 에 다시 묻고, 물을 때마다 gate 기록을 하나 더 남겼다.
- pass 는 그 기록 사슬 전체를 다시 검증한다. 기록이 늘수록 pass 가 느려졌고, 11-16 운영 서버는 CPU 400% 를 넘겼다.
- 원인은 두 가지다.
  - 판정 서버의 거절이 `string` 하나로 바뀌어, 판정 실패와 구별되지 않는다.
  - 다시 묻는 계기가 "앞 시도가 실패했다" 하나뿐이다.
- 이 RFC 는 두 가지를 정한다.
  - 거절은 판정 시도가 아니다. 시도는 끝나지 않고 그대로 기다린다. 새 기록을 만들지 않는다.
  - 다시 묻는 계기는 typed 사건뿐이다. 숫자(시간·횟수)와 문자열 분류를 쓰지 않는다.

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
- gate 는 이 값을 문자열로 바꾼다.
  - `lib/keeper/keeper_librarian_absorb_gate.ml:811`: `Error failure -> Error (Typesafeai_client.failure_to_string failure)`
  - `lib/keeper/keeper_librarian_absorb_gate.ml:1282`: 같다.
  - 결과는 `outcome = Failed of { reason : string; ... }` (`:259`) 다. 로컬 검증 실패(`validate_guidance`, `classify`)도 같은 `Failed` 로 들어간다.
- 실패 여부는 `Gate.failure_detail : ... -> string option` (`:856`) 하나로 읽는다. 이 함수를 13곳이 부른다. 재시도 자리는 세 곳이다.
  - `lib/keeper/keeper_librarian_admission_owner.ml:255~269` (`retry`)
  - `lib/keeper/keeper_librarian_floor_step_judgment.ml:107~113`
  - `lib/keeper/keeper_librarian_durable_commit.ml:361~367`
  - 셋 다 `Some _` 이고 `fresh_authority` 가 통과하면 `Journal.retain ~predecessor:(Some latest.request_id)` 로 새 시도를 만든다.
- `fresh_authority` (`lib/keeper/keeper_librarian_durable_edge.ml:32`) 는 Keeper owner 와 Add-on 목적지 설정만 확인한다. 판정 서버가 지금 받는지는 보지 않는다.
- 판정 서버의 최근 결과는 이미 프로세스 메모리에 있다(`Typesafeai_client.outcomes`, `Answered | Refusing { since; last_at; last; last_answer_at }`, RFC-0484 §3.2). §3.2 는 "이 섹션은 아무것도 막지 않는다" 고 정했다.
- pass 는 typed 사건으로 깬다.
  - `Keeper_librarian_queue_signal.changed`: 턴 뒤 기억, owner 등록, 정리 등에서 부른다.
  - Add-on owner 이벤트(`Lane_addon_runtime.subscribe_owner_events`): `Configuration_observed | Export_inventory_changed | Exact_result_delivered`. `lib/server/server_librarian_addon_wake.ml` 이 이 이벤트로 Keeper 를 깨운다.

## 2. 문제

판정 서버가 거절하면 아무것도 판정되지 않았다. 그런데 지금 gate 는 이것을 "판정을 시도했고 실패했다" 로 적는다. 그래서 두 가지가 생긴다.

1. **기록이 외부 상태에 비례해 는다.** 크레딧이 없는 동안 pass 마다 durable 기록이 하나씩 생긴다. 이 증가에는 끝이 없다.
2. **pass 비용이 기록에 비례해 는다.** pass 는 사슬 전체를 다시 복원해서 검증한다. #52381 이 제곱 비용을 선형으로 줄이지만, 사슬이 계속 길어지는 문제는 남는다.

결과적으로 외부 결제 상태 하나가 서버 전체 CPU 를 정한다. Keeper 턴, 다른 Keeper 의 pass, 배포 preflight 가 모두 함께 느려진다.

## 3. 결정

### 3.1 gate 결과는 닫힌 합타입이다

`Failed.reason : string` 과 `failure_detail : ... -> string option` 을 지운다. 그 자리에 판정 결과를 이렇게 둔다.

```ocaml
type not_judged =
  | Destination_refused of Typesafeai_client.failure
      (* 판정 서버에 닿지 못했거나 서버가 거절했다. 아무것도 판정되지 않았다. *)

type judgment_failed =
  | Guidance_invalid of ...
  | Classification_failed of ...
  | Absorptions_unconfirmed of ...   (* 판정은 받았고, 흡수를 확인하지 못했다 *)

type verdict =
  | Passed
  | Not_judged of not_judged
  | Failed of judgment_failed
```

- `...` 자리의 필드는 1층 구현에서 지금 `Failed` 를 만드는 자리마다 정한다. 문자열 하나로 뭉치지 않는다.
- 13곳의 호출자는 `verdict` 를 빠짐없이 `match` 한다. `_ ->` 를 쓰지 않는다.
- 로그·`/health` 에 보이는 문장은 이 값에서 만든다. 분기는 문장에서 하지 않는다.

### 3.2 `Not_judged` 는 시도를 끝내지 않는다

- 판정 서버가 평가 k 를 거절하면, 그 시도의 transcript 에 평가 1..k-1 의 답을 그대로 둔다. 평가 k 에는 마지막 거절(`Typesafeai_client.failure`)을 적는다.
- 시도는 끝나지 않은 단계(`Dispatch_pending`)에 머문다. `Rejected { stage = Execution }` 으로 가지 않는다.
- 같은 시도가 다시 물을 때는 평가 k 부터 묻는다. 새 시도 기록(`Journal.retain ~predecessor`)을 만들지 않는다.
- 다시 거절되면 평가 k 의 거절 증거를 새 것으로 바꾼다. 쌓지 않는다. 헌법 `failure_keeps_evidence` 의 "최신 실패 증거를 남기고 대상을 소비하지 않는다" 와 같다.
- `Failed`(판정은 받았는데 실패)는 지금처럼 시도를 끝내고, 지금의 재시도 규칙을 따른다. 이 RFC 는 그 규칙을 바꾸지 않는다.

이 절만으로 §2 의 1 과 2 가 같이 사라진다. 거절이 얼마나 오래 이어지든 기록 수는 변하지 않는다.

### 3.3 거절 중인 판정 서버에는 한 번에 한 요청만 간다

- 판정 서버의 최근 결과가 `Refusing` 이면, 그 서버로 가는 gate 요청은 프로세스 전체에서 하나만 날아간다.
- 나머지 시도는 요청을 보내지 않고 `Not_judged` 로 기다린다. 기록을 쓰지 않는다.
- 요청이 `Answered` 를 받으면 기다리던 시도가 깨어난다. 깨는 순서는 원본을 만든 순서다.
- 이것은 숫자로 쉬는 장치가 아니다. 서버가 받는지 모르는 동안, 모르는 것을 한 요청으로만 확인하는 backpressure 다.
- 이 규칙은 RFC-0484 §3.2 의 "이 섹션은 아무것도 막지 않는다" 를 바꾼다(§8).

### 3.4 다시 묻는 계기는 typed 사건뿐이다

`Not_judged` 로 기다리는 시도는 다음 중 하나가 일어나면 다시 묻는다.

| 사건 | 출처 | 왜 계기인가 |
|---|---|---|
| 같은 판정 서버가 `Answered` 를 냈다 | `Typesafeai_client.note_answer` (board attention, 다른 Keeper 의 gate) | 서버가 다시 받는다는 직접 사실이다 |
| Add-on 설정이 바뀌었다 | `Configuration_observed` | 운영자가 키·목적지를 고쳤을 수 있다 |
| 그 Keeper 의 Librarian 에 새 일이 왔다 | `Keeper_librarian_queue_signal.changed` | 답이 필요한 일이 생겼다 |

- 거절 자체는 어떤 사건도 만들지 않는다. 거절 뒤에 `queue_signal.changed` 를 부르지 않는다.
- 서버를 다시 띄우면 최근 결과 표는 빈다. 첫 pass 가 한 요청으로 다시 확인한다. 이것도 §3.3 의 한 요청 규칙을 따른다.
- 시간·횟수로 다시 묻지 않는다. maintenance pulse 도 쓰지 않는다.

`Answered` 사건은 지금 gate 쪽으로 전달되지 않는다. 2층에서 `Typesafeai_client.note_answer` 가 그 판정 서버를 기다리는 Keeper 를 깨우는 이벤트를 하나 더한다. 기존 `subscribe_owner_events` 에 variant 를 더할지, 판정 서버 결과 표에 구독을 둘지는 2층에서 producer → consumer 경로를 읽고 정한다.

### 3.5 hard cut

- 1.0 전이라 저장 상태는 fresh state 로 자른다.
- 1층 배포 때 지금 쌓인 gate 사슬(`keeper-librarian-durable-gate/`, `keeper-librarian-admission-gate/` 아래)과 그 사슬을 가리키는 원본 상태를 지운다. 정확한 경로 목록은 1층 PR 이 preflight 의 `fresh_state_step` 문장으로 적는다.
- 옛 `Failed.reason : string` 을 읽는 reader·converter 를 만들지 않는다.

## 4. 멈추지 않음의 논증

### 4.1 상태

한 gate 시도의 상태다(이 RFC 가 다루는 부분만).

| 지금 | 사건 | 다음 | 기록 쓰기 |
|---|---|---|---|
| `Dispatch_pending`(평가 k 미답) | 요청 → 답 | 평가 k+1 또는 판정 끝 | 평가 k 의 답 |
| `Dispatch_pending`(평가 k 미답) | 요청 → 거절 | `Dispatch_pending`(평가 k 미답, 거절 증거) | 평가 k 의 최신 거절(덮어씀) |
| `Dispatch_pending`(거절 증거) | §3.4 사건 + 한 요청 자리 얻음 | 요청 | 없음 |
| `Dispatch_pending`(거절 증거) | §3.4 사건 + 한 요청 자리 없음 | 그대로 | 없음 |
| 판정 끝 `Failed` | 지금 규칙 | 지금 규칙 | 지금 규칙 |

### 4.2 불변식

- **I1. 기록 수 유한:** 한 원본의 gate 기록 수는 `Failed` 로 끝난 시도 수 + 1 을 넘지 않는다. `Not_judged` 는 기록 수를 바꾸지 않는다.
- **I2. 판정 서버마다 한 요청:** `Refusing` 인 판정 서버로 동시에 날아가는 gate 요청은 많아야 하나다.
- **I3. 증거 유지:** `Not_judged` 상태의 시도는 마지막 거절의 `Typesafeai_client.failure` 를 가진다.
- **I4. 한 번만 판정:** 평가 k 의 답은 한 번만 적힌다. 거절 뒤 다시 묻는 것은 답이 없는 평가 k 뿐이다.

### 4.3 진행

- **가정:** Keeper 턴이 계속 끝난다. 채팅 큐의 진행 조건과 같은 가정이다.
- 턴이 끝나면 Librarian 에 새 일이 온다(`queue_signal.changed`). 그래서 §3.4 의 세 번째 사건이 계속 일어난다.
- 그 사건마다 §3.3 에 따라 많아야 한 요청이 나간다. 그 요청이 `Answered` 를 받으면 기다리던 시도가 만든 순서대로 깨어난다.
- 판정 서버가 영영 거절하면 시도는 영영 기다린다. 이것은 멈춤이 아니라 외부 사실이다. `/health` 의 `operator_action_required` 가 그 사실을 보여 준다(RFC-0484).
- 한 요청이 끝나지 않으면 I2 때문에 다른 요청이 그 서버로 가지 않는다. 그 요청은 `Typesafeai_client` 가 이미 쓰는 요청 경계(`Masc_http_client.default_request_timeout_sec`, `typesafeai_client.ml:153`)에서 끝난다. 이 RFC 는 새 timeout 을 두지 않는다.

### 4.4 대가

- 시스템이 한가할 때 크레딧이 돌아오면, 기다리던 시도는 다음 사건까지 쉰다. 급한 일이 없는 시간이라 손해가 작다.
- 판정 서버가 거절하는 동안에도 새 일이 올 때마다 요청이 하나씩 나간다. 402 요청 수는 §3.4 사건 수를 넘지 않는다. 기록과 CPU 는 늘지 않는다.

## 5. 고르지 않은 길

- **시간·횟수 상한, cooldown:** 헌법 `magic_number`·`budget_gate` 에 걸린다. #51655 의 11-15 댓글, #52382 와 같은 판단이다.
- **maintenance pulse 로 다시 깨우기:** Board attention 이 한도 후보에 쓰는 방식이다. 고정 간격이라는 숫자가 행동을 정한다. §3.4 의 사건으로 충분하다.
- **운영자의 "고쳤음" 확인 버튼:** 운영자는 이미 TypeSafe 에서 크레딧을 채웠다. 같은 사실을 masc 에 한 번 더 넣게 하는 일이다. RFC-0484 §3.4 도 확인(ack) 상태를 새 사실로 저장하지 않기로 했다.
- **`Runtime_quota_window` 의 `Observed` 휴식 재사용:** 운영자가 선언한 cap 만큼 쉰다. 이미 정해진 장치지만 시간 숫자가 다시 묻는 시점을 정한다.
- **로그 문장에서 402 를 찾기:** 문자열 분류다.
- **#52381 만으로 끝내기:** 사슬 하나를 읽는 비용은 줄지만 사슬이 계속 길어진다.

## 6. 층

1. **1층 — typed 결과와 기록 안 만들기**
   - §3.1 의 합타입으로 `Failed.reason : string`, `failure_detail` 을 바꾼다. 13곳이 빠짐없이 `match` 한다.
   - §3.2: `Not_judged` 는 시도를 끝내지 않는다. 재시도 세 자리는 `Not_judged` 에서 `Journal.retain` 을 부르지 않는다.
   - §3.5 hard cut.
   - 이 층만으로 기록 증가와 CPU 증가가 멈춘다.
2. **2층 — 한 요청 규칙과 다시 묻는 계기**
   - §3.3 의 한 요청 규칙.
   - §3.4 의 `Answered` 사건을 기다리는 Keeper 에게 전한다.
   - RFC-0484 §3.2 개정을 이 층에서 구현한다.

두 층은 native stack 으로 쌓는다. 1층이 맨 아래다.

## 7. 검증

### 7.1 시험

- 가짜 판정 서버(402 를 돌려주는 로컬 HTTP)로 Librarian 흡수 한 회차를 돌린다. `feature_surface` 의 Librarian 기능 시험이다.
  - 1층: pass 를 N 번 깨워도 그 원본의 gate 기록 수가 그대로다. 서버가 `Answered` 로 바뀐 뒤 같은 시도가 평가 k 부터 이어서 판정을 끝낸다.
  - 2층: 원본 여럿이 같은 거절 서버를 기다릴 때, 서버로 동시에 간 요청이 많아야 하나다. 서버가 받기 시작하면 원본을 만든 순서대로 끝난다.
- 숫자·문구·snapshot 을 보는 시험은 만들지 않는다.

### 7.2 배포 뒤 측정

- 다음 거절 구간에서 Keeper 마다 gate 기록 수를 시작과 끝에 센다. 같아야 한다.
- 같은 구간의 `durable Librarian inventory validated` 의 `elapsed_ms` 가 거절이 이어진 시간과 상관없이 거절 전 값과 같은 범위에 있다.
- 같은 구간의 402 요청 수를 `queue_signal.changed` 수와 비교한다. 402 요청 수가 더 많으면 §3.3 이 깨진 것이다.

## 8. 바꾸는 문장

- RFC-0484 §3.2 의 "이 섹션은 아무것도 막지 않는다. 판정 경로는 지금과 똑같이 움직인다." → "판정 서버의 최근 결과가 `Refusing` 이면 Librarian gate 는 그 서버로 한 번에 한 요청만 보낸다(RFC-librarian-gate-waits-on-the-destination-not-on-passes §3.3). 그 밖의 판정 경로는 이 기록으로 막지 않는다."
- RFC-librarian-absorb-gate §2 6항의 "판정이 실패하면 … 입력 범위를 남겨 재시도한다" 는 그대로 둔다. 그 재시도가 언제 일어나는지는 이 RFC §3.4 가 정한다.

## 9. 열린 질문

- 1층의 hard cut 대상 경로 목록: gate 사슬과 그 원본을 함께 지워야 원본이 사라진 사슬을 가리키지 않는다. 1층 PR 에서 store 코드로 확정한다.
- `Answered` 사건을 전할 자리(§3.4 끝): 2층에서 producer → store → consumer 를 읽고 정한다.
- 이번 측정에서 Add-on wake discovery(`server_librarian_addon_wake.ml`)가 사건마다 owner 기록 전체를 읽는지 확인하지 못했다. CPU 의 다른 몫일 수 있어 따로 잰다.
- 이미 검증한 gate 기록을 pass 마다 다시 검증하는 비용은 이 RFC 범위 밖이다. #51655·#51281 에서 다룬다.
