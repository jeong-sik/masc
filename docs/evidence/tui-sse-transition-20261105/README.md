# TUI SSE 전환 실측 (2026-11-05)

## 범위와 미검증 상태

이 문서는 PR #48180의 현재 구현과 기존 TUI의 요청 경로를 구분해 기록한다. 현재 head `6357e36cad8ab0d4e70f03d5d1b23ca1e35777de`는 개발 후보이며, 병합·운영 설치·재시작·`~/me/.masc` 변경을 증명하지 않는다. 최종 원격/native 결과가 없는 항목은 통과로 표기하지 않는다.

TUI 렌더링 최적화와 측정은 별도 완료 증거인 [`tui-smoothness-20261104`](../tui-smoothness-20261104/README.md)를 따른다. 호출 수 감소가 UI 입력 지연 감소를 자동으로 의미하지는 않는다.

## 기존 바이너리 기준선

- 실행 파일: `/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin/masc_tui.exe`
- `--build-commit`: `b7a4aa5a81f5fe935fd19a9f4a7b1fb23752be7d`
- 실행: `python3 test/test_tui_browser_push.py <baseline binary>`, 35x200 PTY, `go Browser Lane` 선택, HTTP fixture.
- `open` 단계 총 31.213초의 기존 테스트 실패 기록에서 같은 선택 tab `2`의 read POST가 **13회**, clients GET이 **14회**였다. 초기 tab 미지정 read 1회는 별도다.
- 실패 이유는 `source=live&clientId=…&tabId=2&view=read`의 scoped observer query가 없어서다. 즉 이 측정은 평면 고정 idle 구간이 아니라, scoped query를 기다리던 기존 테스트의 전체 `open` 단계다. 같은 구간 시간당 요청 수로 일반화하지 않는다.
- 실제 Browser는 사용하지 않았다. 응답은 fixture이며, 기존 평면 2초 cadence에 해당하는 반복 HTTP 읽기다.

고정 idle 보정 측정도 같은 35x200 PTY와 palette 경로로 수행했다. 초기 선택 tab 응답 1회를 기다린 뒤 2.4초를 유지하는 동일 스크립트에서 실제 경과는 **2.434742초**, 선택 tab read POST는 총 **2회**(초기 1회 + idle 중 추가 1회), clients GET은 **3회**, scoped observer는 **0회**였다. 이 측정에는 scoped query를 기다리는 실패 대기가 없다. 후보에도 같은 스크립트를 적용해 분모를 맞춘다.

Machine도 같은 바이너리와 `test_tui_spectator_push.py`의 1.2초 초기 화면에서 측정했다. `live:msx_capture` 응답은 **4회**로 후보의 기대값 1회와 달라 기준선 테스트가 실패했다. 이 실패는 전환 전 주기 읽기의 측정값이며, 후보 결과로 기록하지 않는다.

로그 위치: 이 번들의 `baseline-browser-result.log`, `baseline-browser-idle-result.log`, `baseline-spectator-result.log`. 원본 PTY는 `artifacts/tui-sse-lanes-20261104/baseline-browser-push-v3.log`, `baseline-browser-idle.log`, `baseline-spectator-push.log`.

## 구현 경계

- `workspace_dataset_changed.dataset=browser_observation`은 `source`, `clientId`, `tabId`, read/scene/viewport identity와 revision만 갖는다. PNG·page text·scene 본문은 넣지 않는다.
- 서버는 구독이 있는 대상만 2초 간격으로 읽고, `elapsed_ms`를 제외한 응답의 SHA-256 revision이 바뀔 때만 알린다. backend 공통 native DOM event가 아니라 **서버 관측**이다. observer가 닫히면 관측도 멈춘다.
- TUI는 일치하는 알림만 기존 read/scene/screenshot 경로로 읽는다. single-flight·trailing·실패 backoff·재연결 재검증을 공유하며, pointer press·URL 초안·client picker·진행 중 요청은 구독도 멈춘다.
- Machine은 Control 모드에서만 `machine` query와 서버 ticker를 사용한다. Observe·checkpoint 전에는 ticker를 멈추며 `/api/v1/msx/tick`을 호출하지 않는다.
- `--refresh`와 UI 평면 주기 데이터 읽기는 제거됐다. 시작·명시적 `r`·실패 재시도·재연결·표시 전용 애니메이션·로그인 마감은 별개다.

## 후보 검사

- 초기 `41873422680`, `41873431127`, `41874150253`과 후속 `41939020498`, `41939032518`은 컴파일 실패다. 의존성 순환, 테스트 선언·인자, optional argument 경고를 수정했으며 통과로 표기하지 않는다.
- `41940548438`: `pr-type-check.yml`, production head `941a75b3ee3579ee919a2dc41fdb532e4dc2d28e`, **성공**.
- `41940536681`: 20개 targeted suite, 같은 production head, 실행 중.
- `41941769088`: macOS native proof, 입력 source-sha도 같은 production head, 실행 중. workflow ref의 문서-only head `4a24f0615439eec91165f3516c541ffe09ec6e19`와 구분한다.
- 후보 artifact·PTY 결과, 실제 요청 수·sample cap·backend 미검증 범위: 결과 대기.
