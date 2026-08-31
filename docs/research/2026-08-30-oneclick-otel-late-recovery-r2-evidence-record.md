# One-click OTLP late recovery 근거 기록 R2

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:49:26+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-otel-late-recovery-linux-r2`
- 적용 대상: background OTLP recovery와 restart immediate setup
- 결정 상태: `확정`

## 근거

- 항목: background로 옮긴 exporter setup은 collector late-start recovery와
  collector-ready restart 경로를 모두 유지해야 한다.
- 출처: exact-head Linux container health/logs와 synthetic collector HTTP request
  logs
- 확인일시: `2026-08-30T17:49:26+09:00`
- 신뢰도: `High`
- 제한조건: Linux/arm64 Docker network와 HTTP 200 synthetic collector에서
  측정했다.
- Delta: R1 코드 변경 없이 collector availability만 absent에서 present로 바꿨다.

## 검증

- 1차: collector 부재에서 5회 retry와 recovery mode 진입을 확인했다.
- 2차: recovery mode 뒤 collector를 붙여 다음 probe의 exporter active 전환을
  health와 server log로 확인했다.
- 3차: metrics 41건과 trace 1건의 HTTP POST 수신, collector-ready server restart,
  restart 뒤 metrics 전송을 확인했다.
- 재현 결과: 성공. late recovery와 restart immediate setup 모두 startup wiring을
  막지 않았다.

## 불확실성

- 미확인 항목: protobuf decoding 결과와 production collector backend 적재.
- 영향: payload semantic 또는 backend-specific incompatibility는 이번 HTTP 수신
  증거만으로 배제할 수 없다.
- 추가 확인 필요: 실제 OpenTelemetry Collector의 debug exporter로 payload 수용과
  decoded span attributes를 별도 확인한다.

## 적용범위

- 영향 받는 영역: OTLP endpoint recovery probe, exporter setup, metrics/trace HTTP
  transport, restart continuity.
- 제약/배제: production collector, keeper/provider turn, deployed runtime, payload
  semantic validation은 범위 밖이다.
- 롤백 조건: late collector를 발견하지 못하거나, restart가 wiring을 막거나,
  exporter active인데 HTTP POST가 발생하지 않으면 롤백한다.
