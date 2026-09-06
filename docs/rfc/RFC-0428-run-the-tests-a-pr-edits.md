---
rfc: "0428"
title: "PR 이 고친 테스트는 돌려본다"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: []
---

# PR 이 고친 테스트는 돌려본다

## 관찰

**PR 게이트**는 테스트를 실행하지 않는다.

- `pr-check.yml` — `dune build @check` + lint suite
- `ci.yml` (수동 dispatch) — `dune build @check`

**야간 레인은 있다.** `test.yml` 이 매일 02:43 KST 에 전체 스위트를 돌린다. 이 문서의 첫 판은 그걸 빼먹었다 — 바로잡는다.

그런데 실제로 돌아본 적이 거의 없다.

```
schedule 실행 이력 (2026-09-06 기준, 전부)
  2026-09-05  failure    17:43 -> 19:16   93분
  2026-09-04  cancelled  2초
```

**완주한 적이 한 번, 그리고 빨갛다.** 로그가 보여주는 건 단언 실패 목록이 아니라 멈춤이다:

```
alcotest output in flight: heartbeat_integration/direct_keepalive.012.output,
  last written 4764s before the deadline
```

79분 동안 아무것도 안 쓰고 마감에 걸렸다(#33200). 같은 로그에 `Eio clock not initialized` 로 죽은 keeper cycle 과 `test_tui_keyboard_input.py` 의 PTY 타임아웃도 있다.

그리고 `test.yml` 자기 머리말이 적어놨듯, **빨간 schedule 실행은 아무에게도 안 알린다** (#33008).

그래서 "테스트가 안 돈다"는 말은 정확하지 않고, 정확한 말은 이렇다 — **테스트는 하루 한 번 돌다가 멈추고, 멈춘 걸 아무도 안 본다.**

`@check` 는 타입 체크이고 링크를 하지 않는다. `pr-check.yml` 의 주석이 그 이유를 적어놨고, 그 판단 자체는 맞다.

> linking is this repo's slow step, and every breakage class this session produced (unbound values, signature mismatches, an mli-only type, a label that would not resolve) is a compile error @check reports.

문제는 **"every breakage class"** 다. 그 문장이 쓰인 세션이 만든 종류가 전부였을 뿐이다.

## 이번 세션에서 샌 것

2026-09-06 하루, TUI 작업 다섯 건. 적대 리뷰가 잡은 결함을 CI 가 잡았는지로 정리한다.

| 결함 | PR | `@check` | 발견 경로 | PR 이 고친 테스트 파일 |
|---|---|---|---|---|
| 접힌 도구 요약을 두 줄로 갈랐는데, 요약 0번 행을 읽는 테스트 3개가 그대로 남음 | #33449 | pass | 적대 리뷰 (**머지 후**) | `test_tui_keeper_chat_transcript.ml` |
| 새 디코더 테스트의 픽스처에 레인이 하나뿐이라 스냅샷 디코더가 항상 `Error`. 첫 단언부터 거짓, 검사하려던 함수는 0번 실행 | #33458 | pass | 적대 리뷰 (**머지 후**) | `test_tui_decode.ml` |
| floor 를 `0.024` 로 적었는데 실측 최악 쌍이 `0.023960`. `%.4f` 출력이 `0.0240` 이라 반올림된 값을 경계로 씀 | #33473 | pass | 적대 리뷰 | `test_tui_theme_contrast.ml` |
| `Theme.category Slot_6` 이 `Theme.bad ()` 와 바이트 동일. 같은 터미널 행에 파일 마크와 실패 문구가 같은 색으로 그려짐 | #33471 | pass | 적대 리뷰 (**머지 후**) | — (테스트가 없었다) |
| `test_tui_theme_contrast` 스탠자에 `masc_tui_ansi` 누락 → `Unbound module` | #33473 | **fail** | CI | — |

`@check` 가 잡은 건 다섯 중 하나다. 나머지 넷 중 셋은 **PR 이 직접 고친 테스트 파일 안에서** 깨졌다.

## 대시보드는 같은 구멍인데 더 크다

위 표는 OCaml `test/` 얘기다. 같은 날 `dashboard/` 를 재보니 구멍이 하나 더 있었고, 이쪽이 더 크다.

`.github/workflows/ci.yml` 에는 **`tsc --noEmit` 도 `vitest run` 도 없다.** 대시보드는 빌드만 된다(`scripts/build-dashboard-if-needed.sh`).

```
dashboard/ 테스트 파일    697
        테스트            9445
전부 안 돌고 있다
```

빌드가 타입을 안 보느냐 하면 그것도 아니다 — 번들러는 타입을 지운다.

### 실제로 샌 것

2026-09-06, `#33547` 작업 중 `tsc` 기준선을 재다가 main 에서 타입 오류 2건을 찾았다. `#33454` 가 넣은 것이고, 하루를 앉아 있었다.

```
dashboard-misc.test.ts(334,7): error TS2352
dashboard-misc.test.ts(342,7): error TS2352
```

`#33548` 로 고쳤다. **아무도 못 본 이유는 보는 것이 없기 때문이다.**

### OCaml 쪽보다 결정이 쉽다

`test/` 는 스탠자 344개를 어떻게 고를지가 문제였다. 대시보드는 그 문제가 없다 — 명령 하나다. 남는 건 비용뿐이고, 쟀다.

| | 시간 | 결과 |
|---|---|---|
| `tsc --noEmit` | **8.7초** | main 에 하루 앉아 있던 그 2건을 잡는다 |
| `vitest run` (단일 워커, 저장소의 `test` 스크립트) | 481초 | 697 파일 9445개 전부 통과 |
| `vitest run` (기본 병렬) | 95.7초 | **1개 실패** |

`tsc` 8.7초는 논의할 값이 아니다. 지금 붙인다.

`vitest` 는 병렬이 5배 빠르지만 그냥 켤 수 없다. 병렬에서 깨진 건
`connector-action-error.test.ts` 의 `Escape dismiss closes WITHOUT copying` 하나이고,
5초 제한에 5023ms 로 걸렸다 — 단언이 틀린 게 아니라 부하에 굶었다. 같은 테스트가
단일 워커에서는 통과한다. `package.json` 이 `--no-file-parallelism --maxWorkers=1` 을
박아둔 이유가 이것으로 보인다.

그래서 선택지는 둘이다. 481초를 그대로 받거나, 시간에 민감한 테스트를 고쳐서
95초를 쓰거나. 8.7초짜리 `tsc` 는 어느 쪽이든 먼저 붙인다.

## 제안

**PR diff 에 `test/test_*.ml` 이 있으면, 그 실행 파일만 링크해서 돌린다.**

344개 스탠자를 전부 링크하지 않는다 — 그게 지금 설계가 피하는 비용이고, 그 판단은 유지한다. 위 표에서 이 규칙이 잡는 건 **2/3** 이다 — `test_tui_decode` 는 아래 실측대로
스탠자 deps 때문에 돌릴 수 없다 (테스트가 아예 없던 한 건은 애초에 규칙 밖).

```
git diff --name-only origin/$BASE...HEAD -- 'test/test_*.ml'
  → 각 파일에 대해  dune build test/<name>.exe && ./_build/default/test/<name>.exe
```

`@check` 가 이미 도는 job 안에 붙으면 빌드 캐시를 그대로 쓴다.

### 왜 이 규칙인가

테스트를 **고치는 사람**이 그 테스트를 **깨뜨린 사람**이다. 위 세 건이 전부 그 모양이다 — 동작을 바꾸고 기대값을 따라 고쳤는데, 같은 파일의 다른 단언이 남거나 픽스처가 계약을 못 맞췄다. 손댄 파일을 한 번 돌려보는 것이 가장 싼 지점이다.

### 실제로 몇 개를 돌릴 수 있나 (2026-09-06 실측)

바이너리를 직접 실행하는 것은 dune 이 스위트를 돌리는 것과 다르다. 스탠자가
`(deps ...)` 를 달면 그건 runtest 액션의 것이고, `(action (setenv ...))` 는 dune 만
적용하며, `enabled_if` 로 꺼진 스탠자는 실행 파일이 아예 없다. 그래서 이 규칙은
**선언 스탠자가 dune 을 요구하지 않는 스위트에만** 적용된다.

저장소의 모든 테스트 소스에 그 판정을 돌린 결과:

```
패턴에 맞는 테스트 소스   1398
  돌릴 수 있음            1001   71%
  deps                     209   14%
  custom action            179   12%
  실행 파일 아님              8    0%
  조건부 비활성                1    0%
```

못 도는 14% 중 **149개가 스탠자 하나** 때문이다 — 149개 이름을 묶은 그룹이
`(deps ../bin/main_eio.exe)` 를 달고 있다. 채우려면 메인 바이너리를 링크해야 하고
그게 이 설계가 피하는 비용이므로, 지금은 skip 이고 로그에 이름이 남는다.

`test_tui_decode` 가 그 그룹에 있다. 위 표의 세 결함 중 하나가 이 규칙으로는
안 잡힌다는 뜻이다. 규칙을 넓히려면 그 그룹을 쪼개거나 dune 이 per-suite
runtest 를 지원해야 한다.

### 이 규칙이 못 잡는 것

- **`bin/` 만 고치고 안 건드린 스위트를 깨뜨리는 PR.** 규칙 밖이다.
- **테스트가 없는 결함** (#33471 의 슬롯 충돌). 실행 문제가 아니라 부재 문제다.

2단계로 넓힐 수 있다: 바뀐 파일이 속한 라이브러리를 `(libraries ...)` 에 나열한 스탠자를 함께 돌린다. `test/stanzas/*.inc` 에서 계산 가능하다. 비용은 안 쟀으므로 이 RFC 는 제안하지 않는다.

## 착수 순서

1. **보고만.** step 을 `continue-on-error` 로 붙이고 결과를 로그로 남긴다. 게이트 아님.
2. **본선 측정.** main 에서 344개 스위트 중 지금 빨간 게 몇 개인지 센다. 이 숫자를 모르는 채로 게이트를 켜면 무관한 PR 이 막힌다.

   **지금 이 숫자를 야간 레인으로는 못 얻는다.** 완주한 한 번이 멈춤으로 끝나서 개수까지 못 갔다. 먼저 #33200 의 멈추는 스위트를 떼거나, `test.yml` 이 이미 받는 `suite` 입력으로 스위트별 타임아웃을 걸고 나눠 돌려야 한다.
3. **게이트.** 빨간 스위트를 닫거나 명시적으로 waiver 를 적은 뒤 required 로 올린다.

1 과 2 사이에 시간이 필요하다. 1 만으로도 이번 세션의 세 건은 PR 페이지에서 보였다.

대시보드는 이 순서를 따를 필요가 없다. `tsc --noEmit` 은 지금 초록이고(`#33548` 이후) 8.7초다 — 바로 required 로 올린다. `vitest` 는 비용을 잰 뒤 정한다.

## 하지 않는 것

- 전체 스위트를 PR 마다 돌리지 않는다. 링크 비용이 이 설계가 피하려던 것이고, 그 판단은 여전히 옳다.
- `@check` 를 대체하지 않는다. 타입 오류는 여전히 거기서 잡는 게 빠르다.
- 빨간 스위트를 세기 전에 게이트를 켜지 않는다.

## 판정 기준

1. 1단계 붙인 뒤, 위 표의 세 결함을 각각 재현한 브랜치에서 step 이 빨갛게 나오는가.
2. `@check` 가 이미 도는 job 에서 추가 시간이 얼마인가. 스위트 하나 링크 + 실행 기준으로 잰다.
3. 2단계 측정 결과 main 의 빨간 스위트가 0 이면 바로 게이트, 아니면 목록을 RFC 로 흡수한다.
4. `tsc --noEmit` 을 붙인 뒤, `#33454` 의 커밋을 되돌린 브랜치에서 빨갛게 나오는가.
5. `vitest` 병렬 실행 시간이 `@check` job 시간 안에 들어가는가. 아니면 별도 job 으로 뗀다.
