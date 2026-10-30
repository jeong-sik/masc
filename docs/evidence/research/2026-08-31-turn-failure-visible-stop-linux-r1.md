# Turn failure visible stop Linux R1

## 결과

RFC turn-failure-visible-stop(#32105, 구현 #32109)의 fleet 관찰. #31958의 조건 —
provider endpoint가 단절된 상태에서 keeper 턴 실패 — 를 Linux/arm64 컨테이너에서
재현하고, 수정된 binary에서 모든 실패가 crash streak에 오르고 keeper가 `failing`
phase로 보이는지를 확인했다.

## exact identity

- product head: `dc75fd8aff594c9d9e3ad1b0e1b0d9d468dd8b3f`(main, #32109 squash)
- image: `masc-oneclick:turn-failure-verify-dc75fd8`
  `sha256:8f6885ff3664b792f347563f5ecc62fd75863f19c661b561cc433f3347227c69`
- binary(`/app/masc`) SHA-256:
  `e931af78469480e0031088f667b4d4950f64500ce567a14bcac93473c24aec02`
- 부팅: `OLLAMA_CLOUD_API_KEY=dummy-key-for-measurement`로 classic 4 keeper
  (backend/frontend/qa/tech_lead) autoboot
- 관찰 시각: 2026-08-31T14:49–15:01 UTC

## 절차

1. oneclick 이미지 부팅. 첫 턴 4개는 endpoint가 `https://ollama.com/v1`인 상태에서
   더미 key로 `Auth error: Unauthorized` 실패.
2. `runtime.toml`의 endpoint를 `https://turn-failure-measurement.invalid/v1`
   (보증 NXDOMAIN)로 교체(hot-reload) 뒤 컨테이너 재시작으로 부팅 턴을 다시
   유발했다. DNS 실패 클래스가 #31958 실측과 같은지는 로그 문구로 확인했다.
3. 로그·streak 저장 파일·registry lifecycle 전이를 수집했다.

## 관찰

- DNS 실패 로그:
  `Network error (dns_failure): failed to resolve hostname: turn-failure-measurement.invalid`
  — 지연 19–29ms, `(transient, cooldown preserved)` 표기와 함께.
- 모든 실패 관측에 `turn failure observed (consecutive=1)`가 붙었고 4개 keeper
  모두 `registry: lifecycle ... phase=failing event=failing detail=turn_failed(1)`
  전이가 기록됐다. 세어지지 않는 실패는 없었다.
- **`not counted toward crash threshold` 라인은 전체 로그에서 0건.** 수정 전에는
  DNS 클래스 실패마다 이 라인이 나오고 streak가 0에 고정됐다(#31958: 59초 44턴
  전부 `consecutive=0`, fleet `ok`).
- streak 저장 파일 4개가 `/app/.masc/keepers/<name>/turn-failure-streak.json`에
  생성됐다.

## 제약

- oneclick classic 프리셋의 `sandbox_profile = "local"`이 #32078 이후 무효라
  keeper가 자동 부팅하지 않았다(#32115). 측정을 위해 컨테이너 안에서
  `sandbox_profile = "docker"`로 바꿨다. 턴은 sandbox 없이도 도므로 이 측정의
  유효성에는 영향이 없다.
- keeper 턴은 자극이 있을 때만 발생한다. 부팅 자극 1회를 소진한 뒤 큐가 비어
  연속 실패가 쌓이는 모습은 이 관찰에 없다. consecutive 2 이상의 누적과 성공
  리셋은 회귀 테스트(#32112)가 프로덕션 체인으로 증명한다.
- 컨테이너 재시작 후 streak가 이어지지 않았다(재시작 전 파일 `count=1`, 재시작
  후 첫 실패 `consecutive=1`). 복원 경로는
  `keeper_registry_setup.ml:470`(등록 시 persisted streak 적용)에 있으나 이
  관찰에서는 첫 실패 이전에 적용되지 않았다. fiber 재시작이 수명 초기화인
  설계(`Fiber_started` 주석)와 충돌하는지는 이 문서에서 판정하지 않는다 —
  #31969 복원 시맨틱의 후속 확인 항목으로 남긴다.

## 판정

#31958의 종결 조건 — DNS 단절에서 매 실패가 streak에 오르고, keeper가
`failing`으로 보이며, `consecutive=0` 무음 루프가 재현되지 않음 — 을 충족한다.
