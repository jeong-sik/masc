# Keeper purge chat store 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T15:23:36+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-purge-chat-store-same-process-r1`
- 적용 대상: process-local Keeper Owner의 chat operation store lifecycle
- 결정 상태: `추적 필요`

## 근거

- 항목: purge가 runtime directory를 제거한 뒤 same-name `Create`는 남은 Owner
  actor의 삭제된 SQLite handle을 재사용하지 않고 새 store를 열어야 한다.
- 출처: exact Git-context Linux image, binary `build-commit`, `/health`,
  `sha256sum`, Keeper down/purge/up, SQLite stat, chat operation, Qwen metrics/log
- 확인일시: `2026-08-30T15:23:36+09:00`
- 신뢰도: `High`
- 제한조건: 128자 ASCII Keeper와 Local sandbox profile에서 측정했다.
- Delta: actor-serialized `Create`에서 operation store path absence를 확인해
  parent와 SQLite store를 재생성하고 projection을 교체한다.

## 검증

- 1차: baseline은 same-process recreate 첫 message가 SQLite `READONLY`였다.
- 2차: open SQLite directory를 삭제하는 owner actor focused test와 정상 최초
  생성 test가 2/2 통과했다.
- 3차: fixed Linux image에서 동일 runtime instance의 stop→purge→up→message
  operation이 `Succeeded`, 응답 `SAME_PROCESS_OK`, READONLY match 0이었다.
- 재현 결과: 성공. server restart 없이 chat store가 현재 inode로 재생성됐다.

## 불확실성

- 미확인 항목: operation store reopen 자체가 실패하는 filesystem fault injection.
- 영향: 이 경우 `Create`는 명시적 Store_unavailable로 실패하며 재시도/운영 복구
  절차의 별도 검증이 필요하다.
- 추가 확인 필요: reopen failure injection과 concurrent external deletion case.

## 적용범위

- 영향 받는 영역: Keeper Owner meta `Create`와 chat operation SQLite handle.
- 제약/배제: DB schema 변경, migration, plain-agent, deployed
  `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: 정상 최초 Create가 store를 잃거나, purge 뒤 Create가 READONLY를
  재현하거나, operation inventory가 과거 DB 내용을 상속하면 롤백한다.
