# Keeper history 실행 ID 조회 지연

## 공통 헤더

- 날짜(ISO8601): 2026-09-13T03:31:44+09:00
- 작성자: Codex
- 결정 ID: keeper-history-index-20260913
- 적용 대상: Keeper_tool_call_index.by_execution_ids
- 결정 상태: 추적 필요
- Delta: 실행 ID 조건으로 먼저 조회하고 선택된 행만 OCaml에서 정렬한다.

## 근거 (Evidence)

- 항목: history GET의 SQLite 조회 병목
- 출처: sql-benchmark.json; https://www.sqlite.org/optoverview.html#order_by_optimizations; 로컬 sample 86177 3 출력
- 확인일시: 2026-09-13T03:31:44+09:00
- 신뢰도: High
- 제한조건: 실행 중인 서버의 SQL 병목을 확인했으며 수정한 서버 바이너리는 아직 배포하지 않았다.

## 검증 (Verification)

- 1차: 같은 시점의 health GET은 0.0242초에 200, msx-retro-mania history GET은 15.0224초에 timeout이었다. 서버 로그에는 2026-09-12T18:26:21Z의 chat-history cache compute timeout (30s)이 있다.
- 2차: sample에서 작업 스레드의 2454 표본 중 2393이 Keeper_tool_call_index.collect, 그중 2392가 sqlite3_step이었다. 기존 실행 계획은 rows_keeper_ts로 keeper_name만 제한했다.
- 3차: 읽기 전용 트랜잭션의 실행 ID 100개 비교에서 기존 조회 1.246895초, 변경 조회 0.000315초였다. 100개 반환 행과 순서는 일치했으며 변경 계획은 rows_keeper_execution의 두 키를 모두 사용했다. 캐시 상태와 데이터 분포에 따라 시간은 달라진다.
- 재현 결과: OCaml 문법 검사와 diff 검사는 통과했다. 실행 계획 및 중복 행 정렬 회귀 테스트를 추가했으며 컴파일과 실행 판정은 CI에서 확인한다.

## 불확실성 (Uncertainty)

- 미확인 항목: 새 바이너리의 history API 응답 시간, 전체 CI 결과.
- 영향: SQL 개선만으로 모든 history 지연이 제거됐다고 판단할 수 없다. ledger 갱신 및 raw trace 처리 비용은 남는다.
- 추가 확인 필요: CI 통과 후 같은 Keeper history GET을 실제 서버에서 측정한다.

## 적용범위 (Scope)

- 영향 받는 영역: 실행 ID별 정확한 도구 기록 조회와 동일 ID의 중복 증거 정렬.
- 제약/배제: 스키마, cache timeout, 메시지 큐, Keeper 실행 순서를 변경하지 않는다. 기존 keeper 격리와 ledger 재검증을 유지한다.
- 롤백 조건: 조회 결과 또는 순서 회귀 시 이 소스 변경을 되돌린다. DB migration은 없다.
