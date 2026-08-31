# Tool metrics pending spool 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T09:02:33+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-pending-spool-r111-r113
- 적용 대상: `Tool_metrics_persist` accepted-row process-crash recovery
- 결정 상태: 확정

## 근거

- 항목: 성공적으로 pending 게시된 tool metric row를 process SIGKILL 뒤 복구하고 final/pending crash window를 dedup한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-pending-spool-r1/summary.json`, `docs/research/2026-08-31-tool-metrics-pending-spool-linux-r1.md`, issue #32014
- 확인일시: 2026-08-31T09:02:33+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, 단일 process writer, successful pending publication

## 검증

- 1차: focused unit test에서 pending recovery, final-row dedup, spool failure fallback, append retry를 확인했다.
- 2차: exact-head helper와 health가 commit `f2d5269e...` 및 binary SHA `1ea4b93b...`를 증언했다.
- 3차: r111 actual accepted 401, final 0, pending 401 상태에서 SIGKILL하고 replacement 401/401을 확인했다.
- 4차: final append 뒤 pending delete permission failure를 만들고 replacement dedup 1, aggregate/final 402를 확인했다.
- 5차: r112 256-way actual call 1,000건과 fresh old baseline의 mean/p95/p99/max를 비교했다.
- 6차: r112를 다시 SIGKILL하고 replacement recovered/final 1,000을 확인했다.
- 7차: r114 unavailable final storage에서 accepted 5,000을 durable pending 4,096/drop 904로 bounded 분리하고 SIGKILL replacement 4,096을 확인했다.
- 재현 결과: successful pending publication 뒤 process crash로 accepted row가 사라지던 #32014 반례는 r111과 r112에서 재현되지 않았다.

## 불확실성

- 미확인 항목: host power loss, network filesystem, Kubernetes/PVC, multi-process writer, full suite, GitHub CI.
- 영향: pending write failure와 capacity 초과 904건은 crash durability가 아니다. drop counter는 current-process라 replacement가 과거 drop을 복구하지 않는다. local concurrency latency는 배포 환경의 상한이 아니다.
- 추가 확인 필요: Draft PR CI와 review를 통과한 뒤 merge head에서 같은 SIGKILL probe를 재실행한다.

## 적용범위

- 영향 받는 영역: tool metric pending publication, queue capacity accounting, startup hydration/replay/dedup, persistence snapshot.
- 제약/배제: tool result 자체의 durability, host power-loss guarantee, existing JSONL aggregate semantics, percentile algorithm은 바꾸지 않는다.
- 롤백 조건: pending I/O가 실제 workload tail을 허용 범위 밖으로 늘리거나 duplicate/loss가 재현되거나 spool directory가 bounded queue와 독립적으로 증가하면 변경을 중단한다.
