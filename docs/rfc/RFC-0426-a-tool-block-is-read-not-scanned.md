---
rfc: "0426"
title: "도구 블록은 훑는 것이 아니라 읽는 것이다 — 채팅 팬의 세 가지 읽기"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: []
---

# 도구 블록은 훑는 것이 아니라 읽는 것이다

## 관찰

운영자가 keeper 채팅 팬 스크린샷을 놓고 말한 것: 도구 줄이 "주르르륵 나열-숫자 나열-숫자"라 대화의 맥을 끊고, 무엇이 무엇을 했는지 알 수 없다.

화면에 실제로 그려진 한 줄:

```
× Tools 11 · Keeper 3 · Execute 2 · keeper_artifact_read 2 · masc_board_comment 1 ·
masc_board_post_get 1 · github_search_code 2 · masc_ask 2 · keeper_memory_write 1 ·
7 returned, 4 failed: Execute 2, masc_ask, keeper_memory_write · 11 details folded ·
Ctrl-D: full calls / schedule / diffs
```

한 줄에 세 종류가 섞여 있다: **재고**(무엇이 몇 번 불렸나), **결과**(몇이 돌아왔고 무엇이 실패했나), **행동**(무슨 키를 누르면 열리나). 구분자는 `·` 하나뿐이고 색도 하나다.

이 RFC 는 그중 이미 처리된 것을 빼고 남은 셋을 다룬다. 반복되던 키 안내와 `…broadcast` 라벨은 별도 PR 에서 닫혔다.

## 읽기 1 — 성공한 호출이 실패 색으로 그려진다

`tool_block_style` 은 블록 전체를 최악 결과로 칠한다. 주석이 그 결정을 적어놨다:

> A block holding a failure is a failure; one still waiting is attention; one that returned is the ordinary tool row it was before.

블록의 **성격**으로는 맞다. 결과로 생기는 일이 문제다: `7 returned, 4 failed` 인 줄에서 **돌아온 7개의 이름까지 빨갛다.** 재고는 실패가 아닌데 경보색을 입는다. 화면 전체가 같은 빨강이 되면 눈이 내려앉을 자리가 없어지고, 정작 실패한 셋(`Execute 2, masc_ask, keeper_memory_write`)이 나머지와 같은 무게로 읽힌다.

원인은 취향이 아니라 구조다. 줄 하나에 스타일 하나가 붙는다 — `Message_layout` 의 블록 스타일이 행 전체를 감싼다. 절마다 다른 색을 주려면 행 텍스트가 자기 스타일을 품어야 하고, 그러면 바깥 스타일의 리셋과 겹친다.

**제안**: 블록 마크와 라벨(`× TOOLS`)은 지금대로 최악 결과 색을 유지한다 — 블록의 성격은 그것이 맞다. 본문은 절별로 칠한다: 재고는 중립, `N returned` 는 조용하게, `N failed: …` 만 실패색. 눈이 실패 절로 내려앉고 재고는 배경이 된다.

### 접합부는 이미 있다

행 안에서 구간을 칠하고 바깥 스타일로 되돌리는 일은 이 팬이 이미 한다. 붙여넣은 URL 이 그 경우다:

```ocaml
let context = Chat_theme.body_context theme row.style in
Masc_tui_message_layout.dress_bare_links
  ~open_style:(Ansi.underline ^ Theme.Syntax.link)
  ~close_style:context.link_restore
  rest
```

두 조각이 필요한 전부다:

- `Chat_theme.body_context theme row.style` — 그 행의 스타일에 맞는 **복원 문자열**을 준다. 구간이 끝날 때 터미널 기본값으로 떨어지지 않고 블록 색으로 되돌아간다. 그 주석이 이유도 적어놨다: 여기서 reset 을 쓰면 행 꼬리와 패딩 전에 감싼 diff 배경이 잘린다.
- `dress_*` 형태 — `~open_style` / `~close_style` 쌍을 받아 텍스트 안의 특정 구간만 감싼다.

그래서 새 기전을 세울 일이 아니라 **같은 쌍을 실패 절에 적용하는 일**이다. 다만 요약 텍스트는 `Keeper_chat_diff.rows` 가 만들고 그 모듈은 스타일을 모른다. URL 과 같은 순서를 따른다 — 텍스트는 아래에서 만들고, 칠하기는 `context` 가 있는 렌더 층에서 한다.

### 다만 칠하기는 sanitize 뒤여야 한다

여기서 한 번 막힌다. 채팅 본문은 그려지기 전에 소독된다 — `project_tool_block` 이 요약 행을 `safe_line` 으로 감싼다 — 그래서 **행 텍스트 안에 ANSI 를 심는 경로는 없다.** `summary_outcome` 필드가 존재하는 이유가 그것이고, mli 가 그렇게 적어놨다:

> A chat body is sanitized before it is drawn -- a row cannot carry an escape into the terminal -- so a marker inside the text cannot be coloured, and the row's own style is the only channel a reading of state has.

URL dressing 이 되는 것은 그것이 **소독 뒤**, 렌더 층에서 `row.text` 에 적용되기 때문이다. 그 자리에는 `row.text` 와 `row.style` 만 있고 projection 은 없다.

그래서 필요한 변경은 두 조각이다:

1. **생산자**: `compact_outcome_parts` 가 절마다 어느 결과인지 함께 올리고, projection 이 실패 절을 필드로 들고 있는다. 문자열을 다시 파싱하지 않는다.
2. **소비자**: 그 절이 레이아웃 행까지 따라와서, URL 을 칠하는 바로 그 지점에서 `~open_style:(Theme.bad ())` / `~close_style:context.inline_restore` 로 감싸진다.

1만 하고 2를 안 하면 아무도 안 읽는 필드가 남는다. **둘은 같은 변경이다.**

### 세 경로를 재봤고 셋 다 같은 뿌리에서 막힌다

| 경로 | 막히는 지점 |
|---|---|
| 행 텍스트에 ANSI 를 심는다 | `project_tool_block` 이 `safe_line` 으로 소독한다. 이스케이프가 살아남지 못한다 |
| 레이아웃 행이 강조 구간을 들고 다닌다 | 줄바꿈이 절을 쪼갠다. `4 failed: Execute 2, masc_ask, keeper_memory_write` 가 두 줄로 나뉘면 뒷부분이 안 칠해진다 |
| 실패 절을 자기 행으로 내린다 | 스타일은 **메시지당 하나**다. `me_role` 에서 한 번 계산되고, 도구 메시지는 `tool_block_style projection` 하나를 블록의 모든 행에 쓴다 |

뿌리는 하나다. **도구 블록은 스타일 하나를 가진 메시지 하나이고 요약은 소독된 문자열인데, 운영자가 원하는 읽기는 절 단위다.** 색 채널이 메시지당이고 읽기는 절당이라 층이 안 맞는다.

### 그래서 가장 작은 구조 변경

세 번째 경로의 전제만 풀면 된다 — **도구 블록의 행이 각자 스타일을 가지게 한다.** `tool_projection.rows` 를 `string list` 에서 행과 스타일의 쌍으로 올리고, 렌더가 도구 메시지에 대해서만 스타일 하나 대신 그 목록을 쓴다.

이것이 셋 중 가장 작은 이유:

- 소독을 건드리지 않는다. 행은 여전히 평문이다.
- 줄바꿈을 건드리지 않는다. 한 행 전체가 한 색이므로 어디서 접히든 색이 유지된다.
- 새 칠하기 기전이 없다. 이미 스타일→색 경로가 있고, 그것을 행마다 부를 뿐이다.

그러면 요약이 이렇게 갈라진다:

```
■ TOOLS  11 calls · Execute 2 · keeper_artifact_read 2 · … · 7 returned
✗        4 failed: Execute 2, masc_ask, keeper_memory_write
```

윗줄은 도구 톤, 아랫줄만 실패 톤. 눈이 `✗` 행에 내려앉고 재고는 배경이 된다. 실패가 없는 블록은 지금처럼 한 줄이다.

측정: 스크린샷의 다섯 블록 중 넷이 실패를 가졌으니 그 창에서는 +4 행이다. 다만 지금도 그 줄들은 길이 때문에 두 줄로 접히고 있어서, 갈라도 높이는 늘지 않을 수 있다. 구현 시 확인한다.

## 읽기 2 — 호출들 사이의 관계가 요약에 없다

요약은 `이름 N · 이름 N` 평면 나열이다. 원장(`tool_calls`)은 그보다 많이 안다 — 각 호출의 `batch_index`/`batch_size`, `planned_index`, `execution_mode`, 그리고 무엇이 무엇 뒤에 왔는지. 요약줄은 그걸 전부 버리고 이름과 개수만 남긴다.

그래서 "무엇이 무엇을 어떻게 했는지" 를 못 읽는다. `Execute 2` 가 두 번 실패했다는 것은 알지만, 그 둘이 같은 배치였는지, 앞선 `github_search_code` 의 결과를 받아 돈 것인지는 접힌 상세를 열어야 안다.

**제안**: 요약을 배치 단위로 묶는다. 한 배치가 한 줄이고, 배치 안의 호출은 마크로 잇는다.

```
× TOOLS  11 calls in 3 batches · 4 failed
   1  ✓ github_search_code ✓ github_search_code
   2  ✓ keeper_artifact_read ✓ keeper_artifact_read ✗ Execute ✗ Execute
   3  ✓ masc_board_post_get ✓ masc_board_comment ✗ masc_ask ✗ keeper_memory_write
```

세 줄이 지금 두 줄보다 길지만, **순서와 동시성이 보인다.** 실패가 어느 배치에서 났는지, 그 배치에 무엇이 같이 있었는지가 접기 전에 읽힌다. 트리로 더 갈 수도 있으나, 배치는 원장에 이미 있는 사실이고 트리는 추론이다 — 있는 사실부터 쓴다.

### 측정 (2026-09 원장, 64,767 콜 / 9,911 턴)

배치 크기 분포는 1에 몰려 있다 — 82% 가 `batch_size 1`, 턴 단위 중앙값도 1이다. 그대로 두면 이 묶기는 대부분의 블록에서 줄만 늘린다.

그런데 블록 크기로 갈라 보면 다르다:

| 블록 크기 | 턴 | 배치>1 을 가진 턴 |
|---|---:|---:|
| 1–2 콜 | 4,271 | 145 (3%) |
| 3–5 | 2,502 | 516 (21%) |
| 6–10 | 1,777 | 593 (33%) |
| **11+** | **1,362** | **682 (50%)** |

**묶을 것이 있는 블록이 곧 읽기 힘든 블록이다.** 스크린샷의 11콜 블록이 그 구간이고, 거기서는 절반이 배치를 가진다. 1–2콜 블록은 3% 라 묶을 것이 없고 애초에 읽기 어렵지도 않다.

그래서 무조건 묶지 않는다. **블록이 배치를 하나라도 가질 때만** 배치 줄로 펼치고, 아니면 지금의 한 줄을 유지한다. 조건은 추론이 아니라 그 블록의 기록에서 바로 읽힌다.

## 읽기 3 — 마우스와 오버레이는 이미 있다, 이 화면이 안 쓸 뿐이다

운영자가 "마우스라도 지원하던가", "플로팅 레이어를 쓰든가" 라고 했는데, 둘 다 이미 저장소에 있다.

- **마우스**: SGR 리포트를 디코드하고(`lib/tui_decode.ml:1355`), `Mouse_left_press of int * int` 로 올리고(`bin/masc_tui.ml:574`), `Ctrl-T` 로 해제해 드래그 선택을 넘긴다. **소비자는 하나다** — Lanes overview (`handle_lanes_overview_click`). 다른 모든 화면에서 클릭은 catch-all 로 떨어져 버려진다. 모달이 클릭을 가로막는 게이팅도 이미 그 자리에 쓰여 있다.
- **오버레이**: `bin/masc_tui_answering.ml` 이 오버레이다. 한 키로 열리고 표면 위에 뜬다.

즉 새로 세울 계층이 아니라 **검증된 패턴을 이 표면에 잇는 일**이다.

**제안**:
1. 채팅 팬의 도구 블록 행을 클릭 대상으로 만든다. 클릭한 블록만 펼친다 — 지금 `Ctrl-D` 는 팬 전체의 접힘을 토글하므로, 하나를 보려고 전부를 여는 것이 현재의 비용이다.
2. 펼친 상세를 인라인이 아니라 오버레이로 띄우는 안을 같이 잰다. 인라인 확장은 그 아래 대화를 밀어내고, 운영자의 불만이 정확히 "맥이 끊긴다" 였다.

## 하지 않는 것

- 도구 요약에서 개수를 없애지 않는다. 접힌 상태에서 규모를 말하는 유일한 값이다.
- 블록 마크의 최악-결과 규칙을 바꾸지 않는다. 블록 하나가 실패를 품으면 그 블록은 실패다 — 바꾸는 것은 본문이지 마크가 아니다.
- 트리 구조를 추론으로 만들지 않는다. 배치는 기록된 사실이고 호출 간 인과는 아니다.

## 판정 기준

1. 읽기 1 은 절별 스타일 경계가 서면 바로 값을 한다. 선행 측정 없음.
2. 읽기 2 는 위에서 쟀다. 중앙값 1 이라 무조건 묶기는 접었고, 배치를 가진 블록에서만 펼치는 조건부로 남는다. 그 조건이 실제로 큰 블록만 고르는지는 구현 후 화면에서 확인한다.
3. 읽기 3 은 1·2 뒤다. 줄이 읽히게 된 뒤에도 여는 비용이 남는지를 보고 정한다.

---

## 보정 — 읽기 1 의 비용 추정이 틀렸다 (2026-09-06 측정)

위에서 읽기 1 을 "선행 측정 없음, 절별 스타일 경계가 서면 바로 값을 한다" 로 적었고,
가장 작은 변경이 `tool_projection.rows` 를 행과 스타일의 쌍으로 올리는 것이라고 했다.
구현에 들어가기 전에 소비자 쪽을 따라가 봤더니 **그 경로는 채팅 팬에 닿지 않는다.**

### 확인한 것

`Message_layout.row` 에는 이미 행마다 `style` 이 있다. 그래서 "행마다 스타일"이 새 개념은 아니다.
막히는 자리는 그 위다.

| 지점 | 사실 |
|---|---|
| `bin/masc_tui_render.ml:8758` | 채팅 팬은 모든 entry 를 `~markdown:(cached_chat_markdown …)` 로 넘긴다. 도구 블록도 예외가 아니다 |
| `masc_tui_message_layout.ml:1181` | markdown 이 있으면 본문 조각은 `render ~entry ~width` 가 만든다. 돌려주는 건 평평한 `string list` 라 **어느 조각이 어느 원본 줄에서 왔는지가 없다** |
| `masc_tui_message_layout.ml:1224` | 그래서 본문 행은 전부 `style = entry.style` 로 만들어진다. 행별 `style` 필드는 있지만 채워 넣을 값이 없다 |
| `bin/masc_tui_render.ml:322` | `chat_markdown ~context` 는 인라인 span 을 `context.markdown_close` 로 닫는다. 그 context 는 `Chat_theme.body_context theme entry.style` 에서 나온다 — **본문의 바탕색이 markdown 렌더 안에서 굳는다** |
| `bin/masc_tui_render.ml:405` | 그 렌더 결과가 `cmi_style = entry.style` 을 identity 에 넣은 캐시에 저장된다 |

즉 스타일은 레이아웃이 행에 붙이는 장식이 아니라 **markdown 렌더의 입력이고 캐시 키의 일부**다.
한 entry 안에서 줄마다 색을 다르게 하려면 markdown 렌더가 줄별 스타일을 받고 캐시 키가 그걸 포함해야 한다.
"이미 스타일→색 경로가 있고 그것을 행마다 부를 뿐" 이라는 위의 문장은 틀렸다.

### 열려 있는 경로

스타일이 **entry 단위**로는 이미 완전히 동작한다. 캐시도 entry 단위로 갈린다.
그래서 열린 길은 도구 블록 하나를 entry 둘로 나누는 것이다 — 재고 entry(도구 톤)와 실패 entry(실패 톤).
새 기전이 없고, 각 entry 가 자기 context 로 렌더되고 자기 `cmi_style` 로 캐시된다.

값도 공짜는 아니다. entry 는 지금 `List.mapi` 로 메시지당 하나씩 만들어지고(`masc_tui_render.ml:8315`),
#32878 이 그 목록을 **메시지 물리 동일성으로 메모이즈**했다. 메시지 하나가 entry 둘을 내려면
그 자리가 `concat_map` 이 되고 메모 항목이 리스트를 들어야 한다.

### 그래서 다시 정한 것

- 읽기 1 의 "선행 측정 없음" 을 취소한다. 측정이 필요했고, 위가 그 측정이다.
- `tool_projection.rows` 를 쌍으로 올리는 안은 접는다. 그 필드를 채워도 읽는 곳이 없다.
- 대신 entry 분리안을 읽기 1 의 구현 후보로 둔다. 착수 전에 #32878 메모 구조를 먼저 읽는다.
- 읽기 3(클릭으로 한 블록만 펼치기)은 여전히 1·2 뒤다.
