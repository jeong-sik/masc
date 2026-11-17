# Farm의 원격 stdio 세션 소유권

[양방향 shim 입력](2026-11-17-farm-interactive-stdin.md)과 `Mcp.Channel` 다음 층이다.
기존 MCP 클라이언트는 로컬 프로세스를 직접 만들었다. SSH·microVM의 실행 경로를
사용하려면 호스트가 원격 세션을 소유하고 MCP에는 입출력만 빌려줘야 한다.

## 프로세스 소유권

`Process_eio.with_stdio`는 기존 foreground process-group 관리자를 사용한다.
초기화된 Eio 환경과 spawn guard, cwd 권한을 유지하며 Unix fallback은 하지 않는다.
프로세스가 생기기 전 실패만 typed refusal로 반환한다. 실행 뒤 callback·stream
오류와 취소는 프로세스 정리 뒤 전파한다.

callback이 정상 반환하면 stdin을 닫고 남은 stdout과 stderr를 끝까지 전달한 뒤
실제 종료 상태를 기다린다. 본문을 head/tail 미리보기로 줄이지 않으며 종료값을
합성하지 않는다. 이 소유권은 로컬 carrier 프로세스와 그 그룹에 대한 것이다.
carrier를 종료했다는 사실만으로 다른 기기의 payload가 죽었다고 판단하지 않는다.

## 원격 요청과 관측

`Keeper_sandbox_remote.Stdio_request.prepare`는 endpoint, carrier argv, 환경,
payload argv·cwd·jail·mode를 캡처한다. 이 단계에서는 probe나 payload를 실행하지
않는다. endpoint의 기존 동시 세션 제한을 획득한 뒤 V3와 `interactive_stdin`
capability를 확인하고, 동일한 세션 제한을 프로세스 정리까지 유지한다.

`Keeper_sandbox_remote_stdio.with_stdio`는 실행 직전에 호출자의 typed dispatch
판정을 받는다. 거절되면 payload 요청을 보내지 않는다. 첫 프레임 쓰기를 시도하기
전에 실행 관측을 결과 불확실로 바꾸므로 부분 전송을 미전송으로 표시하지 않는다.

수신한 trailer의 버전과 receipt의 mode를 준비한 요청과 대조한다. 잘못된 receipt나
carrier 종료값과 맞지 않는 trailer를 정상 실행으로 만들지 않는다. callback의
반환값과 실제 종료 관측도 별도 값이다. MCP 응답 보존은 callback 안에서 세션을
닫기 전에 이루어져야 한다. 수신·보존 실패나 취소는 재전송 허가가 아니다.

stderr의 기존 acceptance/trailer decoder를 별도 모듈로 옮겨 framed runner와
공유한다. payload stdout에는 경로 치환이나 출력 길이 축약을 적용하지 않는다.

## 현재 범위와 검증

이 층은 OpenSSH와 microVM `Exec_per_request` carrier를 연결한다. guest-agent
소켓과 Docker는 실행 전에 명시적으로 거절하며 다른 carrier로 바꾸지 않는다.
특히 기본 microVM guest-agent 경로의 양방향 소켓·취소 지원은 남은 필수 작업이다.

제품 소스 10개 파일의 OCaml 5.5.2 구문 검사와 독립 소스 검토를 수행했다.
타입·링크·동작 시험은 아직 실행하지 않았다. 실제 shim을 쓰는 로컬 carrier 시험은
실제 SSH 네트워크나 VM 실행의 증거와 구분한다. 배포하거나 설치한 변경도 아니다.

외부 reader 선언, Gate 승인과 재개, 원본·전체 응답 보존, 불확실한 호출의 중복
실행 방지, 실제 DOCX 읽기까지 연결되어야 WIM-S05의 실행 경로가 된다.
이 프로세스·전송 기반 층만으로 Farm 목표 완료를 선언하지 않는다.
