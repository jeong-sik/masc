---
rfc: "turn-failure-visible-stop"
title: "턴 실패는 멈추고 그 상태를 보여준다 — 실패 면제와 예산 계정을 걷어낸다"
status: Draft
created: 2026-08-31
updated: 2026-08-31
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: 턴 실패는 멈추고 그 상태를 보여준다 (turn-failure-visible-stop)

## 0. 요약

네트워크가 완전히 죽어도 Keeper는 같은 턴을 영원히 재시도하고 fleet health는
`ok`를 보고한다(#31958 실측: 59초에 44턴 실패, 전부 `consecutive=0`,
`operator_action_required=false`). 원인은 "일시적 실패는 crash 계정에서
면제한다"는 설계와, 그 면제를 봉합하는 클래스별 예산 장치다.

이 RFC는 그 방향을 폐기한다. 실패 클래스를 분류해 면제하고 예산으로 봉합하는
대신, CLI 에이전트(Claude Code, Codex)와 같은 모양을 무인 fleet에 옮긴다:

**유한한 재시도는 하부 계층에 맡기고, 턴이 실패하면 원인 불문 대기(백오프)하고,
연속 실패가 임계치를 넘으면 멈춘 상태를 fleet health에 보여준다.**

면제, 클래스별 예산, 예산의 내구 저장(`keeper_failure_exemption_store`)은
걷어낸다.

## 1. 문제

### 1.1 현재 구조

턴 실패 처리는 세 겹이다.

1. `Keeper_error_classify.is_auto_recoverable_turn_error`가 실패를 분류한다.
2. `Keeper_unified_turn_failure.account_failure_counting`이 crash 계정
   streak에 셀지 정한다. 조건은
   `(not auto_recoverable) || runtime_exhausted || empty_completion 소진 ||
   invalid_request 소진`.
3. streak가 임계치를 넘으면 Keeper는 Failing으로 승격되고 fleet health에
   반영된다.

"일시적" 클래스(네트워크/타임아웃, 0바이트 completion, InvalidRequest)는 2에서
면제된다. 면제가 무한이면 영구 장애에서 무한 재시도가 되므로, 면제 클래스마다
예산(InvalidRequest 3회, empty completion 5회)을 두고 소진 시 다시 streak에
세게 돌려주며, 예산은 재시작 후에도 유지한다(#31970 → #31971).

### 1.2 실패한 지점

- 네트워크/타임아웃에는 예산 항이 없다. `account_failure_counting`의 어느
  항과도 성립하지 않으므로 영원히 면제다. #31958의 무한 루프가 여기서
  난다. 이슈는 아직 열려 있다.
- `keeper_error_classify.ml`의 불변식 주석("면제에는 보상 회계가 따라온다",
  "network exemption은 account_failure_counting이 별도로 묶는다")은
  633-640행에서 코드와 어긋난다. 주석만 존재하는 불변식은 컴파일러도 테스트도
  지켜주지 못한다. 실제로 썩은 채 방치됐다.
- 구조적으로도 이 설계는 O(클래스)로 자란다. 면제 클래스가 하나 늘 때마다
  예산 상수, 소진 판정, 증가 지점, 리셋 경로, 저장 스키마 필드가 함께
  늘어난다. #31960(draft)은 네트워크 예산을 세 번째로 추가하는 방향이었고,
  그 15초(예산 3 × 케이던스 5초)를 위해 내구 카운터 전체를 하나 더 복제한다.

### 1.3 같은 문제를 남들은 어떻게 푸나

- Claude Code: Anthropic SDK가 `maxRetries` 기본 2회, 0.5초 시작 지터 백오프로
  재시도한 뒤 포기하고 사용자에게 에러를 보여준 뒤 멈춘다.
- Codex CLI: 재시도 5회 상한(`retrying 3/5 in 863ms`), 초과하면 정지하고
  에러를 보여준다.

둘 다 crash 계정도, 원인 분류 면제도, 예산 내구화도 없다. 사람이 터미널 앞에
있기 때문에 "유한 재시도 → 정지 → 보여주기"로 충분하다. 무인 fleet에서 정지가
안전하려면 두 역할만 더 필요하다: 멈춤 상태의 가시성(fleet health), 재개
판단(운영자 또는 상한 있는 타이머).

## 2. 설계

### 2.1 원칙

- **재시도는 한 곳에서만.** 전송 계층 재시도는 이미 하부에 있다(Claude SDK
  기본 2회, Codex 5회). MASC 턴 레벨은 실패한 턴을 즉시 재시도하지 않는다.
  direct provider 레인의 HTTP 재시도 정책은 구현 시 감사하여 이 원칙이
  유지되는지 확인한다(3.4).
- **원인 불문.** streak와 백오프에 실패 원인을 넣지 않는다. 분류가 틀려도
  시스템이 거짓을 보고하는 일이 없어진다.
- **시간은 리셋할 수 없는 상태다.** 백오프의 진행 상태는 streak 값과 마지막
  실패 시각에서 유도한다. 재시작 리셋(#31970)과 "성공 1회 전체 리셋" 구멍이
  원천적으로 사라진다.

### 2.2 동작

1. 턴이 실패하면(원인 불문) streak를 +1 하고, 실패한 자극을 "T 이전 재시도
   금지"로 예약한다. T는 그 자극의 연속 실패 수에 따라 케이던스에서 시작해
   배수로 늘고 상한에서 멈춘다(제안: 케이던스 ×1, ×2, ×4, … 상한 5분 —
   구현 시 확정).
2. streak가 임계치를 넘으면 Keeper는 Failing으로 승격한다. 기존 상태머신
   전이(`Turn_failed { consecutive }`)와 health 반영 그대로 쓴다. 이제
   면제가 없으므로 어떤 실패 클래스도 이 길을 우회하지 못한다.
3. 턴이 성공하거나 운영자가 clear하면 streak와 백오프가 리셋된다.
4. health는 백오프 사실을 그대로 노출한다("N 연속 실패, T까지 재시도 대기").
   무음 루프 대신 정직한 신호가 운영자에게 간다.
5. 블립 보호는 면제가 아니라 구조가 담당한다: 하부의 유한 재시도 + 백오프가
   회복 시간을 주고, 성공이 streak를 지운다.

### 2.3 결정론 경계

- 결정론: streak 카운트, 백오프 스케줄 계산, 임계 승격 판정. 전부 순수
  계산이며 단위 테스트로 증명한다.
- 비결정론(외부): 네트워크/회복 시점. 타이머에 의한 느린 탐침으로만 확인하고,
  예측하지 않는다.

## 3. 걷어내는 것

### 3.1 즉시 (이 RFC 구현에 포함)

- `keeper_failure_exemption_store.ml` / `.mli` 전체.
- `account_failure_counting`의 클래스별 소진 항과 예산 상수
  (`max_consecutive_invalid_request_failures`,
  `empty_completion_exemption_budget`), `persist_exemption_increment`,
  `reset_failure_exemptions` 배관.
- `keeper_error_classify.ml` 617-659 주석 블록 — 코드와 일치하는 새 불변식
  ("면제는 없다")으로 재작성.

### 3.2 순서

구현이 landing된 뒤에 걷는다. 먼저 지우면 InvalidRequest/empty completion
두 클래스의 재시작 리셋 구멍(#31970)이 다시 열린다.

### 3.3 저장 파일 마이그레이션

Hard cut. 예산 store가 쓴 기존 파일의 reader/converter를 만들지 않는다.
streak(#31969)와 백오프 유도에 필요한 마지막 실패 시각만 내구 상태로 남는다.
잔재 파일 정리는 스키마 cut 시 live strip과 함께 진행한다.

### 3.4 감사 항목 (구현 전 확인)

- `is_auto_recoverable_turn_error`의 crash-accounting 외 소비자(runtime
  rotation, capacity backpressure, quarantine, 자극 재예약 경로). 이 RFC는
  crash 계정 면제만 닫는다. 나머지 용도는 각각 유지 여부를 판정한다.
- direct provider 레인의 HTTP 재시도가 유한한지. 무한이거나 없다면 상한을
  명시한다.
- streak 임계치 값. 면제가 사라지면 블립이 곧바로 streak에 오르므로, 기존
  임계치가 짧은 장애(수십 초)에서 오탐 승격을 만들지 않는지 케이던스와 함께
  재확인한다.

## 4. 검증

- #31958 재현: DNS 차단 → 상한 도달까지 유한한 실패 후 Keeper 정지, fleet
  degraded, receipt/log 증가 유한. 59초 44턴 무음 루프가 재현되지 않아야
  한다.
- 블립: 1-2회 실패 후 회복 → streak 리셋, Keeper 계속.
- 재시작: streak 내구 → 백오프 유지, 예산 리셋 악용 불가.
- 상태머신: 면제 경로가 없는 전이 표가 exhaustive match를 지키는지
  (`_ -> false` catch-all 금지, 모든 쌍 명시).

## 5. 폐기하는 방향

- #31960(네트워크 예산 추가) — 닫는다. 예산 확장은 이 RFC가 폐기하는 방향이다.
- #31971의 예산 내구 장치 — 이 RFC landing 후 삭제 대상(3.2).
- #31958은 이 RFC 구현으로 닫는다.
