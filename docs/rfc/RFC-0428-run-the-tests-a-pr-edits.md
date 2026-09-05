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

이 저장소의 CI 는 두 레인 다 테스트를 실행하지 않는다.

- `pr-check.yml` — `dune build @check` + lint suite
- `ci.yml` (수동 dispatch) — `dune build @check`

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

## 제안

**PR diff 에 `test/test_*.ml` 이 있으면, 그 실행 파일만 링크해서 돌린다.**

344개 스탠자를 전부 링크하지 않는다 — 그게 지금 설계가 피하는 비용이고, 그 판단은 유지한다. 위 표에서 이 규칙이 잡는 건 **3/3** 이다 (테스트가 아예 없던 한 건 제외).

```
git diff --name-only origin/$BASE...HEAD -- 'test/test_*.ml'
  → 각 파일에 대해  dune build test/<name>.exe && ./_build/default/test/<name>.exe
```

`@check` 가 이미 도는 job 안에 붙으면 빌드 캐시를 그대로 쓴다.

### 왜 이 규칙인가

테스트를 **고치는 사람**이 그 테스트를 **깨뜨린 사람**이다. 위 세 건이 전부 그 모양이다 — 동작을 바꾸고 기대값을 따라 고쳤는데, 같은 파일의 다른 단언이 남거나 픽스처가 계약을 못 맞췄다. 손댄 파일을 한 번 돌려보는 것이 가장 싼 지점이다.

### 이 규칙이 못 잡는 것

- **`bin/` 만 고치고 안 건드린 스위트를 깨뜨리는 PR.** 규칙 밖이다.
- **테스트가 없는 결함** (#33471 의 슬롯 충돌). 실행 문제가 아니라 부재 문제다.

2단계로 넓힐 수 있다: 바뀐 파일이 속한 라이브러리를 `(libraries ...)` 에 나열한 스탠자를 함께 돌린다. `test/stanzas/*.inc` 에서 계산 가능하다. 비용은 안 쟀으므로 이 RFC 는 제안하지 않는다.

## 착수 순서

1. **보고만.** step 을 `continue-on-error` 로 붙이고 결과를 로그로 남긴다. 게이트 아님.
2. **본선 측정.** main 에서 344개 스위트 중 지금 빨간 게 몇 개인지 센다. 이 숫자를 모르는 채로 게이트를 켜면 무관한 PR 이 막힌다.
3. **게이트.** 빨간 스위트를 닫거나 명시적으로 waiver 를 적은 뒤 required 로 올린다.

1 과 2 사이에 시간이 필요하다. 1 만으로도 이번 세션의 세 건은 PR 페이지에서 보였다.

## 하지 않는 것

- 전체 스위트를 PR 마다 돌리지 않는다. 링크 비용이 이 설계가 피하려던 것이고, 그 판단은 여전히 옳다.
- `@check` 를 대체하지 않는다. 타입 오류는 여전히 거기서 잡는 게 빠르다.
- 빨간 스위트를 세기 전에 게이트를 켜지 않는다.

## 판정 기준

1. 1단계 붙인 뒤, 위 표의 세 결함을 각각 재현한 브랜치에서 step 이 빨갛게 나오는가.
2. `@check` 가 이미 도는 job 에서 추가 시간이 얼마인가. 스위트 하나 링크 + 실행 기준으로 잰다.
3. 2단계 측정 결과 main 의 빨간 스위트가 0 이면 바로 게이트, 아니면 목록을 RFC 로 흡수한다.
