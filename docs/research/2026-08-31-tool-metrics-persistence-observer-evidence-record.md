# Tool metrics persistence observer 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T07:33:57+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-persistence-observer-r106-r107
- 적용 대상: `/api/v1/tool-metrics`, `Tool_metrics_persist` current-process state
- 결정 상태: 확정

## 근거

- 항목: aggregate tool count와 process-local persistence queue/drop/failure 상태를 한 응답에서 분리한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-persistence-observer-r1/r106-r107/summary.json`, `docs/research/2026-08-31-tool-metrics-persistence-observer-linux-r1.md`, issues #32014 and #32015
- 확인일시: 2026-08-31T07:33:57+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volumes, 단일 session load, current-process counters

## 검증

- 1차: initial API와 `/health?full=1`의 runtime identity가 일치하고 missing last-event가 `null`인지 확인했다.
- 2차: r106에서 5,000 accepted call 동안 queue/flush state를 polling하고 SIGKILL 전 pending 904를 확인했다.
- 3차: r106 replacement의 새 identity, hydrate/API 4,096, process counter reset을 확인했다.
- 4차: r107에서 실제 mode 0555 permission failure와 append-failure snapshot을 확인했다.
- 5차: storage mode 복구 뒤 success snapshot과 clean replacement 1/2 hydration을 확인했다.
- 6차: 4,096행 hydration 상태에서 API 1,000회의 mean/p95/max latency를 측정했다.
- 재현 결과: observer가 crash pending loss와 transient append loss를 추론 없이 직접 구분했다.

## 불확실성

- 미확인 항목: multi-process writer, network filesystem, Kubernetes/PVC, long-running counter overflow, full suite, GitHub CI.
- 영향: process counter reset은 replacement recovery가 아니라 새 identity의 새 관측 구간이다.
- 추가 확인 필요: #32014 durable pending spool과 #32015 append retry 구현 뒤 같은 반례를 다시 실행한다.

## 적용범위

- 영향 받는 영역: tool metrics summary JSON, persistence queue/drop/flush/failure bookkeeping.
- 제약/배제: aggregate hydration, queue capacity, non-blocking completion, JSONL row 형식, percentile은 바꾸지 않는다.
- 롤백 조건: snapshot이 HTTP latency를 유의하게 높이거나 identity가 health와 어긋나거나 failure/recovery state가 거짓으로 보이면 변경을 중단한다.
