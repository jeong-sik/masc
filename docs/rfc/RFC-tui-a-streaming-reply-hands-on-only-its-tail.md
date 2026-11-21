---
rfc: "tui-a-streaming-reply-hands-on-only-its-tail"
title: "스트리밍 답은 frame 마다 꼬리만 넘긴다"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: claude
related: ["tui-a-streaming-reply-only-grows-at-its-end", "tui-a-long-reply-opens-from-its-last-blocks"]
---

# 스트리밍 답은 frame 마다 꼬리만 넘긴다

- 코드 좌표는 `origin/main` `a4f165c39f6a` 에서 읽었다.
- 측정은 그 main 에 Draft #54181(맨 아래 창이 새 답의 행을 한 번만 훑음)을 얹은 가지에서 했다.
- RFC `tui-a-streaming-reply-only-grows-at-its-end`(#54170) §6 이 남긴 다음 단계다.

## 0. 결정

- 렌더 캐시가 닫은 행은 뒤에만 붙는 배열에 쌓는다. 새 모듈 `Masc_tui_closed_rows` 가 이 배열을 갖는다.
  - 읽는 쪽은 배열과 길이를 같이 받는다(`prefix`). 길이 안의 칸은 다시 바뀌지 않는다.
  - 한 frame 이 넘기는 값은 「닫힌 prefix + 꼬리 목록」이다. 꼬리는 아직 끝나지 않은 블록의 행 몇 개다.
- 배치(`Masc_tui_message_layout`)도 같은 모양으로 행을 쌓는다.
  - 닫힌 줄의 행은 한 번만 그려 entry 의 행 배열에 붙인다.
  - frame 마다 그리는 행은 꼬리 줄의 행, 머리 행(시간 줄·띄움·보낸 이), 진단 행뿐이다.
- 맨 아래 창은 행을 세지 않고 길이를 읽는다. 끝에서 화면 한 장만 index 로 꺼낸다.
- 밖으로 내는 `rows_of_entry : ... -> row list` 는 그대로 둔다. /find 와 시험이 쓴다.
- snapshot 이 frame 마다 1MB 본문 문자열을 만드는 일은 이 글에서 없애지 않는다. §6 에 둔다.

## 1. 지금

1MB 답이 스트리밍될 때 한 frame 은 닫힌 행을 여러 번 새로 만든다.

| | 위치 | 하는 일 | frame 당 할당 몫 |
|---|---|---|---|
| 1 | `bin/masc_tui_markdown_render_cache.ml:270·274` | newest-first 목록을 `List.rev_append` 로 읽는 순서로 다시 만든다 | 27% |
| 2 | `bin/masc_tui_markdown_render_cache.ml:281` | 블록 표를 `Array.init` 로 다시 만든다 | 7.5% |
| 3 | `bin/masc_tui_message_layout.ml:2437` | 줄을 `lines` 배열에 옮긴다 | 9% |
| 4 | `bin/masc_tui_message_layout.ml:2317` | 행 배열 `drawn` 을 만든다. 닫힌 행은 지난 배열에서 꺼낸다 | 9% |
| 5 | `bin/masc_tui_message_layout.ml:2327` | `drawn` 을 `Array.to_list` 로 목록으로 바꾼다 | 27% |
| 6 | `bin/masc_tui_growing_text.ml:38` | snapshot 이 닫힌 글 1MB 를 복사한다 | 16% |

닫힌 줄 전부를 지나는 훑기도 남아 있다.

- `find_kept_rows` 가 줄 목록을 `List.equal` 로 비교한다(`message_layout.ml:2365`). 끝에 가서야 다르다.
- `last_content`(2419행)가 내용 있는 마지막 줄을 찾는다.
- `shared_lines`(2290행)가 지난 줄 배열과 줄마다 비교한다.
- 맨 아래 창(2705행)이 행을 세고 끝을 고른다. #54181 이 다섯 번을 두 번으로 줄였다.

측정(macOS M3 Max, `test_tui_chat_search_projection` 안 stream bench: 1MB 답, 1500 frame, frame 마다 delta 하나, 2026-11-21):

- 할당은 frame 당 약 865k words 다(`MASC_TUI_ALLOC_PROFILE`, 1.30G words / 1501 frame). 위 표의 몫이 이 할당을 나눈 것이다.
- `sample` 10초에서 GC(`do_some_marking`, `pool_sweep`, `oldify_one`, `caml_modify` 등)가 맨 위 표본의 약 74% 다(5,699 중 4,219).
- frame 중앙값은 #54181 가지에서 5.65~6.72ms, main 에서 6.09~8.30ms 다. 기계 load average 가 100 을 넘어 흔들렸다.
- frame 비용은 답 크기에 거의 비례한다. #54174 의 측정에서 30KB 0.18ms, 300KB 1.72ms, 1MB 6.5ms 였다.
- 가장 느린 frame 은 12.8~18.8ms 다. GC 가 몰린 frame 이다.

## 2. 기대는 성질

- 렌더 캐시의 같은 key 에서, 한 frame 이 닫은 행은 그 뒤 frame 에서 같은 index 에 같은 문자열로 남는다.
  - RFC #54170 의 약속(앞 `closed` byte 는 다시 바뀌지 않는다)에서 나온다.
  - 지금 `render_growing` 은 `mutable_row_start` 앞의 행을 다시 그리지 않는다. 그 성질을 그대로 쓴다.
- 배치에서, 닫힌 줄의 행은 entry 모양(`body_shape`), index, 줄이 같으면 같다.
  - 지금 `body_rows_reusing`(2300행)이 이미 이 성질로 행을 다시 쓴다.
  - 단 마지막 행은 다를 수 있다(rail 이 닫힌다). 그래서 뒤에 행이 하나 더 있는 행만 닫힌 배열에 넣는다. 지금 코드도 마지막 index 는 다시 쓰지 않는다.
- 맨 아래 창이 고르는 행과 숨긴 수는 행 목록 전체에서 고른 것과 같다. #54181 의 시험 `a live edge window counts every row it hides` 가 이 답을 지킨다.

## 3. 설계

### 3.1 `Masc_tui_closed_rows`

```ocaml
type 'a t        (* 쓰는 쪽. 렌더 캐시나 배치 기억의 한 칸이 갖는다 *)
type 'a prefix   (* 읽는 쪽. 배열과 길이 *)

val create : unit -> 'a t
val append : 'a t -> 'a -> unit
val prefix : 'a t -> 'a prefix
val length : 'a prefix -> int
val get : 'a prefix -> int -> 'a
val extends : 'a prefix -> kept:'a prefix -> bool
(* 같은 [t] 에서 나왔고 길이가 [kept] 이상이다 *)
val to_list : 'a prefix -> 'a list
```

- 배열이 차면 두 배 크기로 새로 만든다. 지난 prefix 는 옛 배열을 계속 가리킨다. 길이 안의 칸은 옛 배열과 새 배열에서 같다.
- `append` 는 UI domain 만 부른다.
  - 렌더 캐시(`chat_markdown_cache`, `render_chat.ml:80`)와 배치 기억(`Domain.DLS`)은 UI domain 만 쓴다.
  - /find 는 CPU domain 에서 따로 그린다(`search_chat_markdown`, `render_chat.ml:5164`).
- `'a t` 는 렌더 캐시 key(identity·width·theme·palette) 하나마다 하나다. key 가 바뀌면 새로 만든다.
- 메모리는 늘리는 동안 행 배열의 최대 두 배다. 캐시 칸이 밀려나면 같이 놓인다.

### 3.2 렌더 캐시

- `Streaming.growing` 이 `stable_rows_newest_first` 대신 `stable_rows : string Masc_tui_closed_rows.t` 를 갖는다.
- 블록 표도 `(int * int) Masc_tui_closed_rows.t` 로 쌓는다. `growing_blocks` 는 prefix 와 꼬리 블록을 돌려준다.
- markdown 콜백이 돌려주는 값은 합타입이다. `Masc_tui_message_layout` 이 정한다.

```ocaml
type body_lines =
  | Whole of string list
      (* 끝난 답과 스트리밍이 아닌 글. 지금과 같다 *)
  | Grown of { closed : string Masc_tui_closed_rows.prefix; tail : string list }
      (* 스트리밍 답. 닫힌 행과, 이 frame 이 다시 그린 꼬리 *)
```

- 콜백 타입이 `entry:entry -> width:int -> string list` 에서 `-> body_lines` 로 바뀐다. `.mli` 의 서명 여덟 곳이다.
- 저널 줄(`chat_journal_rows`)은 꼬리 뒤에 붙인다.

### 3.3 배치

entry 의 행은 세 부분이다.

```ocaml
type entry_rows = {
  head : row list;                           (* 시간 줄, 띄움, 보낸 이 행 *)
  closed : row Masc_tui_closed_rows.prefix;  (* 닫힌 줄의 행. 한 번만 그린다 *)
  tail : row list;                           (* 꼬리 줄의 행과 진단 행 *)
}
```

- `Whole` 은 처음 배치할 때 행 전부를 `closed` 에 넣고 `tail` 을 비운다. 끝난 답의 창도 index 로 고른다.
- `Grown` 은 지난 frame 의 줄 prefix 를 `extends` 로 확인한다. 새로 닫힌 줄만 행으로 그려 붙인다.
- `find_kept_rows` 의 `List.equal` 은 `Grown` 에서 `extends` 와 꼬리 비교가 된다. 꼬리는 몇 줄이다.
- 내용 있는 마지막 줄(`last_content`)은 닫힌 배열에 붙일 때 같이 기억한다.
- 맨 아래 창(`newest_entry_window`)은 `entry_rows` 를 받는다.
  - 행 수는 `List.length head + length closed + List.length tail` 이다.
  - 끝 행은 `tail` 과 `closed` 끝에서 index 로 꺼낸다.
  - 진단 행은 `tail` 끝에만 있다.
- `body_rows_of_chosen` 은 고른 행의 index 로 body row 를 바로 계산한다.
- 공개 `rows_of_entry` 는 `head @ to_list closed @ tail` 을 돌려준다. 행 값이 같은 값(physical)이라 시험의 identity 비교가 그대로 맞는다.

### 3.4 다른 방법

- **배치 안의 `Array.to_list` 만 없애기.** 1·2·6번이 남는다. 같은 원인(행 전체가 frame 마다 흐름)을 다섯 곳 중 한 곳에서만 고친다.
- **행을 newest-first 목록으로 끝까지 넘기기.** 맨 아래 창에는 맞다. 하지만 렌더러, 검색, 스크롤이 모두 읽는 순서로 다시 뒤집어야 한다.
- **finger tree 같은 일반 rope.** 가운데 끼우기와 자르기가 된다. 이 경로는 뒤에만 붙으니 그 기능이 필요 없고, 코드와 상수 비용만 늘어난다.

## 4. 하지 않는 것

- snapshot 의 1MB 복사(§1 표의 6번, 16%)는 그대로 둔다. bin 에서 `entry.body` 를 읽는 곳이 24곳이다.
- 스크롤해 올라간 frame(`scrolled_rows`)과 줄 수 세기(`total_rows`·`clamp_scroll`)는 모양을 바꾸지 않는다. `entry_rows` 의 길이만 읽게 한다.
- thinking 글과 높이 재기(`measure_growing_details`)는 다루지 않는다. 측정한 비용이 아니다.

## 5. 확인 방법

목표는 구현 전에 정해 둔다. 에이전트가 바꾸지 않는다.

- **할당.** 같은 stream bench 에서 frame 당 할당이 200k words 이하다.
  - 근거: §1 표의 1~5번(약 79%)이 닫힌 행 수에 비례하는 몫이다. 이것이 꼬리 길이에 비례하게 된다.
  - 6번(약 131k words, 1MB 문자열 하나)은 남는다.
- **크기에 매이지 않음.** 시험이 같은 글을 30KB 와 1MB 로 스트리밍하고 frame 마다 센다.
  - 배치가 그린 body 행 수(`body_rows_built`)가 두 크기에서 같다.
  - 렌더 캐시가 새로 만든 행 수가 두 크기에서 같다.
- **시간.** 같은 bench 에서 frame 중앙값이 3.0ms 이하다. load average 가 20 아래일 때 잰다.
  - 근거: 할당이 4분의 1 아래로 주면 GC 몫(74%)도 그만큼 준다고 본다. 5.7ms × (0.26 + 0.74 × 0.25) ≈ 2.5ms 다.
- **같은 화면.**
  - `Grown` 으로 그린 행 목록(`rows_of_entry`)이 같은 글을 `Whole` 로 그린 것과 같다. 무작위 글을 무작위 delta 로 나눠 frame 마다 확인한다.
  - #54181 의 창 시험, `test_tui_message_layout`, `test_tui_chat_search_projection`, 렌더 캐시 시험이 그대로 통과한다.
  - prefix 하나를 들고 1000번 `append` 해도 그 prefix 의 칸이 그대로다. 배열이 몇 번 새로 만들어져도 같다.
- **변이.** 아래가 각각 시험에서 실패해야 한다.
  - 마지막 행도 닫힌 배열에 넣기. rail 이 닫히는 행을 잃는다.
  - `extends` 가 길이만 보고 같은 `t` 인지는 안 보기. 같은 자리에 온 다른 토막이 옛 행을 쓴다.
  - 두 배로 늘릴 때 옛 칸을 복사하지 않기.
  - 창이 `closed` 끝에서 꺼내는 index 를 하나 밀기.

## 6. 다음 단계

- snapshot 의 1MB 복사를 없애려면 `entry.body` 를 「닫힌 글 + 열린 줄」로 나눠야 한다.
- 먼저 `entry.body` 를 읽는 24곳을 쓰임새로 나눈다(검색 원문, 복사, 링크 카드, plain 배치).

## 7. 단계

단계마다 새 가지, 새 PR 이다.

1. `Masc_tui_closed_rows` 와 시험(§5 의 prefix 시험, 셋째 변이). 새 파일 셋과 stanza 하나다.
   → 확인: 새 시험 통과, 변이 실패.
2. 렌더 캐시가 `body_lines` 를 돌려준다(§3.2). 배치는 우선 `Grown` 을 목록으로 펴서 받는다. 약 7파일이다.
   → 확인: 렌더 캐시 시험, `test_tui_message_layout`, `test_tui_chat_search_projection` 통과. 할당 표에서 1·2번이 빠진다.
3. 배치가 `entry_rows` 를 쓴다(§3.3). 약 4파일이다.
   → 확인: §5 의 할당·크기·시간 목표, 같은 화면 시험, 변이 넷.

## 8. 정할 것

- 이 RFC 로 구현을 시작할지 정한다.
  - 1MB 답은 이미 frame 예산(16ms) 안이다.
  - 얻는 것: 더 긴 답에서 frame 이 크기에 매이지 않는다. 가장 느린 frame(12.8~18.8ms)이 GC 와 같이 준다.
  - 잃는 것: 배치에 행 표현이 둘(`Whole`·`Grown`) 생긴다. 새 모듈 하나를 지켜야 한다.
