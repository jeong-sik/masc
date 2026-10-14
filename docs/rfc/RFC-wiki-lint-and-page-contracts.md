---
rfc: "wiki-lint-and-page-contracts"
title: "위키에 읽기 전용 점검(lint)을 더하고 페이지·log·출처의 호환 규칙을 정한다"
status: Draft
created: 2026-10-13
updated: 2026-10-13
author: masc-productor-owner
supersedes: []
superseded_by: null
related: ["library-becomes-a-wiki"]
---

# RFC: 위키에 읽기 전용 점검을 더하고 페이지·log·출처의 호환 규칙을 정한다

- 상태: 초안. 날짜는 UTC 기준이다.
- 운영자 지시 (2026-10-13T19:39Z, 19:45Z): 위키를 Karpathy 의 llm-wiki 패턴 수준으로 완성한다. 구현 상세는 Keeper 들과 논의해 만든다. v0.54.0 컷 전에는 구현 PR 을 시작하지 않는다.
- 논의 기록: Board `p-e5b36ba455cfa0e42f267b4dc9729296` (설계 창 2026-10-13T19:45Z~20:17Z, 리더 정리 `c-331058eea665b8c6e0401f40c5eb907b`), 스펙 초안 Board `p-2f3637882b00e57543ac545ecce75a2c`.
- 이 문서는 새 규범을 만들지 않는다. 세계 헌법에 기록할 것이 없다. 기존 조항은 대응만 적는다(§11).
- 표기: 직접 읽은 것은 좌표를 적고, 남의 읽기를 옮긴 것은 "(옮김: 누구)", 근거가 약한 것은 "추정", 읽지 못한 것은 "미확인"으로 적는다. 읽은 범위는 §13 에 모았다.

## 0. 요약

위키에는 지금 쓰고 읽는 도구만 있고, 페이지들이 서로 맞는지 보는 도구가 없다. 이 RFC 는 세 가지를 정한다.

1. 읽기 전용 점검 도구 `masc_wiki_lint` 하나를 더한다. 모델도 네트워크도 쓰지 않고, 아무것도 쓰지 않는다. 깨진 링크, 고아 페이지, 출처 없는 페이지, 읽히지 않는 페이지, 받지 않는 링크 형식을 건수와 목록으로 낸다.
2. 앞으로 위키를 넓힐 때 옛 페이지와 옛 바이너리가 깨지지 않도록 페이지 헤더, log, 출처 표기의 호환 규칙을 먼저 적는다.
3. 위키가 쓸모 있는지 재는 질문 묶음과 조건을 정한다.

Keeper 턴에 위키 목차를 싣는 일은 이 RFC 가 다루지 않는다. 그것은 Draft PR #42951(`RFC-keepers-see-the-wiki-table-of-contents.md`, task-2316)의 범위다(§10).

## 1. 결정

- D1. 원문·위키·스키마 세 층을 §3 의 표대로 둔다. 원문 층은 복사본 폴더가 아니라 참조다(운영자 확정 전, §12 Q1).
- D2. `masc_wiki_lint` 는 설정 스위치 없이 싣는다. 부르지 않으면 아무 일도 일어나지 않는다(리더 결정 `c-e63bcd39744d2888ed2626e20db0e783`).
- D3. 링크로 받는 형식은 `[글자](page.md)` 하나다. 그 밖의 형식은 오류도 무시도 아니고 `unsupported_link` 값으로 남긴다(§5).
- D4. 페이지 헤더에 새 필수 키를 더하지 않는다. `source` 에 새 값을 더하려면 모르는 값을 견디는 읽기가 먼저 배포되어야 한다(§6).
- D5. log 를 해석하는 파서는 한 곳에만 둔다. 모르는 동작 단어는 실패하지 않고 건너뛰되 건수를 보고한다. 개행으로 끝나지 않은 마지막 조각은 줄로 세지 않는다(§7).
- D6. 출처는 본문 `## Sources` 절에 한 줄에 하나씩 적는다. 기존 `source` 칸은 그대로 둔다. `said:` 는 원문으로 치지 않는다(§8).
- D7. 작업공간 기억 원장의 claim 은 위키 출처가 될 수 없다. 위키에서 원장으로 가는 방향은 닫아 둔다. Curator 가 쓰는 페이지는 `author` 칸이나 이름 접두로 구분하고 `source` 값으로 구분하지 않는다(§9).
- D8. lint 의 판단은 순수 모듈 다섯 개에 두고 서버 도구는 얇게 둔다. 동작을 바꾸지 않는 리팩터링 PR 이 먼저다(§4.4).
- D9. 쓸모는 질문 10개를 세 조건에서 채점해 잰다(§10.2).

## 2. 지금 구조 (직독과 옮김, 좌표는 §13)

- 페이지: `<base_path>/.masc/wiki/<page>.md`. 이름은 `[a-z0-9-]+` 이고 처음과 끝에 `-` 를 둘 수 없으며 `index`, `log` 는 예약이다(옮김: ocaml-agent-ic, `tool_wiki.ml:384-402`).
- 헤더: YAML frontmatter 일곱 키(`title`, `summary`, `source`, `author`, `created`, `revision`, `tags`)를 읽고 모두 필수다. `updated` 는 쓰지만 읽지 않는다(`tool_wiki.ml:140-151` 주석과 타입). `source` 는 `direct_experience`, `research`, `experiment`, `observation` 넷이고, 모르는 값이면 `Unknown_source` 로 그 페이지가 읽히지 않는다(`tool_wiki.ml:211`, 235). update 는 `source` 변경을 거절한다(`tool_wiki.ml:682`).
- 도구 일곱 개: `masc_wiki_list`, `masc_wiki_read`, `masc_wiki_search`, `masc_wiki_create`, `masc_wiki_update`, `keeper_wiki_read`, `keeper_wiki_search` (`config/tools/` 의 toml 일곱 개).
- log: `log.md` 에 `## [YYYY-MM-DD HH:MM] <create|update> r<N> | <page> | <author> | <note>` 줄을 제자리에 덧붙인다. 동작은 둘뿐이다(옮김: code-reviewer·ocaml-agent-ic, `wiki_journal.ml:41-71`). log 의 동작 단어를 해석하는 읽기 코드는 지금 없다. `masc://wiki/log` 는 로그의 꼬리(마지막 64 KiB, 줄 경계에서 시작)를 내주고, 목록의 `size` 는 파일 전체 크기다(옮김: ocaml-agent-ic·code-reviewer, `mcp_server_eio_resource.ml`).
- 링크: 코드에 링크를 해석하는 곳이 없다(옮김: ocaml-agent-ic). 링크 모양이 나오는 곳은 index 를 그리는 `- [제목](파일) — 요약` 하나다.
- 라이브 위키(2026-10-13, 직독): 페이지 11장. 페이지 사이 링크 30개가 모두 `[글자](page.md)` 형식이고 깨진 것 0개, 들어오는 링크가 없는 페이지 1장(`rfc-map`), 구조화된 출처 참조가 있는 페이지 0장.
- 없는 것: lint, ingest, promote, 링크 해석, 원문 층, 스키마 페이지, 삭제, 이름 바꾸기, 사용 가이드.

`lib/tool_wiki.ml`, `lib/tool_wiki.mli`, `lib/wiki_journal.ml`, `lib/wiki_journal.mli` 는 `4a7e2013a3` 과 `origin/main` `5d142b8fb2` 사이에 차이가 없다(`git diff --stat` 출력이 비어 있음). 위 좌표는 두 커밋에서 같다.

## 3. 세 층

| llm-wiki 의 층 | MASC 에서 | 지금 | 이 RFC 뒤 |
|---|---|---|---|
| 원문 (raw sources) | 다시 읽을 수 있는 대상을 가리키는 참조: 저장소 커밋의 파일, Board 글·댓글, artifact 해시, 읽은 날짜가 붙은 URL | 없음. 페이지가 출처를 산문으로만 적는다 | 본문 `## Sources` 절의 줄 형식(§8). 복사본 폴더는 만들지 않는다 |
| 위키 | `.masc/wiki/<page>.md` 와 `index.md`, `log.md` | 있음 | 그대로. 점검 도구가 붙는다 |
| 스키마 | 위키를 어떻게 쓰는지 적은 예약 페이지 `schema.md` | 없음 | 2단계에서 페이지로 만든다. 1단계에서는 이 RFC 와 가이드가 그 역할을 한다 |

llm-wiki 의 작업은 ingest, query, lint 셋이다. promote 는 운영자 지시의 넷째 작업이고 원문 패턴에 있는 말이 아니다. 이 RFC 가 구현하는 것은 lint 하나다. ingest·query·promote 는 서버가 모델을 돌리는 기능이 아니라 Keeper 가 따르는 절차(Skill)로 두는 것이 리더 의견이고, 운영자 확정 전이다(§12 Q2).

## 4. lint

### 4.1 성질

- 읽기 전용. 페이지, index, log, 잠금 파일 어느 것도 만들거나 고치지 않는다. `with_wiki_lock` 은 `.wiki.lock` 을 만들기 때문에 lint 는 잠금을 잡지 않는다(옮김: code-reviewer, `tool_wiki.ml:455-470`).
- 결정적. 같은 디렉터리 바이트에 같은 출력. 출력에 시각과 난수가 없고 목록은 이름순이다.
- 모델 호출 없음, 네트워크 없음. `http(s)` 링크는 확인하지 않는다.
- 결과 크기 상한. 도구 결과가 16,384 바이트를 넘으면 봉인된 blob 이 되어 Keeper 가 다시 읽어야 한다(옮김: code-reviewer, `Common.max_tool_result_wire_bytes`). 그래서 출력은 건수 요약과 종류별 앞쪽 일부, 이어 읽기 커서로 나눈다.

### 4.2 입력과 출력 스키마

아래 이름과 타입은 1c 구현에 맞춘 것이다(#42969, main `0a7b21f2f4` 의 `lib/wiki_lint_report.ml` 전체와 `lib/tool_wiki.ml:513-607` 직독). 구현이 바뀌면 이 절을 같은 PR 에서 고친다. 거절되는 입력: 타입이 틀린 값(`{"limit": "20"}`, `{"kind": 5}`), 모르는 `kind`, 1 미만의 `limit`, 이 도구가 내지 않은 모양의 `cursor`, 낡은 `cursor`, 이름 규칙을 어긴 `page`.

입력:

| 필드 | 타입 | 뜻 |
|---|---|---|
| `page` | string, 선택 | 페이지 이름 하나. 주면 그 페이지에서 나온 발견만 낸다. 고아 판정은 전체를 읽어야 하므로 읽는 범위는 줄지 않는다 |
| `kind` | string, 선택 | 아래 `kind` 값 하나로 거른다 |
| `limit` | int, 선택 | 한 번에 내는 발견 수. 기본 50, 최대 200 이고 200 을 넘는 값은 200 으로 맞춘다. 1 미만은 거절한다. 이와 별개로 한 응답에 싣는 발견의 JSON 은 합쳐 12,000 바이트까지다. 응답은 발견을 적어도 하나 실으므로 긴 발견 하나는 이 값을 넘을 수 있다 |
| `cursor` | string, 선택 | 앞 응답의 `next_cursor`. 모양은 `o:<건너뛸 수>:<지문 12자>` 다. 지문은 `kind`·`page` 로 거른 발견 목록에서 나온다. 목록이 달라지면(위키가 바뀌었거나 거르는 값을 바꿨으면) 낡은 커서로 거절하고 커서 없이 다시 부르라고 답한다. 조용히 건너뛰거나 되풀이하지 않기 위해서다 |

출력:

| 필드 | 타입 | 뜻 |
|---|---|---|
| `schema` | string | `"masc.wiki_lint.v1"` |
| `pages_total` | int | 위키 디렉터리의 페이지 파일 수. `Tool_wiki.list_pages` 와 같은 거름을 쓴다: `.md` 로 끝나는 파일 가운데 `Wiki_journal.is_own_file` 이 거르는 `index.md`, `log.md` 를 뺀다. `.wiki.lock` 은 페이지로 세지 않는다(옮김: code-reviewer, `tool_wiki.ml:250-259`). 목록을 낸 뒤 읽기 전에 사라진 파일은 세지 않는다(`lib/tool_wiki.ml:519-546`, main `0a7b21f2f4` 직독) |
| `pages_unreadable` | int | 헤더가 읽히지 않았거나, 있는데 열 수 없었던 파일 수 |
| `counts` | object | `kind` 마다 int 하나. `kind`·`page` 로 거르기 전의 전체 건수 |
| `matched` | int | `kind`·`page` 로 거른 뒤의 발견 수. `findings` 는 그 가운데 한 쪽이다 |
| `findings` | array of finding | 이름순, 같은 페이지 안에서는 줄 번호순 |
| `truncated` | bool | 더 있으면 true |
| `next_cursor` | string 또는 null | 더 있을 때만 문자열이다. 다음 호출의 `cursor` 로 넘긴다 |
| `log_unknown_action` | int | `log.md` 에서 동작 단어가 §7 의 아는 둘 밖인 줄의 수 |
| `log_unreadable_line` | int | `log.md` 에서 줄로 읽히지 않은 줄의 수. 개행으로 끝나지 않은 마지막 조각은 줄이 아니므로 여기에도 세지 않는다 |
| `revision_log_hole_suppressed` | bool | 두 파서 건수 중 하나라도 0 보다 크면 true. 이때 `revision_log_hole` 점검이 꺼지므로 빈 `revision_log_hole` 목록을 "구멍 없음" 으로 읽지 않는다. `log.md` 는 덧붙이기만 하므로 한 번 버린 줄이 들어가면 그 위키가 사는 동안 꺼진 채이고, 손으로 `log.md` 를 고쳐야 다시 켜진다(§4.5) |

finding 은 `kind` 로 갈리는 객체다.

| `kind` | 나머지 필드 | 뜻 |
|---|---|---|
| `broken_link` | `page`: string, `line`: int, `target`: string | 위키 안 페이지를 가리키는 형식인데 그 페이지 파일이 없다 |
| `unsupported_link` | `page`: string, `line`: int, `form`: string, `target`: string | 받지 않는 링크 형식(§5). 오류가 아니다 |
| `orphan` | `page`: string | 다른 읽힌 페이지에서 들어오는 링크가 0개. 자기 자신으로 가는 링크와 `index.md` 의 줄은 세지 않는다 |
| `orphan_unconfirmed` | `page`: string | 들어오는 링크가 0개지만 읽히지 않은 페이지가 있어 확정하지 못한다 |
| `missing_sources` | `page`: string | `## Sources` 절이 없거나 그 절에 읽히는 참조 줄이 하나도 없다(§8) |
| `hearsay_only` | `page`: string | 참조 줄이 `said:` 뿐이다 |
| `unreadable_page` | `file`: string, `reason`: string | 헤더가 읽히지 않거나, 파일이 있는데 열 수 없다. `reason` 은 앞의 경우 기존 `frontmatter_error_to_string` 의 문장이고, 뒤의 경우 `the file could not be opened: ` 로 시작한다 |
| `revision_log_gap` | `page`: string, `log_revision`: int, `page_revision`: int | log 가 이 페이지에 기록한 가장 높은 `r<N>` 을 페이지가 닿지 못했다(§4.5). `log_revision` 이 그 `N`, `page_revision` 이 파일이 지닌 revision 이다. 반대 방향은 발견이 아니다 |
| `revision_log_hole` | `page`: string, `missing`: int | log 가 이 페이지에 기록한 가장 높은 `r<N>` 아래에서 `r<missing>` 을 건너뛰었다(§4.5). 한 페이지의 줄은 `r1`, `r2`, … 로 건너뜀이 없으므로, 빠진 값은 페이지에는 닿고 log 에는 닿지 못한 줄이다. log 에 파서가 버린 줄이 하나라도 있으면(`unknown_action`·`unreadable_line` > 0) 구멍을 확정하지 않고, 열의 시작은 그 페이지 log 줄의 최저값으로 둔다 |

대상이 읽히지 않는 페이지인 링크는 `broken_link` 가 아니다. 파일은 있으므로 그 페이지의 `unreadable_page` 한 번으로만 보고한다(옮김: ocaml-agent-ic).

### 4.3 첫 조각에 넣지 않는 것

- `revision_log_gap` (log 와 페이지 revision 의 어긋남). 첫 조각에는 log 파서가 없어 뺐고, 2단계에서 넣었다(§4.5, §7).
- `revision_log_hole` (log revision 열의 중간 구멍). 2단계에서 넣었다(§4.5).
- 모순 후보. 첫 조각에서 뺀다(리더 정리). 원장을 lint 입력으로 쓰는 일은 닫은 것이 아니라 미룬 것이다. §9 의 "이 RFC 의 결정"이 조건을 적고, 다시 다루는 자리는 §11.2 의 3단계다.
- 입구에서 닿지 않는 페이지(`unreachable`). 입구를 적는 스키마 페이지가 아직 없다. 2단계.
- 순환. 지금 11장은 서로 링크하는 구조라 순환은 결함이 아니다(옮김: ocaml-refactor-woman). 오류로 내지 않는다.

### 4.4 모듈

의존은 위에서 아래로만 흐른다(옮김: ocaml-refactor-woman `c-65d0c4a8ed7b9c79b48bfc94e1920fd9`).

| 모듈 | 성격 | 하는 일 |
|---|---|---|
| `Wiki_page_name` | 순수 | 페이지 이름 타입. 지금 `Tool_wiki` 안의 이름 검사를 꺼낸다 |
| `Wiki_page` | 순수 | frontmatter 파싱, `Line`, `Tag`, `source` 어휘. 지금 `Tool_wiki` 안에 있다 |
| `Wiki_link` | 순수 | 본문 한 장에서 링크 목록을 뽑는다. 항상 성공한다 |
| `Wiki_graph` | 순수 | 노드 목록에서 깨진 링크와 고아를 계산한다. 입력 순서에 결과가 달라지지 않는다 |
| `Wiki_lint` | 순수 | 그래프에서 finding 목록을 만든다. 닫힌 변이형, 정렬된 출력 |
| `Tool_wiki_lint` | 서버 | 파일 읽기, 상한, 커서, 출력 렌더링 |

- 선행 PR: `Tool_wiki` 안의 순수한 부분을 `Wiki_page_name`, `Wiki_page` 로 꺼내고 `Tool_wiki` 가 그것을 쓰게 한다. 동작은 바뀌지 않는다. 수용 기준은 기존 위키 테스트가 고치지 않은 채 통과하는 것이다. 이렇게 해야 서버 도구와 lint 가 같은 정의를 써서 "도구는 받는데 lint 는 못 읽는 페이지"가 생기지 않는다.
- 순수 코어를 `unix`·`eio` 에 의존하지 않는 별도 dune 라이브러리로 둘지는 구현자가 정한다. `lib/dune` 의 `masc` 는 `(include_subdirs unqualified)` 인 한 라이브러리이고 위키 파일은 `lib/` 바로 아래에 있다(옮김: ocaml-agent-ic, PR #42963 댓글 6154636361).
- `Tool_wiki` 의 `Tag` 와 `parse_frontmatter` 는 `lib/mcp_server_eio_resource.ml` 이 쓴다(`parse_frontmatter` 는 72·320·383행, `Tag` 는 330·351행). `Line` 을 `Tool_wiki` 밖에서 쓰는 곳은 `test/test_tool_wiki_coverage.ml` 뿐이다(main `0a7b21f2f4` 의 `lib`·`test`·`bin` 에서 `Tool_wiki.Line`, `Tool_wiki.Tag`, `Tool_wiki.parse_frontmatter` 를 찾아 직독. 처음 읽은 이는 ocaml-agent-ic, PR #42963 댓글 6154636361). 그래서 선행 PR 은 `Tool_wiki` 가 같은 이름을 다시 내보내는 형태여야 기존 테스트를 고치지 않고 통과한다.

### 4.5 동시 쓰기

쓰기 순서는 잠금 아래에서 페이지(원자적 rename), log 한 줄, index 재작성이다(옮김: code-reviewer, `write_page`). 읽기는 잠금을 잡지 않는다. 페이지 하나는 옛것 아니면 새것 전체로 읽힌다. 첫 조각은 페이지만 읽으므로 이것으로 충분하다. log 와 페이지를 함께 보는 2단계에서는 "log 에 `rN` 줄이 있는데 페이지 revision 이 N 보다 작다"만 오류이고 반대 방향은 보류로 낸다(옮김: code-reviewer `c-3082797d1fe2850cff4d07ea2ce8866e`).

2단계의 구현은 이렇다. log 가 한 페이지에 기록한 가장 높은 `rN` 을 그 페이지가 닿지 못했으면 `revision_log_gap` 한 건을 내고, 페이지마다 최대 한 건이다(네 번 뒤진 페이지를 네 건으로 세지 않는다). 반대 방향 — 페이지가 log 보다 앞선 경우 — 은 발견으로 내지 않는다. 읽기가 잠금을 잡지 않으므로 쓰는 중인 페이지를 그 쓰기의 log 줄보다 먼저 볼 수 있고, 그것은 위 쓰기 순서의 정상적인 중간 상태다.

그 중간 상태는 열의 끝만 비운다. `append_log` 가 실패하면 페이지는 `rN` 인데 log 에 그 줄이 없다. 그 뒤 성공한 쓰기가 `r(N+1)` 줄을 적으면, log 열에 `rN` 만 빠진 **중간 구멍**이 생긴다. 그래서 한 페이지의 줄이 `r1`, `r2`, … 로 건너뜀이 없다는 성질을 쓴다. log 가 그 페이지에 기록한 가장 높은 수 아래에서 빠진 수가 있으면 `revision_log_hole` 한 건을 내고 `missing` 에 그 수를 싣는다(옮김: context-reviewer `c-c1bc846252da35cb952ee816ced03a72`). task-2362 에서 구현했다.

이 규칙이 거짓이 되는 자리 둘은 추측하지 않고 거절한다(옮김: context-reviewer review 5517474527, code-reviewer FAIL 5517521234). 첫째, 파서가 버린 줄(모르는 동작 단어, 못 읽은 줄)은 그 페이지의 `r<N>` 을 실었을 수 있는데 그 페이지가 바로 읽을 수 없는 자리다. 그래서 log 에 그런 줄이 하나라도 있으면 구멍을 확정하지 않는다. 둘째, create 줄 없이 log 가 시작한 페이지는 `r1` 로 시작한다고 두면 영구히 `hole r1` 이 된다. 그래서 열의 시작은 그 페이지 log 줄의 최저값으로 둔다. 두 경우는 쓰는 중인 상태와 달리 잠금으로도 구별되지 않으므로, 모르는 것을 "없다" 로 채우지 않는 쪽을 택했다.

## 5. 링크 문법

| 본문에 적힌 것 | 판정 |
|---|---|
| `[글자](page.md)` 이고 `page` 가 이름 규칙을 지킴 | 위키 링크. 파일이 없으면 `broken_link` |
| `[글자](Foo.md)` 처럼 이름 규칙을 어김 | `broken_link`. 도구가 이름을 고치지 않고 거절하는 것과 같은 태도다 |
| `[글자](page.md#절)` | `unsupported_link` |
| `[글자](../x.md)`, `[글자](a/b.md)` | `unsupported_link` |
| `[[이름]]` | `unsupported_link` |
| `[글자](http://…)`, `[글자](https://…)` | 바깥 링크. 확인하지 않고 발견으로 내지 않는다 |
| `[글자](index.md)`, `[글자](log.md)` | 위키 자신의 파일. 발견으로 내지 않는다(제안, 옮김: ocaml-agent-ic) |
| 코드 펜스와 인라인 코드 안의 링크 모양 | 건너뛴다 |
| 이미지 `![글자](…)` | 건너뛴다(제안) |

- 파서는 총합 함수다. 예외를 던지지 않고 모르는 모양을 값으로 돌려준다. 무엇을 오류로 볼지는 파서가 아니라 `Wiki_lint` 의 규칙이 정한다.
- 선형 스캔 한 번이고 되돌아가는 정규식을 쓰지 않는다(옮김: ocaml-refactor-woman).
- 앵커와 `masc://wiki/<이름>` 을 받을지는 설계 창에서 의견이 갈렸다. 리더 정리는 `[글자](page.md)` 하나만 받는 쪽이다. 이 RFC 는 그것을 따르고, 받는 형식을 넓히는 일은 `unsupported_link` 건수가 실제로 쌓인 뒤에 정한다(§12 Q3).

## 6. 페이지 헤더 호환 규칙

오늘 #42729 는 저장되는 레코드에 필드 하나를 더해 옛 이벤트가 읽히지 않게 했다. 위키에서 같은 모양의 위험은 log 가 아니라 헤더에 있다.

| 변경 | 깨지는 것 | 규칙 |
|---|---|---|
| 새 필수 키를 더함 | 새 바이너리가 지금 있는 페이지 전부를 `Missing_field` 로 못 읽는다 | 하지 않는다. 새 키는 선택 키로만 더한다 |
| `source` 에 새 값을 더함 | 옛 바이너리가 그 값을 가진 새 페이지를 `Unknown_source` 로 못 읽는다(`tool_wiki.ml:211`) | 모르는 `source` 값을 견디는 읽기가 먼저 배포되고, 그 판이 운영에 깔린 뒤에만 새 값을 쓴다. 두 변경은 같은 PR 에 넣지 않는다 |
| 선택 키를 더함 | 읽기는 키를 이름으로 찾으므로(`tool_wiki.ml:189`, `List.assoc_opt`) 모르는 키가 있어도 읽히는 것으로 보인다(추정). 그 앞 단계인 `Frontmatter.read` 가 모르는 키를 거절하는지는 읽지 않았다(미확인) | 조건부 허용. update 는 모르는 키를 보존하지 않는다: `render_page` 가 헤더 여덟 줄을 고정으로 쓰고 `handle_update` 가 읽은 레코드에서 다시 쓰므로, 헤더의 다른 키는 update 한 번에 사라진다(`render_page` 의 고정 여덟 줄은 `lib/wiki_page.ml:230-250`, 호출은 `lib/tool_wiki.ml:371`·`471`, main `0a7b21f2f4` 직독. `handle_update` 가 읽은 레코드에서 다시 쓴다는 것은 옮김: ocaml-agent-ic, PR #42963 댓글 6154636361). 그래서 선택 키를 더하는 PR 은 `frontmatter` 레코드와 `render_page` 에 그 키를 함께 넣어야 한다. 옛 바이너리로 update 하면 새 키가 지워지는 것은 피할 수 없으므로 새 키를 아는 판이 먼저 깔린 뒤에 그 키를 쓴다. "모르는 키가 있는 페이지가 옛 바이너리에서 읽히는가"는 여전히 테스트로 답해야 한다 |

이 RFC 의 1단계는 헤더를 바꾸지 않는다. 출처를 헤더 칸이 아니라 본문 절에 두는 이유가 이것이다.

## 7. log 호환 규칙

지금은 log 를 해석하는 코드가 없으므로 옛 바이너리와 새 줄 사이에 충돌이 없다. 호환성은 파서가 처음 생길 때 정해진다. 그래서 파서가 생기기 전에 규칙을 적는다.

- 파서는 한 곳에만 둔다. lint 와 다른 소비자가 같은 함수를 쓴다.
- 줄에서 믿는 것은 앞 세 칸이다: 동작 단어, `r<N>`, 페이지 이름. `author` 와 `note` 는 자유 문자열이라 ` | ` 로 더 쪼개지 않고 한 덩어리로 둔다. `Line` 이 `|` 를 막는지는 미확인이다.
- 모르는 동작 단어를 만나면 실패하지 않는다. 그 줄을 `unknown_action` 으로 세고 건수를 보고한다. 조용히 건너뛰면 "문제없음"과 "읽지 못함"이 같아진다.
- `## [` 로 시작하지 않는 줄은 `unreadable_line` 으로 세고 실패하지 않는다.
- 파일 끝의 개행으로 끝나지 않은 조각은 줄로 세지 않는다. log 는 임시 파일을 거치지 않고 제자리에 덧붙이므로 쓰는 중인 줄이 반만 보일 수 있다(옮김: code-reviewer, `wiki_journal.ml:59-71`).
- 순서는 파일 안의 줄 순서만 쓴다. 시각은 분 단위라 순서의 근거가 못 된다.
- 새 동작을 더할 때: 페이지를 바꾸는 동작만 `## [` 접두를 쓰고 그 페이지의 실제 revision 을 적는다. 찾지 못한 질의처럼 페이지를 바꾸지 않는 사건은 같은 접두에 섞지 않는다(옮김: ocaml-agent-ic `c-6146ceaa7e52fe94a517c524deaa4639`).
- 동작을 더하는 PR 은 `mcp_server_eio_resource.ml` 의 리소스 설명 "One line per wiki page creation or update" 를 같이 고친다(옮김: ocaml-agent-ic).
- 고정할 테스트: 옛 단어 둘만 아는 파서에 새 단어 줄을 넣으면 `unknown_action` 으로 남고 나머지 줄이 그대로 읽힌다. 끝에 개행 없는 마지막 조각은 세지 않는다.
- 두 건수는 응답의 `log_unknown_action` 과 `log_unreadable_line` 으로 나간다(§4.2). 파서가 아는 동작 단어는 지금 `create`·`update` 둘이고, 이 둘 밖의 단어는 줄로 읽지 않는다. 개행 없이 끝난 마지막 조각 뒤에 다음 줄이 이어 붙으면 그 조각이 한 줄로 붙어 `log_unreadable_line` 이 영구히 1 이상이 될 수 있다(옮김: context-reviewer `c-c3c12f57185998957b57cd93b3bf2ac6`). 그 둘 중 하나라도 0 보다 크면 구멍 점검이 꺼지고, 응답의 `revision_log_hole_suppressed` 가 그 사실을 알린다 — 빈 `revision_log_hole` 목록과 "점검 꺼짐" 을 구별하기 위해서다(task-2368).

## 8. 출처

`source` 칸과 참조는 다른 질문에 답한다. `source` 는 이 지식을 어떤 방식으로 얻었는가이고 페이지에 값 하나다. 참조는 어디에서 다시 확인할 수 있는가이고 주장마다 여럿이다. 낱말 `source` 의 와이어 이름은 바꾸지 않는다.

```
## Sources
- repo:jeong-sik/masc@<40hex>:lib/tool_wiki.ml#L211
- board:<post_id>#<comment_id>
- artifact:<sha256>
- url:https://example.org/page (read 2026-10-13)
- said:<누구>@<날짜> — "<한 줄 인용>"
```

- 한 줄에 참조 하나. 접두는 `repo:`, `board:`, `artifact:`, `url:`, `said:` 다섯이다. 원장 claim 은 참조 종류가 아니다(§9).
- `missing_sources` 는 `## Sources` 절이 없거나 그 절에 위 접두로 시작하는 줄이 하나도 없을 때다. 접두 뒤의 내용이 실제로 있는지는 1단계에서 확인하지 않는다. `repo:` 의 커밋과 경로를 대조하는 일은 저장소가 필요하므로 읽기 전용 lint 의 일이 아니다.
- `said:` 는 원문으로 치지 않는다. 다시 읽어 확인할 대상이 없기 때문이다. 참조가 `said:` 뿐인 페이지는 `hearsay_only` 로 따로 센다. 그 말이 Board 에 남아 있으면 `board:` 로 적는다.
- 기존 페이지는 일괄 변환하지 않는다. 없는 출처를 기계가 만들어 넣으면 거짓 출처가 된다. 첫 실행의 `missing_sources` 건수가 출발선이고, 저자가 다음 수정 때 채운다.
- Board 의 `sources`(URL 과 인용)는 이것과 같은 말이 아니다(옮김: glossary-maniac).

절 끝에 확인 종류와 범위를 두 줄로 적는 안(context-reviewer `c-73e370e388c5c85e19880ed7cfd5b5a0`)은 채택됐지만 2단계다. 이 RFC 는 형식을 정하지 않는다.

## 9. Curator 와의 경계

- 원장 claim 은 위키 출처가 될 수 없다. Curator 는 분류만 하고 프롬프트가 "Do not claim semantic verification" 이라고 적는다(옮김: claude-mcp-client). claim 의 id 는 글에서 나오므로 글이 바뀌면 id 가 바뀌고, 구성원이 모두 사라져 0 이 되면 claim 도 지워진다(옮김: context-reviewer, `workspace_memory_ledger.mli` 의 문서 주석 기준, 구현 `workspace_memory_ledger.ml` 은 미독). 그 경우 가리킬 대상이 남지 않는다. claim 을 근거로 쓰려면 구성원 사실의 원 출처까지 내려가 `board:` 나 `repo:` 로 적는다.
- 위키에서 원장으로 가는 방향은 닫아 둔다. 두 코드는 서로를 이름으로 부르지 않는다(옮김: context-reviewer, 양쪽 검색 0건). 다만 Keeper 가 페이지를 읽고 각자 기억하면 원장이 그것을 여러 구성원의 주장으로 묶는 길은 사람을 거쳐 이미 있다. `keeper_memory_write` 의 근거 종류에 위키가 없으므로 그렇게 들어온 사실을 가려낼 수 없다(옮김: claude-mcp-client, `config/tools/keeper_memory_write.toml`).
- 이 RFC 의 결정(옮긴 의견이 아니다): "위키에서 온 사실" 표지가 생기기 전에는 lint 가 원장을 입력으로 쓰지 않는다. 설계 창에서 표지는 위키에서 원장으로 가는 방향의 조건이었고, 원장에서 위키로 가는 방향에 대한 context-reviewer 의 제안은 "후보로만 쓴다"였다(`c-925b5ac63ec9ea5ae60d90e6b17ab883`). 리더 정리는 "첫 조각에서 모순 후보를 뺀다"다. 이 RFC 는 그보다 좁게 잡아 같은 조건을 원장에서 위키로 가는 방향에도 건다. 불어난 주장이 lint 를 타고 위키로 돌아오는 길을 막으려는 것이다. 영구히 닫는 것이 아니라 §11.2 의 3단계로 미루는 것이다.
- 구성원 수는 "여럿이 확인했다"는 뜻이 아니다. 원장은 구성원의 근거가 서로 독립인지 보지 않는다.
- Curator 가 위키에 직접 쓰는 일은 이 RFC 범위 밖이다(보류). 하게 되면 Curator 페이지는 `author` 칸이나 이름 접두로 구분한다. `source` 에 Curator 용 값을 더하지 않는다(§6).
- 전제 상태(옮김: claude-mcp-client `c-fe7fee86ed973568c3536a6ea88d993b`, 미검증): 라이브 Curator lane 에는 `cli_slots` 만 있다. briefing 은 2026-10-08 이후 갱신되지 않았다. 둘 사이의 인과는 확인되지 않았다(원 댓글 `c-659bceab4f021414c2362be1c064d988` 이 로그로 확인하지 못했다고 적음). 설정이 적용되기 전에는 Curator 가 원장 입력을 처리한다고 가정하지 않는다.

저장소 경계의 한 줄 정의는 초안이고 운영자 채택 전이다. 기준으로 삼는 제안은 이렇다(옮김: 리더 정리와 claude-mcp-client `c-fe7fee86ed973568c3536a6ea88d993b` 가 glossary-maniac 의 것으로 옮긴 세 줄, 원문 미직독): 개인 기억은 한 Keeper 가 확인한 사실, 위키는 사람과 Keeper 가 함께 쓴 페이지, 원장은 모델이 분류한 공유 주장과 충돌. 채택 경로는 용어집 문서 PR 이다.

## 10. 범위의 경계와 측정

### 10.1 #42951 과의 경계

| | 이 RFC | #42951 (Draft, task-2316) |
|---|---|---|
| 하는 일 | 위키 내용을 점검한다 | Keeper 턴에 위키 목차를 싣는다 |
| 바꾸는 곳 | 위키 모듈, 새 도구 하나 | Keeper 프롬프트와 dynamic context |
| 턴마다 드는 비용 | 없음. 부를 때만 | 모든 요청에 목차 바이트 |
| 재는 것 | 발견 건수, §10.2 의 정답률 | 위키 도구 호출 수의 전후 변화 |

이 RFC 는 프롬프트를 바꾸지 않고 위키 목차를 어디에도 싣지 않는다. #42951 은 lint 를 다루지 않는다. 둘이 만나는 곳은 하나다: 목차가 실리면 페이지가 더 자주 읽히므로, 출처 없는 페이지와 깨진 링크의 건수를 먼저 아는 편이 안전하다. 순서를 강제하지는 않는다. 리더 정리는 프롬프트 탑재를 "A/B 후 켠다"로 보류했다.

설계 창의 Q9 에서 채택된 것 가운데 셋은 이 RFC 의 범위 밖이다: 도구 설명 양쪽에 "올리는 조건"을 붙인 상호 참조 한 줄, 일이 끝나는 순간(Task 완료, 원장 등기)에 "이 발견은 위키 후보인가"를 묻는 한 줄, 절차(Skill)를 다섯째 자리로 인정하는 것. 채택은 유효하고(리더 정리 `c-331058eea665b8c6e0401f40c5eb907b`) 이 문서가 구현을 정하지 않을 뿐이다. 어느 문서가 맡을지는 이 RFC 가 정하지 않는다.

### 10.2 쓸모 측정

질문 10개. 정답을 저장소나 헌법의 원문 한 줄로 먼저 고정하고, 답이 그것과 같은지 채점한다(옮김: polisher `c-669edae4bcc9486820b74c58dbf22518`). 도구 호출 수와 시간만 재면 빨리 틀린 답이 이긴 것으로 세어진다.

| # | 질문 | 낸 사람 |
|---|---|---|
| 1 | approve-guard 가 받는 판정 줄과 footer 의 정확한 모양, `run:` 이 있으면 거절되는 조건 | polisher |
| 2 | `changelog.d/<PR번호>.md` 의 파일명, 절 머리말, `(#번호)` 형식, Added 에 사용 가이드가 필요한 조건 | polisher |
| 3 | 이 레인에서 로컬 빌드하는 법과 그 결과를 CI 대체로 쓰면 안 되는 이유 | polisher |
| 4 | `test/dune` 의 include 스탠자를 편집하면 안 되는 이유와 새 테스트 등록 방법 | polisher |
| 5 | merge-guard 가 다시 재는 것, Native Stack 에서 병합에 쓰는 PR 번호, 대표 거절 문구의 뜻 | polisher |
| 6 | runtime.toml 을 고치면 언제 반영되는가 | PO |
| 7 | 이 Test run 은 전체 회귀인가 타깃인가, 어떻게 인용하는가 | PO |
| 8 | 이 변경 조각은 Added 인가 Experimental 인가 Internal 인가 | PO |
| 9 | Board 글을 고치거나 댓글 상한에 닿았을 때 무엇이 달라지는가 | PO |
| 10 | 이것은 개인 기억, 위키, Board, Task 중 어디에 쓰는가 | PO |

- 조건 셋: 위키 없음, 위키 있음, 위키 없이 같은 내용을 Skill 로 줌. 셋째가 없으면 "위키가 좋았다"와 "정리된 글이 좋았다"를 가를 수 없다.
- 10번은 경계가 채택되기 전에는 "정해진 답이 없다"가 정답이다. 위키가 없는 답을 지어내게 만드는지 본다.
- 6번은 낡는 질문이다. 동작이 바뀐 뒤 위키가 옛 답을 주면 위키가 해를 끼친 것이다.
- 지표의 순서는 정답률, 도구 호출 수, 걸린 시간이다. 표본 수와 판정 기준은 여기서 정하지 않는다. 숫자를 지금 적으면 추정이다.
- 인용 주의: 설계 창에서 쓰인 "10-13 도구 호출 19,364건 중 위키 27건"은 Board `p-d4e8d2a653438684096b6c2679a9be8a` 의 집계이고 다시 잰 사람이 없다(미검증).

## 11. 수용 기준과 단계

### 11.1 1단계의 수용 기준

1. 라이브 11장에서 병합 뒤 한 번 부른 결과가 손으로 센 값과 같다: `pages_total` 11, `broken_link` 0, `orphan` 1(`rfc-map`), `missing_sources` 11, `unreadable_page` 0. 처음에는 라이브 사본을 픽스처로 돌리는 것으로 적었으나 구현자가 라이브 위키를 읽을 수 없어 라이브 호출로 바꿨다. 결과는 아직 없다.
2. 고정 입력 하나에서 `broken_link` 1, `orphan` 1, `missing_sources` 1, `unreadable_page` 1, `unsupported_link` 1 이 정확히 나온다.
3. 같은 디렉터리에 두 번 돌린 출력이 바이트로 같다.
4. lint 전후로 위키 디렉터리의 파일 이름, 크기, 바이트 해시가 같고 새 파일이 없다(`.wiki.lock` 포함).
5. lint 모듈이 쓰기 함수(`write_page`, `Wiki_journal.append_log`, `write_index`, `with_wiki_lock`)를 참조하지 않는다. 순수 모듈의 `.mli` 에 쓰기 함수가 없다.
6. `Wiki_graph` 의 결과가 입력 순서를 섞어도 같다.
7. 링크 파서 테이블 테스트: 코드 펜스 안, 이미지, 앵커, `[[x]]`, 상대 경로, 대문자 이름.
8. 페이지 11장과 합성 5,000장에서 각각 한 번 돌려 걸린 시간과 출력 바이트를 PR 에 적는다. 값이 없는 채로 "수천 장을 견딘다"고 쓰지 않는다. 한 호출이 수 초를 넘으면 리더 결정의 되돌리는 조건에 따라 스위치를 다시 논의한다.
9. 새 도구의 `config/tools/masc_wiki_lint.toml` 이 같은 PR 에 있다. Keeper 쪽 이름으로 투영한다면 `test/test_keeper_tool_matrix_cases.ml` 의 인자 계약 분기도 같은 PR 에 넣는다(근거: 작성자의 기억, 파일 미독). 도구 설명의 첫 단어는 1c 에서 `Experimental:` 이었고, 라이브 호출 1건 뒤 v0.56 에서 뗐다(#43130).

### 11.2 PR 쪼개기와 켜는 법·끄는 법

| 단계 | PR | 내용 | 켜는 법 | 끄는 법 |
|---|---|---|---|---|
| 0 | 이 문서 | RFC | 해당 없음 | 해당 없음 |
| 1a | 선행 리팩터링 | `Wiki_page_name`, `Wiki_page` 를 꺼낸다. 동작 불변 | 해당 없음 | 해당 없음 |
| 1b | 순수 코어 | `Wiki_link`, `Wiki_graph`, `Wiki_lint` 와 테스트. 아직 도구 없음 | 해당 없음 | 해당 없음 |
| 1c | 도구 | `Tool_wiki_lint`, 도구 toml, 사용 가이드 `docs/guides/wiki-lint.md`, 변경 조각(1c 는 Experimental, v0.56 에서 안정 표기로 바뀜 #43130) | 설정 없음. 도구를 부른다 | 설정 없음. 부르지 않으면 아무 일도 일어나지 않는다 |
| 2 | 별도 PR 들 | log 파서와 `revision_log_gap`·`revision_log_hole`(착지), 스키마 페이지, 절 끝 두 줄, 입구에서 닿지 않는 페이지 | 읽기 전용이면 설정 없음 | 같음 |
| 3 | 별도 RFC | 프롬프트 탑재(#42951), Curator 가 위키에 쓰기, promote, 원장이나 모델을 쓰는 모순 후보 | 자기 테이블의 `enabled`, 기본 꺼짐 | 그 키를 끈다 |

- 1c 의 사용 가이드는 규약 a-dababc7a 의 여섯 항목을 담고, 실행 예시는 와이어 이름 그대로 적는다. Keeper 쪽 이름으로 투영할지(`keeper_wiki_lint`)는 1c 가 정한다.
- 이 RFC 가 다루는 위키 도구에 한해서, 스위치를 다시 논의하는 조건은 쓰기가 생기거나, 모델을 부르거나, 주기적으로 돌거나, 요청마다 비용이 생길 때다. 다른 기능에 적용되는 일반 규칙이 아니다. 그때의 모양은 기존 관례대로 자기 테이블 안의 `enabled` 다(`config/runtime.toml` 의 `[fusion]`, `[typesafeai]`, `[browser.*]`). 최상위 테이블은 `Runtime_toml_namespace` 나 `Keeper_runtime_config.owned_namespaces` 에 등록되어야 한다. `wiki` 는 앞쪽에는 없다(직독). 뒤쪽은 `Keeper_runtime_setting_registry` 에서 나오는데 그 레지스트리를 읽지 않아 미확인이다.
- 구현 PR 은 v0.54.0 컷 브랜치에 넣지 않는다.

### 11.3 기존 헌법 조항과의 대응 (새 규칙 없음)

| 이 RFC 의 규칙 | 같은 정신의 조항 |
|---|---|
| 읽지 못한 것은 건수로 보고한다, `said:` 는 원문이 아니다 | a-6efdf959 (인용 직전 재읽기, 못 읽으면 "원문 미직독") |
| 좌표는 커밋과 함께 적는다 | a-cea0946a (좌표는 판정 대상 head 에서 직독한 값) |
| 사용 가이드와 실험 표시 | a-dababc7a |
| 변경 조각의 파일명과 번호 | a-ba6fa394 |

이 조항들은 Keeper 와 사람의 문장에 걸려 있다. 위키 페이지나 Curator 출력에 걸지는 이 RFC 가 정하지 않는다.

## 12. 열어 둔 물음

- Q1 (운영자). 원문 층을 참조로 둘지 복사본 폴더로 둘지. 리더 의견과 이 RFC 는 참조다.
- Q2 (운영자). ingest·query·promote 를 서버 기능이 아니라 Keeper Skill 로 둘지. 리더 의견은 Skill 이다. 이 RFC 는 어느 쪽이어도 바뀌지 않는다.
- Q3. 앵커(`page.md#절`)와 `masc://wiki/<이름>` 을 링크로 받을지. `unsupported_link` 건수를 본 뒤 정한다.
- Q4. 출력에 읽은 페이지별 revision 목록을 넣을지. 두 번의 실행을 사람이 견주기 좋지만 페이지가 많으면 16,384 바이트를 넘는다. 제안은 `page` 인자를 줬을 때만 넣는 것이다.
- Q5. `orphan` 판정에서 `index.md` 의 줄을 들어오는 링크로 세지 않는 것이 맞는지. 세면 고아가 영영 없다. 스키마 페이지가 입구를 적게 되면 `unreachable` 이 이 자리를 대신한다.

## 13. 읽은 범위와 확신도

직접 읽은 것 (작성자, `4a7e2013a32bc36b6260242e7ee162c7fc065a28`; 위키 네 파일은 `5d142b8fb252f8cd06347e2cd60375f77198f977` 과 차이 없음):

- `lib/tool_wiki.ml` 138-240행(frontmatter 타입, `parse_frontmatter`, 오류 문장), 587-593행, 682행.
- `config/runtime.toml` 1-170행, 2262-2292행. `lib/runtime/runtime_toml.ml` 1-14, 190-206, 2490-2500, 3103-3116행. `lib/runtime_toml_namespace/runtime_toml_namespace.ml` 전체. `lib/keeper_runtime/keeper_runtime_config.ml` 149-172행.
- `config/tools/masc_wiki_list.toml`. `docs/guides/` 파일 목록. `docs/rfc/README.md` 의 정책과 frontmatter 표준.
- 라이브 위키 11장의 본문(2026-10-13).
- #42951 의 patch 전문(head `bcdebcb73416593870a7adb1f6d2126332711967`).

남의 읽기를 옮긴 것 (본문에 "옮김"으로 표시, 작성자가 다시 읽지 않음):

- `tool_wiki.ml` 의 이름 검사·잠금·쓰기 순서·검색, `wiki_journal.ml` 전체, `mcp_server_eio_resource.ml`, `keeper_tool_descriptor.ml`, `workspace_memory_ledger.mli`, Curator 프롬프트, `keeper_memory_write.toml`, 용어집.

읽지 못한 것:

- `Frontmatter.read` 본체, `Line` 모듈 본체, update 가 헤더를 다시 쓰는 방식, 위키 테스트 파일들, `lib/dune` 의 라이브러리 경계, `Keeper_runtime_setting_registry`, 5,000장 규모의 실측. 이 가운데 update 가 헤더를 다시 쓰는 방식, `Line`·`Tag` 의 다른 사용처, `lib/dune` 의 경계는 구현자 ocaml-agent-ic 가 읽어 답했고(PR #42963 댓글 6154636361) 본문 §4.4 와 §6 에 옮김으로 반영했다. 그 뒤 작성자가 `render_page` 와 `Line`·`Tag`·`parse_frontmatter` 의 사용처를 main `0a7b21f2f4` 에서 직독했다. `lib/dune` 은 여전히 읽지 않았다.

확신도:

- 지금 구조(§2)와 호환 위험(§6): 높음. 다만 근거의 폭이 항목마다 다르다. §2 의 일곱 항목 중 넷은 옮긴 읽기다. 이름 규칙, 헤더 일곱 키와 `Unknown_source`, log 형식, 잠금 파일, 16,384 바이트, 리소스 설명 문구는 PR #42963 의 리뷰 5509563867 에서 context-reviewer 가 따로 읽어 일치를 확인했으므로 두 사람이 읽은 것이다. "log 의 동작 단어를 해석하는 코드가 없다"는 두 사람의 검색 범위 안에서 0건이라는 뜻이고 확정은 아니다. §6 의 "모르는 선택 키가 있어도 읽힌다"는 추정이다.
- lint 의 다섯 가지 발견이 쓸모 있는 신호인지: 중간. 지금 11장에서는 `missing_sources` 11 과 `orphan` 1 만 나온다. 페이지가 늘기 전에는 값이 작다.
- 출력 스키마(§4.2)와 링크 표(§5)의 세부: 중간. 제안이고 구현 리뷰에서 바뀔 수 있다.
- 위키가 Keeper 의 답을 낫게 하는지: 모름. §10.2 가 그것을 재는 방법이고, 잰 값은 아직 없다.
