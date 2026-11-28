---
rfc: "workspace-chat-media-renders-where-it-is-written"
title: "Chat Media Renders Where It Is Written"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: vincent
related: ["workspace-media-and-rich-embed", "workspace-documents-arrive-as-pages-and-text", "workspace-documents-are-written-together"]
---

# RFC workspace-chat-media-renders-where-it-is-written: 채팅의 미디어는 쓴 자리에서 그려진다

## 0. 요약

Keeper 가 답에 `![[media:att_…]]` 로 동영상을 넣으면 Dashboard 는 「이미지를 불러올 수 없습니다」를 띄운다.
같은 동영상을 첨부로 보내면 `<video>` 로 재생된다. 미디어가 그려지는지는 지금 「어디에 실렸나」에 달려 있다.

이 RFC 는 채팅에서 미디어가 실린 자리(첨부·Markdown 본문)와 상관없이 종류대로 그려지게 한다.
종류는 이미지·동영상·오디오·MIDI·YouTube·코드·수식이다.
새 저장소나 업로드 경로는 만들지 않는다. `Attachment_store`(`/api/v1/attachments`)와
[workspace-media-and-rich-embed](RFC-workspace-media-and-rich-embed.md) §5.1 의 embed 문법 위에 얹는다.

## 1. 지금 (`899cb2033e5fa`)

| 종류 | TUI | Dashboard |
|---|---|---|
| 첨부 이미지 | 그림: Kitty·iTerm2·반블록 (`lib/masc_tui/app/document_graphics.mli:1-9`) | 썸네일·확대 (`dashboard/src/components/attachments/attachment-gallery.ts`) |
| 본문 Markdown 이미지 | 링크만. embed 목록을 주는 곳이 Wiki 상세뿐이다 (`lib/masc_tui/ui/markdown.mli:39-45`, `screen_knowledge.ml:1323`) | 그림 (`markdown-embed-runtime.ts`) |
| 첨부 동영상 | 포스터 + `[VIDEO]`, `/play` 가 외부 앱으로 연다 (`lib/masc_tui/store/chat_transcript.ml:902`) | `<video>` (`attachment-gallery.ts:325-353`, 인증 blob) |
| 본문 Markdown 동영상 | 링크만 | 「이미지를 불러올 수 없습니다」. slot 캐시가 래스터가 아니면 `unsupported_mime` 으로 거절한다 (`dashboard/src/lib/workspace-media-cache.ts:252-256`, `markdown-embed-runtime.ts:293`) |
| YouTube | OSC 8 링크 | 새 탭 링크. 채팅 sanitizer 허용 목록에 `iframe` 이 없다 (`markdown-renderer.ts:140-147`, 쓰는 곳 :278) |
| 오디오 첨부 | `[AUDIO]`, `/play` | `<audio>` |
| TTS 음성 클립 | 없음 | `keeper-state.ts:794` 가 상태에 붙이기만 하고 그리는 컴포넌트가 없다 |
| MIDI 첨부 | `[MIDI]`, `/play` (fluidsynth) | 악보 재생기 |
| 코드 블록 | 11개 언어 강조, 펜스 태그로만 고름 (`lib/masc_tui/ui/code_lexer.mli:33-53`). 복사 없음 | 강조 없음(11-24 #54560 이 Shiki 를 뺐다). 복사 없음 |
| 수식 | `$tex$` 원문 | 없음 |
| Keeper 가 만든 동영상 | 저장 범주가 없다. `media_category` 에 `Video` 가 없다 (`lib/keeper/keeper_chat_media_store.mli:20-25`) | 같음 |

## 2. 결과

- 미디어를 첨부로 보내든 본문에 쓰든, 두 클라이언트는 같은 종류를 같은 방식으로 그린다.
- YouTube 링크 한 줄은 Dashboard 에서 재생기 카드가 된다. 누르기 전에는 Google 쪽으로 요청을 보내지 않는다.
- Dashboard 코드 블록은 TUI 와 같은 언어를 강조한다. 두 클라이언트 모두 블록 단위로 복사한다.
- 수식은 Dashboard 에서 그려진다. TUI 는 지금처럼 원문을 보여 준다.
- Keeper 가 만든 동영상(예: 브라우저로 받은 Flow 클립)이 동영상 블록으로 저장되고 재생된다.
- Dashboard 첫 화면 `index.js` 는 커지지 않는다. 새 카드·강조기·수식 렌더러는 처음 쓰일 때 불러오는 chunk 다.

## 3. 설계

### 3.1 embed 문법에 YouTube 를 더한다

닫힌 embed 타입은 `Wiki_link.embed_target` 이다(`lib/wiki_link.ml:143-154`).
지금은 모르는 scheme 을 `Unsupported_embed` 로 둔다. 여기에 `Youtube_embed` 를 더한다.
`Media_ref_scan` 은 GC 를 위해 첨부 digest 만 뽑으므로 바꾸지 않는다.

받는 입력은 둘이다.

- `![[youtube:<video_id>]]`, `![[youtube:<video_id>|<label>]]`
- 문단 전체가 URL 하나뿐인 줄. 링크 문법 `[t](url)` 안의 URL 은 링크로 남는다.

URL 은 문자열 부분 일치로 고르지 않는다. URL 파서(`Uri`)로 나눈 뒤 host 를 닫힌 합으로 바꾼다.

```ocaml
type youtube_host = Youtube_com | Youtube_mobile | Youtu_be | Youtube_nocookie
type youtube_embed = { video_id : Youtube_id.t; start_s : int option }
(* Youtube_id.of_string : string -> Youtube_id.t option  — [A-Za-z0-9_-]{11} 만 받는다 *)
```

- 받는 경로는 `/watch?v=`, `/shorts/<id>`, `/embed/<id>`, `youtu.be/<id>` 뿐이다.
- `t`·`start` 가 없으면 `start_s = None` 이다.
- `t`·`start` 가 있는데 초 단위 정수가 아니면 그 URL 전체가 embed 가 아니다. 링크로 남는다.
- id 와 host 가 위 규칙에 맞지 않아도 링크로 남는다. 기본값으로 메우지 않는다.

문법의 정본은 하나의 시험 표(fixture)다. OCaml `Wiki_link` 시험과 Dashboard 파서 시험이 같은 파일을 읽는다.

### 3.2 Dashboard: sanitizer 는 그대로, 요소는 runtime 이 만든다

sanitizer 의 `iframe` 금지는 풀지 않는다. 본문 HTML 이 iframe 을 들여오는 길은 계속 막혀 있다.
embed runtime 이 파싱된 값만으로 요소를 직접 만든다.

slot 은 열 때 먼저 `GET /api/v1/attachments/<id>/meta` 를 읽는다.
카드는 meta 의 `kind` 가 아니라 `mime_type` 으로 고른다. `kind` 만으로는 둘을 못 가른다.
MIDI 는 `Audio`(`attachment_store.ml:135`)이고, 내부 opaque binary 는 `Document`(`attachment_store.ml:1581-1582`)다.
`mime_type` 은 서버의 `supported_mime` 과 같은 닫힌 union 으로 파싱한다. 모르는 값은 다운로드 카드다.

| mime 에서 고른 종류 | 만드는 요소 |
|---|---|
| 래스터 이미지 | 지금 경로 |
| 동영상 | 첨부 동영상 카드(인증 blob, `?poster=1`) |
| 오디오 | 첨부 오디오 카드 |
| MIDI | 첨부 악보 재생기 |
| opaque binary, 모르는 값 | 다운로드 카드 |
| meta 를 못 읽음 | 「불러오지 못함」 카드. 이유(HTTP 상태, 네트워크 오류)를 적는다 |

YouTube 는 먼저 외부 요청이 없는 카드(「YouTube 에서 재생」)를 보여 준다.
누르면 `https://www.youtube-nocookie.com/embed/<id>?start=<s>&autoplay=1` iframe 을 띄운다.
누른 동작이 재생 의사이므로 `autoplay=1` 을 붙여 한 번에 재생되게 한다. 속성은 고정이다.

- `sandbox="allow-scripts allow-same-origin allow-presentation"`
- `allow="autoplay; encrypted-media; picture-in-picture; fullscreen"`
- `referrerpolicy="strict-origin-when-cross-origin"`

카드 컴포넌트는 지금 `attachment-gallery.ts` 안에 export 없이 있다(:75, :181, :315, :522).
L4 가 이를 `attachment-cards.ts` 로 꺼낸다. 카드는 `AttachmentRef` 가 아니라 `{ url; mime }` 을 받는 재생 부품을 감싼다.
TTS 클립(`{ token; audioUrl; mime; expired }`, `types/core.ts:834-842`)도 같은 오디오 부품을 쓴다.
`expired` 클립은 재생 단추 대신 「만료됨」을 보여 준다.

embed runtime 은 `markdown-renderer.ts:18` 이 정적으로 불러온다. 그래서 새 카드는 runtime 에서 동적 import 로 부른다.
Board 첨부 재생 컨트롤 작업(task-4152)도 같은 `attachment-cards.ts` 를 쓰도록 맞춘다.

Dashboard 문서에 CSP 를 붙이게 되면 `frame-src` 에는 `https://www.youtube-nocookie.com` 하나만 넣는다.

### 3.3 코드 블록과 수식

- 강조 언어는 TUI `Code_lexer` 의 11개와 같다. 언어는 펜스 태그로만 고르고 내용으로 추측하지 않는다.
  태그 문법도 `Code_lexer.language_of_tag` 와 같은 시험 표를 쓴다. 두 클라이언트가 같은 블록을 다르게 읽지 않는다.
- 강조기는 별도 chunk 다. 펜스 태그가 있는 블록이 화면에 처음 나올 때 불러온다.
  어떤 강조기를 쓸지는 구현 PR 이 크기를 재서 정한다. 기준은 첫 화면 `index.js` gzip 바이트가 늘지 않는 것이다.
- 복사: Dashboard 는 블록마다 복사 단추를 둔다. 복사하는 값은 펜스 안 원문 그대로다.
  TUI 는 `/copy code <n>` 이 n 번째 코드 블록을 `Cmd.Copy_clipboard`(OSC 52)로 보낸다.
- 수식: `$…$`, `$$…$$` 를 Dashboard 에서 MathML 로 그린다. 렌더러는 수식이 처음 나올 때 불러오는 chunk 다.
  파싱에 실패한 수식은 원문을 코드로 보여 준다. TUI 는 지금처럼 원문이다.

### 3.4 TUI: 채팅 메시지도 embed 목록을 받는다

TUI 의 embed 는 서버가 찾은 것이다(`markdown.mli:39-45`). 지금은 Wiki 상세만 그 목록을 준다.

- 서버: 채팅 메시지의 history 응답과 broadcast 에 `embeds` 를 싣는다.
  Wiki 와 같은 `Wiki_link` 추출기로 메시지 본문에서 찾는다. 클라이언트가 문법을 따로 파싱하지 않는다.
- TUI: `embed_shown` 에 경우를 더한다. 지금은 `Embed_link`·`Embed_image`·`Embed_note` 셋이다(`markdown.mli:30-36`).

```ocaml
type embed_shown =
  | Embed_link of { label : string; uri : string }
  | Embed_image of embed_image
  | Embed_note of string
  | Embed_video of { label : string; attachment : string; poster : embed_image option }
  | Embed_audio of { label : string; attachment : string }
  | Embed_midi of { label : string; attachment : string }
  | Embed_youtube of { label : string; video_id : string; start_s : int option }
```

동영상은 포스터와 `[VIDEO]`, 오디오는 `[AUDIO]`, MIDI 는 `[MIDI]` 다. `/play` 는 첨부와 같이 동작한다.
YouTube 는 `[YouTube]` 칩과 OSC 8 링크이고, `/play` 는 기본 브라우저로 연다.
문서 embed 는 [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) §3.6 이 더한다.

### 3.5 Keeper 가 만든 동영상

`Keeper_chat_media_store.media_category` 에 `Video` 를 더한다. `ext_of_media_type` 은 mp4·webm·mov 를 안다.
새 variant 때문에 모든 `match` 가 경우를 더해야 한다. `_ ->` 로 흘려보내지 않는다.

## 4. 헌법과 맞추기

- `closed_sum_over_string`: YouTube host·embed 종류·미디어 범주·카드 종류가 닫힌 합이다. URL 은 파서로 나눈다.
- `strict_parse_no_default`: 모르는 URL·id·시간·MIME 은 embed 나 카드가 되지 않는다. 링크나 다운로드 카드로 남는다.
- `failure_keeps_evidence`: meta 를 못 읽은 slot 은 이유를 가진 실패 카드로 남는다. 조용히 빈 칸이 되지 않는다.
- `libraries`: 강조기와 수식 렌더러는 쓰는 라이브러리를 가져온다. 새로 만들지 않는다.
- 번들: 11-24 #54560 은 배포 자산을 59.38 MB 에서 4.52 MB 로, 첫 화면 `index.js` gzip 을 246.33 KB 에서 194.90 KB 로 줄였다.
  이 RFC 는 첫 화면 `index.js` 를 늘리지 않는다. 새 chunk 의 크기와 배포 자산 합계는 구현 PR 이 빌드 출력으로 적는다.

## 5. Stack 계획

`main` 위 Native Stack 이다. 한 파일은 한 층만 고친다.
[workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) L6 은 이 RFC 의 L4 가 병합된 뒤 쌓는다.
두 층이 `attachment-gallery.ts`·`workspace-media-cache.ts` 를 같이 고치기 때문이다.

| 층 | 범위 | 확인 |
|---|---|---|
| L1 | 이 RFC | `python3 scripts/rfc-generate-index.py --check` |
| L2 | OCaml: `Wiki_link.Youtube_embed`, `Keeper_chat_media_store.Video`, 공유 시험 표 | PR `type-check`, 대상 시험 `test.yml` |
| L3 | 서버: 채팅 history·broadcast 의 `embeds` | PR `type-check`, 대상 시험 `test.yml` |
| L4 | Dashboard: `attachment-cards.ts` 분리, mime 우선 slot, YouTube 카드, TTS 재생 | `pnpm typecheck`, vitest(만든 요소와 속성), `index.js` gzip 비교 |
| L5 | Dashboard: 코드 강조·복사, 수식 chunk | 위와 같음 + 새 chunk 크기 |
| L6 | TUI: `embed_shown` 새 경우, 채팅 embed, `/copy code`, YouTube `/play` | PR `type-check`. 시험은 보낸 요청·저장 상태·결정만 본다(헌법 `build_and_ci`) |

## 6. 확인 방법

- 같은 동영상을 첨부와 `![[media:…]]` 로 한 번씩 보낸 Keeper 턴을 Dashboard 에서 연다. 두 곳 모두 재생되는 화면을 PR 에 남긴다.
- YouTube 카드를 누르기 전 네트워크 기록에 `youtube`·`ytimg`·`google` 요청이 없음을 PR 에 남긴다.
- 첫 화면 `index.js` gzip 바이트와 새 chunk 크기를 `main` 과 비교한 표를 PR 에 남긴다.

## 7. 범위 밖

- 링크 미리보기. 서버 `POST /api/v1/dashboard/link-previews` 는 부르는 화면이 없다. 붙일지 지울지는 따로 이슈로 정한다.
- 받아들이는 형식 넓히기. 문서는 [workspace-documents-arrive-as-pages-and-text](RFC-workspace-documents-arrive-as-pages-and-text.md) 가 맡는다.
