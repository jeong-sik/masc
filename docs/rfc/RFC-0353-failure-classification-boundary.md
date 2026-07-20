# RFC-0353 — 실패 분류가 모듈 경계에서 소실되는 결함 (결정 요청)

**Status**: Draft — 결정 요청
**연관**: #25489 (수집 이슈), #25482, #25488, #25443, #24838, oas#2736, #25052
**제약**: RFC-0000 §1.2 LAW 1 (No dead-end) · LAW 2 (연속 횟수는 결정 권한 없음) · §9 Anti-patterns

---

## 1. 사실 (2026-07-20~21 라이브 로그 실측, 시간대별 검증)

생산자는 실패를 typed 로 정확히 표현하는데, 소비자가 그 구분을 잃는다. 소실 방식이 두 가지이고 결과도 두 가지다.

### 1.1 형태 A — 재시도 가능성이 소실 → 성공 불가능한 재시도

| # | 경계 | 결정론적 실패 | 소비자 동작 | 실측 |
|---|---|---|---|---|
| #25482 | `keeper_checkpoint_store` → lane | `Ref_identity_invalid Generation_missing` | 오버플로 실패와 동일 취급, 재시도 | 3일간 ERROR 1,354건. keeper 2기 wedge |
| #25488 | `keeper_approval_queue` → `keeper_heartbeat_loop:322` | grant 5종 중 결정론 3종 | `\| Error error ->` catch-all → requeue | 45분 86건. 재부팅 5회 관통 |
| #25443 | compaction plan | 동일 `(trace_id, generation, sha256)` 무변화 | ~50초 주기 재시도, 매회 유료 LLM 호출 | sangsu 시간당 59 거부 + 62 cycle 실패 |
| #24838 | provider 4xx | gateway opaque 400 | `InvalidRequest` → 비재시도 **이자 비회전** | analyst 41/41 동일 런타임, rotation 0건 |
| (해소됨) | scheduler dispatch | `unsupported snapshot schema` | 에러 문자열이 자칭 `retryable` | 07-17 하루 98회 |

**공통점**: 재시도 가능성이 타입이 아니라 (a) catch-all, (b) 문자열 관례(`"retryable …"`), (c) 다른 축과의 결합(`InvalidRequest` 하나가 재시도와 회전을 동시에 차단)으로 결정된다.

### 1.2 형태 B — 실패 사유가 소실 → 진단 불가, 이어서 로그 강등으로 은폐

| # | 위치 | 소실 방식 | 실측 |
|---|---|---|---|
| oas#2736 | `reasoning_history_projection` | 인과가 다른 두 모집단이 단일 집계 | `No_replay` 217k + replay-all 112k/일이 한 필드에 합산. 이후 #2721 로 Warn→Info |
| #25052 | `keeper_memory_lane:242` | drop 시 unit 미식별 + `let (_ : outcome) =` | 343건/일. analyst 24.2% |
| #24838 | `http_client_4xx_request_header_profile` | 배제된 가설만 측정 | `max_single_header=81` vs `limit=8192`. body 크기는 ollama 경로에서 미기록(glm 81건 / ollama 0건) |

**공통점**: 신호가 사유별로 분해되지 않은 채 방출되고, 분해 불가능한 상태에서 레벨이 강등된다.

### 1.3 이 목록이 어떻게 만들어졌는가

`~/me/.masc` ERROR/WARN 을 36회 반복 스윕하며 수집했다. 각 항목은 시간대별 버킷팅으로 라이브 여부를 확인했고, 같은 방식으로 **이미 해소된 2건은 목록에서 제외**했다(oas#2734, #25487 — 각각 03Z·08Z 경계로 소멸, 이슈 종료). 코드 주장은 `.mli`/모듈 doc 대조로 검증했다.

---

## 2. 왜 지금 결정이 필요한가

1. **서로 다른 6개 서브시스템에서 반복된다.** 개별 수정은 N-of-M(§9 시그니처 3번)이 된다.
2. **타입 시스템이 막지 못한다.** 여섯 건 모두 컴파일되는 형태다 — catch-all `| Error _ ->`, nullary variant, match 순서 의존, `let (_ : t) =`. 한 사이트를 고쳐도 다음 사이트가 같은 코드를 다시 쓴다.
3. **AI 에이전트가 선례로 학습한다.** CLAUDE.md 가 명시한 누적 메커니즘이며, 현재 코드베이스 통계상 "실패를 catch-all 로 requeue" 는 합리적 패턴으로 보인다.
4. **비용이 직접 발생한다.** 형태 A 는 성공 확률 0 인 provider 호출을 소비한다.
5. **은폐 수단이 관습화되어 있다.** oas#2721 은 분해 불가능한 신호를 통째로 Info 로 낮췄다. 형태 B 는 고치지 않으면 *보이지 않게* 된다.

---

## 3. LAW 제약 — 초기 제안이 헌법과 충돌했다

#25489 최초 제안은 결정론적 실패를 **typed terminal** 로 분류하고 keeper 를 `needs_operator_repair` 로 전이시키는 것이었다. **LAW 1 위반이다**:

> budget·cost·turn·no-progress·approval·**provider-failure 는 Keeper 전체를 terminal 상태로 만들지 않는다.** enabled Keeper 는 항상 Active·Awaiting·Recovering·(서명된 operator 명령에 의한) Stopped 중 하나. **No dead-end.**

또한 "N회 연속 실패 시 dead-letter" 는 LAW 2("연속 횟수는 결정 권한이 없다") 위반이다.

원안대로면 garnet·sangsu·analyst 가 죽고, LAW 1 이 막으려는 결과(운영자가 모르는 사이 fleet 이 조용히 줄어듦)가 그대로 발생한다.

**따라서 본 RFC 의 방향은 "재시도 중단"이되 "terminal 아님"이다.** 필요한 것은 재시도 루프에서 이탈하되 lifecycle 은 `Awaiting`/`Recovering` 으로 유지하는 typed 상태다.

역으로, #25491 의 `Reconciliation_required` 흡수 상태(출구가 worker·recovery·operator 모두에게 없음)는 **LAW 1 위반 그 자체**다.

---

## 4. 선택지

### Path A — 타입 레벨 강제 (경계 계약을 타입으로)

- **작업**: 실패 타입에 두 축을 필수화한다 — (1) 재시도 가능성, (2) 사유 payload. nullary 실패 variant 금지. 경계 통과 시 재시도 가능성을 뒤집는 변환을 타입으로 차단하거나 명시적 근거를 요구. 재시도/회전 자격을 분리(현재 `InvalidRequest` 하나가 둘을 동시에 차단).
- **장점**: 재발이 구조적으로 막힌다. 새 실패 경로가 컴파일 시점에 결정을 강제받는다.
- **단점/리스크**: 실패 타입이 공개 경계(oas ↔ masc)에 걸쳐 있어 변경 범위가 크다. oas 는 별도 repo 이므로 pin 조율 필요. RFC-OAS-035 가 "source compatibility 를 위해 `ProviderUnavailable` 로 투영" 을 명시했으므로 그 결정의 재검토가 선행된다.

### Path B — 소비 지점 규율 (lint + 명시 match)

- **작업**: 실패 소비 지점의 catch-all `| Error _ ->` 를 CI 로 금지(§9 FSM 특칙의 확장). 각 소비자가 variant 를 명시 match 하고 재시도/비재시도를 선언. 로그 레벨 강등 시 사유별 분해를 전제 조건으로 요구.
- **장점**: 착수 비용이 낮고 repo 경계를 넘지 않는다. 기존 위반을 점진 해소 가능.
- **단점/리스크**: 규율이지 불변식이 아니다 — 새 코드가 variant 를 명시하되 잘못 분류할 수 있다. lint 도입 전 기존 위반 규모를 모른다(선행 조사 필요, §5).

### Path C — 두 형태를 분리해 순차 처리

- 형태 B(관측)를 먼저: 사유 분해 + payload 필수화. 형태 A(재시도)는 그 관측 위에서 판단.
- **장점**: 형태 A 의 올바른 처리(어떤 실패를 어떤 상태로 보낼지)를 정하려면 현재 분포를 알아야 하는데, 지금은 분해되지 않아 모른다. 예: #24838 의 400 이 gateway 기원인지 요청 의미론인지 판별할 데이터가 없다.
- **단점/리스크**: 형태 A 의 비용(성공 불가능한 유료 재시도)이 그동안 계속된다.

---

## 5. 결정 요청

1. **Path A / B / C 중 어느 것인가.** (제안: C → A. 관측을 먼저 세우고 타입 강제로 수렴. B 의 lint 는 A 착지 전 회귀 방지로 병행 가능.)
2. **oas 경계 처리.** RFC-OAS-035 의 `ProviderUnavailable` 투영 결정을 재검토 대상으로 열 것인가, masc 쪽에서만 흡수할 것인가.
3. **재시도 이탈 시의 목적지 상태.** LAW 1 이 허용하는 `Awaiting` / `Recovering` 중 어느 쪽인가, 아니면 새 typed 상태가 필요한가.
4. **선행 조사 승인.** 현재 코드베이스의 실패 소비 지점 catch-all 규모 전수 조사(§4 Path B 의 미지수). 규모를 모른 채 lint 를 세우면 대량 위반으로 CI 가 막힌다.

---

## 6. 비목표

- 개별 이슈(#25482, #25443, #24838 …)의 즉시 수정. 본 RFC 는 그 수정들이 **어떤 형태여야 하는가**를 정한다.
- 로그 볼륨 감소 자체. 감소는 결과이지 목표가 아니다 — §9 "Log Dedup/Demote" 는 목표로 삼는 순간 안티패턴이 된다.
- `Reconciliation_required` 흡수 상태의 해소(#25491). LAW 1 위반으로 별건 우선 처리 대상이다.
