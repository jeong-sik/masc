---
rfc: "workspace-documents-are-written-together"
title: "Workspace Documents Are Written Together"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: vincent
related: ["workspace-documents-arrive-as-pages-and-text", "workspace-chat-media-renders-where-it-is-written", "workspace-media-and-rich-embed"]
---

# RFC workspace-documents-are-written-together: 사람과 Keeper 여럿이 같은 문서를 함께 쓴다

## 0. 요약

지금 사람은 Dashboard 에서 아티팩트를 읽고, 복사하고, 내려받을 수만 있다. 고칠 수는 없다.
Keeper 는 `keeper_artifact_draft` 로 원고를 고친다. #55387 본문 기준으로 10-28~11-27 에 462번 불렸다.
그 원고의 상태는 Yjs CRDT 다. Yjs 를 다루는 외부 실행 파일 `masc-artifact-document` 의 소스는 11-24 #54560 에서 지워졌다.
이 맥에는 11-02 에 설치한 묶음(`artifact-document.mjs`, 579 KB)이 남아 있어서 도구가 돈다.
새로 설치한 곳에서는 그 실행 파일을 만들 수 없다.

stack #55383~#55387 은 부르는 화면이 없는 원고 HTTP 라우트, 실시간 방, Keeper 편집 위치를 지운다.
이 RFC 는 그 stack 이 병합된 뒤를 전제로, 공동 작성을 처음부터 다시 정한다.

목표는 사람과 Keeper 여럿이 함께 쓰는 리치 문서다.

- 문서는 표·그림·체크리스트·접기 같은 블록으로 이루어진다.
- 여러 Keeper 가 서로 다른 블록을 동시에 고쳐도 부딪히지 않는다.
- 사람이 댓글에서 `@<Keeper>` 를 부르면 그 Keeper 의 queue 에 메시지가 들어간다. Keeper 는 같은 스레드에 답하거나 문서를 고칠 수 있다.

## 1. 결과

- 사람이 Dashboard 에서 원고를 열어 블록 단위로 고친다. Keeper 여럿이 같은 원고를 도구로 고친다.
- 다른 블록을 고친 저장은 서로 건드리지 않는다.
- 같은 블록을 동시에 고치면 그 블록 안에서 3-way 병합한다. 겹치는 줄이 있으면 아무것도 쓰지 않고 양쪽을 돌려준다.
  사람은 화면에서 고르고, Keeper 는 다음 도구 호출에서 고를 수 있다. 조용히 한쪽을 덮어쓰지 않는다.
- 다른 사람이나 Keeper 가 저장하면 열어 둔 Dashboard 화면에 바뀐 블록이 바로 보인다. 블록마다 마지막으로 고친 이가 보인다.
- 댓글 스레드는 블록의 문장에 붙는다.
  - 댓글의 `@<Keeper>` 는 그 Keeper 의 queue 에 일반 메시지로 들어간다.
  - Keeper 는 같은 스레드에 답할 수 있다. 문서를 고치면 그 수정이 어느 스레드에 대한 답인지 기록이 남는다.
- 게시하면 서버가 원고를 Markdown 으로 그려 바뀌지 않는 리비전으로 남긴다.
- DOCX·XLSX·PPTX·PDF 로 내보낸다. HWPX 내보내기는 §4.7 의 확인 결과에 달렸다.
- HWP 원본을 HWP 그대로 고치는 길은 §5 의 별도 트랙이다.

## 2. 무엇이 실제로 동시에 일어나나

동시 편집 방식을 고르기 전에 실제 쓰임을 본다.

- Keeper 의 수정은 도구 호출 단위다. 글자 단위로 타이핑하지 않는다. 한 호출은 「이 블록을 이것으로」나 「이 뒤에 표를 넣는다」다.
- 사람의 수정은 블록 편집을 마칠 때 한 덩어리로 도착한다.
- 여러 Keeper 가 한 문서를 쓰면 보통 절을 나눠 맡는다. 같은 블록을 같은 순간에 고치는 일은 드물다.

수정이 블록 단위의 덩어리로 오므로, 글자 단위 CRDT 가 아니어도 덮어쓰기를 막을 수 있다.
블록마다 리비전을 두면 다른 블록을 고친 저장끼리는 아예 비교하지 않아도 된다.

## 3. 결정: 블록 리비전과 블록 안 3-way 병합

11-28 에 운영자가 정했다. 3-way 병합을 바탕에 두고, 여러 Keeper 가 함께 쓰는 리치 문서로 간다.

| | 블록 리비전 + 블록 안 3-way 병합 (택함) | Yjs 변환기를 되살림 (택하지 않음) |
|---|---|---|
| 정본 | 원고마다 append-only 저장 기록 하나. 블록마다 리비전 | Yjs 상태(바이너리) |
| 동시 수정 | 다른 블록은 그대로 둘 다 들어간다. 같은 블록은 3-way 병합, 겹치면 충돌을 돌려준다 | CRDT 가 자동 병합한다. 겹쳐도 한 결과로 수렴한다 |
| 실행 | OCaml 안. 외부 프로세스 없음 | Node 실행 파일. 30초 상한의 외부 프로세스(`artifact_document_engine.ml:55`) |
| 화면 갱신 | 커밋마다 관찰 무효화를 보내고, 화면이 마지막으로 본 리비전 뒤의 변경을 읽는다 | 문서 상태를 실시간으로 동기화한다 |
| 비용 | 블록 타입과 저장소, 블록 편집 화면 | JS 빌드와 설치 경로가 돌아온다. 11-24 에 뺀 의존성의 일부도 돌아온다 |

겹치는 수정을 조용히 수렴시키지 않고 보여 준다. 그 편이 「덮어쓰지 않는다」에 맞다.
글자 단위 실시간 동시 편집이 필요하다는 기록이 쌓이면 그때 CRDT 를 다시 본다. 런타임에 숫자로 방식을 바꾸는 게이트는 두지 않는다.

## 4. 설계

### 4.1 블록

블록 종류는 닫힌 합이다. 블록 안의 글(`inline`)은 Markdown inline 원문 조각과 멘션의 목록이다.

```ocaml
module Draft_block : sig
  type span =
    | Text of string                          (* Markdown inline 원문: 굵게·기울임·코드·링크 *)
    | Mention of Keeper_id.Keeper_name.t      (* 저장할 때 Keeper 목록에서 찾은 이름 *)

  type inline = span list

  type heading_level = H1 | H2 | H3
  type callout_tone = Note | Warning | Decision
  type check_item = { checked : bool; text : inline }

  type body = private
    | Heading of { level : heading_level; text : inline }
    | Paragraph of inline
    | Bullets of inline list                  (* 항목이 하나 이상이다 *)
    | Numbered of inline list                 (* 항목이 하나 이상이다 *)
    | Checklist of check_item list            (* 항목이 하나 이상이다 *)
    | Table of { header : inline list; rows : inline list list }
        (* 열이 하나 이상이다. 행마다 열 수가 header 와 같다 *)
    | Code of { language : string option; text : string }
    | Quote of inline
    | Callout of { tone : callout_tone; text : inline }
    | Toggle of { summary : inline }          (* 자식은 parent 로 이 블록을 가리키는 블록이다 *)
    | Media of { attachment : Attachment_id.t; caption : inline }
    | Youtube of Wiki_link.youtube_embed
    | Math of string
    | Divider

  type body_error =
    | Empty_list
    | No_columns
    | Column_count_mismatch of { row : int; expected : int; actual : int }

  val parse_inline : is_keeper:(Keeper_id.Keeper_name.t -> bool) -> string -> inline
  val bullets : inline list -> (body, body_error) result
  val table : header:inline list -> rows:inline list list -> (body, body_error) result
  (* 다른 종류도 같은 꼴의 생성자 함수가 있다 *)
end
```

- `body` 는 private 이다. 생성자 함수만 값을 만든다. 빈 목록과 열 수가 다른 표는 저장소에 들어오지 못한다.
- `parse_inline` 은 저장할 때 돈다. `@<이름>` 이 `Keeper_name` 문법(`keeper_id.mli:4-11`)에 맞고 그때 Keeper 목록에 있으면 `Mention` 이다. 아니면 `Text` 다.
  저장한 뒤에 Keeper 목록이 바뀌어도 그 글의 뜻은 바뀌지 않는다. `@@all` 같은 selector 는 멘션이 아니다.
- 블록 글의 멘션은 표시만 한다. 메시지는 댓글의 멘션만 보낸다(§4.4).
- `Attachment_id.t` 는 L2 가 만드는 private string 이다. `Attachment_store.parse_id`(`attachment_store.mli:185`)를 통과한 `att_<64hex>` 만 된다.
- `Media` 는 [workspace-chat-media-renders-where-it-is-written](RFC-workspace-chat-media-renders-where-it-is-written.md) 의 카드와,
  [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) 의 문서 카드로 그린다.
- `Youtube` 는 chat-media RFC §3.1 의 `Wiki_link.youtube_embed` 다. 이 타입은 지금 main 에 없다. chat-media L2 가 만든다.
- 게시할 때 블록 목록을 Markdown 으로 그린다. 원고를 열 때는 `cmarkit` 0.4.0(이미 의존성)을 `strict:false` 로 읽는다.
  이 모드는 표·체크 항목·수식 확장을 읽는다. ```` ```math ```` 블록은 `Math` 가 되고, 문단 안의 `$$…$$` 는 inline 수식으로 `Text` 에 남는다.
  `Callout`·`Toggle` 은 CommonMark 에 없다. 그 표기는 L2 가 정하고 왕복 시험 표로 고정한다.

### 4.2 원고와 저장

```ocaml
type target = { artifact_id : string; generation : string }   (* 지금 Artifact_draft.target 과 같다 *)

type block =
  { id : Block_id.t                  (* UUIDv7. 넣는 쪽이 만든다 *)
  ; parent : Block_id.t option       (* Toggle 의 자식이면 그 Toggle *)
  ; revision : int                   (* 이 블록의 글이나 자리를 바꾼 저장마다 1 증가 *)
  ; body : Draft_block.body
  ; edited_by : string               (* 이 리비전을 만든 저장의 actor. 병합한 저장이면 병합한 쪽 *)
  ; edited_at : string }

type draft = private
  { target : target
  ; revision : int                   (* 저장마다 1 증가 *)
  ; base_publication : int           (* 원고가 마지막으로 맞춘 게시 리비전 *)
  ; base_sha256 : string             (* 그 게시본의 sha256 *)
  ; blocks : block list }            (* 문서 순서. 부모가 자식보다 앞에 온다 *)

type position = { parent : Block_id.t option; after : Block_id.t option }
(* parent 아래에서 after 바로 뒤. after 가 None 이면 parent 아래 첫 자리 *)

type op =
  | Insert of { id : Block_id.t; at : position; body : Draft_block.body }
  | Update of { id : Block_id.t; expected : int; body : Draft_block.body }
  | Move of { id : Block_id.t; expected : int; at : position }
  | Delete of { id : Block_id.t; expected : int }
(* expected: 읽었을 때의 블록 리비전 *)

type save =
  { request : Draft_request_id.t     (* UUIDv7. 호출자가 묶음마다 만든다 *)
  ; target : target
  ; answering : string option        (* 답하는 댓글 스레드 id *)
  ; ops : op list }                  (* 적은 순서대로 적용한다 *)

type hunk =
  | Same of string list
  | Changed of { base : string list; ours : string list; theirs : string list }

type structure_problem = Parent_not_toggle | Has_children | Cycle

type block_conflict =
  | Overlap of { op : int; current : block; hunks : hunk list }
  | Kind_changed of { op : int; current : block }
  | Deleted_meanwhile of { op : int; id : Block_id.t }      (* 고치거나 옮기려던 블록이 지워졌다 *)
  | Changed_meanwhile of { op : int; current : block }      (* 옮기거나 지우려던 블록이 바뀌었다 *)
  | Anchor_gone of { op : int; anchor : Block_id.t }        (* parent 나 after 가 지워졌다 *)
  | Structure of { op : int; id : Block_id.t; problem : structure_problem }

type invalid =
  | Empty_batch
  | Unknown_block of { op : int; id : Block_id.t }          (* 이 원고에 한 번도 없던 id *)
  | Expected_ahead of { op : int; id : Block_id.t; expected : int; current : int }
  | Id_taken of { op : int; id : Block_id.t }               (* 지운 블록의 id 도 다시 쓰지 않는다 *)
  | Attachment_unreadable of { op : int; attachment : Attachment_id.t }
  | Unknown_thread of string
  | Request_reused of Draft_request_id.t                    (* 같은 id 로 다른 묶음을 보냈다 *)

type save_result =
  | Saved of { draft : draft; merged : Block_id.t list }
  | Conflict of
      { current : draft
      ; merged : (Block_id.t * Draft_block.body) list     (* 깨끗하게 병합되는 블록과 그 결과 *)
      ; conflicts : block_conflict list }                 (* 아무것도 쓰지 않았다 *)
  | Generation_changed of { current : target }
  | Invalid of invalid
  | Unavailable of string
  | Commit_uncertain of { request : Draft_request_id.t }
```

저장은 `save` 하나를 원고 하나에 원자적으로 커밋한다. 묶음은 전부 들어가거나 하나도 안 들어간다.

1. `generation` 이 다르면 `Generation_changed` 다. 지웠다 다시 만든 원고의 리비전이 우연히 맞아도 섞이지 않는다.
2. 같은 `request` 가 이미 커밋됐으면 그때의 `Saved` 를 다시 돌려준다. `draft` 는 지금 원고다. 같은 id 로 다른 묶음을 보내면 `Request_reused` 다.
3. op 는 적은 순서대로 작업 사본에 적용한다. 앞 op 가 넣은 블록을 뒤 op 가 가리킬 수 있다.
4. `Insert`: id 는 이 원고에서 처음 쓰는 값이어야 한다. 아니면 `Id_taken` 이다. 새 블록은 `after` 바로 뒤에 놓인다.
   같은 `after` 로 셋을 넣으면 나중 op 가 앞에 온다. 차례대로 넣으려면 앞에 넣은 블록을 `after` 로 쓴다.
   다른 저장이 같은 자리에 넣은 블록도 같다. 나중에 커밋한 블록이 `after` 바로 뒤에 온다.
5. `Update`: `expected` 가 지금 리비전과 같으면 그대로 바꾼다. 작으면 `expected` 판 글을 공통 조상으로 3-way 병합한다. 크면 `Expected_ahead` 다.
6. `Move`·`Delete`: `expected` 가 지금 리비전과 같아야 한다. 다르면 `Changed_meanwhile` 이다.
   `Move` 도 블록 리비전을 올린다. 옮긴 블록을 옛 리비전으로 고치면 5번 병합을 탄다. 글이 같으므로 병합은 깨끗하다.
7. 고치거나 옮기거나 지우려던 블록이 그사이 지워졌으면 `Deleted_meanwhile` 이다. 넣거나 옮길 자리가 지워졌으면 `Anchor_gone` 이다.
   한 번도 없던 id 면 `Unknown_block` 이다. 저장 기록에 지운 사실이 남아 있어서 둘을 가른다.
8. 묶음을 다 적용한 작업 사본에서 모든 parent 는 남아 있는 `Toggle` 이어야 한다. 자기 자손 아래로 옮기면 안 된다.
   어기면 그 op 의 `Structure` 다. 자식이 있는 블록을 지우려면 같은 묶음에서 자식을 먼저 지우거나 옮긴다.
9. 다른 블록을 고친 저장끼리는 비교하지 않는다. 여러 Keeper 가 절을 나눠 쓰면 충돌이 나지 않는다.
10. 충돌이 하나라도 있으면 아무것도 쓰지 않는다. `Conflict` 는 지금 원고, 깨끗하게 병합되는 블록의 결과(`merged`), 충돌 목록을 돌려준다.

**줄 규칙.** 3-way 병합은 세 판의 블록 종류가 같을 때 줄 단위로 한다. 줄은 타입 값으로 비교한다. hunk 에는 그 줄의 Markdown 원문을 보인다.

| 종류 | 한 줄 |
|---|---|
| `Heading`·`Paragraph`·`Quote`·`Callout`·`Toggle`·`Media`·`Youtube`·`Divider` | 블록 전체 |
| `Bullets`·`Numbered`·`Checklist` | 항목 하나. 체크 상태도 그 줄에 든다 |
| `Table` | 첫 줄이 header 다. 그 뒤 행 하나가 한 줄이다 |
| `Code`·`Math` | 원문 한 줄 |

- 병합한 줄 목록은 그 종류의 생성자 함수에 다시 넣는다. 열 수가 어긋나거나 목록이 비면 그 블록은 `Overlap` 이다.
- 종류가 다르면 줄로 병합하지 않는다. 지금 글과 보낸 글 가운데 한쪽이 기준판과 같으면 다른 쪽을 쓴다. 둘 다 바뀌었으면 `Kind_changed` 다.
- diff3 구현은 열린 결정 2 다(§11).

**Conflict 뒤에 다시 저장하기.**

- `merged` 에 있는 블록은 그 글로 바꾼다. 충돌한 블록은 고른 글로 바꾼다. 둘 다 `expected` 를 `current` 의 블록 리비전으로 올린다.
- 나머지 op 는 처음 보낸 그대로 둔다. 새 `request` 로 보낸다.
- 예: 묶음 {X 고침, Y 고침} 에서 X 는 병합되고 Y 가 겹쳤다. X 의 `merged` 글은 이미 양쪽을 합쳤다. 그래서 X 에서 다른 쪽 수정이 사라지지 않는다.
- 그사이 또 다른 저장이 끼어들었으면 5번이 다시 돈다. 끼어든 저장이 조용히 사라지는 길은 없다.

**결과를 모를 때.** 쓰기 결과를 모르면 `Commit_uncertain` 이다. 지금 저장소에도 같은 경우가 있다(`artifact_draft_store.mli:9`).
호출자는 같은 `request` 로 다시 보낸다. 커밋됐으면 2번이 같은 결과를 준다. 아니면 처음처럼 적용한다. 블록이 두 번 들어가지 않는다.

**저장 기록.**

- 원고 하나는 append-only private JSONL 파일 하나다. 자리와 잠금은 지금과 같다(`artifact_draft_store.ml:42-43`).
- 첫 줄은 열 때의 블록 목록과 출발 게시본이다. 그 뒤 커밋·댓글 사건·게시·내보내기마다 한 줄을 붙인다.
  커밋 줄에는 request id, actor, 시각, `answering`, 바뀐 블록의 새 리비전·글·자리, 지운 블록 id 가 있다.
- 붙이기는 읽은 snapshot 위에서만 성공한다(`fs_compat.mli:2114`). 그사이 다른 커밋이 있으면 다시 읽고 1번부터 다시 돈다.
- 지금 원고와 블록별 옛 글은 이 파일을 처음부터 접어(fold) 얻는다. 공통 조상 글이 없으면 파일이 깨진 것이고 `Unavailable` 이다.
- 원고마다 파일이 따로라 다른 원고와 나눠 쓰는 내용이 없다. 원고를 지우면 그 파일만 지운다. `Tool_blob_store` 는 쓰지 않는다.
- 첨부 참조는 생긴다. `Media` 가 `att_<64hex>` 를 적기 때문이다.
  이 디렉터리의 분류를 `no_reference` 에서 `attachment_only` 로 바꾼다(`server_tool_blob_scope.ml:172`). 참조를 쓰는 PR 에서 같이 바꾼다.
  안 바꾸면 첨부 GC 가 원고에만 쓰인 그림을 지운다(`tool_blob_maintenance.mli:162-166`).
- 저장할 때 `Media` 첨부가 `Ephemeral` 이면 `Durable` 로 올린다(`attachment_store.mli:71-73`, `promote_to_durable` 는 `:301`).
  Keeper 가 읽을 수 없는 첨부(`can_keeper_read`, `:309`)면 `Attachment_unreadable` 이다.

### 4.3 HTTP 와 화면 갱신

#55386 이 원고 HTTP 라우트 다섯을 지운다. `GET /api/v1/artifact-draft-events/<id>` SSE 도 그 안에 있다.
그래서 Dashboard 가 쓸 라우트를 L4 가 새로 만든다. 권한은 지금 게시 아티팩트 라우트와 같은 workspace 확인을 쓴다.

| 경로 | 하는 일 |
|---|---|
| `POST /api/v1/artifact-drafts` | `artifact_id`·`revision` 으로 원고를 연다(§4.5 open) |
| `GET /api/v1/artifact-drafts/<artifact_id>` | 원고 전체. `?generation=<g>&since=<revision>` 이면 그 뒤 바뀐 블록, 지운 id, 현재 전체 블록 id 순서 |
| `POST …/<artifact_id>/saves` | `save` 하나. 결과는 `save_result` |
| `POST …/<artifact_id>/discussion` | 댓글 명령(§4.4) |
| `POST …/<artifact_id>/publications` | 게시(§4.5 publish) |

화면 갱신은 SSE 로 원고 내용을 보내지 않는다.

- #55386 뒤 남는 SSE 는 Dashboard 관찰 무효화다. 행을 싣지 않는다(`sse_event.atd:4-6`). scope 에 아티팩트가 없다(`sse_event.atd:46-50`).
  합쳐서 보내고, 지난 것을 다시 보내 주지 않는다(`server_dashboard_observation_broadcast.mli:1-2,19-20`).
- L4 가 이 닫힌 계약에 topic `Artifact_draft` 와 scope `Artifact of string`(artifact id)을 더한다. 원고 커밋이 그 무효화를 낸다.
- 화면은 무효화를 받으면 마지막으로 본 리비전으로 `GET …?since=` 를 부른다.
  무효화가 합쳐지거나, 연결이 끊겼다 다시 이어져도 같은 요청이다. 그래서 빠지는 저장이 없다.
- `generation` 이 다르거나 `since` 가 그 원고에 없는 리비전이면 원고 전체를 돌려준다.
- `since` 응답은 현재 리비전의 `block_order` 를 함께 보낸다. 클라이언트는 바뀐 블록을 적용하고 지운 id 를 제거한 뒤 그 순서대로 나열한다. 목록과 로컬 블록이 맞지 않으면 전체를 다시 읽는다. Keeper 의 `read since` 도 같은 모양을 쓴다. 형제 사이 삽입과 내용 변경 없는 이동을 델타로 복원하는 시험을 둔다.
- 사람이 편집 중인 블록이 바뀌었으면 덮어쓰지 않는다. 「다른 쪽이 이 블록을 고쳤어요」를 띄우고, 저장할 때 §4.2 의 병합을 탄다.
- 블록 옆의 「마지막으로 고친 이」는 블록의 `edited_by`·`edited_at` 이다. 따로 저장하는 presence 상태는 없다.
  가시성은 authority 가 아니라 projection 이다.

### 4.4 댓글, 제안, 멘션

`Artifact_discussion` 의 명령 여섯(comment·reply·resolve·reopen·accept·reject)과 request id 규칙은 그대로다.
사건은 지금처럼 원고와 같은 커밋에 들어간다(`artifact_discussion.mli:1-2`). 바뀌는 것은 셋이다.

**위치.** `Comment` 의 위치가 Yjs 위치(`artifact_discussion.mli:4`)에서 `anchor` 로 바뀐다.

```ocaml
type anchor = { block : Block_id.t; quote : string; prefix : string; suffix : string }

type anchor_state =
  | Anchored of { start : int; stop : int }   (* 블록 원문 안의 UTF-16 위치 *)
  | Anchor_lost                               (* prefix·quote·suffix 가 그 블록에 없다 *)
  | Anchor_ambiguous of int                   (* 두 곳 이상에 있다. 값은 찾은 수 *)
  | Block_gone                                (* 블록이 지워졌다 *)
```

- quote 는 블록의 Markdown 원문에서 찾는다. `read` 가 돌려주는 글과 같다. Dashboard 는 고른 글을 그 원문 위치로 바꿔 보낸다.
- `anchor_state` 는 저장하지 않는다. 스레드를 읽을 때 지금 블록에서 계산한다.
- accept 는 `Anchored` 일 때만 그 자리를 제안 글로 바꿔 §4.2 의 `Update` 로 쓴다. 다른 상태면 거절한다. 가장 비슷한 곳을 추측해 바꾸지 않는다.
- 자리를 다시 잡는 명령은 두지 않는다. 사람은 블록을 직접 고치고 스레드를 닫는다.

**답한 수정.** `save` 에 `answering` 이 있으면 같은 커밋에 사건 `Answered { thread_id; draft_revision }` 이 붙는다.
없는 스레드 id 면 저장 전체가 `Unknown_thread` 다.

**멘션 전달.**

- 댓글 본문은 저장할 때 `parse_inline` 으로 읽는다(§4.1). 받는 이는 그 `Mention` 목록이다. 같은 이름은 한 번만 받는다.
- 댓글 본문을 지금의 `Workspace_broadcast.broadcast` 에 넣지 않는다.
  지금 broadcast 는 글에서 처음 쓴 이름 하나로만 보낸다(`board_addressing.ml:173-181`, `workspace_broadcast.ml:1021`).
  그 이름이 Keeper 인지는 고른 뒤에야 본다(`server_bootstrap_loops.ml:223-227`).
  그래서 「@alice @keeper-b」는 `alice` 로 가서 `Rejected Target_not_configured` 가 되고, `keeper-b` 는 아무것도 못 받는다. `@@all` 이 섞이면 그것이 이긴다.
- 그래서 받는 Keeper 를 typed 값으로 넘기는 입구가 있어야 한다. 원고·스레드·블록을 어디에 실을지는 열린 결정 1 이다(§11).
- Keeper 마다 메시지 하나를 보낸다. request id(`Workspace_request_id.t`)는 (댓글 사건, Keeper)마다 하나다. 그 id 를 댓글 사건에 같이 적는다.
- audience 는 `Fleet_conversation` 이다. 사람이 Keeper 에게 건 말이기 때문이다.
- 댓글 저장 응답은 Keeper 별 전달 결과를 별도로 싣는다. 전송이 거절됐거나 전송 오류가 반환되면 실패 이유를 즉시 보여 주고, 댓글 저장 결과는 그대로 유지한다.
- 스레드를 읽을 때는 저장된 request id 로 `find_broadcast` 를 조회한다. 행이 있으면 `Passive`·`Pending`·`Accepted`·`Already_accepted`·`Deferred _`·`Rejected _` 를 그린다. `Ok None` 은 「전달 기록 없음」, 조회 `Error` 는 「전달 확인 불가」로 표시한다. 기록 없음은 댓글 커밋 직후 프로세스가 중단된 경우도 포함하므로 전달 성공을 뜻하지 않는다.
- 검증은 전송 오류와 댓글 커밋 직후 중단, 이후 조회 오류를 각각 재현해 사용자에게 보이는 결과를 확인한다.
- 이 메시지는 계약이 아니다. 답할 의무, 기다림, 재시도를 만들지 않는다. Keeper 는 답할지, 고칠지, 아무것도 안 할지 고를 수 있다.

### 4.5 Keeper 도구

#55387 뒤 `keeper_artifact_draft` 의 동작은 find·published·open·read·select·resolve·edit·discuss·checkpoint 다.
이 RFC 는 select·resolve·checkpoint 를 지우고 publish 를 더한다. select 와 도구 동작 resolve 는 Yjs 위치를 다뤘다.
토론 명령 resolve(스레드 닫기)는 discuss 안에 그대로 남는다.

| 동작 | 바뀌는 것 |
|---|---|
| find·published | 그대로 |
| open | Markdown 게시본만 블록 원고로 연다. HTML 게시본은 `Html_publication` 으로 거절한다. 블록 종류가 없는 구조는 열린 결정 3 이다 |
| read | 블록 목록. 블록마다 id·parent·리비전·종류·원문·마지막으로 고친 이가 있다. `blocks` 로 일부만, `since` 로 그 뒤 바뀐 것만 읽는다. 스레드마다 `anchor_state` 와 멘션 전달 결과가 있다 |
| edit | §4.2 의 `save` 를 받는다. 결과는 `save_result` 다 |
| discuss | 위치를 `anchor` 로 받는다 |
| publish | 새 동작. 아래와 같다 |

checkpoint 는 이 설계에서 돌 수 없다.
지금 checkpoint 는 게시본이 원고 글과 바이트까지 같을 때만 base 를 옮긴다(`artifact_draft_store.ml:147,157,160`).
그런데 게시 도구는 Keeper 가 준 글을 그대로 쓰고(`keeper_artifact_publish.toml:41-46`), 새 `read` 는 블록만 준다.
Keeper 가 서버와 같은 Markdown 을 바이트까지 만들 길이 없으니 checkpoint 는 늘 `Published_content_mismatch` 다.

publish 는 서버가 그린 글을 게시한다.

- 입력은 `target`, 원고 리비전, `expected_publication`, 제목, 요약이다.
- 서버가 그 원고 리비전을 Markdown 으로 그린다. 게시 잠금 안에서 새 게시 리비전을 쓰고, 원고 파일에 `Published { publication; sha256; draft_revision }` 줄을 붙인다.
  잠금 순서는 지금 checkpoint 와 같다(게시 → 원고, `artifact_draft_store.ml:138-165`).
- 최신 게시가 원고의 `base_publication`·`base_sha256` 과 다르면 `Publication_moved { latest }` 로 거절한다. 아무것도 쓰지 않는다.
  원고 밖에서 누가 게시했다는 뜻이다. 그 게시를 덮어쓰지 않는다.
- 게시는 됐는데 원고 줄을 못 붙였으면 `Base_uncertain { publication }` 이다.
  같은 요청을 다시 보내면, 최신 게시가 `expected_publication + 1` 이고 그 sha256 이 그 원고 리비전을 그린 글과 같을 때 원고 줄만 붙인다.
- `keeper_artifact_publish` 는 원고 없이 쓰는 게시로 그대로 남는다.

`Conflict` 를 받은 Keeper 는 다음 호출에서 고른 결과를 다시 저장할 수 있다. 재시도 상한은 두지 않는다.

### 4.6 Dashboard

- 블록 편집기: 블록마다 편집 상태가 따로다. 블록을 고르면 그 블록만 편집 칸이 된다. 「/」로 블록 종류를 고르고, 표는 칸 단위로 고친다.
- 그림·파일은 붙여넣기와 끌어 놓기로 올린다. 첨부 저장소에 올린 뒤 `Media` 블록이 된다.
- 충돌이면 `Changed` hunk 를 양쪽으로 보여 주고 고르게 한다. 다시 저장할 때 §4.2 의 규칙대로 `merged` 를 쓴다.
- 오른쪽에 블록에 붙은 댓글 스레드가 있다. 스레드마다 자리 상태와 멘션 전달 결과가 보인다. 멘션 입력은 Keeper 이름을 자동 완성한다.
- 편집기는 원고를 열 때 불러오는 chunk 다. 첫 화면 `index.js` 는 늘지 않는다.
  편집기 부품을 라이브러리로 쓸지 직접 만들지는 L6 이 chunk 크기를 재서 정한다.

### 4.7 내보내기와 가져오기

내보내기는 [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) §3.2 의 변환기 이미지에서 돈다.
그 worker 에 `export <형식>` 동작을 더한다. 격리와 호스트 검증은 같다. 입력과 출력 이름이 다르다.

- 입력: 그 RFC 의 `render` 는 원본 바이트 하나를 stdin 으로 받는다. `export` 는 그림을 같이 넘겨야 한다. 그래서 호스트가 만든 tar 하나를 stdin 으로 받는다.
  - `document.md`: §4.1 규칙으로 그린 Markdown. 그림 `Media` 는 `media/att_<64hex>.<확장자>` 상대 경로로 가리킨다.
  - `media/…`: 원고에 있는 그림 첨부의 바이트.
  - 동영상·오디오·MIDI·문서 `Media` 는 caption 과 파일 이름을 글로 쓴다. `Youtube` 는 URL 을 글로 쓴다.
- 출력 이름은 닫힌 집합이다. `manifest.json` 과, 요청한 형식의 `export.docx`·`export.pptx`·`export.pdf`·`export.xlsx`·`export.hwpx` 가운데 하나다.
  결과 파일의 형식은 그 RFC L2 의 `media_format` 으로 확인한다.

| 형식 | 경로 |
|---|---|
| DOCX | pandoc |
| PPTX | pandoc `--slide-level=1`. `Heading` `H1` 마다 슬라이드 한 장 |
| PDF | pandoc → DOCX → `soffice --convert-to pdf`. LaTeX 엔진을 들이지 않는다 |
| XLSX | `Table` 블록마다 CSV 로 뽑아 LibreOffice 로 한 시트씩 만든다. `Table` 이 없으면 `No_table` 으로 거절한다 |
| HWPX | rhwp v0.9.1 의 `build-from-ingest`(ingest JSON 과 그림 → HWPX). 블록을 ingest JSON 으로 옮길 수 있는지는 L7 이 schema(`rhwp capabilities --search build-from-ingest`)를 읽고 정한다. 표나 그림을 잃으면 HWPX 는 범위 밖으로 둔다 |

- 결과는 새 첨부로 저장한다. 첨부 meta 는 바꾸지 않는다. meta 는 내용 digest 로 찾는 값이라 출처를 담을 자리가 아니다.
- 원고 파일에 `Exported { format; attachment; draft_revision }` 줄을 붙인다. `format` 은 `Docx | Pptx | Pdf | Xlsx | Hwpx` 다.
- 가져오기: 첨부 문서의 추출 글(그 RFC 의 `text.md`)을 새 Markdown 아티팩트로 게시한다. 그 게시본을 §4.5 open 으로 연다. 원본 첨부는 그대로 둔다.

### 4.8 저장 형식

- 원고 저장은 hard cut 이다. 새 파일은 지금 자리(`.masc/artifact_drafts/<artifact_id>.json`)를 그대로 쓴다.
  기존 Yjs 원고는 새 줄 형식으로 decode 되지 않는다. 변환 reader 를 만들지 않는다.
- 옛 파일이 남은 채 시작해도 조용히 읽거나 덮어쓰지 않는다. 원고 저장소를 `Keeper_durable_store` 표에 `Preflight_only` 로 넣는다(`keeper_durable_store.mli:13-30`).
  배포 전 `validate-stores` 가 decode 되지 않는 원고 파일을 이름으로 알린다. 실행 중에 그런 파일을 만나면 그 원고는 `Unavailable` 이고 아무것도 쓰지 않는다.
- 토론 사건 기록은 원고 안에 있다(`artifact_discussion.mli:1-2`). 그래서 기존 원고의 댓글 스레드도 함께 없어진다.
- 배포 노트의 Fresh state 항목에 `.masc/artifact_drafts/` 삭제를 적는다. 게시된 아티팩트 리비전은 영향이 없다.

## 5. HWP 를 HWP 로 고치는 트랙

사람이 HWP·HWPX 문서 카드에서 「편집」을 누르면 rhwp 편집기(`@rhwp/editor`, WASM)를 그때 불러온다.

- 첫 화면 `index.js` 에 들어가지 않는 별도 chunk 다. 읽기·미리보기 변환은 여기서 하지 않는다.
- 저장하면 새 HWP·HWPX 바이트가 새 첨부가 된다. 원본 첨부는 그대로다.
- 새 첨부는 원본이 실린 자리(채팅 대화, Board 항목)에 「<원본 이름> 편집본」으로 새로 실린다.
  원본과의 관계는 그 메시지·항목 기록이 갖는다. 첨부 meta 는 바꾸지 않는다.
- 이 문서는 블록 원고가 아니므로 4.2 의 병합을 받지 않는다. 두 사람이 동시에 열면 저장마다 새 첨부가 된다. 덮어쓰지 않는다.
- Keeper 는 이 트랙에서 읽기(글·페이지)만 한다.
- Keeper 의 HWP 편집은 따로 정한다. 후보는 rhwp `run` 이다.
  선언적 편집 계획을 원자적으로 실행하고 기록을 남긴다. 계획에 적은 입력 SHA 가 다르면 아무것도 쓰지 않고 종료 코드 3 으로 끝난다.
  이 RFC 의 「덮어쓰지 않는다」와 맞는다. 표 칸·차트 값은 `csv-to-table`·`csv-to-chart` 가 있다.

## 6. 헌법과 맞추기

- `closed_sum_over_string`: 블록 종류, op, 충돌, 잘못된 묶음, 저장·게시 결과, 댓글 자리 상태, 내보내기 형식이 닫힌 합이다.
  멘션은 읽을 때마다 문자열을 다시 보는 값이 아니라 저장할 때 만든 `Mention` 이다.
- `strict_parse_no_default`: 없는 Keeper 이름은 멘션이 아니다. 자리를 잃은 댓글은 추측해 옮기지 않는다. 없는 블록·스레드 id 는 거절한다. 옛 Yjs 원고는 읽지 않고 알린다.
- `failure_keeps_evidence`: 충돌은 아무것도 쓰지 않고 지금 원고와 충돌 목록을 돌려준다. 결과를 모르는 저장은 같은 request id 로 다시 확인한다.
- `budget_gate`: 재시도 횟수·시간 상한이 없다. 병합 방식을 숫자로 바꾸지 않는다.
- Keeper 사이 요청: 멘션은 대상 Keeper queue 의 일반 메시지다. 응답·대기·재시도 의무가 없다.
- 가시성: 「마지막으로 고친 이」, 댓글 자리 상태, 멘션 전달 결과는 기록에서 계산한 projection 이다. 새 presence authority 를 만들지 않는다.
- `legacy_residue`: Yjs 원고는 hard cut 이고 변환 코드가 없다. 쓰이지 않게 된 동작(select·resolve·checkpoint)은 지운다.
- `libraries`: Markdown 은 `cmarkit`, 내보내기는 pandoc·LibreOffice 를 쓴다. diff3 는 열린 결정 2 다.

## 7. Stack 계획

#55383~#55387 병합 뒤 `main` 위에 쌓는다.
Yjs 도구는 L3 에서 한 번에 바뀐다. L2 는 저장소에 닿지 않는다. 그래서 옛 도구와 새 모듈이 같은 파일을 두고 다투는 층이 없다.

| 층 | 범위 | 확인 | 먼저 있어야 하는 것 |
|---|---|---|---|
| L1 | 이 RFC. 세 RFC 와 같은 PR 에서 옛 문서 넷을 지운다(§9) | `rfc-generate-index.py --check` | — |
| L2 | `Draft_block`(타입·생성자 함수·`parse_inline`), Markdown 왕복, 줄 규칙과 3-way 병합 | PR `type-check`, 왕복·병합·생성자 시험 표 | chat-media L2(`Wiki_link.youtube_embed`) |
| L3 | 저장 기록·save·publish, `answering`, 댓글 위치 교체, `keeper_artifact_draft` 동작 교체, Yjs 엔진 모듈과 설치 스크립트 삭제, `Keeper_durable_store`·첨부 참조 분류, Fresh state | PR `type-check`, 끼어든 저장·부분 충돌 뒤 재저장·같은 request 재전송·`Structure` 시험 | L2, #55383~#55387 |
| L4 | 원고 HTTP 라우트, 관찰 topic·scope | PR `type-check`, `since` 읽기 시험 | L3 |
| L5 | 멘션 전달 입구(열린 결정 1) | PR `type-check`, 「@alice @keeper-b」·`@@all` 댓글 시험 | L3 |
| L6 | Dashboard 블록 편집기·충돌 화면·댓글·멘션·실시간 갱신 | `pnpm typecheck`, vitest(보낸 요청·받은 결과), 편집기 chunk 크기 | L4, L5, chat-media L4 |
| L7 | 내보내기 `export`, `Exported` 기록, 가져오기 | 변환 결과 파일을 PR 에 첨부 | 문서 RFC L3·L4 |
| L8 | HWP 편집 chunk | 배포 자산 합계와 첫 화면 `index.js` gzip 비교, 저장 결과가 새 첨부인지 | 문서 RFC L6 |

## 8. 확인 방법

- Keeper 둘과 사람이 같은 원고의 다른 블록을 동시에 고친다. 세 수정이 모두 남은 블록 목록을 PR 에 남긴다.
- 같은 블록의 다른 줄을 동시에 고친다. `merged` 에 그 블록이 있고 두 수정이 모두 남은 기록을 남긴다.
- 같은 줄을 동시에 고친다. `Conflict` 가 나고 아무것도 쓰이지 않았고, 고른 결과가 저장된 기록을 남긴다.
- 묶음 {X, Y} 에서 X 는 병합되고 Y 는 겹친다. `merged` 로 다시 저장한 뒤 X 에 두 수정이 모두 남은 기록을 남긴다.
- 충돌을 고르는 사이 세 번째 저장이 끼어든다. 그 저장이 병합되거나 다시 충돌하는 기록을 남긴다.
- 같은 request 를 두 번 보낸다. 블록이 한 번만 들어간 기록을 남긴다.
- 사람이 댓글에 「@alice @keeper-b」를 쓴다. `keeper-b` queue 에 메시지가 들어간 기록과, Keeper 의 답과 `answering` 수정이 스레드에 남은 화면을 남긴다.
- 옛 Yjs 원고 파일을 둔 base path 에서 `validate-stores` 가 그 파일을 알린 출력을 남긴다.
- 새로 설치한 환경에서 `masc-artifact-document` 없이 원고 도구가 도는 것을 보인다.

## 9. 지우는 옛 문서와 닫힌 이슈

아래 문서는 11-24 #54560 이 지운 브라우저 변환기와 Yjs 편집기를 「구현」 또는 「구현 설계」로 적고 있다.
코드와 맞지 않는 설명은 다음 작업자를 틀린 길로 보낸다. 이 RFC 묶음의 L1 에서 지운다.

- `docs/rfc/RFC-artifact-hwp-import.md`
- `docs/rfc/RFC-artifact-office-roundtrip.md`
- `docs/rfc/RFC-artifact-office-fidelity.md`
- `docs/design/artifact-document-export.md`

지워진 화면을 고치자는 이슈 넷은 11-28 에 NOT_PLANNED 로 닫혔다. 새 설계는 이 결함을 물려받지 않는다.

| 이슈 | 내용 | 대상 코드 |
|---|---|---|
| #53110 | 재연결 뒤 옛 위치 요청이 새 커서 전송을 막는다 | 실시간 공동 편집 화면(11-24 삭제), 위치 기록(#55387 삭제) |
| #53109 | heartbeat 가 끊겨도 연결된 것으로 보인다 | 실시간 공동 편집 스트림(11-24 삭제) |
| #52716 | 빈 값이 든 HWPX 차트를 RHWP 가 잘못 읽는다 | 브라우저 HWPX 내보내기(11-24 삭제) |
| #52637 | Core 0.9 로 다시 저장한 HWPX 의 차트 Excel 연결이 끊긴다 | 브라우저 HWPX 가져오기·내보내기(11-24 삭제) |

## 10. 범위 밖

- 원본 서식을 지키며 DOCX·XLSX·PPTX 를 그 자리에서 고치기. 원고로 가져오면 서식은 남지 않는다.
- 글자 단위 실시간 동시 편집과 참여자 커서.
- HTML 아티팩트의 블록 편집. HTML 게시본은 지금처럼 읽기만 한다. 블록 원고는 Markdown 으로 게시한다.
- 원고 밖에서 게시된 새 리비전 위로 원고를 옮기기. 지금은 `Publication_moved` 로 거절만 한다.

## 11. 열린 결정

1. **멘션 메시지가 원고·스레드·블록을 싣는 자리.** 받는 Keeper 를 typed 값으로 넘기는 것은 정했다(§4.4). 지금 `broadcast` 는 `~content:string` 만 받는다(`workspace_broadcast.mli:157-163`).
   - (가) 받는 이와 typed `subject`(target·thread_id·block)를 받는 입구를 `Workspace_broadcast` 에 더한다. Keeper 는 그 값을 도구 인자로 그대로 넘긴다.
     message row 형식이 바뀐다. `validate_current_message_schema`(`:122-127`)가 옛 row 를 거절하므로 Fresh state 가 생긴다.
   - (나) 받는 이만 typed 로 넘기고, 내용은 서버가 쓴 글이다. 글에 thread_id 를 적는다. 코드는 그 글을 다시 읽지 않고, 모델이 id 를 옮겨 적는다. row 형식은 그대로다.
2. **diff3 구현.** 헌법 `libraries` 는 있는 라이브러리를 쓰라고 한다.
   - (가) Jane Street `patience_diff` 의 `merge`. 기준판·지금 글·보낸 글을 맞춰 `Same`·`Different` 구간을 낸다. `Different` 는 diff3 규칙(한쪽이 기준판과 같으면 다른 쪽)으로 푼다.
     `core`·`ppx_jane` 이 새 의존성으로 들어온다. 지금 잠금 파일에는 `base` 만 있다(`masc.opam.locked:25`).
   - (나) 줄 단위 diff3 를 직접 작게 쓴다. 공개된 diff3 사례로 시험 표를 만든다.
3. **블록 종류가 없는 Markdown 구조(HTML 블록, 각주, 중첩 목록)를 열 때.**
   - (가) open 이 `Unsupported_markdown { line; structure }` 로 거절한다. `structure` 는 닫힌 합이다. 사람은 게시본을 고쳐 다시 게시한다.
   - (나) 그 구조를 원문 그대로 `Code`(language `markdown`) 블록에 담는다. 잃는 글은 없지만 다음 게시에서 모양이 바뀐다.
