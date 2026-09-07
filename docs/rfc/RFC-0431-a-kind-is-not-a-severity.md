---
rfc: "0431"
title: "종류는 심각도가 아니다 — 테마에 없는 축 하나"
status: Implemented
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: []
---

# 종류는 심각도가 아니다

## 관찰

`masc_tui_render.ml:3813` 에 이미 진단이 적혀 있다.

> Verifying keeps a raw colour, and it is not the only one … Thirteen sites, and they are one problem, not thirteen.

세어봤다. `bin/` 에서 테마를 거치지 않고 색을 직접 집는 자리가 **11곳**, 거기에 categorical 용도로 유일한 accent 를 빌려 쓰는 자리가 **2곳** 더 있다.

| 자리 | 무엇을 가르나 | 집는 색 |
|---|---|---|
| `planning_phase_color` (3825) | Goal 단계 — Verifying | `Ansi.magenta` |
| planning 카운터 (4060) | 같은 축, 리터럴만 한 번 더 | `Ansi.magenta` |
| keeper 행 sandbox (5288) | 샌드박스 — microvm | `Ansi.magenta` |
| keeper 행 sandbox (5287) | 샌드박스 — docker | `tone Accent` |
| `change_kind_badge` (12555) | 파일 변경 종류 — EDIT | `Ansi.magenta` |
| File icon (14291) | 파일 종류 — Script | `Ansi.magenta` |
| File icon (14288–14293) | 파일 종류 — Code / Data / Prose / Web / Media | `tone Accent`, `bright_yellow`, `bright_green`, `blue`, `bright_magenta` |
| `context_component_style` (16230) | 컨텍스트 구성요소 — Memory OS recall | `bold magenta` |
| `context_component_style` (16246) | 컨텍스트 출처 — producer digest only | `bold magenta` |

`Ansi.magenta` 하나가 **일곱 자리에서 일곱 가지 다른 뜻**으로 쓰인다. Goal 단계, 샌드박스, 파일 변경, 파일 종류, 메모리 회수, 출처. 운영자가 "이 색은 무슨 뜻이지" 를 배울 수 없다. 뜻이 없기 때문이다.

사용자가 요구한 것이 정확히 그 반대였다.

> 같은걸 의미하는건 같은 계열이 좋겠습니다

## 왜 이렇게 됐나

테마가 가진 축을 보면 답이 나온다 (`masc_tui_ansi.ml:71` 의 `resolved`).

- **상태**: `ok` `warn` `bad` `info` `muted` — 건강 상태. 서로 우열이 있다.
- **역할**: `user` `inbound` `keeper` `tool` `quiet` `probe` `message` — 채팅에서 누가 말했나.
- **무게**: `tone` 의 `Normal | Dim | Accent` — 얼마나 눈에 띌 것인가. accent 는 **하나**다.
- **문법**: `Theme.Syntax` — 코드 토큰이 무엇인가.

**종류(kind)를 가르는 축이 없다.** 작은 닫힌 집합의 원소들인데 서로 우열이 없고, 읽는 사람이 할 일은 그저 구분하는 것뿐인 경우 — 그런 자리가 갈 곳이 없다. 그래서 두 갈래로 샜다. accent 하나를 빌려 쓰거나(2곳), 테마 밖으로 나가 색 이름을 직접 부르거나(11곳).

역할 축이 있다는 게 중요하다. 이 테마는 이미 "상태가 아닌 축"을 하나 갖고 있다. 새 개념을 들이는 게 아니라 **같은 종류의 축을 하나 더** 두는 일이다.

## 두 번째 결과 — 이 자리들만 테마를 안 듣는다

`Theme.ok ()` 는 `(resolved ()).ok` 를 읽는다. 터미널 팔레트가 OSC 응답으로 늦게 도착하면 generation 이 바뀌고 값이 다시 잡힌다.

`Ansi.magenta` 는 상수 SGR 이다. 팔레트가 무엇이든 안 움직인다.

즉 테마를 바꿔도 **종류를 말하는 자리만 그대로 남는다.** 밝은 배경 테마에서 다른 모든 것이 옮겨간 뒤에도 magenta 일곱 개는 자기 자리에 있다. 사용자가 "Theme 별로 판단이 잘 되는걸로 보여야하고" 라고 한 요구가 지금 구조적으로 불가능하다.

## 제안

`resolved` 에 categorical 축을 더한다. 슬롯 이름은 뜻이 아니라 **번호**다.

```ocaml
; category : string array   (* 슬롯 0..n-1, 테마마다 해결됨 *)
```

핵심 결정 하나: **슬롯은 표면마다 붙인다. 전역 의미가 아니다.**

Goal 단계 축과 파일 종류 축은 같은 화면에 안 나온다. 두 축이 슬롯 0 을 같이 써도 아무도 혼동하지 않는다. 반대로 일곱 축의 원소를 전부 모아 전역 색을 하나씩 주려 하면 색이 모자라고, 모자라는 순간 지금과 같은 재사용이 다시 시작된다.

그래서 각 표면이 자기 닫힌 집합을 슬롯에 사상하는 함수를 하나 갖는다. `planning_phase_color` 가 이미 그 모양이다 — 바뀌는 건 오른쪽이 `Ansi.magenta` 대신 `Theme.category 1` 이 되는 것뿐이다.

### 슬롯 수

지금 한 축의 최대 원소 수가 기준이다. 파일 종류가 6개(Code/Data/Prose/Script/Web/Media)로 가장 크다. 상태 색과 섞이지 않으면서 서로 구분되는 슬롯이 **6개** 필요하다.

6개를 실제로 구분 가능하게 고르는 일은 이 RFC 가 정하지 않는다. 테마별로 해결되므로 테마 정의에서 정한다. 다만 판정 기준은 아래에 둔다.

### 색만으로 가르지 않는다

이 저장소에 이미 선례가 있다 (`masc_tui_render.ml:5831` 의 lane 행).

> One mark per colour class, so a reader who cannot tell the colours apart gets the split the colours make.

categorical 축도 같은 규칙을 따른다. 색이 유일한 채널이면 안 된다. 파일 아이콘은 이미 글리프를 갖고 있고, Goal 단계는 이미 단어를 갖고 있다. 색은 그 위에 얹는 것이지 대신하는 것이 아니다.

## 하지 않는 것

- **상태 색을 종류에 쓰지 않는다.** `Verifying` 이 magenta 인 이유가 정확히 이것이다 — `info` 와 `ok` 는 이미 Executing 과 Completed 가 가져갔고, 남은 상태 색을 쓰면 Verifying 이 경고나 실패로 읽힌다. 3813 의 주석이 "Naming them badly here would be worse than leaving them visible" 이라고 적은 이유다.
- **원소마다 전역 색을 주지 않는다.** 일곱 축의 원소를 합치면 스무 개가 넘는다.
- **글리프를 색으로 대체하지 않는다.**
- **이 RFC 에서 색값을 정하지 않는다.** 테마 정의의 일이다.

## 판정 기준과 그 답 (구현 완료)

세 단계가 모두 main 에 있다. 기준은 넷 다 답이 나왔고, **두 개는 이 문서가 틀렸다고 답했다.**

**1. 슬롯이 각 테마에서 서로 구분되는가** — 6이 아니라 **5**, 그리고 스크린샷이 아니라 실측이다.

배포된 43개 스킴 전부에서 기존 keeper action 테스트와 같은 oklab 거리로 쟀다.

```
정상 색각     0.023960   horizon-dark   yellow vs green
적색약(deu)   0.003345   ayu-dark       yellow vs green
녹색약(pro)   0.003246   ayu-light      yellow vs green
```

정상 색각 최악 쌍이 keeper action 이 지키는 0.025 **아래**다. 7개만 이름 붙은 팔레트에서 6개를 그만큼 떨어뜨릴 수 없다. floor 를 0.023 으로 두고 래칫으로 고정했다.

색약 수치는 floor 의 **1/7** 이다. **6칸 축은 색만으로 안 갈린다** — 이 문서가 "색만으로 가르지 않는다"고 쓴 게 예의가 아니라 요구사항이었다는 뜻이다. 슬롯 순서를 바꿔도 안 된다: 가까운 쌍은 스킴의 성질이다.

**2. 슬롯이 상태 색과 혼동되지 않는가** — **혼동된다. 구조적으로.**

테마가 이름 붙인 7색 중 `status_ansi_color` 가 이미 다섯을 갖는다(green·yellow·red·cyan·물러나는 black). 그래서 slot 은 **어떤 status 토큰과 바이트가 같다.** 안 겹치는 건 blue·magenta 둘뿐이다.

`slot_6 = Bright_red` 는 `Theme.bad ()` 와 **완전히 같은 이스케이프**였고, `write_two_panes` 가 파일 목록과 content 팬을 한 터미널 행에 붙이는 바람에 목록의 `.png` 가 옆 실패 문구와 같은 색으로 그려졌다. 그리는 표면이 그 status 토큰을 안 그린다는 확인을 테스트로 넣었다.

**슬롯은 넷이다.** 종류 표시가 흉내 내면 안 되는 색이 셋이다 — `bad` 의 red, `ok` 의 green, 물러나는 black. 7색에서 그 셋을 빼면 cyan·yellow·blue·magenta 넷이 남고, 그게 알파벳 전부다. 다섯 번째 슬롯은 이름이 무엇이든 저 셋 중 하나를 도로 가져온다 (#33696). 파일 팬의 색칠하는 종류 여섯이 넷을 나눠 쓴다 — Web 은 Code 와, Media 는 Script 와 같이 읽고, 한 슬롯 안에서 둘을 가르는 건 글리프다.

여덟 번째 색을 만드는 쪽은 재보고 접었다. ANSI 15 는 base07 인데 `config/themes` 52개 중 여섯에서 base07 과 base05(본문 전경색)가 같은 바이트라, 그 테마에서 슬롯이 파일 이름 글자와 구별되지 않는다.

**3. 팔레트가 바뀔 때 13곳이 따라 움직이는가** — 그렇다. `bin/masc_tui_render.ml` 의 raw hue 식별자는 **0** 이고, AST 가드가 그 자리를 지킨다 (`blue`·`bright_blue`·`bright_cyan`·`bright_magenta`·`bright_yellow`·`bright_green`·`bright_red`·`magenta`). `cyan` 은 열어뒀다 — `tone Accent` 가 그걸로 resolve 되고 스무 곳쯤이 그걸 읽는다.

**4. 축마다 색 아닌 채널이 있는가** — 있다. 파일 종류는 `File_icon.glyph` 7종, Goal 단계·샌드박스·변경 배지·컨텍스트는 단어나 글자를 갖는다. 다만 `glyphs_distinct` 가 확인하는 건 **바이트 구분**이지 마크가 얼마나 떨어져 읽히는지가 아니다.

## 착수 순서 (완료)

1. `resolved` 에 슬롯 + 테마별 값 — #33471
2. 파일 종류 축 이동 — 같은 PR. 그 뒤 #33477 이 red 충돌과 폴더 마크를, #33473/#33481 이 실측 floor 를 붙였다
3. 나머지 다섯 축 — #33485. `Ansi.magenta` 하나가 Goal 단계·샌드박스·변경 배지·컨텍스트 둘을 뜻하고 있었다

## 남은 것

- `cyan` 이 래칫 밖이다. `tone Accent` 를 어떻게 볼지는 raw hue 문제가 아니라 그 토큰에 대한 질문이다
- `glyphs_distinct` 는 바이트만 본다. 마크가 실제로 떨어져 읽히는지는 안 쟀다
- 슬롯 cyan·yellow 는 여전히 `info`·`warn` 과 바이트가 같다. 지금 테스트는 파일 팬이 그리는 `bad`·`ok` 두 개만 막는다. 다른 표면이 슬롯을 쓰려면 자기가 그리는 토큰에 대해 같은 확인을 해야 한다
- 슬롯이 본문 전경색(base05)과 떨어지는지는 계약이 없다. 여덟 번째 색을 검토할 때 그게 먼저다
