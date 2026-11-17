# Farm 외부 reader를 위한 양방향 shim 입력

[Farm 계획의 WIM-S05](2026-11-12-agent-farm-plan.md)는 선언한 외부 서비스가
media를 읽는 경로다. stdio MCP는 첫 응답을 읽은 다음 새 요청을 보내야 한다.
기존 shim은 초기 프레임의 입력만 자식에게 전달하고 이후 채널 입력을 버렸다.
이 변경은 그 실행 프로토콜의 입력 경계를 마련한다.

## 입력과 종료 계약

`Exec_ssh_protocol.request.stdin`은 `Framed of int64 | Interactive`이다.
`Framed`는 기존 `stdin_len`과 초기 payload를 쓰고, 전달이 끝나면 자식 stdin을
닫는다. `Interactive`는 V3에서만 허용하며 `stdin_stream: true`를 쓰고
`stdin_len`을 생략한다. 두 표현을 함께 쓰거나 입력 키를 중복하면 거절한다.
초기 프레임에는 입력 bytes가 없고, 이후 bytes를 그대로 자식에게 보낸다.

호스트는 V3 probe의 `interactive_stdin` capability를 확인해야 한다.
probe 실패는 허가가 아니다. 이전 shim은 필수 `stdin_len`이 없으므로
interactive 요청을 자식을 만들기 전에 거절한다.

interactive 채널의 EOF는 실행 취소다. 입력 완료를 뜻하는 half-close가 아니다.
shim은 입력과 두 출력을 고정 크기 버퍼로 중계한다. 입력 버퍼가 가득 차도
별도로 hangup을 확인하고, 출력이 막혀도 기존 timeout·TERM/KILL 정리를 수행한다.
자식 종료 뒤 기존 drain 유예 안에 출력을 전달하지 못하면
`interactive_output_incomplete` 오류를 남긴다. 실제 sandbox 적용 receipt와
timeout 여부는 유지하며, 그 오류를 정상 완료된 출력으로 다루지 않는다.
최종 제어 프레임 쓰기에도 같은 유예 길이를 별도 적용한다. trailer를 끝까지
쓰지 못하면 shim은 0이 아닌 값으로 종료한다.

독립 리뷰에서 Observe의 알림 수신 루프가 다음 알림을 기다리며 멈추는 결함을
찾았다. `NOTIF_RECV`는 `O_NONBLOCK`만으로 비차단 호출이 되지 않는다.
framed·interactive 감독 루프 모두 준비된 알림 하나에 응답한 뒤 입력·출력·취소
감시로 돌아가도록 바꾼다. 응답 전 대상이 사라진 알림은 실행 증거로 기록하지 않는다.

추가 독립 리뷰에서 기존 Observe 채널 준비 실패가 정적 네트워크 차단도 없는
실행으로 이어지는 경로를 확인했다. listener 전달용 socketpair를 준비하지 못하면
payload를 fork하기 전에 scratch를 정리하고 `Refused` receipt로 끝낸다.
capability probe 성공만으로 대체 차단 장치가 실제 설치됐다고 판단하지 않는다.

## 검증 범위

- 프로토콜 시험은 V2 거절, capability 일치, 입력 키 중복, 초기 payload 거절,
  기존 framed 표현을 다룬다.
- 실제 shim·relay 시험은 첫 응답 이후 두 번째 입력을 보내며 NUL·비 UTF-8
  bytes와 payload 종료값을 확인한다.
- 실제 shim receipt 시험은 입력·출력 정체, EOF 취소, timeout, 자식 그룹 정리,
  불완전 출력 오류를 다룬다. 기존 Observe·Guest_local receipt 시험을 유지한다.
- interactive Observe 시험은 socket 접근 거절 뒤 새 입력에 응답하고 EOF로
  종료하는지, 실제 syscall 관측과 실행 receipt가 남는지 확인한다.

작성 시점에는 OCaml 구문 검사와 macOS C 구문 검사만 수행했다. Linux 전용
C 분기와 추가한 동작 시험은 실행 전이며, 이 문서는 타입·링크·CI·설치·원격
실행 성공의 증거가 아니다.

## 다음 연결

기존 Keeper runner는 계속 `Framed` 요청을 만든다. 이 변경만으로 외부 reader가
실행되지는 않는다. 다음 층에서 SSH·microVM 세션의 소유권, endpoint 동시 실행
제한, capability 확인, 실제 실행 receipt를 유지하는 stdio API를 연결해야 한다.

guest agent relay의 기존 queued-bytes-before-EOF 동작은 유지했다. relay 입력
버퍼까지 가득 찬 경우의 즉시 취소는 이 변경의 보장이 아니며, 호스트 연결 층에서
명시적인 전달 계약을 갖춰 검증해야 한다.

그 뒤 선언한 reader의 설정, typed Gate 승인, 요청 원본과 전체 응답 보존,
결과를 잃은 호출의 중복 실행 방지, 실제 DOCX 해석을 연결한다. WIM-S05와
Farm 전체 목표는 아직 완료되지 않았다.

구현 계약: [프로토콜 인터페이스](../../lib/exec_ssh_protocol/exec_ssh_protocol.mli),
[shim 인터페이스](../../lib/exec_shim/exec_shim.mli).
