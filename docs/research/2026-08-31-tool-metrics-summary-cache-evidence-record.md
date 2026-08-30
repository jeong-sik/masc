# Tool metrics 요약 캐시 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T06:03:33+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-summary-cache-r93
- 적용 대상: `Tool_metrics.all_stats`, `/api/v1/tool-metrics`, Linux production image
- 결정 상태: 확정

## 근거

- 항목: 불변 통계 스냅샷을 첫 조회에서 한 번 계산하고, 기록·전체 교체·초기화 때만 버린다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-cache-r1/r93-1m-concurrency/summary.json`, `docs/research/2026-08-31-tool-metrics-summary-cache-linux-r1.md`, issue #32007
- 확인일시: 2026-08-31T06:03:33+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volume, 1M retained rows, product head `71830bcd9726e1cb73978810bd392d835b742029`

## 검증

- 1차: source에서 `all_stats`가 매 요청마다 duration list를 배열로 복사하고 정렬하는 것을 확인했다.
- 2차: 캐시 전 r92의 1M 16-way와 빈 저장소 16-way를 비교해 server-side tail amplification을 분리했다.
- 3차: cache head를 Linux에서 다시 빌드하고 같은 1M input으로 cold/warm 16-way를 실행했다.
- 4차: 별도 복제 volume에서 실제 `masc_config` 1회 뒤 첫 API가 1,000,001을 재계산하고 다음 API가 같은 값을 캐시에서 반환하는지 확인했다.
- 재현 결과: cold 평균/최대가 1.987/2.905초에서 0.190/0.203초로 줄었다. warm 평균/최대는 0.0016/0.0072초였다. 무효화 뒤 총합은 정확했고 두 컨테이너 모두 exit 0/OOM false였다.

## 불확실성

- 미확인 항목: 호출과 API 조회가 동시에 계속되는 혼합 부하, 여러 도구 분포, 1M 초과, 전체 테스트, GitHub CI, Kubernetes/PVC.
- 영향: 쓰기가 매우 잦으면 캐시 hit 비율이 낮아져 정렬 비용이 다시 나타날 수 있다.
- 추가 확인 필요: 혼합 부하를 별도 측정하고 필요할 때 percentile 자료구조 자체를 바꾼다.

## 적용범위

- 영향 받는 영역: `Tool_metrics.all_stats`의 계산 재사용과 세 쓰기 경로의 캐시 무효화.
- 제약/배제: percentile 알고리즘, persisted JSONL 형식, `stats_for`, retention, 배포 volume은 바꾸지 않는다.
- 롤백 조건: 새 호출 뒤 오래된 총합이 보이거나, 동시 reader가 서로 다른 snapshot을 보거나, 메모리 사용이 지속해서 증가하면 변경을 중단한다.

