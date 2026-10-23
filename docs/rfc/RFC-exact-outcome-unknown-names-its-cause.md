---
rfc: "exact-outcome-unknown-names-its-cause"
title: "Exact 결과는 결과를 모르는 까닭을 담고, Curator 는 서버가 멈춰 끊긴 호출만 다시 준비한다"
status: Draft
created: 2026-10-23
updated: 2026-10-23
author: claude
related: ["workspace-curator-curates-changed-facts"]
---

# Exact 결과는 결과를 모르는 까닭을 담고, Curator 는 서버가 멈춰 끊긴 호출만 다시 준비한다

## 1. 문제

2026-10-23 14:51 KST 에 서버를 다시 띄울 때, Workspace Curator 의 첫 분류 원본이 세 번째 모델 호출을 하고 있었다(#45401).

- 다음에 읽을 때 호스트 복구가 그 Exact 기록을 `outcome_unknown` 으로 끝냈다.
- Curator 는 그 원본을 `Rejected` 로 끝냈다. `Rejected` 분류 원본은 자기가 고른 사실을 다음 묶음에서 뺀다.
- 그래서 가장 오래된 사실 447개가 빠졌다. 다음 원본은 다른 사실 496개를 골랐고, 겹치는 사실은 0개였다.

사실을 빼는 규칙은 같은 사실 때문에 계속 실패하는 경우를 막으려고 있다. 재시작은 사실 탓이 아니다. 그런데 `outcome_unknown` 이 생기는 경우는 둘이고, Curator 는 둘을 구분하지 못한다.

- **서버가 멈추거나 호출이 취소된 경우.** 시작한 시도가 끝나지 않은 채 남는다. 사실과 상관없다.
- **호출이 이 서버 안에서 예외를 낸 경우.** 호스트 코드의 결함이다. 같은 입력에서 다시 날 수 있다.

어느 쪽으로 정해도 한쪽이 틀린다.

- 모두 막으면 재시작할 때마다 진행 중이던 묶음이 막힌다(#45401).
- 모두 풀면, 같은 사실로 예외가 매번 날 때 패스마다 같은 사실로 새 원본을 만들고 다시 호출한다. 원본 하나에 약 4.5MB 가 남고, 멈추는 장치가 없다.

2026-10-23 06:35Z 쯤 라이브와 보관 위치의 호스트 Exact 기록 8개를 봤다. 예외로 끝난 호출은 0개, 서버가 멈춰 끊긴 호출은 #45401 의 1개였다.

### 1.1 두 경우가 남기는 기록 (main `f366b406982`)

| 경우 | 쓰는 코드 | 결과(final) | 마지막 시도 |
|---|---|---|---|
| 서버가 멈춤, 호출 취소 | 다음에 읽을 때 복구가 쓴다(`lib/lane_addon/lane_addon_exact.ml:633-639`). 취소된 호출도 시작한 시도를 남긴다(`:695-696`) | `{"status":"outcome_unknown"}` | `null`. 시작만 적혀 있다 |
| 예외 | 그 자리에서 쓴다(`:698-714`) | `{"status":"outcome_unknown"}` | `{"status":"outcome_unknown","exception":"<예외 문구>"}` |

호스트 기록은 두 경우를 구분한다. 기록 검사는 `exception` 이 `outcome_unknown` 시도에만 붙도록 한다(`:352-358`). #45401 의 호스트 기록(`25f4c4b5…`)은 시도가 `[provider_unavailable, provider_unavailable, null]` 이고, 결과가 `outcome_unknown` 이다.

### 1.2 결과를 받는 쪽이 보는 것

결과(final)에는 원인이 없다.

- 호스트는 결과를 `final_to_json` 으로 worker 에 넘긴다(`lib/lane_addon/lane_addon_runtime.ml:1058`). 예외 문구는 넘기지 않는다.
- Curator 는 거절을 `Progress.Refused {stage=Execution; evidence=final_to_json final}` 로 남긴다(`lib/server/server_workspace_memory_addon.ml:161-167`).
- 호스트 기록을 읽는 `observe_retained` 도 결과만 돌려준다(`Retained_terminal of final`, `lane_addon_exact.mli:202`).

그래서 결과를 받는 어느 쪽도 두 경우를 구분하지 못한다.

## 2. 지금 있는 것

- 결과 타입은 `final` 이다(`lane_addon_exact.mli:87-96`). `Outcome_unknown` 은 인자가 없다.
- JSON 은 `{"status":"outcome_unknown"}` 이다(`lane_addon_exact.ml:182`). 읽을 때 다시 써서 같은지 보므로(`:218-223`), 모르는 필드가 있으면 거절한다.
- OCaml 에서 `Outcome_unknown` 을 직접 나누는 곳:
  - Exact 자신: `lane_addon_exact.ml:415`, `:516`, `:646`, `:652`, `:681`.
  - Curator: `server_workspace_memory_addon.ml:130`, `:166`, `:202`, `:212`, `workspace_memory_observation_receipt.ml:93`, `:110`, `workspace_memory_execution_capture.ml:296`, `:467`, `server_workspace_memory_curator.ml:34`.
  - Candle Appraiser: `server_candle_appraiser.ml:179`. 거절 코드 `candle_appraisal_outcome_unknown` 으로 끝낸다.
  - browser 모델 요청: `browser_addon_models.ml:127`, `browser_addon_locate.ml:50`.
- Python 에서 결과를 읽는 곳:
  - `addons/exact_worker.py:110-138` `final_of_json` 은 필드를 정확히 본다. `outcome_unknown` 은 `{"status"}` 하나만 받는다(`:133-134`). Curator 와 Candle worker 가 이 파일을 같이 쓴다. 저장한 기록을 다시 읽을 때도 이 검사를 한다(`:195-200`).
  - operator-quiz 는 `status` 만 본다(`addons/operator-quiz/quiz_flow.py:632-636`, `:703`, `:840`). 다른 필드는 읽지 않는다.
- worker 의 저장소는 설치마다 컨테이너 볼륨(`masc-lane-state-<…>`)에 있다(`lane_addon_engine.ml:307-308`).
- 배포 전 저장소 검사 `validate-stores` 는 호스트 Exact 기록을 `Lane_addon_exact.check_retained_record` 로 읽는다(`lane_addon_store_preflight.ml:274-276`). 운영자가 이전 서버를 멈춘 뒤, 새 빌드를 올리기 전에 돌린다(`lane_addon_store_preflight.mli:1-15`).
- Curator 가 사실을 빼는 곳은 `classification_blocked` 다(`server_workspace_memory_curator.ml:115-121`, 호출 `:131`). Briefing 패스를 막는 곳은 `briefing_blocked` 다(`:159-168`). 둘 다 `Rejected` 원본이면 거절 내용과 상관없이 막는다.

## 3. 결정

### 3.1 원인을 결과 타입에 싣는다

```ocaml
(** Why a started call has no retained outcome. *)
type unknown_cause =
  | Interrupted
      (** The started attempt never ended: the host process stopped or the
          call was cancelled before an outcome or proof was written. The next
          read of the record finds it. *)
  | Raised
      (** The call raised in this process. The exception text stays in the
          attempt evidence and is never delivered. *)

type final =
  | Call_final of call_final
  | Outcome_unknown of unknown_cause
  | Not_allowed of { reason : string }
  | Request_id_reused
```

- JSON 은 `{"status":"outcome_unknown","cause":"interrupted"}` 와 `{"status":"outcome_unknown","cause":"raised"}` 다.
- `cause` 는 반드시 있어야 하고, 두 값 말고는 거절한다.
- 예외 문구는 지금처럼 시도 증거에만 남는다. worker 에 넘기지 않는다.
- 원인을 따지지 않는 곳은 `Outcome_unknown _` 로 나눈다. 새 원인이 생기면 컴파일러가 원인을 따지는 곳을 모두 다시 보게 한다.

### 3.2 호스트 기록 규칙

- 복구(`lane_addon_exact.ml:638`)는 `Outcome_unknown Interrupted` 를 쓴다.
- 예외(`:702`)는 `Outcome_unknown Raised` 를 쓰고, 그 시도에 예외 문구를 남긴다.
- 결과가 정해진 뒤에 선택이 바뀌면 `not_allowed` 시도가 뒤에 붙는다(`:647-656`). 그래서 아래의 "결과를 정한 시도"는 그런 `not_allowed` 를 뺀 마지막 시도다.
- 기록을 읽을 때(`validate_record`, `check_retained_record`) 다음을 확인한다.
  - 예외 문구가 있는 시도는 결과가 `Outcome_unknown Raised` 이고, 문구가 비어 있지 않다.
  - `Outcome_unknown Raised` 시도에는 예외 문구가 있다.
  - 결과가 `Outcome_unknown Interrupted` 이면 결과를 정한 시도가 `null` 이다.
  - 결과가 `Outcome_unknown Raised` 이면 결과를 정한 시도가 그 `Raised` 시도다.
- 실행 증거(proof)는 지금처럼 `Outcome_unknown` 을 담지 못한다(`:409-416`).

### 3.3 Curator 는 끊긴 호출만 다시 준비한다

- `Outcome_unknown Interrupted` 로 끝난 원본은 아무것도 막지 않는다. 분류 원본이면 고른 사실이, Briefing 원본이면 같은 패스가 다음 패스에 새 원본으로 다시 준비된다.
- `Outcome_unknown Raised` 와 다른 거절은 지금처럼 막는다.
- 규칙은 패스가 기록을 읽을 때마다 거절 증거에서 정한다. 증거를 닫힌 variant 로 읽고 생성자를 모두 적는다. 새로 저장하는 값은 없다.
- 끊긴 원본은 증거로 scope 에 남는다. 보관 위치로 옮기지 않는다(6장 Q4).
- `Interrupted` 가 같은 사실로 되풀이되려면 그 호출마다 서버가 멈춰야 한다. 그 반복은 운영자가 서버를 멈출 때만 생긴다.

### 3.4 다른 소비자는 동작을 바꾸지 않는다

- Candle Appraiser 는 두 원인 모두 지금처럼 `candle_appraisal_outcome_unknown` 으로 끝낸다.
- browser 모델 요청은 두 원인 모두 지금처럼 답하지 않은 것으로 다룬다.
- operator-quiz 는 `cause` 를 읽지 않는다. 코드를 바꾸지 않는다.
- `exact_worker.py` 는 `{"status","cause"}` 를 받고, `cause` 가 두 값 중 하나인지 본다. 원인 없는 옛 모양은 거절한다. Curator 와 Candle 패키지 revision 을 올리고 worker 이미지를 다시 만든다.

### 3.5 하드컷

결과 모양이 바뀐다. 원인 없는 `{"status":"outcome_unknown"}` 을 읽는 코드는 만들지 않는다. 배포할 때 서버를 멈추고 다음을 옮긴다.

1. 호스트 Exact 기록 중 결과나 시도가 옛 모양인 파일(`lane-addons/exact-requests/<선언 digest>/`). 새 빌드의 `validate-stores` 가 파일마다 알려 준다.
2. 거절 증거가 옛 모양인 Curator 원본. 사슬을 통째로 옮긴다(진행 중 기록 `lane-addons/tool-request-owners/5e5665b7…/` 와 본문 `lane-addons/tool-request-bodies/5e5665b7…/`). #45401 의 원본이 여기에 든다. 옮기면 그 원본이 막던 447개가 다음 패스에 다시 들어간다.
3. Curator·Candle worker 상태 볼륨 안의 Exact 요청 기록 중 결과가 옛 모양인 파일. 새 worker 는 그런 기록을 다시 읽다가 거절한다.

2026-10-23 06:35Z 기준으로 1번은 1개, 2번은 1개다. 3번은 볼륨을 열어 봐야 해서 배포 때 센다.

실행 기록 payload 와 끝난 원본의 보관 위치는 그대로 둔다. 결과를 `final_of_json` 으로 다시 읽는 곳(2장 목록)에 들지 않는다.

## 4. 다른 방법과 비교

| 방법 | 좋은 점 | 나쁜 점 |
|---|---|---|
| 모두 막는다 (지금) | 반복이 없다 | 재시작할 때마다 진행 중이던 묶음이 막힌다 |
| 모두 푼다 (#45401 의 첫 수정, push 하지 않음) | 고칠 곳이 적다. 447개가 배포만으로 풀린다 | 예외가 같은 사실로 되풀이되면 패스마다 다시 호출하고 원본이 쌓인다. 멈추는 장치가 없다 |
| Curator 가 패스마다 호스트 기록을 읽어 원인을 본다 | 결과 모양이 그대로다 | 호스트 기록은 요청을 품어서 라이브에서 1.1~4.2MB 다. 끊긴 원본마다 패스마다 읽는다. 원인을 가리는 코드가 Exact 밖에 생긴다 |
| Curator 가 거절을 적을 때 원인을 한 번 읽어 자기 증거에 넣는다 | Python worker 가 그대로다 | 결과는 여전히 두 경우를 한 이름으로 부른다. Candle 과 browser 는 계속 모른다. Curator 증거 모양이 바뀌어 하드컷도 남는다 |
| 이 RFC: 원인을 결과 타입에 싣는다 | 결과를 받는 모든 곳이 원인을 안다. 원인을 따지는 곳을 컴파일러가 찾는다 | 결과 모양이 바뀌어 Python worker 와 저장된 기록을 같이 바꾼다. 배포 때 서버를 멈추고 기록을 옮긴다 |

## 5. 나눠 올리는 순서

스택으로 올린다. 층마다 draft PR 이다.

1. Exact 결과에 원인을 싣는다. OCaml 타입, JSON, 기록 규칙, 모든 match, `exact_worker.py`, 패키지 revision 을 한 층에서 바꾼다. 호스트가 넘기는 결과를 worker 가 읽어야 해서, 계약의 양쪽이 같은 배포에 들어간다. Curator 동작은 바뀌지 않는다.
2. Curator 가 `Interrupted` 로 끝난 원본에서 사실과 Briefing 패스를 풀어 준다.
3. 설계 문서(`docs/design/workspace-curator-addon-execution.md`)와 배포 안내. changelog 조각에 하드컷 단계를 적는다.

## 6. 정할 것

- **Q1. 원인 이름.** `interrupted`·`raised` 와 `host_stopped`·`call_raised` 중 무엇으로 할지.
  - 권고: `interrupted`·`raised`. 취소도 `interrupted` 에 들어서 `host_stopped` 는 좁다.
- **Q2. 다른 add-on 의 동작.** Candle 이나 operator-quiz 가 원인에 따라 다르게 움직일지.
  - 권고: 이 RFC 에서는 바꾸지 않는다. 필요하면 각 add-on 에서 정한다.
- **Q3. `Raised` 로 막힌 사실.** 예외는 호스트 결함이라, 결함을 고친 뒤에도 사실은 막힌 채 남는다.
  - 권고: 지금처럼 남긴다. 결함을 고친 운영자가 그 원본의 사슬을 옮기면 풀린다.
- **Q4. 끊긴 원본의 보관.** 아무것도 막지 않는 원본을 scope 밖으로 옮길지.
  - 권고: 이 RFC 에서는 하지 않는다. 재시작 때만 생겨서 수가 적고, 패스는 기록만 읽는다.

## 7. 검증

모델 없이 테스트하는 것:

- 시작한 시도가 끝나지 않은 기록을 다시 읽으면 `Outcome_unknown Interrupted` 가 되고, 마지막 시도는 `null` 로 남는다.
- 취소된 호출도 다음에 읽을 때 `Interrupted` 가 된다.
- 예외를 낸 호출은 `Outcome_unknown Raised` 가 되고, 시도에 예외 문구가 남는다. worker 에 넘기는 결과에는 문구가 없다.
- 기록 검사는 다음을 거절한다: 문구 없는 `Raised` 시도, 문구가 붙은 `Interrupted`, 결과를 정한 시도가 `null` 이 아닌 `Interrupted` 결과, 원인 없는 옛 모양, 모르는 원인.
- `Interrupted` 나 `Raised` 로 끝난 기록에 선택 변경으로 `not_allowed` 시도가 붙어도 기록 검사를 통과한다.
- 두 원인의 결과가 호스트 → Python worker → 호스트로 같은 바이트로 돌아온다. Python 은 옛 모양과 모르는 원인을 거절한다.
- `validate-stores` 가 옛 모양 호스트 기록을 파일마다 알려 준다.
- Curator
  - `Interrupted` 로 끝난 분류 원본의 사실을 새 뿌리가 다시 골라 분류한다.
  - `Interrupted` 로 끝난 Briefing 이 지금 상태를 준비했어도 같은 패스를 다시 준비한다.
  - `Raised` 로 끝난 원본의 사실은 다른 원본이 고르지 않는다.
  - 잘못된 답으로 끝난 원본의 사실도 지금처럼 고르지 않는다.
- 규칙을 하나씩 깨뜨린 mutant 가 위 테스트에서 실패한다. `Interrupted` 도 막기, `Raised` 도 풀기, Briefing 만 규칙 무시, 분류만 규칙 무시.

배포 뒤 라이브에서 보는 것:

- 첫 분류 패스가 #45401 의 447개를 오래된 순서로 다시 고른다.
- `Raised` 로 끝난 원본 수. 지금까지 0개였다.

## 8. 다루지 않는 것

- 끊긴 원본을 보관 위치로 옮기기(Q4).
- Candle, operator-quiz, browser 의 동작 변경(Q2).
- `Raised` 를 낸 결함 자체. 생기면 그 결함을 따로 고친다.
- Curator 원본이 원장 사본 대신 판본을 가리키는 일(#45392).
