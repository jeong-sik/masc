---
name: prior-art
description: "Looks one phrase up in your durable memory facts, the knowledge library and board posts in one call, before diagnosing or building something another Keeper or an earlier turn may already have met. Use it when a failure, a tool name or a piece of work is new to this turn. All three match the phrase as a case-insensitive substring, so pass a short fragment exactly as it appeared, such as an error code, a tool name or a file name, not a sentence or a guessed cause. Returns up to 5 memory facts, the titles of matching library documents, and up to 10 board posts, newest first, one line each; board comments are not searched. Read a document with keeper_library_read and a post with masc_board_post_get. No match in all three is an answer too: the problem is new here and worth recording. If one search fails, the call fails and names that action, and searches scheduled after it do not run."
---

# prior-art

`keeper_compose_prior-art` 는 같은 검색어를 세 곳에 한 번에 던진다.

Keeper 에게 보이는 설명은 아래 fence 의 `description` 과 params 설명뿐이다.
이 본문은 사람이 읽는다.

## 노드

| id | 도구 | 입력 | 도구 기본값과 다른 점 |
|---|---|---|---|
| `memory` | `keeper_memory_search` | `query`, `limit = 5`, `source = "current"` | 현재 Memory만 조회하는 기본값을 명시한다 |
| `library` | `keeper_library_search` | `query` | 이 도구에는 개수 인자가 없다. 제목 한 줄씩만 돌려준다 |
| `board` | `masc_board_search` | `query`, `limit = 10`, `compact = true` | 기본 `limit` 은 20 이다 |

- 노드 입력에 개수와 모양을 적어 두는 이유: 입력을 비워 두면 도구 기본값이 그대로 나오고,
  기본값이 바뀌면 이 합성의 응답 크기도 말없이 바뀐다.
- `keeper_memory_search` 는 descriptor 가 `Serial` 이라 따로 돈다. `keeper_library_search`
  와 `masc_board_search` 는 `Concurrent` 라 같은 batch 에서 함께 돈다. 한 batch 가 실패하면
  그 뒤 batch 는 돌지 않는다.
- 세 도구 모두 대소문자를 가리지 않는 부분 문자열 일치로 찾는다. 긴 문장이나 짐작한 원인은
  거의 걸리지 않는다. 보드는 글의 제목·본문·작성자와, 글에 hearth(주제 이름)가 있으면
  그것까지 보고 댓글은 보지 않는다 (`lib/board/board_dispatch.ml` `search`).
- 세 도구 모두 결과가 없을 때 오류가 아니라 성공 결과를 돌려준다. `keeper_memory_search` 는
  기억 저장소를 못 읽으면 실패하고, 그러면 이 호출 전체가 실패한다.

```toml composition
[[compositions]]
name = "prior-art"
description = "Looks one phrase up in your durable memory facts, the knowledge library and board posts in one call, before diagnosing or building something another Keeper or an earlier turn may already have met. Use it when a failure, a tool name or a piece of work is new to this turn. All three match the phrase as a case-insensitive substring, so pass a short fragment exactly as it appeared, such as an error code, a tool name or a file name, not a sentence or a guessed cause. Returns up to 5 memory facts, the titles of matching library documents, and up to 10 board posts, newest first, one line each; board comments are not searched. Read a document with keeper_library_read and a post with masc_board_post_get. No match in all three is an answer too: the problem is new here and worth recording. If one search fails, the call fails and names that action, and searches scheduled after it do not run."
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
description = "A short fragment exactly as observed: an error code, a tool name, a file name. At most 200 characters."

[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 5
[[compositions.nodes.input.fields]]
name = "source"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "current"

[[compositions.nodes]]
id = "library"
tool = "keeper_library_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"

[[compositions.nodes]]
id = "board"
tool = "masc_board_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 10
[[compositions.nodes.input.fields]]
name = "compact"
[compositions.nodes.input.fields.value]
kind = "literal"
value = true
```
