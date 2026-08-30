# Tool metrics flush cadence 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T06:41:30+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-flush-cadence-r100
- 적용 대상: `MASC_METRICS_FLUSH_SEC`, `Tool_metrics_persist`, Linux production image
- 결정 상태: 확정

## 근거

- 항목: non-blocking 4,096 queue의 기본 background flush를 0.5초마다 실행한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-flush-r1/r100-5000-call-replacement/summary.json`, `docs/research/2026-08-31-tool-metrics-flush-cadence-linux-r1.md`, issue #32011
- 확인일시: 2026-08-31T06:41:30+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, admitted sequential 5,000-call burst

## 검증

- 1차: r97의 rate-limit rejection을 확인하고 queue 증거에서 폐기했다.
- 2차: r98에서 rate limit만 높여 5,000회 성공, live 5,000, disk/replacement 4,096을 재현했다.
- 3차: 기존 image에 flush 0.5초 override를 준 r99에서 drop 0과 replacement 5,000을 확인했다.
- 4차: 새 default image r100을 override 없이 실행해 같은 5,000-call replacement를 반복했다.
- 재현 결과: r100은 5,000회를 모두 background batch로 기록했고 replacement API도 5,000이었다. 두 runtime은 exit 0/OOM false였다.

## 불확실성

- 미확인 항목: 0.5초 안의 4,096 초과 burst, 느린/network filesystem, 장시간 idle wake cost, 전체 테스트, GitHub CI, Kubernetes/PVC.
- 영향: drain 처리량을 넘는 burst에서는 best-effort drop이 다시 발생할 수 있다.
- 추가 확인 필요: high-watermark wake 또는 durable spool이 필요한 처리량 경계를 별도 측정한다.

## 적용범위

- 영향 받는 영역: metrics persistence background wake cadence, operator default snapshot, interval log.
- 제약/배제: queue capacity, enqueue non-blocking contract, JSONL 형식, hydration, percentile은 바꾸지 않는다.
- 롤백 조건: idle CPU/wake cost가 허용 범위를 넘거나, background I/O가 tool call latency를 높이거나, 5,000-call replacement가 다시 손실되면 변경을 중단한다.

