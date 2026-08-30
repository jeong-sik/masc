# Tool metrics append retry 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T07:48:15+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-append-retry-r109-r110
- 적용 대상: `Tool_metrics_persist` failed append retention and retry
- 결정 상태: 확정

## 근거

- 항목: failed JSONL row를 bounded process queue에 보존하고 storage 복구 뒤 자동 재시도한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-append-retry-r1/r109-r110/summary.json`, `docs/research/2026-08-31-tool-metrics-append-retry-linux-r1.md`, issue #32015
- 확인일시: 2026-08-31T07:48:15+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volumes, default 0.5s interval, process-memory retry

## 검증

- 1차: deterministic append guard failure에서 같은 row가 retry queue에 남고 복구 뒤 기록되는지 확인했다.
- 2차: r109 실제 mode 0555 failure에서 queue/retry 1을 관측하고 mode 0755만 복구했다.
- 3차: 새 call 없이 자동 flush, disk 1행, clean replacement 1/1을 확인했다.
- 4차: r110 mode 0555 상태에서 256-way actual call 1,000건을 모두 수락했다.
- 5차: bounded retry cadence와 drop 0을 확인하고 mode 복구만으로 disk/replacement 1,000을 확인했다.
- 재현 결과: #32015의 transient append clean-restart loss는 r109와 r110에서 재현되지 않았다.

## 불확실성

- 미확인 항목: SIGKILL, process exit까지 지속되는 failure, capacity 초과, partial append, 자정 경계, network filesystem, Kubernetes/PVC, 전체 테스트, GitHub CI.
- 영향: 이 변경은 transient in-process storage recovery이며 durable spool이 아니다.
- 추가 확인 필요: #32014의 crash-pending acceptance를 별도 durable 설계로 검증한다.

## 적용범위

- 영향 받는 영역: tool metrics queue capacity accounting, failed append retry order/backoff, persistence snapshot.
- 제약/배제: tool completion non-blocking contract, capacity 4,096, JSONL row 형식, aggregate hydration, percentile은 바꾸지 않는다.
- 롤백 조건: producer latency가 storage I/O에 묶이거나 retry가 capacity 밖으로 증가하거나 unavailable storage에서 busy loop하면 변경을 중단한다.
