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

남는 결정: 실패 절을 어떻게 식별하느냐. `compact_outcome_parts` 가 이미 결과별로 절을 만들고 있으므로, 문자열을 다시 파싱하지 않고 절 목록을 결과 태그와 함께 올리면 된다.

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
