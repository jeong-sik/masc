---
rfc: "0475"
title: "browser worker 호출자 소켓이 닫히면 호스트의 대기를 취소한다"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: vincent
related: ["46310", "46324"]
---

# RFC-0475 — browser worker 호출자 소켓이 닫히면 호스트의 대기를 취소한다

## 0. 요약

호스트가 browser worker 에 요청을 보낸 뒤 사라져도, 서비스는 연결 닫힘을 관측하지 않아 대기를 취소하지 않는다. 특히 #46310 의 BiDi 경로는 이미 보낸 exchange 를 호출자의 긴 deadline 까지 기다릴 수 있어 직렬 worker 가 오래 묶인다. 리뷰 두 건이 같은 P2 로 막고 있다.

이 RFC 는 이렇게 고치자고 제안한다.

- 클라이언트는 요청 한 줄을 쓴 뒤 응답을 읽을 때까지 연결을 쥐고 있는다. 쓰지도, half-close 하지도 않는다.
- 서비스는 대상인 live 요청을 처리하는 동안 같은 소켓을 함께 본다. 완료 확정 전에 소켓 닫힘(EOF 또는 reset)을 관측하면 호출자가 떠난 것으로 보고 호스트 쪽 요청 대기를 취소한다.
- live 요청은 호스트 안에서 호출자가 취소될 때 쓰는 기존 경로(`Eio.Cancel.Cancelled` → `interrupt`)를 그대로 쓴다. 다른 경로는 §3.3 에서 구분한다.

별도의 cancel 프레임은 만들지 않는다. 이유는 §4 에 있다.

사용자는 2026-10-28 에 제안 A 를 선택했다. 적용 범위와 남은 검증은 §6 에 적는다. 이 결정은 구현이나 검증이 끝났다는 뜻은 아니다.

## 1. 지금 무슨 일이 일어나나

#46310 head `30c5e7354ef8` 기준이다. main 에는 아직 상한 제거가 없다.

1. `Browser_addon_service.serve` 는 연결마다 요청 한 줄을 읽고, `handle` 이 끝난 뒤에야 응답을 쓴다. `handle` 이 도는 동안 소켓을 읽는 곳이 없다. 호출자가 소켓을 닫아도 `handle` 은 계속 돈다.
2. `Browser_lane.issue_live_with` 가 `interrupt` 를 푸는 곳은 `Eio.Cancel.Cancelled` 를 잡는 한 자리뿐이다. 호스트 안의 취소와 `retire_unlocked` 만 여기까지 온다. 소켓이 닫혔다는 사실은 여기에 닿지 않는다.
3. `Reply_window` 의 deadline 은 호출자가 준 `timeout_sec` 이다. #46310 이전에는 BiDi 의 한 exchange 전송 창이 `default_timeout_sec`(20초)로 고정이었다. 이것은 worker 전체 수명이나 후속 입력 정리 시간의 상한이 아니다. #46310 은 `extended = max transport_window remaining_deadline` 로 그 exchange 가 요청의 남은 deadline 까지 기다릴 수 있게 한다.
4. 묶인 동안 다른 요청은 줄을 선다. `only_if_idle` 요청은 waiter 가 있거나 command 큐가 비지 않으면 `optional_document_observation_busy` 로 거절된다(`browser_lane.ml:1255-1260`).

일반 제품 경로(`read_browser_document`)는 기본 20초 창을 쓴다. 긴 deadline 은 private wire 에서만 가능하다.

## 2. 확인한 사실

2026-10-28 에 #46310 head 소스를 직접 읽었다. 빌드와 테스트는 돌리지 않았다.

- 애드온 소켓에 연결하는 코드는 `Browser_addon_client`(운영)와 테스트뿐이다. 클라이언트는 `Eio.Flow.copy_string` 으로 한 줄을 쓰고 `Eio.Buf_read.line` 으로 한 줄을 읽는다. `shutdown` 을 부르지 않는다. 이 소켓에 half-close 를 쓰는 코드는 lib, bin, test 어디에도 없다. (`Flow.shutdown` 은 `browser_addon_live_ego.ml` 에 한 번 있고, 다른 소켓이다.)
- `Issue` 는 route 를 명시한다(`browser_addon_wire.ml:31-45,168`). `Browser_addon_owner.issue` 는 route 를 target 으로 풀고 `waiting` 에서 실행한다(`browser_addon_owner.ml:213-216,242-259`). `Live_client` 는 `issue_live_with` 로, `Automation` 과 `Stagehand` 는 각 backend 실행으로 갈라진다(`browser_lane.ml:1444-1449`). 따라서 `Issue` 전체가 live interrupt 경로를 쓴다는 뜻은 아니다. `Eio.Cancel.protect` 는 `cleanup`(Retire)에 있으나 `waiting` 에는 없다.
- live 안에서도 BiDi 는 `live_request_window` 의 interrupt 를 `Peer.dispatch` 에 넘기지만(`browser_addon_live_bidi.ml:237-265`), Ego 는 interrupt 를 구독하지 않고 이미 꺼낸 명령을 직렬 `Peer.dispatch` 로 계속 처리한다(`browser_addon_live_ego.ml:353-368`). Web extension 은 독립 실행자이므로 여기서 실행 중단을 가정하지 않는다.
- `Page_downloads` 의 성공 답은 별도로 broker `bind` 를 호출해 grant 를 만든다(`browser_addon_owner.ml:217-223`). 이 효과의 취소·정리 경계는 여기서 확인하지 않았다.
- `test_browser_addon_service.ml` 의 주석: 서비스가 응답 없이 연결을 닫으면 Linux 는 reset, macOS 는 EOF 를 준다. 소켓이 닫혔다는 신호가 플랫폼마다 둘로 나뉜다.

## 3. 제안

### 3.1 연결 계약

- 클라이언트는 요청 줄을 쓴 뒤 응답 줄을 읽을 때까지 연결을 열어 둔다. 그동안 아무것도 쓰지 않고 half-close 도 하지 않는다. 현재 클라이언트는 이미 이렇게 동작한다.
- 감시 대상 요청의 완료 확정 전에 연결 닫힘(EOF 또는 `Connection_reset`)을 관측하면 호출자가 떠난 것으로 본다. 완료 확정 뒤에야 확인된 닫힘은 결과를 뒤집지 않는다. 응답 쓰기에서 닫힘이 드러나면 그 연결의 쓰기 오류를 처리한다(T7).
- 감시 대상 요청의 줄 뒤에 바이트가 오면 계약 위반이다. dispatch 전에 발견하면 시작하지 않고 응답 없이 연결을 닫는다. 시작 후 완료 확정 전에 관측하면 요청 대기를 취소하고 응답 없이 닫는다. 같은 wire 는 이미 모르는 필드와 중복 필드를 거절한다.

### 3.2 서비스 쪽 변경

`serve` 는 읽은 프레임의 줄 종료자 유무를 보존하면서 요청을 한 번 decode 하고 typed command 로 §3.3 의 대상을 고른다. 대상일 때는 dispatch 전에 줄 종료자를 확인하고 아래 버퍼 선검사를 마친 뒤 같은 decoded request 의 `Owner.dispatch` 와 "연결이 닫히는지 보기"를 함께 실행하고 조정 규칙으로 결과를 고른다. 나머지 명령과 decode 거절은 기존 처리 경로를 쓴다. 닫힘이 먼저 관측되면 dispatch 파이버가 취소된다. 이미 `issue_live_with` 에 들어간 대상은 기존 `Cancelled` 갈래로 가서 `interrupt` 를 푼다. admission 중 취소되면 이 갈래에 들어가지 않을 수도 있다. 이 신호가 이미 시작한 입력의 후처리까지 같은 시간 창 안에 끝낸다는 보장은 없다.

**버퍼와 경합의 구현 조건.** 대상 요청의 줄 종료자를 소비한 직후, `Owner.dispatch` 와 닫힘 감시 파이버를 시작하기 전에 같은 `Buf_read` 에 이미 남은 바이트를 확인한다. `buffered_bytes` 는 추가 flow 읽기 없이 현재 버퍼의 크기를 알려 준다. 0보다 크면 계약 위반으로 응답 없이 연결을 닫고 dispatch 와 효과 호출을 시작하지 않는다. 0은 이미 버퍼에 든 초과 바이트가 없다는 뜻일 뿐, 커널에 없거나 이후 도착하지 않는다는 뜻은 아니다. 이후 닫힘 감시는 요청 줄을 읽은 `Buf_read` 자체를 이어서 읽는다. 이미 그 버퍼에 있는 요청 뒤 바이트를 확인하지 않고 underlying flow 만 감시하면 안 된다. 선검사 이후에야 관측한 바이트는 이미 시작한 효과를 중단하거나 되돌린다는 보장이 없다. dispatch 완료와 위반 관측은 한 조정 상태에서 직렬화한다. 완료를 확정하기 전에 이미 버퍼에 든 뒤 바이트를 먼저 확인하고, 확인되거나 감시가 위반을 먼저 등록했다면 위반이 이긴다. 완료가 확정된 뒤에야 관측된 바이트는 해당 결과를 뒤집지 않는다. 즉 순서는 서비스가 관측·확정한 시점으로 정하며, 아직 읽지 못한 커널 바이트의 실제 도착 순서를 안다고 주장하지 않는다. `Fiber.first` 만으로 동시 준비의 우선순위를 가정하지 않는다. T2 와 T11 은 이 조정 규칙을 구현할 때 고정한다.

**프레임과 예외.** `Eio.Buf_read.line` 은 개행 전 EOF 에서 읽은 바이트를 마지막 줄로 반환할 수 있으므로, EOF 예외만으로 종료자를 확인하지 않는다. 대상 요청은 LF 또는 CRLF 종료자를 실제로 확인하고, 종료자 없이 EOF 를 만난 완전한 JSON 도 불완전 프레임으로 거절해 dispatch 하지 않는다(T13). decode 이후 `Owner.dispatch` 를 직접 조정해도 기존 `handle` 의 경계를 유지한다. `Eio.Cancel.Cancelled` 는 재전파하고, 그 외 예상치 못한 예외는 로그와 `Outcome_unknown` 으로 처리한다. 효과 이후 예외를 실행 전 거절이나 재전송 허가로 바꾸지 않는다(T14).

응답은 `handle` 이 먼저 끝났을 때만 쓴다. 취소된 요청은 읽을 사람이 없으므로 응답을 쓰지 않는다. 대신 stderr 에 한 줄을 남긴다(`browser addon caller left; request cancelled`). 조용히 사라지게 두지 않는다.

**취소 뒤 늦은 답변.** #46310 head `30c5e7354ef8` 의 `issue_live_with` 는 요청마다 UUID 를 만들고 클라이언트별 `waiters` 에 그 ID 로 대기를 등록한다. 취소되면 switch 정리가 그 ID 의 waiter 를 지운다(`browser_lane.ml:1249-1269`). `deliver_result` 는 같은 클라이언트의 **답변 ID** 로만 waiter 를 찾아 풀며, 없으면 이미 전달한 동일 결과에 대한 멱등 응답을 제외하고 거절한다(`browser_lane.ml:1184-1204`). 따라서 A 취소 후 B 가 대기할 때 늦게 온 A 답변은 B 를 풀 수 없다. 이 규칙을 구현에서 유지하고 T6 으로 고정한다. 큐에 들어간 A 를 아직 꺼내지 않았다면 waiter 가 없어도 큐는 비지 않는다. 다음 poll 이 A 를 꺼내 waiter 가 없음을 보고 건너뛰기 전까지 `only_if_idle` 은 busy 다(`browser_lane.ml:1150-1163,1258-1260`). T8 에서 이 경우를 따로 확인한다.

**이미 보낸 효과.** 이 취소는 호스트가 결과를 기다리는 일을 끝내고 로컬 interrupt 를 알리는 것이다. 이미 extension 이나 브라우저에 전달된 클릭·입력의 실행 중단, 완료 또는 되돌림을 보장하지 않는다. 효과가 발생했는지 모르면 재전송하지 않는다. 소스상 BiDi 는 interrupt 뒤 이미 전송한 명령의 답을 그 명령의 전송 창 잔여 시간 동안 기다릴 수 있다(`browser_bidi_peer.ml:813-843`). 입력을 보냈다면 `input.releaseActions` 정리는 별도 `exchange ~window:timeout` 을 시작할 수 있어, 전체 처리 시간이 그 첫 창 안에 든다고 보장하지 않는다(`browser_bidi_peer.ml:395-402,413-418,864-881`). `Outcome_unknown` 이면 live BiDi 의 serve 루프가 오류로 끝나 클라이언트를 끊는다(`browser_addon_live_bidi.ml:240-248,266-273`). waiter 정리, 입력 정리, worker 종료와 새 peer 의 준비는 서로 다른 경계다. 소켓 닫힘만으로 즉시 worker 가 풀리거나 같은 peer 가 유지된다고 약속하지 않는다. T1 과 T10 은 각각을 따로 확인한다.

Ego 와 Web extension 에서는 대상 live `Issue` 의 호스트 waiter 만 정리한다. 실행 중인 A 가 끝나지 않았더라도 B 를 큐에 넣는 것이 실행자가 idle 이거나 B 가 완료됐다는 증거는 아니다. `only_if_idle` 은 `Page_document` 만 받으며, Ego 는 그 기능을 지원하지 않아 idle 검사 전에 거절한다(`browser_addon_owner.ml:251-257`, `browser_lane.ml:752-758,1240-1245`). BiDi 와 Web extension 의 지원 경로에서는 waiter·큐 검사 통과도 worker 의 실행 완료를 뜻하지 않는다. A 결과는 원래 ID 로 돌아오며 §3.2 의 늦은 답 규칙을 따른다. 실행 취소·worker 가용성을 보장하려면 transport 별 별도 설계와 검증이 필요하다(T12).

### 3.3 어떤 명령에 적용하나

명령마다 호출자가 떠난 뒤 취소해도 되는지가 다르다. 예를 들어 `Retire` 의 정리는 취소돼도 끝까지 가야 하고, `Download_commit` 은 영속 효과가 있다.

`Browser_addon_wire` 에 `ends_with_caller : command -> bool` 을 두고, 모든 명령을 `_` 없이 적는다. 새 명령이 생기면 컴파일러가 결정을 강제한다. 서비스는 이 함수가 `true` 인 명령에만 닫힘 감시를 붙인다. 이 구조여서 "N 군데 중 일부만 고친" 패치가 되지 않는다.

초기 `true` 는 `Issue {route = Live_route (Some _); verb; ...}` 중 `Page_downloads` 를 제외한 경우다. 이 분기에서 verb 도 `_` 없이 모든 생성자를 열거해, 새 verb 가 생기면 기존 분류에 자동으로 들어가지 않고 취소 안전성을 결정하게 한다. `Live_route None` 은 owner 가 거절한다. `Automation_route` 와 `Stagehand_route` 는 backend 실행 경로가 달라 취소 안전성이 확인되지 않았고 `false` 다. `Page_downloads` 는 live 라도 grant 준비 경계가 확인되기 전까지 `false` 다. 나머지(`Poll`, `Model_wait`, `Extension` 등)도 `false` 다. 이 제외 때문에 #46310 의 모든 긴 요청이 해결됐다고 주장하지 않는다. 범위를 넓히기 전에는 각 경로의 취소·부분 효과를 확인한다.

## 4. 대안과 트레이드오프

| 안 | 장점 | 단점 |
|---|---|---|
| A. 제안안: 닫힘 = 호출자가 떠남 | 호스트가 죽거나 kill 당해도 커널이 소켓을 닫아 감지된다. 기존 취소 경로를 쓴다. wire 형식이 안 바뀐다 | half-close 를 쓰는 클라이언트는 지원하지 않는다. 그런 클라이언트가 생기면 요청이 취소된다(조용한 hang 이 아니라 눈에 보이는 실패) |
| B. 명시적 cancel 프레임 | half-close 와 닫힘을 구별할 수 있다 | 클라이언트가 죽으면 프레임 없이 소켓만 닫힌다. 이때 서비스는 "프레임 없는 닫힘"을 어떻게 볼지 정해야 한다. 취소로 보면 프레임은 필요 없고, 안 보면 호스트가 죽은 경우 현재 구멍이 그대로 남는다. 클라이언트와 서비스 wire 를 둘 다 바꾼다 |
| C. 원격 요청 deadline 에 20초 상한 | 한 줄 수정 | 증상을 가리는 상한(Cap)이라 워크어라운드 기준에 걸린다. 대체 설계(A)를 후속으로 써야 하고, #46310 이 목표로 한 "원래 deadline 존중"을 private wire 에서는 포기한다 |
| D. keep-alive 하트비트 | 죽은 상대를 시간 안에 알 수 있다 | 간격과 허용 횟수를 정해야 한다. 닫힘이 이미 있는 신호를 시간으로 다시 추측하는 셈이다 |

사용자는 A 를 선택했다. B 는 half-close 클라이언트가 실제로 생길 때 다시 검토한다. 그때 계약을 바꾸면 이 RFC 도 갱신한다.

## 5. 검증

코드 전에 시험 틀을 먼저 둔다.

| 시험 | 내용 | 변이(mutant) |
|---|---|---|
| T1 | `Page_document` 를 지원하는 BiDi 또는 Web extension client 에 긴 `timeout_sec` 의 live `Issue` A 를 보낸다. client 가 A 를 큐에서 꺼내 전달받았다는 barrier 뒤 소켓을 닫는다. A waiter 가 지워지고 큐에 A 가 남지 않아 다음 `only_if_idle` `Page_document` B 가 실제로 접수되어 큐에 들어간다. `client_disconnected` 같은 다른 거절은 통과가 아니다. 이는 worker idle, B 완료, peer 생존의 증거가 아니다 | 닫힘 감시를 지우면 T1 이 실패해야 한다 |
| T2 | 감시 대상 요청의 줄 종료자와 뒤 바이트가 같은 `Buf_read` 버퍼에 들어간 상태를 만든다. 선검사에서 위반을 발견해 응답 없이 닫고 `Owner.dispatch` 와 효과 호출이 각각 0회인지 확인한다. 별도로 선검사 후 뒤 바이트가 도착한 경우를 검사하되, 이미 시작된 효과는 취소·복원했다고 가정하지 않는다 | 버퍼 선검사를 dispatch 뒤로 옮기거나 바이트 검사를 지우면 실패 |
| T3 | 응답이 먼저 오는 정상 경로. 기존 service 시험이 그대로 통과한다 | — |
| T4 | `ends_with_caller` 가 `_` 없이 모든 명령과 live `Issue` 의 모든 verb 를 적었는지는 컴파일로 확인한다 | 새 명령 또는 verb 를 임시로 추가하면 컴파일이 실패해야 한다 |
| T5 | Linux 컨테이너에서 reset 경로(`Connection_reset`)가 EOF 와 같게 처리된다 | — |
| T6 | 같은 클라이언트에서 A 를 전달한 뒤 호출자 연결을 닫아 A waiter 를 정리하고 B 를 발행한다. A 의 늦은 답을 주입해도 B 가 풀리지 않으며, B 자신의 ID 로 보낸 답만 B 를 푼다 | ID 대신 현재 waiter 를 풀면 실패 |
| T7 | `handle` 이 먼저 끝났지만 응답 쓰기 전에 상대가 소켓을 닫아 `EPIPE` 또는 reset 이 난다. 연결 처리만 끝나고 서비스와 다음 요청은 계속된다 | 쓰기 오류가 서비스 전체로 전파되면 실패 |
| T8 | `Page_document` 를 지원하는 live client 에서 A 가 큐에 들어간 뒤 poll 전에 연결을 닫는다. waiter 는 지워져도 큐가 남아 `only_if_idle` `Page_document` 는 busy 다. 이어 유한한 poll 창에서 A 는 전달되지 않고 건너뛰며, 다른 command 가 없으면 poll 은 빈 결과로 끝난다. 큐가 빈 뒤에만 새 `only_if_idle` 요청이 허용된다 | waiter 만으로 idle 을 판단하거나 취소된 A 를 전달하면 실패 |
| T9 | `Automation_route`, `Stagehand_route`, `Live_route None`, live `Page_downloads` 와 나머지 명령은 닫힘 감시 대상으로 분류되지 않는다. 유효한 다른 live `Issue` 는 대상으로 분류된다 | route 또는 download 예외를 지우면 실패 |
| T10 | BiDi 입력 전송 뒤 호출자를 끊고 입력 응답과 `releaseActions` 응답을 각각 지연시킨다. 첫 명령과 별도 입력 정리의 결과·시간을 구분해 기록한다. 결과가 `Outcome_unknown` 이면 기존 serve 루프가 종료하고 연결을 끊는지 확인하며, 새 peer 준비는 따로 확인한다 | 정리 누락이나 미확인 결과를 성공으로 처리하면 실패 |
| T11 | dispatch 완료와 뒤 바이트 감시가 둘 다 준비된 상태를 barrier 로 만든다. 완료 확정 전에 이미 버퍼에 있는 바이트나 먼저 등록된 위반은 이기고, 완료 확정 뒤에만 관측된 바이트는 완료를 뒤집지 않는다 | `Fiber.first` 승자만으로 판정하면 동시 준비 시험에서 실패 |
| T12 | Ego 에서 A 실행 시작 barrier 뒤 호출자를 끊고 A 를 계속 막는다. waiter 정리와 일반 `Issue` B 의 큐 진입을 관찰하되 B 가 A 종료 전 실행·완료됐다고 가정하지 않는다. A 의 늦은 결과가 B 에 배달되지 않는지 확인한다. Web extension 은 같은 ID 격리와 실행 지속을 독립 client fixture 로 확인한다 | 큐 진입을 실행 완료로 취급하거나 늦은 A 를 B 에 붙이면 실패 |
| T13 | 효과가 있는 감시 대상 live `Issue` 의 완전한 JSON 뒤에 줄 종료자 없이 EOF 를 보낸다. 불완전 프레임으로 거절되고 dispatch 와 효과 호출은 0회다. LF 와 CRLF 정상 프레임도 각각 허용한다 | `Buf_read.line` 의 반환만으로 종료자를 인정하면 실패 |
| T14 | 효과 호출 뒤 dispatch 가 예외를 내면 `Outcome_unknown` 으로 분류하고 다음 연결도 처리한다. `Eio.Cancel.Cancelled` 는 별도로 재전파된다 | 효과 후 예외를 `Not_started` 로 바꾸거나 취소를 삼키면 실패 |

측정 목표는 "소켓이 닫힌 뒤 worker 가 풀리기까지 걸린 시간"이다. 숫자는 구현 뒤 측정해서 적는다. 지금은 측정값이 없다.

## 6. 결정과 남은 일

1. **연결 계약**. 사용자는 제안 A 를 선택했다. 대상 요청에서는 완료 확정 전에 관측한 EOF 또는 reset 을 호출자 이탈로 본다. half-close 는 지원하지 않는다.
2. **초기 적용 범위**. §3.3 의 선택된 live `Issue` 중 `Page_downloads` 를 제외한 범위로 구현한다. 다른 route·`Poll`·`Model_wait` 등으로 넓히기 전에는 해당 경로의 취소 안전성을 확인한다.
3. **요청 줄 뒤 바이트**. §3.1–3.2 에 따라 dispatch 전 이미 버퍼에 있으면 시작하지 않고 닫는다. 시작 후 완료 확정 전에 관측하면 대기를 취소하고 응답 없이 닫는다.
4. **구현과 검증**. 구현은 이 P2 가 제기된 #46310 에 얹는다. §5 의 시험과 독립 리뷰는 별도로 필요하다. 결정만으로 #46310 의 열린 변경 요청이나 HOLD 가 해소된 것은 아니다.

## 7. 하지 않는 것

- 클라이언트가 보내는 새 프레임 종류, keep-alive, 재시도.
- 옛 클라이언트용 호환 경로. 지금 클라이언트가 이미 계약을 지키므로 필요 없다.
- `Retire`, `Download_commit` 등 §3.3 에서 제외한 별도 command 에 닫힘 취소를 붙이는 일. 대상 live `Issue` 가 일으킨 페이지 효과는 취소를 보장하지 않는다.

## 8. 확신 수준

중간. 소스 직독이고 실행은 하지 않았다. 확신이 낮은 곳은 둘이다. 하나는 `Poll` 등 다른 명령의 서버 쪽 취소가 안전한지, 하나는 종료자 확인과 `Buf_read` 선검사·이후 감시를 실제 서비스에서 어떻게 조합할지다. 구현 전후에 각각 확인한다.
