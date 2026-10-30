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
