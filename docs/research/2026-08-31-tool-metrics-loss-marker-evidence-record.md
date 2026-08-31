# Tool metrics loss marker 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T09:26:25+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-loss-marker-r116
- 적용 대상: `/api/v1/tool-metrics.aggregate_integrity`, `Tool_metrics_persist` queue-full loss marker
- 결정 상태: 확정

## 근거

- 항목: retention 범위의 queue-full 손실 증거를 process restart 뒤에도 aggregate와 함께 노출한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-loss-marker-r1/summary.json`, `docs/research/2026-08-31-tool-metrics-loss-marker-linux-r1.md`, issue #32019
- 확인일시: 2026-08-31T09:26:25+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, single process writer, 30-day retention

## 검증

- 1차: focused tests에서 fresh unknown, valid known-incomplete, expiry, invalid marker, marker-write failure를 확인했다.
- 2차: exact-head helper와 health가 commit `9978e056...` 및 binary SHA `d1adf832...`를 증언했다.
- 3차: unavailable final storage에서 actual MCP 5,000/5,000, queue 4,096/drop 904와 durable marker를 확인했다.
- 4차: SIGKILL exit 137/OOM false 뒤 replacement가 4,096을 복구하고 current drop 0과 known-incomplete를 함께 반환하는지 확인했다.
- 5차: origin runtime ID/timestamp가 replacement에서도 유지되는지 확인했다.
- 6차: corrupt marker restart가 unknown이 아니라 invalid-marker로 분리되는지 확인했다.
- 재현 결과: pre-kill snapshot 없이 aggregate 4,096만 남아 과거 drop 904를 알 수 없던 #32019 반례가 r116에서 재현되지 않았다.

## 불확실성

- 미확인 항목: host power loss, network filesystem, Kubernetes/PVC, multi-process writer, full suite, GitHub CI.
- 영향: marker는 exact lifetime count가 아니며 write failure 시 restart-safe loss evidence가 없다. saturation 단일 run은 배포 latency 상한이 아니다.
- 추가 확인 필요: Draft PR CI/review 뒤 merge head에서 queue-full SIGKILL과 marker corruption을 재검증한다.

## 적용범위

- 영향 받는 영역: tool metrics queue-full path, retention-scoped aggregate integrity API, startup marker hydration.
- 제약/배제: aggregate count, 4,096 queue capacity, pending spool recovery, normal in-capacity enqueue path는 바꾸지 않는다.
- 롤백 조건: normal path가 marker I/O를 수행하거나 marker absence를 complete로 표시하거나 stale/invalid marker가 known-incomplete로 오인되면 변경을 중단한다.
