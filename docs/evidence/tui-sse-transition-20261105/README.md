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

로그 위치: `artifacts/tui-sse-lanes-20261104/baseline-browser-push-v3-result.log`, 원본 PTY `baseline-browser-push-v3.log`.

## 구현 경계

- `workspace_dataset_changed.dataset=browser_observation`은 `source`, `clientId`, `tabId`, read/scene/viewport identity와 revision만 갖는다. PNG·page text·scene 본문은 넣지 않는다.
- 서버는 구독이 있는 대상만 2초 간격으로 읽고, `elapsed_ms`를 제외한 응답의 SHA-256 revision이 바뀔 때만 알린다. backend 공통 native DOM event가 아니라 **서버 관측**이다. observer가 닫히면 관측도 멈춘다.
- TUI는 일치하는 알림만 기존 read/scene/screenshot 경로로 읽는다. single-flight·trailing·실패 backoff·재연결 재검증을 공유하며, pointer press·URL 초안·client picker·진행 중 요청은 구독도 멈춘다.
- Machine은 Control 모드에서만 `machine` query와 서버 ticker를 사용한다. Observe·checkpoint 전에는 ticker를 멈추며 `/api/v1/msx/tick`을 호출하지 않는다.
- `--refresh`와 UI 평면 주기 데이터 읽기는 제거됐다. 시작·명시적 `r`·실패 재시도·재연결·표시 전용 애니메이션·로그인 마감은 별개다.

## 후보 검사

- `41873422680`: targeted Test, `6357e36cad8ab0d4e70f03d5d1b23ca1e35777de`, 결과 대기.
- `41873431127`: `pr-type-check.yml`, 같은 head, 결과 대기.
- Native artifact와 후보 PTY: 결과 대기.
- 최종 결과·실제 요청 수·sample cap·backend 미검증 범위: 결과 대기.
