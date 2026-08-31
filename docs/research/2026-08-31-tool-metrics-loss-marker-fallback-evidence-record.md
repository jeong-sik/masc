# Tool metrics loss marker fallback 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T10:37:05+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-loss-marker-fallback-r119
- 적용 대상: `/api/v1/tool-metrics.aggregate_integrity`, `Tool_metrics_persist` runtime-state fallback marker
- 결정 상태: 확정

## 근거

- 항목: bulk data root가 쓰기 불가여도 queue-full 손실 증거를 별도 `.masc` state root에 보존한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-loss-marker-fallback-r1/summary.json`, `docs/research/2026-08-31-tool-metrics-loss-marker-fallback-linux-r1.md`, issue #32024
- 확인일시: 2026-08-31T10:37:05+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volumes, single process writer, 30-day retention
- Delta: r118의 bulk-root 단일 failure domain을 분리하고 marker source와 invalid source를 current API에 추가했다.

## 검증

- 1차: focused tests 17/17에서 fallback write/restart, mixed valid-invalid sources, 이중 write failure를 확인했다.
- 2차: focused `lib/masc.cma`, 두 test executable build, `@fmt`, `Tool_unified` 6/6을 확인했다.
- 3차: Linux builder가 commit `3aa69fb3...` 서버와 helper를 새로 만들고 helper/health/binary SHA가 일치하는지 확인했다.
- 4차: r119에서 `/app/data` 전체 write failure, queue 4,096/drop 1, primary failure 1/fallback failure 0을 확인했다.
- 5차: r119 `SIGKILL` exit 137/OOM false 뒤 aggregate row 0인 replacement가 origin runtime ID와 `known_incomplete`를 유지하는지 확인했다.
- 6차: r121/r122 각각 actual MCP HTTP/body success 4,097/4,097와 latency 분포를 확인했다.
- 7차: r124에서 fallback target만 실패시켜 primary/fallback failure 1/1, pre-kill `unknown`, restart `invalid_marker`를 확인했다.
- 재현 결과: r118에서 restart 뒤 사라졌던 loss evidence가 r119에서는 독립 fallback marker로 남았다.

## 불확실성

- 미확인 항목: host power loss, fsync durability, network filesystem, Kubernetes/PVC, multi-process writer, full suite, GitHub CI.
- 영향: `.masc` fallback까지 실패하면 restart-safe loss evidence가 없고 current failure counter만 남는다. 로컬 latency 차이는 배포 상한이 아니다.
- 추가 확인 필요: Draft PR CI/review 뒤 merge head에서 같은 data-root failure와 SIGKILL replacement를 재검증한다.

## 적용범위

- 영향 받는 영역: queue-full marker write/read, startup hydration, aggregate integrity와 persistence JSON projection.
- 제약/배제: full metrics row 복제, exact lifetime drop count, queue capacity, normal in-capacity enqueue path는 바꾸지 않는다.
- 롤백 조건: 정상 enqueue가 fallback I/O를 수행하거나 valid fallback이 restart 뒤 사라지거나 invalid source가 숨겨지면 변경을 중단한다.
