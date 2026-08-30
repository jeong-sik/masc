# Tool metrics incremental percentiles 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T06:20:55+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-incremental-percentiles-r95
- 적용 대상: `Tool_metrics` accumulator, `/api/v1/tool-metrics`, Linux production image
- 결정 상태: 확정

## 근거

- 항목: exact order-statistics AVL tree로 요청 시 전체 duration 정렬을 제거한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-incremental-r1/r95-1m-mixed-load/summary.json`, `docs/research/2026-08-31-tool-metrics-incremental-percentiles-linux-r1.md`, issue #32009
- 확인일시: 2026-08-31T06:20:55+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, 1M retained rows, product head `cf9bda267f925e166576a061173e0d4aad66993e`

## 검증

- 1차: r94에서 snapshot cache가 write/read 교차 때 generation마다 전체 정렬하는 것을 실측했다.
- 2차: 20,000개 결정론적 값과 기존 sorted reference를 비교하고 100,000개 단조 입력으로 AVL 양쪽 경로를 확인했다.
- 3차: Linux에서 같은 1M input과 같은 20-write/20-read 간격을 r95에 적용했다.
- 4차: 정상 종료 뒤 같은 volume으로 replacement를 시작해 1,000,020개와 두 도구 percentile을 복구했다.
- 재현 결과: mixed read 평균/최대가 188.911/216.727ms에서 0.374/1.455ms로 줄었다. 총합과 exact percentile은 유지됐고 두 runtime 모두 exit 0/OOM false였다.

## 불확실성

- 미확인 항목: 1M 모두 고유한 runtime 데이터, 장시간 heap churn, 다수 도구 분포, 전체 테스트, GitHub CI, Kubernetes/PVC.
- 영향: duration이 모두 다르면 AVL node 메모리가 기존 list보다 커질 수 있다.
- 추가 확인 필요: 고유 duration 1M과 장시간 쓰기 부하에서 heap/GC를 측정하고 필요하면 retention window를 별도 설계한다.

## 적용범위

- 영향 받는 영역: duration 저장, exact percentile 선택, 누적 평균.
- 제약/배제: JSONL 형식, snapshot invalidation, HTTP shape, retention, 배포 volume은 바꾸지 않는다.
- 롤백 조건: sorted reference와 percentile이 다르거나, 단조 입력에서 stack/시간 문제가 생기거나, 실측 메모리가 허용 범위를 넘으면 변경을 중단한다.

