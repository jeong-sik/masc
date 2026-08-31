# Turn failure visible stop 근거 기록

## 공통 헤더

- 날짜(ISO8601): 2026-08-31T23:59:00+09:00
- 작성자: Claude
- 결정 ID: turn-failure-visible-stop-count-all
- 적용 대상: `Keeper_unified_turn_failure`, `Keeper_error_classify`,
  `keeper_failure_exemption_store`(삭제), `Keeper_unified_turn_success`,
  `Keeper_tool_surface`
- 결정 상태: 확정(main `dc75fd8aff`, #32109). RFC는
  `docs/rfc/RFC-turn-failure-visible-stop.md`(#32105).

## 근거

- 항목: 턴 실패의 crash 계정 면제와 클래스별 예산을 걷어내고, 원인 불문
  streak에 센다.
- 출처: issue #31958(DNS 차단 59초에 44턴 실패, 전부 `consecutive=0`,
  fleet `ok`, `operator_action_required=false` 실측),
  `lib/keeper/keeper_error_classify.ml`의 면제 불변식 주석(코드와 불일치),
  RFC-32105 §1.2의 이중 부패 기록(2026-07-21 parse 루프 923회 포함)
- 확인일시: 2026-08-31T23:59:00+09:00
- 신뢰도: High(메커니즘, 단위 검증 기준) / Medium(fleet 실측 미완)
- 제한조건: macOS/arm64 네이티브 빌드 기준 단위 검증. Linux exact-source
  fleet 관찰은 별도 문서로 남긴다.

## 검증

- 1차: 구조 확인 — 네트워크/타임아웃은 `account_failure_counting`의 어느
  항과도 성립하지 않아 영구히 면제였고, 면제된 실패는 streak 0 때문에
  상태머신에 `Turn_succeeded`로 보고됐다(#31958 침묵의 직접 원인).
- 2차: 임계치 부재 확인 — `Turn_failed`는 무조건 `turn_healthy=false`를
  설정하고 `consecutive` 페이로드는 관측이다. 세어지는 첫 실패가
  가시성을 만든다.
- 3차: 단위 스위트 — invalid_request 분류 3/3, runtime observation
  boundaries 10/10, cycle attribution 2/2, terminal reason 8/8, context
  overflow 8/8, supervisor 48/48, work-as-heartbeat 24/24. `dune build
  @default` 통과, ocamlformat --check 통과.
- 4차: 회귀 핀(#32112) — 네트워크 실패 → streak 1, 2 →
  `Turn_failed{consecutive=2}` → phase `failing`까지 프로덕션 체인을
  테스트로 고정. 수정 전 코드에서는 첫 assertion이 실패한다.
- 5차: 턴 아래 재시도 루프 부재 확인 — `http_client` 동기 dispatch는
  재시도 정책 없는 raw 호출, `retry.mli`는 분류 전용. 턴당 시도 1회,
  케이던스가 상한(#31958 실측의 실패 1회/케이던스와 일치).

## 불확실성

- 미확인 항목: Linux exact-source fleet 관찰(DNS 차단 → 매 실패 streak
  상승 → fleet Failing 표시 → 무음 루프 미재현). #31958 종결 조건.
- 영향: 면제가 사라져 짧은 장애(수 턴) 동안 phase가 `failing`으로
  떨릴 수 있다. 다음 성공 또는 운영자 clear에서 회복되고, 기존 비면제
  클래스가 수년간 같은 모양으로 동작했다.
- 추가 확인 필요: Linux fleet measurement(`-linux-r1.md` 문서로 남긴다).

## 적용범위

- 영향 받는 영역: 턴 실패 관측의 crash 계정, 성공/운영자 clear의 streak
  리셋(리셋 자체는 불변), 실패 분류의 문서화(분류 자체는 유지).
- 제약/배제: 백오프 스케줄링(not-before-T)은 route/supervisor 계약이
  지연 합성을 명시적으로 거부하므로 넣지 않았다(RFC §2.3). 상태머신,
  supervisor 재시작 정책, streak 내구 저장(#31969)은 바꾸지 않는다.
- 롤백 조건: Linux fleet 관찰에서 매 실패가 streak에 오르지 않거나
  fleet 표시가 여전히 `ok`이면 변경을 중단한다.
