---
rfc: "turn-failure-visible-stop"
title: "턴 실패를 숨기지 않고 상태로 보여준다 — 실패 면제와 예산 계정을 걷어낸다"
status: Implemented
created: 2026-08-31
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: 턴 실패를 숨기지 않고 상태로 보여준다 (turn-failure-visible-stop)

## 0. 요약

네트워크가 완전히 죽어도 Keeper는 같은 턴을 영원히 재시도하고 fleet health는
`ok`를 보고한다(#31958 실측: 59초에 44턴 실패, 전부 `consecutive=0`,
`operator_action_required=false`). 원인은 "일시적 실패는 crash 계정에서
면제한다"는 설계와, 그 면제를 봉합하는 클래스별 예산 장치다.

이 RFC는 그 방향을 폐기한다. 실패 클래스를 분류해 면제하고 예산으로 봉합하는
대신, 실패한 턴을 즉시 가시화하고 재시도 권한을 각 실행 레인에 남긴다:

**각 실행 레인이 소유한 유한한 시도가 끝나 턴이 실패하면 원인 불문 crash
계정에 센다. 첫 실패부터 상태머신은 Failing이 되고 fleet health에 보이며,
다음 성공(또는 운영자 clear)이 되돌린다.**

면제, 클래스별 예산, 예산의 내구 저장(`keeper_failure_exemption_store`)은
걷어냈다. 구현은 #32109로 main에 들어왔고(`dc75fd8aff`), 프로덕션 체인
회귀 테스트 #32112도 main에 들어왔다(`e2638513a6`). #31958은 종결됐다.

## 1. 문제

### 1.1 변경 전 구조

턴 실패 처리는 세 겹이다.

1. `Keeper_error_classify.is_auto_recoverable_turn_error`가 실패를 분류한다.
2. `Keeper_unified_turn_failure.account_failure_counting`이 crash 계정
   streak에 셀지 정한다. 조건은
   `(not auto_recoverable) || runtime_exhausted || empty_completion 소진 ||
   invalid_request 소진`.
3. streak가 0보다 크면 상태머신에 `Turn_failed`가, 0이면
   `Turn_succeeded`가 전달되고, `turn_healthy=false`인 Keeper는 Failing
   phase가 된다.

"일시적" 클래스(네트워크/타임아웃, 0바이트 completion, InvalidRequest)는 2에서
면제된다. 면제가 무한이면 영구 장애에서 무한 재시도가 되므로, 면제 클래스마다
예산(InvalidRequest 3회, empty completion 5회)을 두고 소진 시 다시 streak에
세게 돌려주며, 예산은 재시작 후에도 유지한다(#31970 → #31971).

### 1.2 실패한 지점

- 네트워크/타임아웃에는 예산 항이 없다. `account_failure_counting`의 어느
  항과도 성립하지 않으므로 영원히 면제다. #31958의 무한 루프가 여기서
  났다. 이슈는 구현과 실측 뒤 종결됐다.
- 면제된 실패는 streak가 0인 채 3번으로 전달돼 **실패한 턴이 상태머신에는
  성공으로 보고된다.** 침묵의 직접 원인이다.
- `keeper_error_classify.ml`의 불변식 주석("면제에는 보상 회계가 따라온다")은
  코드와 어긋난다. 주석만 존재하는 불변식은 컴파일러도 테스트도 지켜주지
  못한다. 실제로 썩은 채 방치됐다.
- 구조적으로도 이 설계는 O(클래스)로 자란다. 면제 클래스가 하나 늘 때마다
  예산 상수, 소진 판정, 증가 지점, 리셋 경로, 저장 스키마 필드가 함께
  늘어난다. #31960(draft)은 네트워크 예산을 세 번째로 추가하는 방향이었고,
  그 15초(예산 3 × 케이던스 5초)를 위해 내구 카운터 전체를 하나 더 복제한다.

### 1.3 실행 레인별 재시도 소유권

- Claude Code: Anthropic SDK가 `maxRetries` 기본 2회, 0.5초 시작 지터 백오프로
  재시도한 뒤 포기하고 사용자에게 에러를 보여준 뒤 멈춘다.
- Codex CLI: 재시도 5회 상한(`retrying 3/5 in 863ms`), 초과하면 정지하고
  에러를 보여준다.

Claude Code와 Codex 레인은 각 공식 클라이언트가 유한 재시도를 소유한다. 반면
MASC direct-provider HTTP 레인은 내부 재시도 루프가 없어 턴당 한 번만 시도한다.
세 레인을 "하부 재시도가 항상 있다"고 묶어 말할 수는 없다. 공통 계약은 각
레인이 정한 유한한 시도 뒤 실패를 턴 경계로 올리고, MASC가 그 실패를 숨기거나
즉시 자체 재시도 루프로 감싸지 않는다는 것이다.

## 2. 설계

### 2.1 원칙

- **재시도 권한은 실행 레인이 소유한다.** Claude Code와 Codex 공식 클라이언트
  레인은 자체 상한을 사용한다. direct-provider 레인은 내부 재시도 없이 한 번
  시도한다. MASC 턴 레벨은 어느 레인도 즉시 재시도 루프로 다시 감싸지 않는다.
- **원인 불문.** streak에 실패 원인을 넣지 않는다. 분류가 틀려도 시스템이
  거짓을 보고하는 일이 없어진다.
- **가시성은 계정에서 유도한다.** 별도 상태가 아니라 streak/`turn_healthy`가
  곧 fleet 표시다.

### 2.2 동작

1. 턴이 실패하면(원인 불문) streak를 +1 하고 `Health.record_failure`를 남긴다.
   상태머신은 `Turn_failed`를 받아 `turn_healthy=false`, Keeper는 Failing
   phase가 된다. 임계치는 없다 — 세어지는 첫 실패가 가시성을 만든다.
2. Keeper는 계속 산다(fiber는 죽지 않는다). 실패한 자극은 기존대로
   urgency-lane 꼬리로 물러나 다른 자극을 막지 않는다. 케이던스가 재시도
   속도의 상한이다.
3. 턴이 성공하면(완료 및 모든 정상 yield 정지 사유) streak가 리셋되고
   Keeper는 Failing에서 회복된다. 운영자 clear도 같다.
4. 블립 보호는 면제가 아니라 레인 구조가 담당한다. 자체 재시도가 있는 레인은
   그 유한 상한 안에서 순간 장애를 흡수하고, direct-provider 레인은 첫 실패를
   즉시 가시화한다. 어느 경우든 다음 성공이 streak를 지운다.

### 2.3 왜 백오프 스케줄링(not-before-T)을 넣지 않는가

초안에는 "실패한 자극을 T시각 이전 재시도 금지로 예약하고 T를 배수로 늘린다"는
조항이 있었다. 구현 검토 중 두 곳의 기존 계약과 충돌함이 확인돼 철회한다.

- `Keeper_runtime_failure_route`는 route가 관측임을 명시하고 "지연을 합성하거나
  강제하지 않는다"고 못 박는다.
- supervisor는 크래시된 keeper 재시작에도 "invented delay 없이" 재시작하며,
  재시작 카운터는 관측일 뿐이라고 명시한다.
- 프로젝트 원칙 또한 과거 evidence를 scheduling gate로 쓰지 않는다.

이 계약들을 뒤집으려면 별도 RFC로 scheduling authority 자체를 다시 설계해야
한다. 이 RFC는 그 싸움 없이도 #31958을 닫을 수 있음을 확인했다: 침묵의
원인은 재시도 속도가 아니라 "면제 → streak 0 → 실패를 성공으로 보고"였다.
케이던스(5초)당 1회의 실패 기록은 유한하고 가시적이다. 재시도 속도를 더
줄이고 싶다면 그때 계약 supersession을 별도로 제안한다.

### 2.4 결정론 경계

- 결정론: streak 카운트, 리셋, 상태머신 전이. 전부 순수 계산이며 단위
  테스트로 증명한다.
- 비결정론(외부): 네트워크/회복 시점. 예측하지 않고, 성공 관측으로만
  회복한다.

## 3. 걷어내는 것

### 3.1 대상 (구현 PR에 포함)

- `keeper_failure_exemption_store.ml` / `.mli` 전체.
- `account_failure_counting`, 예산 상수 2개(`max_consecutive_invalid_request_failures`,
  `empty_completion_exemption_budget`), `persist_exemption_increment`,
  `note_invalid_request_failure`, `empty_completion_exemption_exhausted`,
  `invalid_request_budget_exhausted`, `reset_failure_exemptions` 배관.
- `record_failure_observation`의 `counts_toward_crash` 갈래.
- 성공/운영자 clear 경로의 예산 리셋 호출.
- `keeper_error_classify.ml`의 면제 불변식 주석 블록 — "면제는 없다"로
  재작성.

### 3.2 순서

count-all 전환과 예산 장치 삭제가 **같은 PR에서 동시에** 일어난다. 예산이
보호하던 유일한 것은 면제 클래스였고, 면제가 사라지면 예산은 역할이 없다.
#31970의 재시작 리셋 구멍은 예산이 존재할 때만 의미가 있으므로, 동시 삭제는
구멍을 재개하지 않는다.

### 3.3 저장 파일 마이그레이션

Hard cut. 기존 예산 store 파일의 reader/converter를 만들지 않는다.
잔재 파일은 미해독 상태로 남으며, 대량 정리 시 live strip과 함께 처리한다.
streak(#31969)는 그대로 유지된다.

### 3.4 감사 결과

- streak 임계치: **존재하지 않는다.** 상태머신의 `Turn_failed`는
  `turn_healthy=false`를 무조건 설정하고, `consecutive` 페이로드는 관측일
  뿐이다. 초안의 "임계치 재확인" 항목은 해소됐다.
- `is_auto_recoverable_turn_error`: crash 계정이 유일한 lib 소비자였고 이번에
  사라졌다. 함수는 분류 계약(telemetry, failure route)과 다수 테스트가
  붙어 있어 유지하되, 분류 전용으로 재문서화했다. lib 내 소비자 0인 상태는
  후속 sweep에서 재판단한다.
- direct provider 레인의 HTTP 재시도: **재시도 루프가 존재하지 않는다.**
  `http_client`의 동기 dispatch는 재시도 정책 없는 raw 호출이고
  (`http_client.mli` "No ... retry policy has run"), `retry.mli`는
  분류(is_retryable, retry_after 힌트) 전용이다. 턴당 시도는 1회이고
  케이던스가 상한이다 — #31958 실측의 실패 1회/케이던스와 일치한다.

## 4. 검증

- 단위(통과): invalid_request 분류 3/3, runtime observation boundaries
  10/10(#32112의 #31958 회귀 핀 포함 — 네트워크 실패 → streak →
  `Turn_failed` → phase `failing`을 프로덕션 체인으로 고정), cycle
  attribution 2/2, terminal reason 8/8, context overflow 8/8, supervisor
  48/48, work-as-heartbeat 24/24, `@default` 전체 빌드, ocamlformat
  --check.
- #31958 Linux exact-source 관찰: DNS 차단 부팅 턴에서 실패 4건 모두
  `consecutive=1`, phase `failing`으로 기록됐고 면제 로그는 0건이었다. 반복
  누적과 성공 리셋은 #32112 회귀 테스트가 고정한다. 원시 제약과 exact identity는
  `docs/research/2026-08-31-turn-failure-visible-stop-linux-r1.md`에 남겼다.
- 재시작: 예산 store가 삭제돼 예산 리셋 악용 경로는 없어졌다. 다만 Linux
  관찰에서 persisted streak의 재등록 적용은 확인되지 않았으므로 #31969 복원
  시맨틱은 별도 후속 항목이며, 이 RFC의 구현 완료 주장에 포함하지 않는다.

## 5. 폐기하는 방향

- #31960(네트워크 예산 추가) — 닫았다. 예산 확장은 이 RFC가 폐기하는
  방향이다.
- #31971의 예산 내구 장치 — 이 RFC 구현과 함께 삭제됐다(§3.2).
- #31958은 구현과 Linux measurement 뒤 닫혔다.
