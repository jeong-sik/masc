# Tool metrics fallback pending spool 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T11:04:31+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-fallback-pending-spool-r126
- 적용 대상: `Tool_metrics_persist` pending spool, startup hydration, `/api/v1/tool-metrics.persistence`
- 결정 상태: 확정

## 근거

- 항목: bulk data pending write 실패 시 bounded exact record를 `.masc` fallback에 보존하고 restart에서 복구한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-fallback-pending-spool-r1/summary.json`, `docs/research/2026-08-31-tool-metrics-fallback-pending-spool-linux-r1.md`, issue #32032
- 확인일시: 2026-08-31T11:04:31+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volumes, single process writer, queue capacity 4,096
- Delta: queue-full 전 memory-only row가 restart에서 사라지던 r125를 per-record runtime-state fallback spool로 교체했다.

## 검증

- 1차: focused tests 20/20에서 fallback recovery, double failure, duplicate ID, invalid fallback path를 확인했다.
- 2차: focused build, `@fmt`, `Tool_unified` 6/6을 확인했다.
- 3차: Linux builder가 commit `f7eac670...` 서버와 helper를 새로 만들고 helper/health/binary SHA가 일치하는지 확인했다.
- 4차: r126 actual 1,000 calls에서 fallback-backed queue/file 1,000과 primary/fallback failure 1,000/0을 확인했다.
- 5차: r126 `SIGKILL` replacement가 fallback 1,000을 복구해 final 1,000으로 옮기고 다음 restart가 중복 없이 final 1,000만 읽는지 확인했다.
- 6차: r127 actual 5,000 calls에서 fallback files가 queue capacity 4,096을 넘지 않고 drop marker와 함께 동작하는지 확인했다.
- 7차: r128에서 fallback target failure가 memory-only counter와 invalid fallback startup count로 남는지 확인했다.
- 재현 결과: r125의 replacement aggregate 0이 r126 replacement에서는 aggregate/final 1,000으로 바뀌었다.

## 불확실성

- 미확인 항목: host power loss, fsync durability, network filesystem, Kubernetes/PVC, multi-process writer, full suite, GitHub CI.
- 영향: 두 pending 위치가 모두 실패하면 crash recovery는 불가능하다. Per-record fallback은 data-root 장애 path latency와 inode/block 사용량을 늘린다.
- 추가 확인 필요: Draft PR CI/review 뒤 merge head에서 1,000-call와 5,000-call restart를 재검증하고 batch/WAL 대안의 비용을 별도 측정한다.

## 적용범위

- 영향 받는 영역: pending file publication/removal, dual-source startup hydration/dedup, persistence observability.
- 제약/배제: normal primary spool success path, final JSONL schema, queue capacity, exact lifetime drop count는 바꾸지 않는다.
- 롤백 조건: fallback record가 queue bound를 넘거나 final append 전에 삭제되거나 restart에서 duplicate aggregate를 만들면 변경을 중단한다.
