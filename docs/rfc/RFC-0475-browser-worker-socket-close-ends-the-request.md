---
rfc: "0475"
title: "browser worker 소켓이 닫히면 요청을 끝낸다"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: vincent
related: ["46310", "46324"]
---

# RFC-0475 — browser worker 소켓이 닫히면 요청을 끝낸다

## 0. 요약

호스트가 browser worker 에 요청을 보낸 뒤 사라져도, worker 는 그 요청의 deadline 이 끝날 때까지 직렬 worker 를 놓지 않는다. #46310 이 요청 deadline 의 상한(20초)을 없애면서 이 구멍이 커졌다. 리뷰 두 건이 같은 P2 로 막고 있다.

이 RFC 는 이렇게 고치자고 제안한다.

- 클라이언트는 요청 한 줄을 쓴 뒤 응답을 읽을 때까지 연결을 쥐고 있는다. 쓰지도, half-close 하지도 않는다.
- 서비스는 요청을 처리하는 동안 같은 소켓을 함께 본다. 응답 전에 소켓이 닫히면(EOF 또는 reset) 호출자가 떠난 것이다. 처리하던 요청을 취소한다.
- 취소는 새로 만들 신호가 아니다. 호스트 안에서 호출자가 취소될 때 쓰는 기존 경로(`Eio.Cancel.Cancelled` → `interrupt`)를 그대로 쓴다.

별도의 cancel 프레임은 만들지 않는다. 이유는 §4 에 있다.

사용자 결정이 필요한 곳은 §6 이다. 결정 전에는 코드를 쓰지 않는다.

## 1. 지금 무슨 일이 일어나나

#46310 head `0dc40dfef564` 기준이다. main 에는 아직 상한 제거가 없다.

1. `Browser_addon_service.serve` 는 연결마다 요청 한 줄을 읽고, `handle` 이 끝난 뒤에야 응답을 쓴다. `handle` 이 도는 동안 소켓을 읽는 곳이 없다. 호출자가 소켓을 닫아도 `handle` 은 계속 돈다.
2. `Browser_lane.issue_live_with` 가 `interrupt` 를 푸는 곳은 `Eio.Cancel.Cancelled` 를 잡는 한 자리뿐이다. 호스트 안의 취소와 `retire_unlocked` 만 여기까지 온다. 소켓이 닫혔다는 사실은 여기에 닿지 않는다.
3. `Reply_window` 의 deadline 은 호출자가 준 `timeout_sec` 이다. #46310 이전에는 전송 창이 `default_timeout_sec`(20초)로 고정이라 worker 가 최대 20초만 묶였다. #46310 은 `extended = max transport_window remaining_deadline` 로 이 상한을 없앤다.
4. 묶인 동안 다른 요청은 줄을 선다. `only_if_idle` 요청은 `Hashtbl.length client.waiters <> 0` 때문에 `optional_document_observation_busy` 로 거절된다.

일반 제품 경로(`read_browser_document`)는 기본 20초 창을 쓴다. 긴 deadline 은 private wire 에서만 가능하다.

## 2. 확인한 사실

2026-10-28 에 #46310 head 소스를 직접 읽었다. 빌드와 테스트는 돌리지 않았다.

- 애드온 소켓에 연결하는 코드는 `Browser_addon_client`(운영)와 테스트뿐이다. 클라이언트는 `Eio.Flow.copy_string` 으로 한 줄을 쓰고 `Eio.Buf_read.line` 으로 한 줄을 읽는다. `shutdown` 을 부르지 않는다. 이 소켓에 half-close 를 쓰는 코드는 lib, bin, test 어디에도 없다. (`Flow.shutdown` 은 `browser_addon_live_ego.ml` 에 한 번 있고, 다른 소켓이다.)
- 요청 처리 `Browser_addon_owner.dispatch` 의 `Issue` 갈래에는 `Eio.Cancel.protect` 가 없다. `handle` 파이버를 취소하면 취소가 `issue_live_with` 까지 내려간다. `Eio.Cancel.protect` 는 `cleanup`(Retire)에만 있다.
- `test_browser_addon_service.ml` 의 주석: 서비스가 응답 없이 연결을 닫으면 Linux 는 reset, macOS 는 EOF 를 준다. 소켓이 닫혔다는 신호가 플랫폼마다 둘로 나뉜다.

## 3. 제안

### 3.1 연결 계약

- 클라이언트는 요청 줄을 쓴 뒤 응답 줄을 읽을 때까지 연결을 열어 둔다. 그동안 아무것도 쓰지 않고 half-close 도 하지 않는다. 현재 클라이언트는 이미 이렇게 동작한다.
- 응답 전에 연결이 닫히면(EOF 또는 `Connection_reset`) 호출자가 떠난 것이다.
- 요청 줄 뒤에 바이트가 오면 계약 위반이다. 요청을 취소하고 응답 없이 연결을 닫는다. 같은 wire 는 이미 모르는 필드와 중복 필드를 거절한다.

### 3.2 서비스 쪽 변경

`serve` 가 요청 줄을 읽은 뒤, `handle` 과 "연결이 닫히는지 보기"를 `Eio.Fiber.first` 로 겨룬다. 닫힘이 먼저 오면 `handle` 파이버가 취소된다. 취소는 `issue_live_with` 의 기존 `Cancelled` 갈래로 가서 `interrupt` 를 풀고, #46310 이 이미 넣은 규칙(남은 전송 창만 쓰고 새 창을 열지 않는다)이 이어진다.

응답은 `handle` 이 먼저 끝났을 때만 쓴다. 취소된 요청은 읽을 사람이 없으므로 응답을 쓰지 않는다. 대신 stderr 에 한 줄을 남긴다(`browser addon caller left; request cancelled`). 조용히 사라지게 두지 않는다.

### 3.3 어떤 명령에 적용하나

명령마다 호출자가 떠난 뒤 취소해도 되는지가 다르다. 예를 들어 `Retire` 의 정리는 취소돼도 끝까지 가야 하고, `Download_commit` 은 영속 효과가 있다.

`Browser_addon_wire` 에 `ends_with_caller : command -> bool` 을 두고, 모든 명령을 `_` 없이 적는다. 새 명령이 생기면 컴파일러가 결정을 강제한다. 서비스는 이 함수가 `true` 인 명령에만 닫힘 감시를 붙인다. 이 구조여서 "N 군데 중 일부만 고친" 패치가 되지 않는다.

제안하는 초기 값은 `Issue` 만 `true` 다. 나머지(`Poll`, `Model_wait`, `Extension` 등)는 각 명령의 서버 쪽 취소가 안전한지 읽어 본 뒤 바꾼다.

## 4. 대안과 트레이드오프

| 안 | 장점 | 단점 |
|---|---|---|
| A. 제안안: 닫힘 = 호출자가 떠남 | 호스트가 죽거나 kill 당해도 커널이 소켓을 닫아 감지된다. 기존 취소 경로를 쓴다. wire 형식이 안 바뀐다 | half-close 를 쓰는 클라이언트는 지원하지 않는다. 그런 클라이언트가 생기면 요청이 취소된다(조용한 hang 이 아니라 눈에 보이는 실패) |
| B. 명시적 cancel 프레임 | half-close 와 닫힘을 구별할 수 있다 | 클라이언트가 죽으면 프레임 없이 소켓만 닫힌다. 이때 서비스는 "프레임 없는 닫힘"을 어떻게 볼지 정해야 한다. 취소로 보면 프레임은 필요 없고, 안 보면 호스트가 죽은 경우 현재 구멍이 그대로 남는다. 클라이언트와 서비스 wire 를 둘 다 바꾼다 |
| C. 원격 요청 deadline 에 20초 상한 | 한 줄 수정 | 증상을 가리는 상한(Cap)이라 워크어라운드 기준에 걸린다. 대체 설계(A)를 후속으로 써야 하고, #46310 이 목표로 한 "원래 deadline 존중"을 private wire 에서는 포기한다 |
| D. keep-alive 하트비트 | 죽은 상대를 시간 안에 알 수 있다 | 간격과 허용 횟수를 정해야 한다. 닫힘이 이미 있는 신호를 시간으로 다시 추측하는 셈이다 |

A 를 권한다. B 는 half-close 클라이언트가 실제로 생길 때 쓴다. 그때 계약을 바꾸고 이 RFC 를 갱신한다.

## 5. 검증

코드 전에 시험 틀을 먼저 둔다.

| 시험 | 내용 | 변이(mutant) |
|---|---|---|
| T1 | 응답하지 않는 live client 에 긴 `timeout_sec` 의 `Issue` 를 보낸 뒤 소켓을 닫는다. waiter 표가 비고, 다음 `only_if_idle` 요청이 `optional_document_observation_busy` 로 거절되지 않는다 | 닫힘 감시를 지우면 T1 이 실패해야 한다 |
| T2 | 요청 줄 뒤에 바이트를 보낸다. 요청이 취소되고 응답이 오지 않는다 | 바이트 검사를 지우면 실패 |
| T3 | 응답이 먼저 오는 정상 경로. 기존 service 시험이 그대로 통과한다 | — |
| T4 | `ends_with_caller` 가 `_` 없이 모든 명령을 적었는지는 컴파일로 확인한다 | 새 명령을 임시로 추가하면 컴파일이 실패해야 한다 |
| T5 | Linux 컨테이너에서 reset 경로(`Connection_reset`)가 EOF 와 같게 처리된다 | — |

측정 목표는 "소켓이 닫힌 뒤 worker 가 풀리기까지 걸린 시간"이다. 숫자는 구현 뒤 측정해서 적는다. 지금은 측정값이 없다.

## 6. 사용자가 정할 것

1. **A 로 갈지**. §4 의 B 를 원하면 "프레임 없는 닫힘"을 어떻게 볼지가 같이 정해져야 한다.
2. **초기 적용 범위**. `Issue` 만(제안), 또는 `Poll`·`Model_wait` 같은 순수 대기까지.
3. **요청 줄 뒤 바이트**. 취소하고 닫기(제안), 또는 무시.
4. **어디에 넣나**. 구현은 #46310 에 얹기를 권한다. 이 P2 가 #46310 의 상한 제거에서 생겼고, 리뷰어가 그 PR 에서 닫히기를 기다린다. 그동안 #46310 은 Draft 로 둔다.

## 7. 하지 않는 것

- 클라이언트가 보내는 새 프레임 종류, keep-alive, 재시도.
- 옛 클라이언트용 호환 경로. 지금 클라이언트가 이미 계약을 지키므로 필요 없다.
- `Retire` 와 영속 효과 명령에 닫힘 취소를 붙이는 일.

## 8. 확신 수준

중간. 소스 직독이고 실행은 하지 않았다. 확신이 낮은 곳은 둘이다. 하나는 `Poll` 등 다른 명령의 서버 쪽 취소가 안전한지, 하나는 `Buf_read` 로 닫힘을 기다릴 때 요청 줄 뒤에 이미 버퍼에 들어온 바이트를 어떻게 구별할지다. 둘 다 구현 전에 읽어서 확인한다.
