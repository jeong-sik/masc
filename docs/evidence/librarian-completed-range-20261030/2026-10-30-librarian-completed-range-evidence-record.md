# 완료 대화 범위와 Keeper별 Librarian 연속성

## 공통 헤더

- 날짜(ISO8601): `2026-10-30T16:04:32+09:00`
- 작성자: `Codex`
- 결정 ID: `librarian-completed-range-20261030`
- 적용 대상: `keeper_librarian_continuity`, `keeper_librarian_queue_refresh`, 공식 실패 턴 종료
- 결정 상태: `추적 필요`
- Delta: 신호 합치기와 모델 판단 단위를 구분하고, 기존 Keeper별 레인에서 고정된 완료 범위를 묶어 읽도록 했다. 기존 atom 폭 재사용은 실제 완료 턴·거절된 원본 메시지 단위로 대체했다.

## 근거 (Evidence)

- 항목: 기존 레인·출력 형식을 유지한 범위 선택과 종료 wake 변경.
- 출처: 이 변경의 직접 부모 `d3b79a960fcffdf562a1084609206e85bdad7e93`(retained 원본 판단 복구, PR #46911). `lib/keeper/keeper_librarian_continuity.{ml,mli}`, `keeper_librarian_queue_refresh.{ml,mli}`, `keeper_agent_run_finalize_response.ml`, `keeper_agent_run_post_turn_memory.{ml,mli}` 및 [lifecycle §4.12](../../rfc/RFC-librarian-lifecycle.md#412-완료된-범위를-묶어-이어-쓰기-2026-10-30-개정).
- 확인일시: `2026-10-30T16:04:32+09:00`
- 신뢰도: `High` (소스 경로·타입·명시적 계약), `Medium` (실행 전 행동 예상)
- 제한조건: 아래 검증은 커밋 전 소스·문법 검토다. 타깃 CI의 head·run·conclusion은 PR의 실행 기록으로 별도 결속한다. 이 문서가 CI 성공이나 배포를 증명하지 않는다.

## 검증 (Verification)

- 1차: producer → 저장소 → source 선택 → 판단 → Memory/W 커밋 → foreground 소비를 대조했다. Keeper별 서버 소유 레인, admission/durable/continuity/queue/cleanup 순서, foreground 비대기를 유지했다.
- 2차: 별도 source-review와 review-response 세션이 현재 diff를 읽었다. Memory 반영 범위 중복과 캐시된 fitting prefix의 반복 거절 반례를 수정하고, Context-only 출력 계약·fixture 타입·메시지 범위 측정 오류를 바로잡았다. 이는 GitHub 독립 승인이나 교차 모델 검증이 아니다.
- 3차: 변경한 OCaml 9개 파일에 `ocamlc -stop-after parsing -c`를 실행했고 `git diff --check`를 통과했다. 로컬 Dune 빌드·타입 검사·동작 테스트는 실행하지 않았다. 별도의 타깃 Test 요청 대상은 `test_keeper_librarian_continuity`, `test_keeper_memory_lane`, `test_keeper_librarian_durable_consumer`, `test_keeper_librarian_capacity_callback`이다.
- 재현 결과: 실행 검증 전이다. 추가·수정한 회귀 사례는 다음과 같다.

| 경계 | 검사 내용 |
| --- | --- |
| 완료 범위 | 여러 완료 턴을 기본 선택하고 미완료 꼬리는 제외 |
| Memory `[B,F)` | 미반영 baseline 앞부분, Context-only 구간, 미반영 suffix 분리 |
| 서로 다른 턴 크기 | 배치 거절 뒤 실제 첫 턴, 다음 턴의 실제 크기, 해당 원본 메시지 floor |
| 캐시된 CLI 한도 | 두 메시지의 정확한 prompt/schema 크기로 한도를 만들고, 거절된 fitted prefix가 다음 신호에서 floor에 도달 |
| 고정 E | 원본 receipt 복구 중 새 완료 턴이 생겨도 이번 작업은 최초 E에서 종료 |
| 공정성 | 대기 작업이 있으면 현재 커밋 뒤 양보 |
| 공식 실패 종료 | durable append 뒤 enabled wake, disabled 무신호, append 실패 무신호 |
| 기존 회귀 | 원본 receipt 우선, 역사적 Task 구간, 늦은 원문 변경의 게시 거절, invalid/unknown/effect veto, 메시지 바닥의 원자적 게시 |

## 불확실성 (Uncertainty)

- 미확인 항목: 타입 검사·실행 결과, 실제 모델의 여러 턴 의미 보존, 비용·지연·거절률, 설치 바이너리와 소스 일치.
- 영향: 커버리지는 의미 보존을 증명하지 않는다. 큰 배치의 호출 시간이 길어질 수 있으며, 레인이 매 턴 사이에 비면 매번 호출할 수 있다. 신호 없는 일반 실패의 자동 회복 시점은 보장하지 않는다.
- 추가 확인 필요: 타깃 CI 결과와 현재 head 결속, 실제 Keeper의 사용자 제약·정정·미완료 일 이어가기 평가. 테스트·배포 결과는 해당 실행 증거로만 주장한다.

## 적용범위 (Scope)

- 영향 받는 영역: 완료 대화의 continuity 범위, 실패 후 일시적 source 모드, 공식 실패 종료의 기존 wake 연결. 스펙은 lifecycle §4.12와 RFC-0467의 후속 개정 표기로 연결했다. 공식 wake 누락은 [#46920](https://github.com/jeong-sik/masc/issues/46920)에서 추적한다.
- 제약/배제: 새 중요도 분류기·임의 주기/임계치·추가 Librarian 레인·설정·출력 스키마·내구 정본을 만들지 않았다. 공식 native 세션을 Agent Core로 변환하지 않았다. 실제 Apple 서비스·guest·volume·Keeper 조작과 배포를 하지 않았다. 공식 fragment의 W 지원과 매우 긴 미완료 턴은 이 변경이 해결하지 않는 기존 한계다.
- 롤백 조건: Memory 중복 판단·거짓 커버리지·원본 효과 불명 재실행·앞 원문 변경의 게시 허용이 확인되면 적용을 중단하고 해당 범위 선택 변경을 되돌린다. 운영 적용 전 상태다.

## 추가 관측 — 첫 실행과 추정 정책 보완

- 출처: [Test 41018214853](https://github.com/jeong-sik/masc/actions/runs/41018214853), head `3a1eb45b473de02490072a0fa7385841fed0aa55`, ref `feat/librarian-completed-range-20261030`, conclusion `failure`.
- 확인일시: `2026-10-30T16:42:16+09:00`.
- 신뢰도: `High` (CI 실제 빌드·fixture 실행), 실제 모델 의미 보존은 미확인.
- TARGET_SUITES: `test_keeper_librarian_continuity,test_keeper_memory_lane,test_keeper_librarian_durable_consumer,test_keeper_librarian_capacity_callback`.
- 실제 네 실행 파일이 빌드됐고, 238개 검사 중 236개가 통과했다. 새 완료 범위·Memory 분할·고정 E·캐시 복구·공식 wake 사례도 통과했다. 실패는 torn W rebuild가 첫 턴 끝 1을 기대했으나 완료 범위 끝 2를 얻은 경우와, 별도 두 커밋을 검증하는 기존 durable fixture가 기본 선택을 한 턴으로 가정한 경우다.
- 수정은 rebuild 전체 두 턴·catch-up 해제·quiet 무호출을 검증하고, 두 커밋 fixture에는 명시적 oldest 선택을 쓰는 것이다. 별도로 batched Memory receipt가 W 저장 전에 내구 소비자의 중복 판단을 막는 경우도 추가했다.
- 기존 공통 historical 분류는 timeout·일반 Invalid_request도 축소 후보로 보았다. 이번 Queue continuity는 실제 named input-capacity 증거를 추가로 요구하며, 본문 미수신만으로 축소하지 않는다. 공통 historical 분류표 전체를 제거한 것으로 주장하지 않는다.
- 다른 slot의 크기 거절 뒤 unsafe·opaque native 실패가 와도 private host 관측 `unsettled_native_execution`을 보존하고 `Unsettled_native_blocks_descent`로 작은 새 원본을 막는다. retained 관측 decode도 typed cause/flags에서 이를 다시 도출한다. worker가 안전 boolean을 공급하지 않는다.
- 실제 CLI 한도의 fitting에는 기존 atom 이분 탐색이 남아 있다. 실제 렌더링 크기 predicate로 후보를 검사하는 탐색이며, 중요도·주기·임의 입력 상한이 아니다. 자연어 substring으로 작업 의미나 크기 거절을 추측하는 분기를 추가하지 않았다.
- 보완 후 재검증 대상은 기존 네 suite와 `test_keeper_librarian_cli_lane`, `test_keeper_librarian_floor_chain`이다. 현재 보완분은 parse-only 18개 파일·diff/changelog 검사를 통과했으며, 새 head의 실행 결과는 PR에 별도로 결속한다. 첫 실행의 성공한 검사도 새 head의 실행 성공으로 이월하지 않는다.
- 이 실행은 임시 workspace·fixture HTTP/native 응답으로 실제 프로그램·저장소·훅을 실행한 증거다. 운영 Keeper·실제 모델의 N+M 의미 보존·호출 비용 개선·배포 증거는 아니다.
