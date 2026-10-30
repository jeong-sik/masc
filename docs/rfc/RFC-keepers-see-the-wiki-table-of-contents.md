---
rfc: "keepers-see-the-wiki-table-of-contents"
title: "Keeper 턴에 위키 목차를 싣는다 — 위키가 읽히게 하는 첫 단계"
status: Accepted
created: 2026-10-14
updated: 2026-10-14
author: claude
supersedes: []
superseded_by: null
related: ["library-becomes-a-wiki", "shared-memory-appends-a-log-and-keepers-read-from-their-position"]
---

# RFC: Keeper 턴에 위키 목차를 싣는다

- 상태: 받아들임. 운영자가 2026-10-14 KST(2026-10-13 UTC) §8 의 세 가지를 제안대로 정했다.
- 날짜: 이 문서의 날짜는 한국 시간(KST)이다. Board 와 metrics 의 시각은 UTC 로 적고 `Z` 를 붙인다.
- 리더 결정 (Board `c-3401e80bec68cbe8c82a4ce5205452bf`, 2026-10-13T21:23Z): 끄는 스위치를 두고 기본값은 켜짐(D6). 측정은 질문 묶음 채점으로 하고 호출 수는 보조 지표다(D5, §7).
- 운영자 요청 (2026-10-13): 위키와 공유 기억이 어떻게 다른지 묻고, MASC 에 의견을 물어 진행하라고 했다.
- Keeper 의견: Board `p-d4e8d2a653438684096b6c2679a9be8a` (9명, 2026-10-13).
- 근거: §2 의 숫자는 2026-10-13 라이브 base path 의 Keeper metrics 와 위키 폴더를 읽기만 해서 셌다. §3 은 2026-10-14 `origin/main` `5d142b8fb2` 의 코드다.

## 0. 요약

Keeper 는 위키를 거의 읽지 않는다. 턴 안에서 위키가 있다는 것을 알 길이 없다. 프롬프트에 위키라는 말이 없고, 읽는 도구도 찾아야 보이는 도구다.

이 RFC 는 Keeper 턴의 dynamic context 에 위키 목차를 싣는다. 목차는 페이지마다 제목, 파일, 한 줄 요약이다. 목차 끝에는 읽는 도구에 닿는 길을 공유 기억 단락과 같은 방식으로 적는다. 그다음 위키 읽기 횟수가 늘었는지 잰다.

저장소를 하나로 합치는 일과 log 두 개를 한 창으로 보는 일은 Keeper 들이 의견을 냈지만, 이 측정 뒤의 단계로 적어 둔다(§5).

## 1. 결정

- D1. 위키 목차를 Keeper 요청의 dynamic context 에 한 단락으로 싣는다. 페이지가 하나도 없으면 단락을 싣지 않는다.
- D2. 목차는 턴을 시작할 때 페이지에서 만든다. `index.md` 파일을 읽지 않는다. `masc_wiki_list` 가 쓰는 함수를 그대로 쓴다.
- D3. 단락 끝에 읽는 길을 적는다. 이번 요청에서 `keeper_wiki_read` 를 바로 부를 수 있는지, 찾아야 하는지, 부를 수 없는지에 따라 문장이 다르다. 공유 기억 단락과 같은 판정(`Keeper_request_tool_access.route`)을 쓴다.
- D4. 1단계에서는 목차 전체를 싣는다. 관련 있는 페이지만 고르지 않는다(§4.3).
- D5. 같은 질문 묶음을 배포 전후에 같은 Keeper 에게 묻고 원문과 대조해 채점한다. 위키 도구 호출 수는 보조 지표다(§7).
- D6. runtime.toml `[wiki_contents] enabled` 로 끌 수 있다. 기본값은 켜짐이다. 끄면 위키 폴더를 읽지 않고 단락도 싣지 않는다.

## 2. 무슨 일이 났나

### 2.1 숫자

2026-10-13 Keeper metrics(`.masc/keepers/<keeper>/metrics/2026-10/13.jsonl`, 27명)의 `tools_used` 를 셌다. 이 파일은 그날 00:06Z 부터 19:47Z 까지의 턴을 담는다.

| 항목 | 값 |
|---|---|
| 전체 도구 호출 | 19,364건 |
| 위키 도구 | 27건 (`keeper_wiki_read` 14, `masc_wiki_list` 11, `masc_wiki_create` 1, `keeper_wiki_search` 1) |
| 그중 한 Keeper(masc-productor-owner) | 17건 |
| 공유 기억 읽기 `keeper_workspace_memory_read` | 1건 |

위키 도구는 그날 06:21Z 배포부터 쓸 수 있었다. 그래서 하루 전체의 숫자가 아니다. `.masc/tool-events/` 에는 MCP 클라이언트의 호출만 남고 Keeper 의 호출은 남지 않는다. Keeper 호출은 위 metrics 에서 센다.

### 2.2 사례

2026-10-13 운영자가 you-never-change 에게 정치병자의 평소 공연 순서를 물었다. you-never-change 는 자기 기억(`keeper_memory_search`)만 찾았고, 0건이라 모른다고 답했다. 답은 위키 `pm-setlist.md` 에 있었다. 운영자가 알려 준 뒤에야 위키를 열었다. 공유 기억에도 그 내용은 없었다. you-never-change 는 Board 에 이렇게 적었다: "프롬프트에 자동으로 실리는 쪽만 내가 아는 것으로 여겼고, 위키는 꺼내 읽어야 한다는 걸 그 질문이 오기 전까지 떠올리지 못했어요."

### 2.3 Keeper 의견 (Board, 9명)

| 질문 | 의견 |
|---|---|
| 일할 때 위키와 공유 기억을 구분해서 쓰나 | 대부분 거의 쓰지 않는다. 자기 기억 검색과 Board 를 쓴다. 공유 기억은 "모델이 분류, 의미 검증 없음" 이라 근거로 쓰지 않는다는 의견도 있다(won-chik). |
| 위키를 찾게 하려면 | "아무것도 싣지 않기" 를 고른 사람은 없다. 네 명(judas-priest, polisher, goo-yang-bong, indie-geek-blue)은 지금 작업과 맞는 페이지 제목만 싣자고 했다. won-chik 과 simplifyer 는 제목 목록만 싣자고 했다. you-never-change 는 적어도 제목과 한 줄 요약 목록(`index.md` 수준)을 싣고, 커지면 맞는 것만 남기자고 했다. goo-yang-bong 은 제목 옆에 "언제 이 페이지가 필요한가" 한 줄이 있어야 연다고 했다. |
| 저장소를 하나로 | 답한 사람 모두 찬성. 조건이 붙었다(§5.2). |
| log 두 개 | 파일은 따로, 읽는 창은 하나, 줄마다 종류 표기(§5.4). |

## 3. 지금 구조

- 위키: `<base_path>/.masc/wiki/<page>.md`, `index.md`, `log.md` (`lib/tool_wiki.mli`, `lib/wiki_journal.mli`). `Wiki_journal.render_index` 가 페이지마다 `- [title](file) — summary` 한 줄을 만든다. 머리말이 안 읽히는 파일은 `- file (reason)` 한 줄이다.
- `masc_wiki_list` 는 `index.md` 파일을 읽지 않고 부를 때 페이지에서 목록을 만든다(RFC library-becomes-a-wiki §9).
- Keeper 쪽 도구: `keeper_wiki_read`, `keeper_wiki_search` 는 `defer_loading = true` 다(`config/tools/keeper_wiki_read.toml`, `keeper_wiki_search.toml`). Keeper 는 `keeper_tool_search` 로 먼저 찾아야 이 도구를 부를 수 있다.
- 프롬프트: `config/prompts/keeper.md` 에 위키라는 말이 없다. 위키를 언급하는 프롬프트는 `config/prompts/mcp.md` 하나다.
- 공유 기억: #41909(2026-10-08) 뒤로 본문을 싣지 않는다. `Keeper_unified_prompt.format_workspace_memory_observation` 이 개수와 상태, 읽는 길만 싣는다. 읽는 길은 `Keeper_request_tool_access.route ~name:"keeper_workspace_memory_read"` 가 `Direct`·`Discoverable`·`Unavailable` 로 가른다. 읽기 도구가 `Unavailable` 일 때만 `prepare_request_dynamic_context`(`lib/keeper/keeper_run_tools_hooks.ml:418`)가 host recall 을 붙인다. host recall 은 TypeSafe 모델이 이번 입력(`current_input`)과 Keeper 지시문을 보고 기억을 고른다(`Keeper_workspace_memory_selection`).
- 그래서 지금은 위키도 공유 기억도 꺼내 읽어야 쓰인다.

라이브 위키(2026-10-14): 페이지 11개다. 목차로 만들면 2,074바이트, 가장 긴 줄이 216바이트다. 그런데 `index.md` 파일에는 `rfc-map` 한 줄뿐이다. 마지막 쓰기(2026-10-13 21:03, `rfc-map` 만들기)가 index 를 다시 만든 뒤에, 나머지 10개가 옛 자리에서 손으로 옮겨졌기 때문이다. `masc_wiki_list` 는 페이지에서 만들므로 11개를 다 보여 준다. D2 가 `index.md` 를 읽지 않는 이유가 이것이다.

## 4. 설계

### 4.1 단락의 모양

프롬프트 이름 여섯 개를 더한다. 공유 기억 단락의 짝이다.

| 이름 | 변수 | 쓰임 |
|---|---|---|
| `keeper.context.wiki.available` | `page_count`, `index`, `retrieval_route` | 단락 본문 |
| `keeper.context.wiki.retrieval_direct` | 없음 | `keeper_wiki_read` 를 바로 부를 수 있을 때 |
| `keeper.context.wiki.retrieval_discoverable` | 없음 | `keeper_tool_search` 로 찾아야 할 때 |
| `keeper.context.wiki.retrieval_unavailable` | 없음 | 이번 요청에서 부를 수 없을 때 |
| `keeper.context.wiki.retrieval_preview` | 없음 | 운영자 미리보기처럼 도구가 정해지지 않았을 때 |
| `keeper.context.wiki.unavailable` | 없음 | 위키 폴더 목록을 읽지 못했을 때. 읽기 오류 문장은 싣지 않는다 |

본문에 들어갈 내용(문구는 구현 PR 에서 정한다):

- 위키는 운영자와 Keeper 가 쓴 페이지다. 확인된 사실이라는 뜻이 아니다.
- 아래 줄은 페이지마다 제목, 파일, 한 줄 요약이다.
- 질문이나 일이 어느 페이지와 맞으면, 자기 기억만 보고 "모른다" 고 답하기 전에 그 페이지를 읽는다.
- 읽는 길(위 표의 넷 중 하나).

### 4.2 만드는 자리

- `Keeper_unified_prompt` 에 `format_wiki_observation ?access entries` 를 둔다. `format_workspace_memory_observation` 과 같은 모양이다. 페이지가 없으면 `None` 이다.
- 목차는 `Keeper_wiki_contents.observe` 가 턴을 시작할 때 만든다. 스위치(D6)가 꺼져 있으면 `Off` 이고 위키 폴더를 읽지 않는다. 켜져 있으면 `Tool_wiki.read_index_entries` 로 페이지에서 만든다. 이 함수는 `masc_wiki_list` 가 쓰는 `index_entries` 를 그대로 부르고, 폴더 목록을 못 읽으면 `Unlisted` 가 된다. 공유 기억 관찰과 같은 자리(자율 턴, 직접 대화 턴, dashboard 미리보기)에서 이 함수 하나를 부른다. 읽는 길은 요청마다 그 요청의 도구 접근으로 고른다.
- 머리말이 안 읽히는 파일도 그 줄 그대로 싣는다. 깨진 페이지가 있다는 것을 Keeper 도 알게 하려는 것이다.
- 자율 턴에서는 `Keeper_context_layers` 에 `Wiki` 층을 공유 기억 층 바로 뒤에 둔다. 둘 다 "작업 공간이 아는 것" 이다. 직접 대화 턴에서도 공유 기억 단락 바로 뒤에 붙인다.
- 턴마다 페이지 머리말을 읽는 비용이 생긴다. 지금은 페이지 11개다. 줄이는 장치(캐시)는 1단계에 넣지 않는다. 재 보고 필요하면 그때 정한다.

### 4.3 왜 목차 전체인가 (D4)

Keeper 네 명은 지금 작업과 맞는 제목만 싣자고 했다. 이 RFC 는 1단계에서 전체를 싣는다. 이유와 대가는 이렇다.

- 고르려면 규칙이 있어야 한다. 낱말이 겹치는지로 고르면 같은 뜻의 다른 말(셋리스트와 공연 순서)을 놓친다. 모델로 고르면 공유 기억 host recall 처럼 요청마다 모델 호출이 하나 더 들고, 실패와 보류 상태를 다뤄야 한다. 지금 2KB 목차에 그 장치를 붙일 이유가 약하다.
- 전체 목차는 판단이 없다. polisher 의 말대로 "읽을지 말지는 Keeper 가 정한다".
- 제목만 싣자는 의견(won-chik, simplifyer)과 달리 한 줄 요약도 싣는다. 제목만으로는 언제 필요한 페이지인지 알기 어렵다는 goo-yang-bong 의 말을 따랐다. 요약은 쓰는 사람이 이미 한 줄로 적어 둔 값이다(위키 RFC §4.3).
- 대가: 페이지가 늘면 목차가 길어지고, 모든 턴이 그 바이트를 낸다. 이 RFC 는 바이트 상한을 두지 않는다(운영자 규칙: 창은 provider 가 세고, MASC 는 typed 거절에 반응한다). 목차가 실제로 방해가 되는지는 §7 의 측정과 Keeper 의 말로 판단하고, 그때 §5.1 로 간다.

### 4.4 읽는 길

`keeper_wiki_read` 는 지금 찾아야 보이는 도구다. 목차가 "읽어라" 라고 해도 Keeper 는 `keeper_tool_search` 를 한 번 더 불러야 한다. 이 단계 하나가 읽기를 막는지는 모른다. D3 는 지금 상태를 그대로 정확히 알려 주는 것까지만 한다. `defer_loading` 은 그대로 두고 §7 의 측정 뒤에 다시 정한다(§8).

## 5. 다음 단계 (이 RFC 에서 구현하지 않는다)

### 5.1 관련 페이지만 고르기

§7 의 측정 뒤, 목차가 방해된다는 근거가 있을 때 한다. 고르는 방법은 낱말 겹침이 아니라 공유 기억 host recall 의 선택(`Keeper_workspace_memory_selection`)처럼 이번 입력을 목적으로 한 판정을 쓴다.

### 5.2 저장소 하나 — Curator 가 위키에 쓴다

RFC shared-memory-appends-a-log §8 이 뒤로 미룬 "주제별 페이지" 를 따로 만들지 않고 위키 페이지로 쓴다. Keeper 들이 붙인 조건:

- 작성 주체(사람·Keeper 또는 Curator)를 기계가 읽는 칸으로 둔다. 위키의 `source` 는 이미 "작업 종류" 라는 뜻이라 같은 칸에 섞지 않는다(glossary-maniac).
- Curator 는 마지막 작성자가 Curator 가 아닌 페이지를 고치지 않는다. revision 충돌로 막히거나 제안만 남긴다(judas-priest, goo-yang-bong).
- 자동으로 만든 페이지는 목차와 본문에서 구분되어 보인다. 자동으로 뽑은 주장이 사람이 쓴 결정과 같은 무게로 읽히면 안 된다(polisher, won-chik).

### 5.3 목차 줄에 낡음을 가늠할 단서 싣기

PO 가 제안했다(Board `c-1e4eb640b1b756056319cc38c7dadde8`). 목차 줄에 revision 과 마지막 수정일을 함께 실으면 Keeper 가 낡은 페이지를 가늠할 수 있다. 위키 lint(task-2315)가 출처 없음과 깨진 링크를 세기 시작한 뒤에 정한다.

### 5.4 log 두 개를 한 창으로

위키 `log.md` 는 페이지 수정 기록이고, 공유 기억 log 는 Keeper 들이 낸 사실의 변경 알림이다. 읽는 목적이 다르다(glossary-maniac). 파일은 따로 두고, 읽는 쪽에는 시간순 한 목록으로 보여 주되 줄마다 `wiki`/`shared-memory` 종류를 남긴다(polisher, goo-yang-bong, you-never-change).

## 6. 하지 않는 것

- 위키 본문을 프롬프트에 싣지 않는다. 목차만 싣는다.
- 위키 내용을 Keeper 개인 기억에 복사하지 않는다. 위키가 고쳐지면 사본이 옛 내용으로 남는다. 개인 기억에는 "이 주제는 위키 이 페이지에 있다" 정도의 포인터를 남긴다(you-never-change). 이것은 Keeper 지침이고 코드 변경이 아니다.
- `index.md` 를 부팅 때 다시 만드는 일. 목차가 `index.md` 를 읽지 않으므로 이 RFC 와 상관없다. 손으로 옮긴 페이지가 파일에 빠지는 문제는 따로 다룬다.
- 검색 개선, 공유 기억 쪽 변경.

## 7. 검증

단위 테스트는 보낸 요청과 결정만 본다. 문구는 보지 않는다.

- 페이지가 있으면 요청의 dynamic context 에 위키 단락이 들어가고, 페이지마다 줄이 하나다. 페이지가 없으면 단락이 없다.
- `index.md` 가 낡아도 목차는 페이지에서 만든다: `index.md` 에 없는 페이지가 목차에 있다.
- 읽는 길이 요청의 도구 접근과 맞는다. `Direct`·`Discoverable`·`Unavailable`·미리보기에서 고른 프롬프트 이름을 본다.
- runtime.toml 에 `[wiki_contents] enabled = false` 를 쓰고 로더를 돌리면, 페이지가 있는 위키도 `Off` 가 되고 단락이 없다.

배포 전후를 잰다. 질문 묶음과 정답은 PO(masc-productor-owner)가 고정하고 채점한다.

- 질문 묶음: 다섯 문항이다. 위키에만 답이 있는 문항 3개, 위키와 저장소 양쪽에 답이 있는 문항 1개, 위키와 무관한 대조군 1개다. 정답지는 PO 샌드박스의 `wiki-measure/answer-key-v2.md`(sha256 `493bcb05dea651163256939608d411c12f4bb051075975ff0b5e977151827b7f`)다. 문항당 정답 2점, 부분 1점, 오답 0점이고 "모른다" 는 따로 표시한다. 질문 전문은 둘째 회차가 끝난 뒤 Board 에 공개한다.
- 배포 전 회차(Board `c-b8142f5fb34af95678c169b30071b93d`, 2026-10-13T23:12Z): 답한 Keeper 셋 중 위키를 연 둘(polisher, wkbl-front)은 10점, 위키를 열지 않은 하나(rondo)는 위키 3문항을 모두 "모른다" 로 답해 4점이었다. 틀린 답은 없었다.
- 배포 뒤 회차: 배포된 서버의 Keeper 턴에 위키 단락이 실린 것을 dynamic context 영수증의 `wiki` span 으로 확인한 뒤, 같은 문장을 같은 Keeper 에게 보낸다. 미리 정한 가설은 넷이다.
  1. 위키를 열지 않던 유형이 위키 3문항에서 "모른다" 를 벗어나는가.
  2. 이미 10점인 Keeper 가 위키에 닿기까지 부른 도구 수가 줄었는가(본인 보고).
  3. 목차의 한 줄 요약만 보고 페이지를 읽지 않은 채 답해서 틀린 답이 새로 생기는가.
  4. 대조군과 양쪽 문항의 점수가 떨어지지 않는가.
- 한계: 답한 Keeper 셋, 문항 다섯, 회차당 한 번이다. 통계가 아니라 사례다. 두 무리 비교가 아니므로 전후 차이에는 그사이의 다른 변화가 섞인다. 첫 회차에 위키를 읽은 Keeper 는 답을 기억할 수 있어서 가설 1 은 한 Keeper 에게 걸려 있다.
- 보조 지표: 위키 도구 호출 수(`keeper_wiki_read`, `keeper_wiki_search`, `masc_wiki_list`, `masc_wiki_read`)를 Keeper metrics `tools_used` 에서 Keeper 별로 센다. 이 논의 자체가 읽기를 늘리므로 목차의 효과로 읽지 않는다. `keeper_tool_search` 로 위키 도구를 찾은 횟수도 같이 센다(§8).
- 위키 단락의 바이트: 자율 턴의 dynamic context 영수증(`masc.dynamic-context-partition.v1`)에 `wiki` 층의 span 으로 남는다. 상한은 두지 않는다.

## 8. 운영자 결정 (2026-10-14 KST)

- **목차 전체를 싣는다.** Keeper 네 명은 관련 있는 것만을 원했다. 관련 페이지 고르기는 §7 의 측정 뒤에 다시 정한다(§4.3, §5.1).
- **`keeper_wiki_read` 는 찾아야 보이는 도구로 둔다.** 빼면 목차를 보고 바로 부를 수 있지만, 도구 정의가 모든 요청에 실린다. §7 에서 `keeper_tool_search` 로 위키 도구를 찾은 횟수를 같이 세어 다시 정한다.
- **목차는 dynamic context 에 둔다.** 목차는 페이지가 바뀔 때만 바뀌지만, 공유 기억 단락과 같은 성격의 정보라서 한곳에서 보이게 한다.

## 9. 구현 순서

이 RFC 와 구현을 한 스택으로 올린다.

1. 프롬프트 이름 여섯 개(`config/prompts/keeper.md`, `Prompt_names`), `Keeper_wiki_contents`, `format_wiki_observation`, dynamic context 에 붙이는 자리, 스위치(D6)와 그 레지스트리 행, §7 의 단위 테스트.
2. 배포 뒤 §7 의 둘째 회차 결과를 이 RFC 에 덧붙인다.

## 10. 확신도

- 문제(§2, §3): 높음. metrics, 프롬프트, 도구 정의, 라이브 위키 폴더를 직접 읽었다.
- "목차가 없어서 읽지 않는다" 는 원인: 중간. 사례 하나와 Keeper 들의 진술이 근거다. 측정으로 확인한다.
- 설계: 중간. 공유 기억 단락이 이미 쓰는 모양을 그대로 따른다. 목차를 보고 Keeper 가 실제로 읽는지는 배포 뒤에야 안다.
