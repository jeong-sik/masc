---
rfc: "0462"
title: "수를 그리는 자리는 그 수가 덜 읽혔는지 말한다"
status: Draft
created: 2026-09-23
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0004"]
---

# RFC-0462: 수를 그리는 자리는 그 수가 덜 읽혔는지 말한다

## 0. 결정

서버는 목록을 셀 때 **못 읽은 것도 같이 보고한다**. 파싱 못 한 파일, 프로필이
안 열린 키퍼, 건너뛴 행. 그 값들은 "운영자용" 이라고 생산자 주석에 적혀 있는데,
TUI 는 대부분 안 읽는다. 그래서 화면의 수는 언제나 완전한 읽기처럼 보인다.

1. 수와 "못 읽은 수" 를 한 타입으로 묶어 읽는다. 둘 중 하나만 화면에 도달하는
   경로를 없앤다.
2. 그리는 쪽은 그 타입 하나를 받는다. 못 읽은 게 있으면 수 옆에 말하고, 없으면
   지금과 똑같이 수만 말한다.
3. 새 목록이 이 타입을 쓰지 않으면 가드가 잡는다.

## 1. 기준선 (2026-09-23, main `8a1a2be8da`)

| 자리 | 서버가 보내는 것 | 화면 | 라이브 |
|---|---|---|---|
| fleet 소유자 스캔 | `active_task_owner_scan_error_count` | #38012 이전엔 안 읽음 | 0 |
| 검증 대기열 | `unreadable_total`, `awaiting_unresolved_total` | 안 읽음 | 0 |
| 키퍼 turn record | `skipped_rows` (`count` 바로 옆) | 안 읽음 | 0 |

생산자 주석이 의도를 적어 뒀다.

> 읽는 쪽이 파싱 못 한 파일의 운영자용 모양. 저장소를 읽는 모든 projection 이
> 같이 내보내므로, 못 읽은 기록이 counter 와 로그 줄을 대조하지 않고도 보인다.
> (`lib/dashboard/dashboard_verification.ml`)

반대로 이 화면이 **이미 지키는 자리**도 있다.

- Approvals 제목: `", confirm queue unread"`, `", held calls stale"`
- Overview 승인 행: 다섯 가지 출처 중 하나라도 못 읽으면 수를 신뢰 불가로 표시
- `test_tui_row_wiring`: "모든 승인 출처가 수를 신뢰 불가로 표시할 수 있어야 한다"

즉 규칙은 이미 있고, 적용이 자리마다 손으로 반복된다.

## 2. 한 건씩 고치면 안 되는 이유

#38012 은 fleet 한 자리를 고쳤다. 같은 모양이 최소 둘 더 있고, 새 목록이 생길
때마다 하나씩 는다. 고치는 비용도 매번 같다 — 디코더 필드 하나, 렌더 분기 하나,
테스트 한 벌. 그리고 **빠뜨려도 아무것도 빨개지지 않는다**. 수는 그려지고,
못 읽은 것만 조용히 사라진다.

바뀌어야 하는 건 자리마다의 분기가 아니라 "센 수" 라는 개념이 반쪽만 타입에
있다는 것이다.

## 3. 설계

```ocaml
(* lib/tui_decode.ml *)
type counted = {
  counted : int;       (** 읽어서 센 것 *)
  unread : int;        (** 세려다 못 읽은 것 — 파일, 키퍼, 행 *)
}

val counted_field : Yojson.Safe.t -> count:string -> unread:string -> (counted, string) result
```

- 디코더는 두 필드를 **같이** 읽는다. 한쪽만 읽는 경로가 타입에 없다.
- 그리는 쪽은 `Masc_tui_counted.text` 하나를 쓴다. `unread = 0` 이면 지금과
  같은 문자열, 아니면 `3 (2 sources unread)` 처럼 뒤에 붙인다. 말은 한 곳에서만
  정해진다.
- 이미 그렇게 하는 Approvals·Overview 는 같은 함수로 모은다. 지금은 `held_note`
  와 `queue_note` 가 각자 문장을 갖고 있다.

`unread` 의 단위는 자리마다 다르다(파일·키퍼·행). 단위를 타입에 넣지 않고
`text ~noun:"source"` 처럼 부르는 쪽이 준다 — 단위를 타입에 넣으면 자리마다
생성자가 늘고, 그건 이 RFC 가 없애려는 그 모양이다.

## 4. 단계

| 단계 | 내용 | 끝났다는 기준 |
|---|---|---|
| 1 | `counted` 타입과 `text` | 단위 테스트: 0 이면 수만, 1+ 면 뒤에 붙음 |
| 2 | 세 자리를 이 타입으로 (fleet·검증 대기열·turn record) | 각 화면 라이브 캡처 |
| 3 | Approvals·Overview 의 손문장을 같은 함수로 | 문장이 한 곳에만 남음 |
| 4 | 가드 | 서버가 `*_unread`/`*_error_count`/`skipped_rows` 를 보내는 목록 중 `counted` 를 안 쓰는 것이 0 |

4 단계 가드는 payload 키 목록을 소스에서 찾는 방식이면 된다. 이 RFC 를 쓰게 만든
훑기가 그대로 가드가 된다 — 라이브 payload 의 키 중 `bin/**` 와 `tui_decode.ml`
어디에도 안 나오는 것을 세는 스크립트.

## 5. 검증

- 라이브: 세 자리 모두 `unread = 0` 이라 화면은 지금과 같아야 한다. 값이 0 이
  아닌 상태는 픽스처로만 만든다.
- 테스트: 자리마다 `unread > 0` 픽스처로 문장이 붙는 것, `= 0` 에서 안 붙는 것.
- 가드: 4 단계.

## 6. 하지 않는 것

- 못 읽은 것을 **고치지** 않는다. 이 RFC 는 화면이 그 사실을 말하게 할 뿐이다.
- `unread > 0` 을 경고색이나 알림으로 올리지 않는다. 수 옆의 사실이다.
- 서버가 안 보내는 자리에 필드를 새로 만들지 않는다. 이미 보내는 것만 읽는다.

## 7. 열린 질문

- `awaiting_unresolved_total` 은 "못 읽음" 이 아니라 "backlog 와 join 이 안 되는
  요청" 이다. 같은 타입으로 볼지, 다른 사실로 둘지 정해야 한다.
- Approvals 의 `held calls stale` 은 수가 아니라 **목록 전체가 낡았다**는 뜻이다.
  `unread` 와 같은 칸에 둘지, 별도 상태로 둘지.
