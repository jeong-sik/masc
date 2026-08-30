# Tool metrics 재시작 복구 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T05:42:07+09:00
- 작성자: Codex
- 결정 ID: tool-metrics-hydration-r89
- 적용 대상: `Tool_metrics`, `Tool_metrics_persist`, `/api/v1/tool-metrics`, production Docker runtime
- 결정 상태: 확정

## 근거

- 항목: 보존된 tool-metrics JSONL을 서버 시작 때 한 번 읽고 대시보드 집계를 같은 스냅샷에서 계산한다.
- 출처: `benchmarks/context_recovery/results/20260831-tool-metrics-hydrate-r1/r89-production-replacement/summary.json`, `observations.jsonl`, `docs/research/2026-08-31-tool-metrics-hydration-linux-r1.md`
- 확인일시: 2026-08-31T05:42:07+09:00
- 신뢰도: High
- 제한조건: Linux/arm64 Docker Desktop, local named volumes, product head `4dd5fc316520460f5f52795bced68b552744da28`

## 검증

- 1차: Hada 요약, Lemmalog 원문, STALE, Supersede를 확인하고 성공 로그가 아닌 최종 consumer 반환값을 판정 기준으로 삼았다.
- 2차: macOS binary를 재사용하지 않았다. Linux OCaml 5.5 builder에서 서버와 preflight helper를 빌드하고 ELF, binary SHA-256, image OS/arch/ID를 확인했다.
- 3차: r87 인증 가정을 폐기했다. r88에서 `hydrated 1`과 API 0의 모순을 재현해 두 메모리 원천을 찾았다. r89에서 새 이미지와 새 볼륨으로 A→B→C를 다시 실행했다.
- 4차: 정상 형식, 깨진 JSON, 현재 형식과 맞지 않는 행, 보존 기간, 반복 복구, 읽기 실패 원자성을 focused unit test로 확인했다.
- 5차: 같은 Linux image에서 빈 저장소, 100,000행, 1,000,000행을 비교했다. 각 크기를 두 번 시작해 skip count, API 총합/percentile/응답 시간, 메모리, exit/OOM을 확인했다.
- 재현 결과: r89 A는 호출 뒤 API 1, B는 새 호출 전 API 1과 호출 뒤 2, C는 새 호출 없이 API 2를 각각 두 번 연속 반환했다. 세 runtime은 고유하고 모두 exit 0/OOM false였다.

## 불확실성

- 미확인 항목: 1,000,000행 초과, 여러 도구 분포, 동시 API 요청, Kubernetes/PVC, multi-host filesystem, published release artifact, 전체 테스트, GitHub CI.
- 영향: 다른 저장 장치나 배포 경로의 권한·일관성 문제는 이번 로컬 Docker 결과만으로 확정할 수 없다.
- 추가 확인 필요: Draft PR CI와 실제 배포 환경에서 같은 consumer 검사를 반복한다.

## 적용범위

- 영향 받는 영역: 서버 시작 시 tool-metrics 복구와 `/api/v1/tool-metrics` 집계 원천.
- 제약/배제: 예전 JSONL 변환, 호출 출처/assignment 복원, `/Users/dancer/me/.masc`, 현재 8935 서버.
- 롤백 조건: 시작 시간이 허용 범위를 넘거나 API 집계가 live dispatch와 달라지면 observer 등록 전 복구와 요약 원천 변경을 함께 되돌린다.
