---
rfc: "0502"
title: "제목 줄은 값으로 만들고 연결 배지는 그리는 쪽이 붙인다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC-0502 — 제목 줄은 값으로 만들고 연결 배지는 그리는 쪽이 붙인다

## 0. 요약

- 좁은 터미널에서 제목 줄 끝의 연결 배지(`HTTP [connected]`)가 잘린다. 제목 줄 67줄을 읽었더니 5줄이 잘렸고(화면 4개), 6줄은 배지가 없다(화면 2개)(1.1).
- 배지가 줄 끝에 있는 까닭은 `[workspace mismatch]`(서버가 다른 워크스페이스를 본다)를 어느 화면에서나 말하려는 것이다. 줄이 모자라면 프레임이 줄 끝을 자르므로 이 경고가 가장 먼저 잘린다(1.2).
- 같은 원인을 네 번 고쳤다. 도구가 셋이다: `detail_heading`(#39712), `badge_row`(#44368), `compact_connection_badge`(#47384). #49045 는 `detail_heading` 을 한 번 더 불렀다(1.3). 화면 하나를 고치면 다음 화면이 남는다.
- `connection_badge state` 는 55줄(14개 파일)에서 불린다. 14줄은 라벨 인자로 넘기고, 36줄은 화면이 제목 문자열에 직접 이어 붙인다(1.4).
- 제안: 제목 줄을 `heading` 값으로 만든다. `heading` 에는 배지 칸이 없다. 배지는 `heading` 을 그리는 함수가 `state` 에서 만들어 줄 끝에 붙인다. 마지막 층에서 `connection_badge` 를 `.mli` 에서 지운다.
- 줄이 모자랄 때의 순서는 지금 `detail_heading` 이 정한 그대로다. 이 RFC 는 순서를 바꾸지 않는다. 순서를 거치지 않고 지나가는 길을 막는다.

## 1. 지금

### 1.1 잘리는 줄과 배지가 없는 줄

main 증명 빌드(`6ad837c7cac`, run 42154515127)를 시험용 서버에 붙여 두 가지를 읽었다.

- 14화면 순회를 64x30 과 56x30 으로 읽었다(28줄).
- 상세 화면 16곳을 64x30, 56x30, 72x30 으로 읽었다(48장). 제목 줄이 `MASC` 로 시작하지 않는 3곳(9장)은 세지 않았다. 남는 것이 39줄이다.

제목 줄은 화면 위쪽 여섯 줄 중 `MASC` 가 든 첫 줄이다. 배지가 `[낱말]` 로 끝나면 온전, `[` 뒤에 `]` 가 없거나 `…` 로 끝나면 잘림, 둘 다 아니면 없음으로 셌다. 시계는 `hh:mm:ss` 로 가렸다.

| 읽은 곳 | 제목 줄 | 배지 |
| --- | --- | --- |
| Memory, 64x30 | `MASC 메모리 · 키퍼 3명 · 기억 필요 0 · 11/06 12:36 관측  HTT…` | 잘림 |
| Memory, 56x30 | `MASC 메모리 · 키퍼 3명 · 기억 필요 0 · 11/06 12:38  …` | 통째로 잘림 |
| Fusion 목록, 56x30 | `MASC Fusion (0 runs · 0 done)  hh:mm:ss  HTTP [conne…` | 잘림 |
| Artifacts / Resources, 56x30 | `MASC Artifacts / Resources  hh:mm:ss  HTTP [connecte…` | 잘림 |
| Workspace, 56x30 | `MASC Workspace (0)  hh:mm:ss  HTTP [connected] · ref…` | 진행 글만 잘림 |
| Board 글 상세, 세 크기 모두 | `MASC Board  [p-7…2dbb499d]  #verification   0  💬0` | 없음 |
| Task 검토 상세, 세 크기 모두 | `MASC 작업  목표  ▸작업 검토·1  작업 판정 ▸ details  task-002` | 없음 |

읽은 67줄 중 배지가 온전한 곳은 56줄이다. 잘린 곳은 5줄(화면 4개)이고, 배지가 없는 곳은 6줄(화면 2개)이다. 배지가 없는 두 화면은 세 크기 모두에서 화면 어디에도 `HTTP [` 가 없다.

이 빌드 뒤 main(`059ffb7d3e7`)까지 `bin/` 파일 13개가 바뀌었지만 `connection_badge`, `screen_title`, `detail_heading`, `surface_chrome`, `runtime_substrate_heading`, `pane_surface_title` 를 건드린 줄은 0줄이다(`git diff` 로 센 값). 이 RFC 의 줄 수와 함수 이름은 `059ffb7d3e7` 기준이다.

이 읽기가 못 보는 것이 둘 있다. 시험용 서버의 `HTTP [connected]`(16칸)만 읽었고 긴 배지는 읽지 않았다. 사용자 터미널의 열 수 분포도 재지 않았다.

### 1.2 배지가 줄 끝에 있는 까닭과 폭

코드 주석 둘이 같은 말을 한다.

- `refresh_progress_badge` 위: 모든 화면 머리가 이 배지로 끝나서, 서버가 같이 쓰지 않는 워크스페이스를 어느 화면에서나 말한다.
- `detail_heading` 위: 워크스페이스 불일치는 배지만 말하고 화면의 다른 곳은 말하지 않는다.

`connection_badge` 가 돌려주는 글은 네 토막을 잇는다.

- `[events lost] ` — 이벤트 피드가 원천에서 이벤트를 잃었다고 알렸을 때.
- `HTTP [connected]`, `HTTP [partial]`, `HTTP [loading...]`, `HTTP [server booting...]`, `HTTP [refresh failed]` 중 하나.
- ` [workspace mismatch]` 또는 ` [workspace unconfirmed]` — 워크스페이스가 다르거나 확인되지 않았을 때.
- 진행 글 — ` · reading workspace`, ` · partial: … failed; … received +N` 같은 글. 길이가 정해져 있지 않다.

앞의 세 토막이 겹치면 배지만으로 줄보다 넓다.

- `[events lost] `(14칸) + `HTTP [refresh failed]`(21칸) + ` [workspace mismatch]`(21칸)은 56칸이다. 꼬리 앞 틈 2칸을 더하면 58칸이다.
- 줄 폭은 열 수에서 2칸을 뺀 값이다. 56열은 54칸이고 60열은 58칸이다. 진행 글은 이 뒤에 더 붙는다.
- 이 값은 캡처가 아니라 코드에 적힌 글의 칸 수를 센 것이다.
- 이때 `detail_heading` 은 꼬리를 줄이지 않고 lead·id·`after` 를 0칸으로 만든다. 남은 꼬리를 프레임이 끝에서 자르면 진행 글과 `[workspace mismatch]` 가 잘린다. 이 마지막 단계는 코드를 읽고 낸 추론이고 캡처로 확인하지 않았다.

### 1.3 같은 원인을 네 번 고쳤다

| 도구 | 들어온 PR | 줄이 모자랄 때 | 쓰는 화면 |
| --- | --- | --- | --- |
| `detail_heading ~tail` | #39712 | 배지는 그대로. `after` 조각을 끝에서부터 통째로 빼고, id 를 접고, 마지막에 lead 를 자른다 | Activity, Memory 사실 목록, Fusion 상세, Lanes 의 run 목록·상세, Runtime 상세, Repositories 셋, Harness 상세, Diff |
| `badge_row` | #44368 | 배지는 그대로. label 을 `…` 로 자른다 | Dashboard 머리 |
| `compact_connection_badge ~width` | #47384 | 배지를 짧은 말로 바꾼다(`WS mismatch`, `mismatch`). 긴 글은 본문에 둔다 | Usage |
| `runtime_substrate_heading` | #49045 | `detail_heading` 을 부른다 | Runtime, Features, Clients |

한 화면 무리를 고칠 때마다 도구를 새로 고르거나 기존 도구에 옮겨 붙였고, 옮기지 않은 화면은 그대로 남았다. Fusion 은 상세 줄이 `detail_heading` 으로, 목록 줄이 손으로 이은 문자열로 그려진다. 같은 Fusion 화면 안에서 길이 둘이다.

### 1.4 화면이 직접 이어 붙이는 곳

`connection_badge state` 는 `bin/` 의 55줄에서 불린다. 스크립트로 줄이 든 정의 하나의 글을 훑어 갈랐다(파서가 아니라서 "읽어 볼 곳"을 가리킨다).

| 무리 | 줄 | 뜻 |
| --- | ---: | --- |
| 라벨 인자(`~tail`·`~badge`)로 넘김 | 14 | 배지가 줄 끝에 온전히 남는 도구를 거친다 |
| 화면이 `box_line` 으로 직접 그리는 머리 줄 | 19 | 제목 문자열에 배지를 이어 붙인다 |
| `surface_chrome ~title` 에 문자열로 넘김 | 16 | 위와 같고 프레임이 줄 끝을 자른다 |
| 공용 제목 함수 | 2 | `pane_surface_title`(Code, Resources), `config_pane_title`(Config) |
| 배지 함수의 가족 | 3 | `usage_connection_badge`, `compact_connection_badge`, `coordinator_status_row` |
| 분류 못 함 | 1 | `system_logs_status` |

이어 붙이는 36줄(19 + 16 + 1)과 공용 제목 함수 2곳이 이 RFC 의 대상이다. 1.1 에서 잘린 네 화면은 세 무리에 모두 있다: Memory 와 Workspace 목록은 `surface_chrome ~title`, Fusion 목록은 직접 그리는 줄, Resources 는 공용 제목 함수다.

## 2. 제안

### 2.1 제목 줄은 값이다

```ocaml
(* masc_tui_render_prim.mli *)
type heading =
  { lead : Masc_tui_ansi.heading_lead  (* 화면 이름, 탭 줄 *)
  ; id : string                        (* 화면이 한 기록을 가리키면 그 id, 아니면 "" *)
  ; after : string list                (* 읽은 시각, 개수, 필터. 모자라면 끝에서부터 통째로 빠진다 *)
  }

val heading_row : Masc_tui_types.state -> cols:int -> heading -> string
(** [Masc_tui_ansi.detail_heading] 로 한 줄을 그린다. 꼬리는 [state] 에서 만든 배지다. *)
```

`heading` 에는 배지 칸도 꼬리 칸도 없다. 화면은 배지를 문자열로 받을 길이 없다. 줄이 모자랄 때의 순서는 `detail_heading` 의 순서 그대로다(id 접기, `after` 끝에서부터 빼기, lead 자르기).

### 2.2 화면용 chrome 과 덮개용 chrome 을 나눈다

`surface_chrome` 은 이미 `state` 와 `cols` 를 받고, `?frame` 으로 화면 전체(`Chrome_screen`)와 덮개(`Chrome_overlay`)를 가른다. 화면용을 새 함수로 나눈다.

```ocaml
val screen_chrome :
  ... -> heading:heading -> hints:... -> body:... -> ...
```

- `screen_chrome` 은 `~title:string` 대신 `~heading` 을 받는다. 화면은 배지 없는 제목 줄을 고를 수 없다.
- 화면용 호출이 모두 옮겨 가면 `surface_chrome` 에서 `Chrome_screen` 갈래를 지운다. 덮개 호출(`~frame:Chrome_overlay`)은 문자열 제목 그대로 남는다.
- 화면이 `surface_chrome` 을 안 거치고 `box_line` 으로 머리 줄을 직접 그리는 곳(19줄)은 `box_line buf cols (heading_row state ~cols heading)` 를 쓴다.

### 2.3 옮기는 순서와 끝

- 층마다 화면 무리 하나를 `heading` 으로 옮긴다. 옮기는 층은 그 화면들을 64x30 과 56x30 으로 읽은 앞뒤 캡처를 붙인다.
- 중간에는 옛 길과 새 길이 같이 있다. 저장하는 데이터가 없어서 옛 형식을 읽는 코드나 변환 코드는 만들지 않는다.
- 마지막 층에서 `connection_badge` 와 `usage_connection_badge` 를 `.mli` 에서 빼고, 부르는 곳이 없어진 함수는 그 층에서 지운다. 남은 사용처는 컴파일러가 알려 준다.

### 2.4 시계

시계를 꼬리에 두는 화면(Activity)과 `after` 조각으로 두는 화면(Runtime·Features·Clients 의 읽은 시각)이 섞여 있다. 시계는 줄이 모자라면 빠져도 되고 배지는 안 된다. 시계를 `after` 의 마지막 조각으로 통일하자고 제안한다. 열린 질문 3 이다.

### 2.5 시험

화면 배치를 확인하는 시험은 더하지 않는다(`docs/constitution.xml` 354~355줄). 막는 것은 타입이다. `heading` 에 배지를 넣을 칸이 없고, `screen_chrome` 은 `heading` 만 받는다. 줄이 모자랄 때 어떤 조각이 남는지는 이미 `test_tui_detail_heading` 이 본다.

### 2.6 왜 이 모양인가

장점

- 배지를 자를 수 있는 길이 없어진다. 화면은 배지를 문자열로 만지지 않고, 줄이 모자랄 때의 규칙은 `detail_heading` 한 곳에 있다.
- 배지가 없던 화면(1.1 의 두 곳)도 `screen_chrome` 으로 옮기면 배지가 생긴다.
- 새 화면이 `screen_chrome` 을 쓰면 `heading` 을 만들어야 하고, 배지를 빼먹을 수 없다.

단점

- 층이 많다. 36곳, 14개 파일이고 층은 열 개쯤이다.
- 화면마다 제목 글을 `lead`, `id`, `after` 로 가르는 판단이 든다. 지금은 문자열 하나다.
- `box_line` 으로 머리 줄을 직접 그리는 화면(19곳)은 `heading_row` 를 안 부르고 배지 없는 문자열을 그릴 수 있다. 배지를 문자열로 이어 붙이는 길은 막히지만 배지를 빼는 길은 타입이 못 막는다.
- Board 글 상세와 Task 검토 상세에 배지가 생긴다. 줄이 모자라면 `after` 가 먼저 빠진다. 지금 이 두 화면이 배지를 빼는 것이 뜻이었는지는 코드에서 확인하지 못했다.
- 배지 자체가 줄보다 넓은 경우(1.2 의 산술)는 풀지 못한다. 열린 질문 4 이다.
- 덮개 쪽에는 `surface_chrome` 이 남는다.

## 3. 대안

| | 하는 일 | 장점 | 단점 |
| --- | --- | --- | --- |
| A | 잘리는 네 화면만 `detail_heading` 으로 옮긴다(#49045 와 같은 방식) | 층이 네 개이고 빨리 끝난다 | 같은 원인의 다섯 번째 고침이다. 나머지 이어 붙인 곳과 새 화면이 같은 길로 간다. 배지 없는 두 화면은 그대로다 |
| B | CI 에서 `connection_badge state` 글자를 막는다 | 바뀌는 줄이 적다 | 글자 검사다. 다른 이름으로 감싸면 지나간다. 잘림이 아니라 이름을 막는다 |
| C | 프레임이 줄 끝의 `[…]` 를 알아보고 자르지 않는다 | 화면을 안 고친다 | 글자 모양으로 배지를 알아보는 분류기다. 색 코드 사이에서 괄호를 찾아야 하고, Board 글 id `[p-7…2dbb499d]` 도 걸린다 |
| D | 배지만 추상 타입 `Badge.t` 로 만들고 제목은 문자열로 둔다 | 바뀌는 곳이 적다 | 제목에 붙일 때 문자열이 필요해서 `Badge.to_string` 이 생긴다. 배지를 빼먹는 화면(1.1 의 두 곳)은 못 막는다 |

## 4. 바뀌는 것과 하지 않는 것

바뀌는 것

- `masc_tui_render_prim.ml`·`.mli`: `heading`, `heading_row`, `screen_chrome`. 마지막 층에서 `connection_badge`·`usage_connection_badge` 를 지운다.
- 제목 줄을 그리는 화면 파일 14개의 36곳과 공용 제목 함수 2곳.
- 사용자에게 보이는 것: 잘리던 5줄이 온전해지고, 배지가 없던 두 화면에 배지가 생긴다.

하지 않는 것

- 줄이 모자랄 때의 순서와 배지 글(`[connected]`, `[workspace mismatch]`)과 색.
- 본문, 푸터, 키.
- 화면 배치 시험.
- Usage 의 짧은 말 배지(`compact_connection_badge`)는 옮기지 않는다. 열린 질문 4 가 정한 뒤에 한다.

## 5. 층

1. `heading`·`heading_row`·`screen_chrome` 과 Memory(2곳). 확인: Memory 를 64x30·56x30 으로 읽은 앞뒤 캡처.
2. Fusion 목록(2곳).
3. Code·Resources(`pane_surface_title`).
4. Keepers(4곳).
5. Lanes(Clients 를 포함한 3곳).
6. Runtime(6곳 중 Usage 넷을 뺀 둘).
7. Verification(6곳).
8. Work(3곳), Board(2곳), Connectors(2곳), Approvals(1곳), Chat(1곳), Activity(2곳), Repositories 목록(Workspace 화면, 2곳).
9. 배지가 없는 Board 글 상세와 Task 검토 상세.
10. 마지막: `connection_badge`·`usage_connection_badge` 를 `.mli` 에서 빼고 `Chrome_screen` 갈래를 지운다.

층 수와 묶음은 파일 단위 추정이다. 층 1 을 만들 때 36곳의 `lead`·`id`·`after` 나눔을 표로 먼저 낸다.

## 6. 열린 질문

1. 방향. 이 RFC(열 층쯤)와 A(잘리는 네 화면만 고치기) 중 어느 쪽인가. 이 RFC 를 제안한다. 같은 원인의 다섯 번째 고침이고, 배지가 없는 화면이 둘 있기 때문이다.
2. chrome 을 화면용과 덮개용으로 나눌지, `title` 을 변형 타입(`Heading` 과 `Plain`)으로 둘지. 나누기를 제안한다. 변형 타입은 화면이 `Plain` 을 골라 배지를 빼는 길을 열어 둔다.
3. 시계를 `after` 의 마지막 조각으로 통일할지, 꼬리에 둘지. Activity 는 지금 꼬리에 두므로 `after` 로 옮기면 Activity 의 시계가 줄이 모자랄 때 빠진다.
4. 배지 자체가 줄보다 넓은 경우. Usage 의 `compact_connection_badge` 처럼 짧은 말로 바꾸는 규칙을 `heading_row` 에 넣을지, 이 RFC 밖에서 따로 할지. 넣으면 `detail_heading` 의 "꼬리는 줄이지 않는다"는 규칙이 "꼬리는 더 짧은 완전한 말로 바뀐다"로 바뀐다.
5. Config 창 제목(pane 읽기 상태와 pane 이름이 파일 경로보다 먼저 빠진다)과 Dashboard 머리(workspace 이름이 온전해야 하는 PTY 시나리오가 있다)는 `detail_heading` 을 안 거치고 자기 배치를 가진다(`detail_heading` 주석). `heading` 으로 같은 배치를 낼 수 있는지 층 1 에서 확인해야 한다. 안 되면 둘은 이 RFC 에서 뺀다.
