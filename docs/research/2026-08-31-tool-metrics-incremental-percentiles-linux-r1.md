# Tool metrics incremental percentiles Linux R1

## 결과

`Tool_metrics`가 duration 전체 목록을 보관하고 API 요청 때 정렬하던 구조를 exact order-statistics
AVL tree로 바꿨다. 각 노드는 같은 duration의 개수와 subtree 전체 개수를 가진다. 기록은
O(log distinct), p50/p95/p99 선택은 각각 O(log distinct)다. 기존
`round((n-1)*p)` 위치와 `Float.compare` 순서를 그대로 쓴다.

근삿값이나 구간 histogram을 쓰지 않았다. 정상·deferred·failure 수, 평균, percentile JSON 계약도
그대로다.

## 테스트

- 20,000개 결정론적 난수와 기존 배열 정렬 결과의 p50/p95/p99를 직접 비교했다.
- 50,000개 고유값을 오름차순과 내림차순으로 넣어 양쪽 회전과 중복 개수를 확인했다.
- snapshot cache의 연속·8-domain 공유와 `record`/`replace_samples` 무효화도 유지했다.
- `test_tool_metrics` 11/11, persist 5/5, unified 6/6, focused `main_eio` build 통과.

## r95 Linux/arm64 1M 혼합 부하

- product head: `cf9bda267f925e166576a061173e0d4aad66993e`
- image: `sha256:a71bd4beff99d0d37cad4fe6fac394dde0754394d234ba4232b7565efe55efa6`
- binary: `d0bf177faa94e67a7be76764250803c70e0090929d7592f061e0d808ec3540d5`
- 입력: 정상 1,000,000행 + 깨진 JSON 1,000 + 형식 불일치 1,000, 89,019,000 bytes.
- 시작→hydration 로그: 1.708초. 첫 API: 0.361ms. 메모리: 78.98MiB.
- 실제 `masc_status` 20회와 API read 20회를 r94와 같은 간격으로 교차했다.
- read 최소/평균/최대: 0.216/0.374/1.455ms.
- 20개 call 모두 HTTP 200/`isError=false`, 최종 총합 1,000,020.
- 관측 최고 CPU 46.91%, 메모리 83.85MiB, exit 0/OOM false.

r94 snapshot-cache 구조에서 write 뒤 read 평균/최대는 188.911/216.727ms였다. r95는 평균
505배, 최대 149배 빨랐다. r94의 관측 메모리 최고 205.8MiB도 r95에서는 83.85MiB였다.

## 재시작

첫 runtime을 정상 종료하자 JSONL은 1,002,020 physical rows가 됐다. 같은 state/data volume으로
replacement를 시작했다. `hydrated 1000020`, 시작→hydration 1.687초, 첫 API 0.443ms,
총합 1,000,020이었다. `masc_config` 1M의 p50/p95/p99는 51/95/99로 유지됐고
`masc_status` 20개의 percentile도 교체 전후가 같았다. replacement도 exit 0/OOM false였다.

## 경계

- tree는 불변이며 기존 `Stdlib.Mutex` 안에서 순수 계산만 한다. I/O나 Eio yield는 없다.
- 같은 duration이 많으면 한 노드의 multiplicity로 압축된다. 모두 다른 값이면 노드 수는 호출 수와
  같아져 기존 list보다 노드당 메모리가 커질 수 있다.
- duration을 삭제하는 sliding window는 아직 없다. retention은 재시작 시 JSONL day file 단위다.
- 1M 모두 고유한 runtime 데이터, 장시간 heap churn, 다수 도구 분포는 아직 실측하지 않았다.
- 전체 테스트, GitHub CI, Kubernetes/PVC, published artifact는 확인 범위 밖이다.
- `/Users/dancer/me/.masc`와 현재 8935 서버는 변경하거나 재시작하지 않았다.

## 근거

- [근거] exact sorted-reference/단조 입력 테스트, source/image/binary identity, 동일 1M input,
  r94/r95 mixed-load HTTP 시간, 실제 MCP calls, restart hydration/API/percentile, exit/OOM과 disk SHA,
  2026-08-31T06:20:55+09:00 확인, 신뢰도 High.

