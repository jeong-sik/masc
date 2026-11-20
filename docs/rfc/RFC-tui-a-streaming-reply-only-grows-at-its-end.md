---
rfc: "tui-a-streaming-reply-only-grows-at-its-end"
title: "스트리밍 중인 답은 뒤에만 붙는 글로 다룬다"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: claude
related: ["tui-a-long-reply-opens-from-its-last-blocks"]
---

# 스트리밍 중인 답은 뒤에만 붙는 글로 다룬다

- 코드 좌표는 `origin/main` `5bd9a7715260` 에서 읽었다.
- 측정은 그 main 에 열린 PR #54169(스트리밍 frame 이 닫힌 행을 복사하지 않음)를 얹은 가지에서 했다.
- #54169 가 병합되기 전에는 이 글의 구현 단계를 시작하지 않는다.

## 0. 결정

- 스트리밍 중인 글 한 토막(`Node_text`)은 뒤에만 붙는다. 이것을 타입으로 드러낸다.
  - 새 모듈 `Masc_tui_growing_text` 가 토막의 글을 갖는다. 바꾸는 함수는 `append` 하나뿐이다.
  - 끝난 줄(마지막 `\n` 까지)은 받을 때 한 번만 화면용으로 바꾼다(`terminal_safe_text`). 그 MD5 도 그때 이어서 계산한다.
  - 아직 끝나지 않은 줄 하나만 frame 마다 다시 바꾼다.
- frame 은 끝난 줄을 다시 훑지 않는다.
  - 화면용 변환, MD5, 렌더 캐시의 앞부분 비교가 끝나지 않은 줄 길이만큼으로 준다.
  - 본문 identity 는 지금과 같은 값이다. 같은 byte 면 같은 MD5 다. 그래서 위치(`Body_byte`)의 뜻이 바뀌지 않는다.
- frame 마다 1MB 본문 문자열을 새로 만드는 일(`Buffer.contents`)과 행 목록 복사는 이 글에서 없애지 않는다. §6 에 다음 단계로 적는다.

## 1. 지금

- 글 조각은 `trail_text`(`bin/masc_tui_keeper_chat_transcript.ml:626`)가 받는다. 같은 토막이면 `Buffer.add_string` 으로 뒤에 붙인다(628행).
  - 토막의 buffer 를 바꾸는 곳은 이 한 줄뿐이다. `Buffer.clear` 는 모두 다른 buffer 에 쓴다(609·617·1780·1844행).
  - 토막을 읽는 곳도 transcript walk 한 곳뿐이다(830행).
- walk 는 delta 가 올 때마다 돈다. 그때마다 토막 전체를 다시 만든다(832행).
  - `Buffer.contents buffer` 로 1MB 를 복사한다.
  - `safe_block`(`terminal_safe_text ~preserve_newlines:true`, `bin/masc_tui_keeper_chat_projection.ml:287`)이 1MB 를 두 번 훑는다. `passes_unchanged` 한 번, `escape_invisible` 한 번이다.
- 그 본문을 frame 이 또 두 번 훑는다.
  - live edge 의 원문 위치를 읽으려고 `Search.body_identity`(`bin/masc_tui_chat_search.ml:20`)가 1MB 의 MD5 를 계산한다. 기억은 물리적으로 같은 문자열에만 맞으니 스트리밍 중에는 매번 빗나간다.
  - `Markdown_render_cache.render_growing` 이 `String.starts_with ~prefix:old text` 로 1MB 를 byte 하나씩 비교한다(`bin/masc_tui_markdown_render_cache.ml:241` 부근).
- 측정(macOS M3 Max, 1MB 답 스트리밍 1500 frame, frame 마다 delta 하나, `test_tui_chat_search_projection` 의 stream bench, 2026-11-21):
  - frame 중앙값 8.41~8.71ms.
  - `/usr/bin/sample` 10초, UI thread 7138 sample 중 상위:

    | 함수 | sample | 비율 |
    |---|---|---|
    | `caml_MD5Transform`(`body_identity`) | 1101 | 15.4% |
    | `passes_unchanged` 의 `scan`(`safe_block`) | 820 | 11.5% |
    | `String.starts_with` 의 `aux`(`render_growing`) | 671 | 9.4% |
    | `escape_invisible` 의 `loop`(`safe_block`) | 451 | 6.3% |
    | GC(`pool_sweep`·`do_some_marking`·`oldify_*`·`caml_shared_try_alloc`·`caml_modify`) | 약 2100 | 약 30% |

  - 위 넷이 같은 1MB 를 frame 마다 다시 읽는 데 쓰는 몫이고, 합쳐서 약 42% 다.

## 2. 기대는 성질

- **토막은 뒤에만 붙는다.** 위 §1 대로 지금 코드가 이미 그렇다. 이 글은 그것을 타입으로 굳힌다.
- **화면용 변환은 줄 끝에서 나눠도 같다.** `a` 가 `\n` 으로 끝나면 `safe (a ^ b) = safe a ^ safe b` 다.
  - `escape_invisible` 은 앞뒤 scalar 를 본다. ZWJ 는 다음 scalar 를, variation selector 는 앞 scalar 를, 깃발 tag 는 뒤의 tag 들을 본다(`lib/tui_terminal_text.ml:125`).
  - `\n` 은 이 문맥을 끊는다. `\n` 은 emoji 가 아니고, tag 를 읽는 쪽은 `\n` 에서 멈춘다.
  - 무작위 검사로 확인했다. ZWJ·깃발 tag·selector·피부색·깨진 UTF-8·제어 문자·결합 문자를 섞은 글 20만 개를 만들었다. 모든 `\n` 바로 뒤에서 나눈 103,436 경우에서 어긋남이 0 이었다. 구현 PR 은 이것을 시험으로 남긴다(§5).
- **MD5 는 이어서 계산할 수 있다.** `digestif` 가 이미 의존성에 있다(`masc.opam:69`).
  - `Digestif.MD5.feed_string` 은 값을 바꾸지 않고 새 context 를 돌려준다. `feed (feed t a) b = feed t (a ^ b)` 다.
  - 그래서 끝난 줄까지의 context 에 끝나지 않은 줄만 먹이면 `Digest.string body` 와 같은 16 byte 가 나온다.
- **위치는 지금과 같은 일을 한다.** identity 값이 같으니 `Body_byte {body; offset}` 를 만드는 곳·찾는 곳이 바뀌지 않는다.
  - 붙잡은 점이 스트리밍 다음 frame 에서 빗나가는 지금 동작(identity 가 frame 마다 바뀜)도 그대로다. 이것을 고치는 일은 이 글의 범위가 아니다.

## 3. 설계

### 3.1 `Masc_tui_growing_text`

```ocaml
type t                                  (* 한 토막. 뒤에만 붙는다 *)
val create : unit -> t
val append : t -> string -> unit        (* 받은 delta *)
type snapshot = private {
  text : string;                        (* 화면용 본문 전체 *)
  closed : int;                         (* text 의 앞 [closed] byte 는 이 토막에서 다시 바뀌지 않는다 *)
  identity : Digest.t;                  (* = Digest.string text *)
  stretch : int;                        (* 토막 번호 *)
}
val snapshot : t -> snapshot
```

- 안에는 셋을 둔다.
  - 끝난 줄의 화면용 글 `closed_text : Buffer.t`.
  - 그 MD5 context `closed_md5 : Digestif.MD5.ctx`.
  - 아직 끝나지 않은 원래 byte `open_line : Buffer.t`.
- `append` 는 delta 를 `open_line` 에 붙인다. 그 안의 마지막 `\n` 까지를 화면용으로 바꿔 `closed_text` 에 붙이고 `closed_md5` 에 먹인다. 남은 byte 만 `open_line` 에 둔다.
  - UTF-8 이 delta 사이에서 끊겨도 된다. 끊긴 sequence 는 줄이 끝날 때까지 `open_line` 에 원래 byte 로 남는다.
- `snapshot` 은 끝나지 않은 줄 하나만 화면용으로 바꾼다.
  - `text = Buffer.contents closed_text ^ safe open_line` 다.
  - `identity = MD5.get (feed closed_md5 (safe open_line))` 다.
  - 원래 byte 의 사본은 두지 않는다. walk 말고 토막을 읽는 곳이 없기 때문이다(§1).

### 3.2 토막과 walk

- `Node_text of int * float * Buffer.t * int option` 의 `Buffer.t` 를 `Masc_tui_growing_text.t` 로 바꾼다.
- `trail_text` 는 `Buffer.add_string` 대신 `Growing_text.append` 를 부른다.
- walk(830행)는 `safe_block (Buffer.contents buffer)` 대신 `Growing_text.snapshot` 을 쓴다.
- 만든 entry 의 `markdown_source = Markdown_growing {...}` 에 snapshot 의 `closed`·`identity`·`stretch` 를 싣는다.

### 3.3 렌더 캐시

- `growing_markdown_identity`(`bin/masc_tui_render_chat.ml:245`)에 `stretch` 를 넣는다. 같은 자리에 다른 토막이 오면 다른 key 다.
- `render_growing` 은 지난 frame 의 `closed` 를 기억한다.
  - 같은 key 의 새 글은 앞 `min(지난 closed, 새 closed)` byte 가 같다. 같은 토막이고 그 byte 는 다시 바뀌지 않기 때문이다.
  - 그래서 그 뒤 구간만 비교한다. 지금의 `starts_with` 1MB 비교가 끝나지 않은 줄 길이로 준다.
- 이 약속을 받는 입구는 snapshot 을 받는 함수 하나로 둔다. 그냥 문자열을 받는 지금 입구는 지금처럼 전체를 비교한다.

### 3.4 본문 identity

- `Search.body_identity` 를 부르는 곳(`entry_block_reads`, `bin/masc_tui_render_chat.ml:4482`)은 entry 가 `Markdown_growing` 이면 실린 `identity` 를 쓴다.
- 값은 `Digest.string entry.body` 와 같다. 다른 domain(/find worker, #54043)이 읽어도 된다. 미리 계산된 값이고 `Lazy` 가 아니기 때문이다.

## 4. 하지 않는 것

- 끝난 답의 본문(`Drawn_reply (safe_block reply_text)`, transcript 2750~2776행)은 바꾸지 않는다. 기록된 답에서 한 번 만든다.
- 붙잡은 점이 스트리밍 frame 을 넘어 살아남게 하는 일은 하지 않는다. 지금 그 시험도 없다. 따로 다룬다.
- thinking 글은 다루지 않는다. 같은 방법을 쓸 수 있지만 측정한 비용이 아니다.

## 5. 확인 방법

목표는 구현 전에 정해 둔다. 에이전트가 바꾸지 않는다.

- **성능.** 같은 stream bench(1MB, 1500 frame, delta 하나씩)에서 frame 중앙값이 5.0ms 이하다.
  - 근거: §1 의 42% 를 걷어내면 8.4ms × 0.58 ≈ 4.9ms 다.
  - `sample` 에서 `caml_MD5Transform`·`passes_unchanged`·`escape_invisible`·`String.starts_with` 가 각각 1% 아래다.
- **같은 글.** 시험이 다음을 확인한다.
  - 무작위 글을 무작위 위치(UTF-8 중간 포함)에서 delta 로 나눠 `append` 한다. 매번 `snapshot.text = safe_block (지금까지 받은 byte 전체)` 다.
  - 매번 `snapshot.identity = Digest.string snapshot.text` 다.
  - `snapshot.text` 의 앞 `closed` byte 는 그 뒤 모든 snapshot 의 앞 `closed` byte 와 같다.
  - `\n` 바로 뒤에서 나눈 `safe (a ^ b) = safe a ^ safe b`(§2 의 무작위 검사)를 시험으로 둔다.
  - 렌더 캐시가 snapshot 으로 그린 행과 블록 표가 글 전체를 한 번에 그린 것과 같다(`assert_incremental_matches_full` 에 snapshot 입구를 더한다).
- **변이.** 아래가 각각 시험에서 실패해야 한다.
  - 마지막 `\n` 대신 delta 끝까지 닫기.
  - 끝난 줄을 MD5 에 두 번 먹이기.
  - 렌더 캐시 key 에서 `stretch` 빼기. 같은 자리에 다른 토막이 오는 시험이 실패해야 한다.
  - `snapshot` 이 끝나지 않은 줄을 화면용으로 바꾸지 않기.

## 6. 다음 단계

- §0 에서 남긴 frame 마다의 복사는 `sample` 의 GC 몫(약 30%)과 #54169 가 남긴 할당의 대부분이다.
  - 1MB 본문 문자열 하나.
  - 닫힌 행 목록 한 벌, `lines`·`drawn` 배열, `Array.to_list` 한 벌, 블록 표 한 벌.
- 이것을 없애려면 본문과 행을 「닫힌 부분 + 열린 꼬리」로 나눠 넘겨야 한다. `entry.body : string` 을 읽는 곳이 검색·복사·배치에 걸쳐 많다. 그래서 따로 RFC 를 쓴다.
- #54145(긴 답은 화면에 닿는 끝 블록부터 그린다)와 겹친다. 그 RFC 의 블록 표가 닫힌 부분의 경계가 된다.

## 7. 단계

1. `Masc_tui_growing_text` 와 시험(§5 의 같은 글·변이). → 확인: 새 시험 통과, 변이 넷 실패.
2. 토막·walk 를 바꾼다(§3.2). → 확인: transcript 시험 전부, `test_tui_chat_search_projection` 통과.
3. 렌더 캐시 입구와 identity(§3.3·§3.4). → 확인: §5 성능 목표, render cache 시험 통과.
