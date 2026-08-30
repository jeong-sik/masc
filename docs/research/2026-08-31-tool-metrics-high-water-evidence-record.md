# Tool metrics high-water wake 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T07:12:50+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-high-water-wake-r104
- 적용 대상: `Tool_metrics_persist` bounded queue writer wake policy
- 결정 상태: 확정

## 근거

- 항목: 4,096 queue의 50%인 2,048건에서 background writer를 조기 기상시킨다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-high-water-r1/r104-300s-replacement/summary.json`, `docs/research/2026-08-31-tool-metrics-high-water-linux-r1.md`, issue #32011
- 확인일시: 2026-08-31T07:12:50+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, 단일 session 순차 5,000-call load, Eio 1.3

## 검증

- 1차: exact Eio 1.3 Condition/Broadcast source와 local installed version을 확인했다.
- 2차: cross-domain producer가 2,048건에서 10초 timer보다 먼저 waiter를 깨우는 focused test를 추가했다.
- 3차: 300초 timer를 둔 exact Linux image에서 body-level accepted call 5,000건을 실행했다.
- 4차: 2,048행 high-water batch 두 번, drop 0, shutdown 904행, replacement 5,000을 확인했다.
- 5차: default 0.5초 image run에서 threshold 미만 한 건이 timer로 flush되는 회귀 검증을 수행했다.
- 재현 결과: r98의 clean-restart 904건 손실은 같은 300초 timer 조건의 r104에서 재현되지 않았다.

## 불확실성

- 미확인 항목: writer scheduling 전 4,096 초과 burst, storage보다 빠른 지속 부하, 강제 지연/network filesystem, 장시간 idle, 전체 테스트, GitHub CI, Kubernetes/PVC.
- 영향: high-water wake는 손실 가능 구간을 줄이지만 best-effort queue를 durable store로 바꾸지 않는다.
- 추가 확인 필요: queue depth/drop/high-water runtime 관측과 storage drain보다 빠른 부하에서 durable spool 필요성을 측정한다.

## 적용범위

- 영향 받는 영역: tool metrics persistence writer wake timing과 flush trigger log.
- 제약/배제: queue capacity, non-blocking completion contract, JSONL 형식, hydration, percentile은 바꾸지 않는다.
- 롤백 조건: cross-domain wake가 유실되거나 timer flush가 멈추거나 completion latency가 유의하게 악화되면 변경을 중단한다.
