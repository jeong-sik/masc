# 메인 도메인 지연 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-09-05T17:20:00+09:00`
- 작성자: `Claude`
- 결정 ID: `main-domain-scheduler-latency-r1`
- 적용 대상: `main_eio.exe` 메인 Eio 도메인의 HTTP/SSE/keeper 스케줄링
- 결정 상태: `추적 필요`

## 근거

- 항목: 메인 스레드는 CPU 가 아니라 blocking syscall 뒤의 도메인 락 재획득에 시간을 쓴다. `/health` 는 p50 즉답, p90 3.38s, max 9.62s 로 이중 모드다.
- 출처: `sample 19654 3` 콜 그래프, `ps -M 19654`, `/health` 30회 curl, `.masc/logs/system_log_2026-09-05.jsonl` 의 `[snapshot_json]`·`heavy refresh`·`Domain_pool created`·`Shutdown complete` 행, `deployment_preflight_helper cut-run-registries` 보고, `find/stat` 로 잰 `.masc` 쓰기량
- 확인일시: `2026-09-05T16:45:00+09:00` ~ `2026-09-05T17:20:00+09:00`
- 신뢰도: `High` (측정값), `Medium` (락 보유자와 live 힙 구성 추정)
- 제한조건: 호스트 load 80~300 에서 잰 값이다. 조용한 호스트의 기준선은 없다. 서버는 측정 중 한 번 재시작됐다(07:57Z SIGINT, 08:00Z 재기동).
- Delta: 이전 문서(RFC-0204)는 "기다림이 지배한다"를 관찰로만 적었다. 이번에는 메인 스레드 샘플의 72% 가 락 재획득 대기임을 프레임 단위로 세었고, 재시작 횟수와 부팅 창 길이를 처음 기록했다.

## 검증

- 1차: 문서 §3 표의 샘플 수는 콜 그래프 파일의 메인 스레드 서브트리에서 직접 셌다.
- 2차: `/health` 지연 분포는 같은 서버에서 30회 반복으로 얻었고, 다른 시각의 3회 측정(0.7~1.5s)과 모순되지 않는다.
- 미검증: 3~10초 정지 구간의 OCaml 호출자, live 2.5GB 의 구성. RFC Phase 0 의 프로브와 Phase 0b 의 힙 루트 진단이 채운다.
