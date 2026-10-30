---
rfc: "0424"
title: "판정 요청은 pending 상태의 것이다 — 끝난 후보가 186MB 를 붙들고 있다"
status: Draft
created: 2026-09-05
updated: 2026-09-06
revision: 2
author: vincent
supersedes: null
superseded_by: null
related: ["0423"]
---

## 0. 이 개정에서 바뀐 것

revision 1 은 "목록이 안 읽는 필드를 캐시에서만 빼자"고 제안했다. 두 번 구현했고
두 번 되돌렸다. 실패의 원인이 필드의 모양이 아니라 **후보의 수명**에 있었으므로
제안을 통째로 바꾼다. 실패한 두 시도는 2절에 그대로 남긴다.

## 1. 문제

`keeper_board_attention_candidate` 의 원장 캐시가 살아있는 힙의 **247MB** 를
차지한다. RFC-0423 이 실행 기록 493MB 를 없앤 뒤로 이것이 1위다.

원장 파일은 `~/me/.masc/board_attention_candidates/`, 19파일 13,295행 230MB,
고유 후보 10,857건이다. 이 중 판정 요청이 193MB 로 83% 다.

**정리 로직이 없다.** 압축은 덮어쓰인 행만 지우고 살아 있는 항목은 남긴다.
가장 오래된 행이 5.5일 전이고 하루 37MB 씩 는다. 지금 상태로는 한 달에 1.1GB 가
된다.

## 2. 두 번 되돌린 기록

### 2.1 `Null` 로 두기 — 타입이 허용하는 값이 불변식을 깼다

캐시를 채울 때 `judgment_request` 를 `` `Null `` 로 두었다.

```
FAIL worker callback integration: judgment request must be an object
```

| 스위트 | main | 시도 |
|---|---|---|
| `test_keeper_board_attention_candidate` | 20/20 | 10건 실패 |
| `test_keeper_board_attention_worker` | 38/38 | 27건 실패 |

타입은 `Yojson.Safe.t` 라 `` `Null `` 을 허용하지만 코드는 객체임을 가정한다.
RFC-0423 이 통했던 이유는 그쪽 `Exact_input` 이 `` `Null `` 을 이미 정상값으로
다루고 있었기 때문이다. 두 필드가 같은 모양처럼 보였지만 불변식이 달랐다.

### 2.2 타입으로 나누기 — 캐시가 쓰기의 원본이었다

`Loaded of Yojson.Safe.t | Not_loaded` 로 나눴다. 컴파일이 60군데를 짚어 줬고
타입 변경 자체는 깨끗하게 끝났다. 그다음에 쓰기 경로를 읽었다.

```ocaml
(* update_ledger_many *)
match decide state.latest with          (* state.latest 가 캐시다 *)
| Ok (Some updated, result) ->
  ... if compact
      then rewrite ... (serialize_candidates appended.latest)   (* 캐시 전체 *)
      else append  ... (serialize_candidates updated)           (* 캐시에서 꺼낸 것 *)
```

`update_candidate` 는 캐시에서 후보를 찾아 상태를 바꾼 뒤 그대로 돌려주고,
압축은 캐시 전체를 파일에 다시 쓴다. **캐시에서 뺀 값은 다음 쓰기에서 디스크에서도
지워진다.** 되돌렸다.

### 2.3 두 시도의 공통점

두 번 다 **메모리와 디스크가 서로 다른 말을 하게** 만들려고 했다. 1차는 타입의
불변식을 안 봤고, 2차는 그 구조에서 누가 쓰는지를 안 봤다. "목록이 안 읽는다"는
필요조건이었지 충분조건이 아니었다.

## 3. 무게가 어디 있는지 다시 쟀다

판정 요청 193MB 를 하위 키로 쪼갰다.

| 키 | 크기 | 비중 |
|---|---|---|
| `comments` | 117.6MB | 61% |
| `post` | 30.7MB | 16% |
| `signal` | 24.2MB | 12% |
| `keeper_context` | 18.7MB | 9% |
| `candidate_id` | 0.8MB | 0% |

`signal` 과 `candidate_id` 는 **13,297행 전부 후보 자신의 필드와 같다.**
`canonical_judgment_request` 가 매 검증마다 그 둘이 같은지 확인한다. 코드가 스스로
중복임을 단언하고 있다.

그다음 상태별로 쟀다. 이쪽이 결정적이었다.

| 상태 | 건수 | 크기 |
|---|---|---|
| `consumed` | 9,808 | **185.9MB (92%)** |
| `quarantined` | 1,023 | 15.1MB |
| `pending` | **26** | 0.4MB |

**247MB 짜리 캐시가 살아 있는 후보 26건을 위해 존재한다.**

### 3.1 판정 요청을 읽는 것은 pending 하나뿐이다

`keeper_board_attention_exact_flow.ml` 의 `prepare` 가 `status_view` 를 닫힌
match 로 받아서, `judged`·`consumed`·격리 상태를 전부 `Candidate_not_pending` 으로
거부한다. `singleton_judgment_request` 까지 가는 것은 pending 뿐이다.

읽는 곳이 하나 더 있는데 `validate_candidate_for_persistence` 다. 이건 **쓸 때마다**
불린다. 즉 다시 읽히지 않을 18KB 짜리 요청을 후보가 상태를 바꿀 때마다 파싱하고
검증한다.

## 4. 제안

**판정 요청이 후보의 필드가 아니라 pending 상태가 들고 있는 값이 된다.**

```ocaml
type judgment_material =
  { post : Board.post
  ; comments : Board.comment list
  ; keeper_context : Yojson.Safe.t
  }

type pending_state =
  { last_delivery_failure : delivery_failure option
  ; material : judgment_material
  }
```

후보에서 `judgment_request : Yojson.Safe.t` 를 없앤다. 판정 요청은 판정하는
자리에서 후보의 `candidate_id`·`signal` 과 pending 의 material 로 만든다.

```ocaml
let judgment_request candidate material = `Assoc
  [ "candidate_id", `String candidate.candidate_id
  ; "signal", signal_to_yojson candidate.signal
  ; "post", Board.post_to_yojson material.post
  ; "comments", `List (List.map Board.comment_to_yojson material.comments)
  ; "keeper_context", material.keeper_context ]
```

이 제안이 앞의 두 실패를 피하는 이유:

- **메모리와 디스크가 계속 같은 말을 한다.** 소비를 기록할 때 material 이 사라지고,
  그 사실이 그대로 파일에 쓰인다. 캐시가 쓰기의 원본인 것이 이제 맞는 동작이다.
- **불변식을 깨지 않는다.** `` `Null `` 을 끼워 넣는 자리가 없다. 요청은 만들어질 때
  항상 완전하다.
- **중복 두 개가 사라진다.** `candidate_id` 와 `signal` 은 만들 때 후보에서 오므로
  달라질 수가 없다. 그 둘을 비교하던 검증을 유지하는 게 아니라 지운다.

격리 경로는 그대로 맞는다. `Resumable_pending of pending_state` 라서
pending 에서 격리된 후보는 material 을 그대로 들고 있고, 재투입되면 판정된다.
`Resumable_judged`·`Resumable_consumed` 는 애초에 안 들고 있다.

### 4.1 무엇이 줄어드는가

| | 지금 | 뒤 |
|---|---|---|
| 원장 파일 | 230MB | 약 45MB |
| 캐시 | 247MB | 비례해서 줄어듦 |
| 증가 속도 | 37MB/일, 무한 | 진행 중인 후보 수에 비례 |

마지막 줄이 이 RFC 의 요점이다. **원장이 누적 이력이 아니라 진행 중인 일에
비례하게 된다.**

## 5. 무엇을 하지 않는가

- **보존 기간을 만들지 않는다.** 끝난 후보의 흔적은 남는다. 중복 판정을 막는 것이
  그 흔적의 일이고, 거기엔 material 이 필요 없다.
- **`signal`(24.2MB)과 `status`(12.4MB)는 그대로 둔다.** 목록이 읽는다.
- **파일을 나누지 않는다.** 원장의 원자적 쓰기 계약을 지킨다.
- **다른 원장에 적용하지 않는다.**

## 6. 검증

| 무엇 | 어떻게 |
|---|---|
| pending 이 판정을 받는다 | 후보를 쓰고 → 판정 경로 → 프롬프트에 post·comments 가 있다 |
| 만든 요청이 전과 같다 | 지금 저장된 요청과 새로 만든 요청의 JSON 이 일치 |
| 소비하면 material 이 없어진다 | 소비 후 파일 행에 material 키가 없다 |
| 격리→재투입이 판정된다 | pending 에서 격리한 뒤 재투입 → 판정 성공 |
| 중복 판정을 계속 막는다 | 소비된 후보와 같은 signal 을 다시 넣으면 `Duplicate` |
| 메모리가 준다 | `Obj.reachable_words` 로 캐시를 저울에 단다 |
| 기존 계약 | `test_keeper_board_attention_{candidate,worker}` 통과 |

마지막 것이 성패다. 2.1 에서 37건이 깨졌으므로, 그 37건이 초록인 것이 증거다.

## 7. 위험

**진행 중인 후보 1,049건을 잃는다.** 행 형식이 바뀌면 `exact_fields` 가 기존 행을
전부 거부한다. 거부된 행은 `report_rejected_rows` 로 기록되고 첫 압축에서 사라진다.
hard cut 이 저절로 실행되는 셈이다. 없어지는 것은 pending 26건과 격리 1,023건이고,
소비된 9,808건은 어차피 다시 안 쓰인다.

이 비용은 격리 대기열이 줄었을 때 배포하면 작아진다. 배포 시점을 고르는 문제이지
설계를 바꿀 문제는 아니다. 변환 코드는 만들지 않는다.

**쓸 때마다 하던 검증이 줄어든다.** 지금은 매 쓰기가 18KB 를 파싱한다. 없어지는
쪽이 맞지만, 그 검증이 잡던 것이 있는지 확인한다.

## 8. 대안

**(a) 그냥 둔다.** 247MB 는 지금 live 1.69GB 의 15% 다. 다만 하루 37MB 씩 늘고
정리 로직이 없다. 두는 것은 결정이 아니라 미루기다.

**(b) 원장을 두 파일로 나눈다.** 요청을 별도 파일에 두고 후보 행은 참조만 갖는다.
타입 변경이 없지만 두 파일의 일관성을 지켜야 하고 원자적 쓰기가 깨진다.
2.2 의 문제는 피하지만 4절보다 계약이 약해진다.

**(c) 압축을 파일에서 흘려 쓴다.** 캐시가 아니라 옛 파일을 읽어 재작성한다.
2.2 의 장애물을 정면으로 없애지만 쓰기 경로 전체를 건드린다.

**(d) 보존 기간을 둔다.** 오래된 후보를 지운다. 가장 간단하지만 중복 판정 방지가
같이 사라진다.

4절은 (d) 의 효과를 (d) 의 손실 없이 얻는다. 흔적은 남기고 무게만 버린다.

## 9. 측정 근거

전부 2026-09-05 ~ 09-06, 이 워크스페이스.

```
live 힙 (RFC-0423 뒤)                        1.69GB
keeper_board_attention_candidate.ml:1467     247MB  (1위)

board_attention_candidates/   19파일 13,295행 230MB / 고유 10,857건
  judgment_request     193.0MB  83%
    comments           117.6MB  61%
    post                30.7MB  16%
    signal              24.2MB  12%   후보 필드와 동일 13,297/13,297
    keeper_context      18.7MB   9%
    candidate_id         0.8MB   0%   후보 필드와 동일 13,297/13,297
  signal                24.2MB  10%
  status                12.4MB   5%

상태별   consumed 9,808건 185.9MB (92%) / quarantined 1,023건 15.1MB
         pending 26건 0.4MB
가장 오래된 행 5.5일 전, 유입 37MB/일, 정리 로직 없음
```

실패한 두 시도:

```
2.1  Null      candidate 20/20 → 10건 실패, worker 38/38 → 27건 실패
               "judgment request must be an object"
2.2  타입 분리  컴파일 통과, 쓰기 경로 확인 후 되돌림 (커밋 없음)
```
