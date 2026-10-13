---
rfc: "library-becomes-a-wiki"
title: "도서관을 위키로 바꾼다 — 페이지는 고쳐 쓰고, index 와 log 를 둔다"
status: Draft
created: 2026-10-13
updated: 2026-10-13
author: claude
supersedes: []
superseded_by: null
related: ["shared-memory-appends-a-log-and-keepers-read-from-their-position"]
---

# RFC: 도서관을 위키로 바꾼다

- 상태: 초안.
- 운영자 지시 (2026-10-13): "librarian 하고 도서관이 겹치는 의미니까 wiki 로 바꿔야할거같음". 방향은 Karpathy 의 llm-wiki 를 따른다.
- 참고: <https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f>
- 근거: §2 의 숫자는 2026-10-13 라이브 base path 의 `docs/library/` 를 읽기만 해서 셌다. §3 은 그날 `origin/main` 의 코드다.

## 0. 요약

masc 의 도서관(Library)은 마크다운 문서를 쌓아 두는 곳이다. 문제가 셋 있다.

1. 이름이 Librarian 과 겹친다. Librarian 은 Keeper 한 명의 기억을 정리하는 일이고 도서관과 상관이 없다. 그래서 용어집에 "Library 는 Librarian 과 다른 것"이라고 따로 적어야 했다 (#37519).
2. 문서를 고칠 수 없다. 넣기만 된다. 같은 주제가 v2, 부록, 다른 작성자의 새 문서로 계속 늘어난다.
3. 무엇이 있는지 한눈에 보는 목록과 언제 무엇이 바뀌었는지 적는 기록이 없다.

이 RFC 는 도서관을 위키(Wiki)로 바꾼다. 페이지는 이름이 고정되고 고쳐 쓸 수 있다. 쓸 때마다 `log.md` 에 한 줄이 붙고 `index.md` 가 다시 만들어진다.

llm-wiki 는 세 층(원재료, 위키, 스키마)과 안내 파일 둘(index, log)로 되어 있다. 이번에는 위키 층과 안내 파일 둘만 만든다.

## 1. 결정

- D1. 이름: Library → Wiki. 옛 이름은 별칭 없이 지운다.
- D2. 페이지 이름: 쓰는 쪽이 `page` 를 직접 정한다. 제목이나 날짜에서 만들지 않는다.
- D3. 만들기: `masc_wiki_create` 는 같은 `page` 가 있으면 거절한다. 덮어쓰지 않는다.
- D4. 고치기: `masc_wiki_update` 를 새로 둔다. 읽었던 판(`revision`)을 같이 보내야 하고, 그 사이 누가 고쳤으면 거절한다.
- D5. `index.md`: 서버가 페이지마다 한 줄씩 만든다. 아무도 손으로 고치지 않는다.
- D6. `log.md`: 만들기와 고치기마다 한 줄을 붙인다. 붙이기만 한다.
- D7. Keeper 는 지금도 도서관에 문서를 넣는다(`masc_library_add`). 그래서 만들기와 고치기도 Keeper 에게 그대로 열린다. Librarian 이 위키를 정리하게 하는 일은 이번에 하지 않는다.

## 2. 무슨 일이 났나

2026-10-13 라이브 `docs/library/` 에 문서가 41개 있다. 같은 주제가 여러 문서로 갈라져 있다.

| 주제 | 문서 수 | 모양 |
|---|---|---|
| GitHub Stacked PR | 5 | 2026-10-01 하루에 작성자 4명이 따로 썼다 |
| board-reading-protocol | 3 | 원본, v2, 부록 |
| kidsnote-slack-channel-nav | 2 | 원본, v2 |
| Lane Add-on 운영 가이드 | 2 | 원본, v2. 같은 날, 같은 작성자 |
| allowed_paths validator bug | 2 | 같은 날, 같은 작성자 |

고칠 수가 없으니 고친 내용을 새 문서로 낸다. 읽는 쪽은 어느 것이 최신인지 제목의 "v2" 를 보고 짐작해야 한다.

한글 제목은 파일 이름에서 사라진다. `board-reading-protocol — 판독 표면 비결정성 대응 절차` 는 `board-reading-protocol-------20260915.md` 가 된다. 제목이 전부 한글이면 파일 이름은 `-<날짜>.md` 다. 같은 날 그런 문서를 둘 넣으면 두 번째가 첫 번째를 말없이 덮는다 (§3).

41개 중 11개는 도구 시험 중에 남은 문서다 (`tool-matrix-test-*`, `admin-tool-*`, `dogfood-finding`, `nc-library-entry` 등).

## 3. 지금 구조

- 도구: `masc_library_list`, `masc_library_read`, `masc_library_search`, `masc_library_add`. Keeper 는 이 가운데 `masc_library_list` 와 `masc_library_add` 를 그대로 부르고, 읽기와 검색은 `keeper_library_read`, `keeper_library_search` 라는 이름으로 부른다(`Keeper_tool_descriptor.masc_library_descriptor`). 라이브 문서 41개의 작성자도 대부분 Keeper 다. 용어집의 "Keeper 쪽에는 read-only 투영만 있다" 는 문장은 틀렸다.
- 리소스: `masc://library`, `masc://library.json` (`config/mcp/resources.toml`).
- 저장: `<base_path>/docs/library/<slug>-<YYYYMMDD>.md` (`lib/tool_library.ml`). slug 는 제목을 소문자로 바꾸고 `a-z`, `0-9`, `-` 밖의 글자를 버린 것이다.
- 쓰기: `Out_channel.with_open_text` 로 바로 쓴다. 같은 파일이 있으면 내용을 비우고 새로 쓴다. 잠금도 임시 파일도 없다.
- frontmatter: `title`, `source`, `author`, `created`, `updated`, `tags`. `updated` 는 쓰기만 하고 읽는 곳이 없다 (`tool_library.ml` 주석).
- 고치기 도구가 없다. 같은 제목으로 다시 `add` 하면 같은 날에는 덮어쓰고, 다른 날에는 새 문서가 생긴다.
- 이 이름을 쓰는 곳: 코드, 설정, 테스트, 현행 문서를 합쳐 52개 파일. `docs/evidence`, `docs/rfc`, `docs/audits`, `changelog.d`, `CHANGELOG.md` 는 뺀 수다.

## 4. 설계

### 4.1 D1 — 이름 바꾸기

| 지금 | 바뀐 뒤 |
|---|---|
| `masc_library_list`, `read`, `search`, `add` | `masc_wiki_list`, `read`, `search`, `create`, `update` |
| `keeper_library_read`, `search` | `keeper_wiki_read`, `search` |
| `masc://library`, `masc://library.json` | `masc://wiki`, `masc://wiki.json` |
| `<base_path>/docs/library/` | `<base_path>/.masc/wiki/` |
| `Tool_library`, `tool_schemas_library*`, `tool_shard_types_schemas_library*` | `Tool_wiki`, `tool_schemas_wiki*`, `tool_shard_types_schemas_wiki*` |
| 용어집 `Library` | 용어집 `Wiki`, `Page revision`. `Librarian` 항목은 그대로 둔다 |

옛 이름을 받는 별칭은 만들지 않는다. 옛 경로를 읽는 코드도 만들지 않는다. 용어집에도 옛 이름을 안내하는 줄을 남기지 않는다.

용어집 `Wiki` 항목에는 경계를 한 줄로 적는다: Wiki 는 이름 붙은 공유 페이지이고 사람과 Keeper 가 같이 본다. Keeper 한 명의 기억(Memory OS, Librarian)과는 다른 것이다.

용어집에는 `revision` 이 이미 여럿 있다(`Backlog revision`, `content_revision` 등). 위키의 것은 `Page revision` 으로 부른다.

지난 기록(`docs/evidence`, 지난 RFC, 감사 문서, changelog)은 그 날짜에 있었던 일이라 고치지 않는다.

라이브의 옛 문서 41개를 어떻게 할지는 §8 Q1 이다.

### 4.2 D2 — 페이지 이름

- `page` 는 `a-z`, `0-9`, `-` 로만 된 문자열이다. 비어 있으면 안 되고 `-` 로 시작하거나 끝나면 안 된다.
- 쓰는 쪽이 정한다. 규칙에 안 맞으면 고쳐 주지 않고 거절한다. 지금처럼 글자를 몰래 버리면 서로 다른 제목이 같은 이름으로 모인다.
- 파일은 `<base_path>/.masc/wiki/<page>.md` 다. 이름에 날짜를 넣지 않는다. 날짜는 frontmatter 와 log 에 있다. 위키는 서버가 자기 세계를 위해 쓰는 상태라 다른 상태와 함께 `.masc/` 아래에 둔다. workspace 의 `docs/` 에 두면 그 workspace 가 속한 저장소의 파일로 섞인다.
- `title` 은 어느 나라 글자로든 쓸 수 있다. 한글도 된다.
- 머리말에 한 줄로 들어가는 값(`title`, `summary`, 쓴 사람 이름, 태그 하나하나)은 비어 있지 않은 한 줄이어야 하고 앞뒤에 공백이 없어야 한다. 읽을 때 앞뒤 공백을 잘라 내므로, 그렇지 않은 값은 쓴 것과 다르게 읽힌다. 태그에는 쉼표도 쓸 수 없다. 쉼표가 태그를 나누기 때문이다. 이 규칙에 안 맞는 값은 고쳐 쓰지 않고 거절한다.
- 한글로 찾을 때는 `title` 이 그 구실을 한다. `masc_wiki_read` 는 지금처럼 제목의 일부로도 페이지를 찾고, `masc_wiki_search` 는 frontmatter 를 포함한 파일 전체에서 찾는다. 그래서 따로 한글 별칭 칸을 두지 않는다.
- `index` 와 `log` 는 페이지 이름으로 쓸 수 없다.

### 4.3 D3·D4 — 만들기와 고치기

페이지 frontmatter 는 이렇게 생겼다.

```markdown
---
title: 사주팔자
summary: mix-man 의 정식 제목. 같은 흐름을 두 번 돌고 클라이맥스는 3:54
source: observation
author: claude
created: 2026-10-13
updated: 2026-10-13
revision: 1
tags: [band, song]
---
```

- `revision` 은 1 에서 시작해서 고칠 때마다 1 씩 는다. 용어집 이름은 `Page revision` 이다.
- `summary` 는 한 줄이다. 비어 있거나 줄바꿈이 있으면 거절한다. index 에 이 줄이 들어간다.
- `source` 는 지금 도서관의 네 가지(`direct_experience`, `research`, `experiment`, `observation`)를 그대로 쓴다. 만들 때 꼭 넣어야 하고, 고칠 때는 바꾸지 않는다. 페이지가 처음 어떤 일에서 나왔는지를 적는 칸이기 때문이다.
- `masc_wiki_create(page, title, summary, source, tags, body)`: `page` 가 이미 있으면 거절한다.
- `masc_wiki_update(page, base_revision, body, note, title?, summary?, tags?)`:
  - 파일의 `revision` 이 `base_revision` 과 다르면 거절한다. 거절 응답에는 지금 `revision` 과 지금 본문을 같이 싣는다. 쓰는 쪽은 다시 읽지 않고 그 본문에 자기 변경을 합쳐서, 받은 `revision` 을 `base_revision` 으로 다시 보낸다. 합치기는 쓰는 쪽이 한다. 서버는 본문을 합치지 않는다. Keeper 도 같은 규칙을 따른다. 도구 설명에 이 순서를 적는다. geek-scout 가 낸 쓰임새(며칠에 걸쳐 사실이 쌓이는 조사를 페이지 하나로 계속 고치기)가 이 경로다.
  - 같으면 본문을 통째로 바꾼다. `revision` 을 1 올리고 `updated` 를 오늘로 바꾼다.
  - `note` 는 log 에 들어갈 한 줄이다. 무엇을 왜 고쳤는지 적는다. 비어 있으면 거절한다.
- `masc_wiki_read` 는 본문과 함께 `revision` 을 돌려준다.
- 쓰는 순서: 페이지 → `log.md` 한 줄 → `index.md`. 셋 다 위키 디렉터리 잠금 하나 안에서 한다.
  - 페이지와 index 는 임시 파일에 쓰고 rename 한다 (`Fs_compat.write_file_atomic_strict_staged`).
  - 잠금은 프로세스 사이에서도 걸리는 파일 잠금(`File_lock_eio`)을 쓴다. 여러 세션과 Keeper 가 같은 디렉터리에 쓰기 때문이다.

### 4.4 D5 — `index.md`

```markdown
# Wiki index

- [사주팔자](saju-palja.md) — mix-man 의 정식 제목. 같은 흐름을 두 번 돌고 클라이맥스는 3:54
- [YTN](ytn.md) — 11박 리프. A 를 계속 울리고 위의 손모양만 움직인다
```

- 서버가 쓰기마다 모든 페이지의 frontmatter 를 읽어서 다시 만든다.
- 페이지 이름 순서로 쓴다.
- frontmatter 가 안 읽히는 페이지는 지금 `masc_library_list` 처럼 파일 이름과 이유를 한 줄로 쓴다.
- `masc_wiki_list` 와 `masc://wiki` 는 이 파일을 그대로 돌려준다.

### 4.5 D6 — `log.md`

```markdown
## [2026-10-13 21:40] create r1 | saju-palja | claude | 첫 정리
## [2026-10-13 22:05] update r2 | saju-palja | claude | YTN 과 비교한 문단을 더했다
```

- 붙이기만 한다. 줄을 지우거나 고치는 도구는 없다.
- 시간은 서버 로컬 시각, 분 단위다. 지금 도서관 파일 이름이 로컬 날짜를 쓰는 것과 같다.
- 줄 머리가 `## [` 로 같아서 `grep "^## \[" log.md | tail -5` 로 최근 변경을 볼 수 있다. llm-wiki 가 권하는 모양이다.

### 4.6 남는 틈

- 페이지를 쓰고 log 를 붙이기 전에 서버가 죽으면 그 변경의 log 줄이 없다. 페이지의 `revision` 과 log 에 남은 그 페이지의 마지막 revision 을 비교하면 찾을 수 있다. 찾아 주는 점검 도구(llm-wiki 의 lint)는 이번에 만들지 않는다.
- 페이지 이름을 바꾸거나 페이지를 지우는 도구가 없다. 필요해지면 따로 정한다.

## 5. 하지 않는 것

- **Librarian 이 위키를 정리하기**: Keeper 가 턴 안에서 직접 쓰는 것과 달리, Librarian 이 대화에서 내용을 뽑아 페이지를 고치는 일은 이번에 하지 않는다. 뼈대가 실제로 돌아가는 걸 본 다음 RFC 에서 정한다.
- **게시판 글을 위키로 옮기기**: 게시판 글은 기본으로 사라지지 않는다(`Board_types.Limits.default_ttl_hours = 0`). 대신 주제별로 모이지 않고 흩어진다. 남길 내용을 정리된 페이지로 옮겨 적는 동작은 이 RFC 다음 단계다. 지금 board 첨부 작업이 같은 TUI board 화면을 고치고 있어서 겹치지 않게 뒤로 둔다.
- **원재료 층과 점검(lint)**: llm-wiki 의 나머지 두 부분이다. 이번에는 만들지 않는다.
- **공유 기억의 원장과 log**: #41957 이 따로 다룬다. 두 log 는 다른 것이다. 위키 log 는 페이지가 바뀐 기록이고, #41957 의 log 는 Keeper 들이 낸 사실의 기록이다. 용어집에 둘을 나눠 적는다.
- **검색 개선**: 지금처럼 부분 문자열로 찾는다.

## 6. 검증

단위 테스트는 저장된 파일만 본다. 화면 문구는 보지 않는다.

- create 가 이미 있는 page 를 거절하고, 그 파일은 그대로다.
- update 가 낡은 `base_revision` 을 거절하고, 그 파일은 그대로다. 거절 응답에 지금 `revision` 과 지금 본문이 들어 있다.
- update 로 `source` 를 바꿀 수 없다.
- update 가 `revision` 을 1 올리고 본문을 바꾼다.
- 규칙에 안 맞는 page 를 거절한다: 대문자, 한글, 빈 값, `-` 로 시작, `index`, `log`.
- 한글 `title` 이 frontmatter 와 index 에 그대로 남는다.
- create 한 번, update 두 번 뒤 `log.md` 에 그 page 줄이 3개, `index.md` 에 그 page 줄이 1개다.
- `summary` 가 비었거나 줄바꿈이 있으면 거절한다.

이름 바꾸기는 이렇게 확인한다.

- `git grep -E "masc_library_|keeper_library_|Tool_library|docs/library|masc://library"` 결과가 `docs/evidence`, `docs/rfc`, `docs/audits`, `changelog.d`, `CHANGELOG.md` 밖에서 0건이다.
- 도구 목록 테스트(`test_enum_mirror_sync`, tool name prefix, catalog coverage)가 새 이름으로 통과한다.

라이브에서는 배포 뒤 밴드 정리 페이지 9개(곡 7, 곡 비교, 셋리스트)를 만들고 한 페이지를 두 번 고친다. `index.md` 9줄, 그 페이지의 log 3줄을 확인한다.

## 7. 확신도

- 문제(§2, §3): 높음. 라이브 파일과 `lib/tool_library.ml` 을 직접 읽었다.
- 설계: 중간. `revision` 으로 동시 수정을 막는 방식은 task 의 `expected_version` 과 같은 모양이다. Keeper 가 실제로 거절을 받고 다시 보내는지는 배포 뒤 log 로 확인한다.
- 이름 바꾸기에서 놓치는 곳: 낮음. §6 의 `git grep` 이 잡는다.

## 8. 열어 둔 물음

- **Q1. 옛 문서 41개**
  - (a) 하드컷: 위키는 빈 채로 시작한다. 남길 문서만 새 페이지로 옮겨 적는다. 같은 주제의 여러 문서는 이때 하나로 합친다. 옛 `docs/library/` 는 읽는 코드가 없어지고, 운영자가 지운다.
  - (b) 옮기기: 배포 때 스크립트로 `summary` 와 `revision: 1` 을 붙여서 옮긴다.
  - 제안은 (a) 다. 41개 중 11개가 시험 문서이고, 남길 만한 문서는 v2 로 갈라져 있어서 어차피 합쳐야 한다.
  - Keeper 의견(2026-10-13 게시판): geek-scout 가 (a) 에 찬성했다. 스크립트로 옮기면 시험 문서까지 옮긴다는 이유다.
- **Q2. page 를 ASCII 로만 받을지**: 한글 파일 이름은 macOS 가 자모를 풀어서(NFD) 저장한다. 같은 이름이 두 가지로 보일 수 있다. 제안은 ASCII 다.
  - Keeper 의견: geek-scout 와 glossary-maniac 이 ASCII 에 찬성했다. 한글로 찾는 문제는 `title` 로 푼다(§4.2).
- **Q3. (닫힘) Keeper 쓰기**: 초안은 "Keeper 는 읽기만 한다" 고 적었는데 틀렸다. Keeper 는 지금도 `masc_library_add` 를 부른다. 그래서 따로 열 것이 없고, create 와 update 가 같은 경로로 Keeper 에게 간다.

## 9. 구현 순서

Native Stack 으로 올리고, 맨 위 PR 로 한 번에 병합한다.

1. 이름 바꾸기 (D1). 동작은 그대로 둔다.
2. page 이름, create, update, `revision`, 잠금, 원자적 쓰기 (D2–D4).
3. `index.md` 와 `log.md` (D5–D6).

구현은 스택 #42706 (#42703, #42704, #42705) 이다. 설계와 다르게 한 곳이 둘 있다.

- `masc_wiki_list` 는 `index.md` 파일을 읽어 돌려주지 않고, 부를 때 페이지에서 바로 만든다. 파일에 쓰는 것과 같은 함수를 쓰므로 내용은 같다. 손으로 고친 페이지가 있어도 목록이 맞게 나온다.
- `masc://wiki` 리소스는 지금 모양을 그대로 둔다. 리소스의 줄에는 `masc://wiki/<topic>` 주소가 들어 있고, 리소스를 읽는 쪽은 그 주소가 필요하다.

`note` 는 고치기에만 받는다. 만들기는 페이지의 `summary` 를 log 에 적는다.
