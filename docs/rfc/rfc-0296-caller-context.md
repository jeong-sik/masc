# RFC-0296 Caller Context

Owner request, 2026-06-28 (Vincent, /goal 4-PR review sweep 중 main 만성 red 발견):

- 4개 PR(#22386/#22388/#22329/#22363) 마지막 adv 코멘트 P0/P1/P2 대응 중, #22386/#22388
  CI Build and Test fail이 base와 동일 32종(inherited)으로 드러남.
- first-red bisect 시도 → skip 게이트(`changes.outputs.build` + `run_heavy`)가 회귀 PR의
  CI 결과를 기록하지 않아 구조적으로 식별 불가(만성 red)로 판명.
- AskUserQuestion "어느 방향으로" → **게이트 수리(근본)** 선택.

수렴한 경계 결정:

- 본 RFC는 skip 게이트 회로의 4th hole(RFC-0270 Hole 2와는 라인·메커니즘이 상이).
- Step 1(이 PR): `ci.yml:557` Build `if`에 `live_state == 'NON_PR'` OR 추가(dashboard
  `ci.yml:1004` "main-push safety-net" 선례 그대로). PR event는 build-scope 게이트 유지(비용 절약 보존).
- Step 2(후속): ci-gate `check()`(`ci.yml:1176`) skipped→PASS 회로 근본 수정. Step 1 후 main green일 때.
- Step 3(후속, defense-in-depth): `main-nightly-health.yml`에 quick suite 추가.

Design constraints:

- main push는 `changes.outputs.build` 무관·`run_heavy` 무관하게 항상 Build and Test 실행.
  workflow `on:` push가 main/develop만 트리거 → tag push 자동 제외.
- `live_state == 'NON_PR'`는 pr-live-gate(`ci.yml:78-86`)가 non-PR event에만 세트. dashboard
  job이 이미 같은 조건 사용 → 검증된 선례.
- `ci_core`(`ci.yml:232`, `:310-324`)가 ci.yml 변경 PR에서 `build=true` 강제 → 자기참조 hole 없음.
- 워크어라운드 거부 기준: Step 1은 path 게이트를 main-push surface에서 제거(string 분류기
  보강이 아님) → 시그니처 2/3 해당 없음.

Verification expectation:

- 로컬 rfc-enforcer(R1–R5, 이 caller-context 포함) 통과.
- 게이트 PR 자체: ci_core로 `build=true` → Build and Test 실행으로 `if` 변경 검증.
- merge 후 dashboard-only/docs-only merge의 main push run에서 Build and Test가 `skipped`가
  아닌 실행 상태로 확인.
- main green 전까지 Step 1이 dashboard merge를 red로 폭로(의도된 동작).
