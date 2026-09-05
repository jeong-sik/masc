---
rfc: "0427"
title: "종류는 심각도가 아니다 — 테마에 없는 축 하나"
status: Draft
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

## 판정 기준

1. 6개 슬롯이 이 저장소의 각 테마에서 서로 구분되는가. 스크린샷으로 확인한다.
2. 슬롯 색이 상태 색(`ok`/`warn`/`bad`)과 혼동되지 않는가. 종류를 심각도로 읽으면 실패다.
3. 팔레트 generation 이 바뀔 때 13곳이 전부 따라 움직이는가. 지금은 11곳이 안 움직인다.
4. 축마다 색 아닌 채널(글리프나 단어)이 하나 이상 남아 있는가.

## 착수 순서

1. `resolved` 에 슬롯 추가 + 테마별 값. 소비자 없음 — 이 단계만으로는 화면이 안 바뀐다.
2. 축 하나(파일 종류, 6원소로 가장 큼)를 옮기고 스크린샷으로 1·2 판정.
3. 통과하면 나머지 여섯 축을 옮긴다.

1 과 2 는 같은 PR 이어야 한다. 슬롯만 넣고 소비자를 안 붙이면 아무도 안 읽는 필드가 남는다.
