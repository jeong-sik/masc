---
name: prior-art
description: "Looks one observed phrase up in your durable memory facts, wiki and board posts when the current task needs prior findings. Skip repeated lookup when the relevant finding is already available. Memory prioritizes whole-query matches, then term/BM25 candidates; 1-2 character ASCII alphanumeric terms require word boundaries. Wiki and board use case-insensitive substring matching. Pass a short observed error code, tool name or file name. Returns up to 5 memory facts, matching wiki titles and up to 10 compact board posts; board comments are not searched. Open needed details with keeper_wiki_read or masc_board_post_get. Empty results do not prove source verification completed or that the problem is new; Memory may succeed with source_verification.status=incomplete and no matches. Independent searches finish despite a failed node. Use available results and name failed or incomplete sources before retrying."
---

# prior-art

`keeper_compose_prior-art` 는 같은 검색어를 세 곳에 한 번에 던진다.

Keeper 에게 보이는 설명은 아래 fence 의 `description` 과 params 설명뿐이다.
이 본문은 사람이 읽는다.

## 노드

| id | 도구 | 입력 | 도구 기본값과 다른 점 |
|---|---|---|---|
| `memory` | `keeper_memory_search` | `query`, `limit = 5`, `source = "current"` | 현재 Memory만 조회하는 기본값을 명시한다 |
| `wiki` | `keeper_wiki_search` | `query` | 이 도구에는 개수 인자가 없다. 제목 한 줄씩만 돌려준다 |
| `board` | `masc_board_search` | `query`, `limit = 10`, `compact = true` | 기본 `limit` 은 20 이다 |

- 노드 입력에 개수와 모양을 적어 두는 이유: 입력을 비워 두면 도구 기본값이 그대로 나오고,
  기본값이 바뀌면 이 합성의 응답 크기도 말없이 바뀐다.
- 세 descriptor 모두 `Concurrent`이고 출력 의존성이 없으므로 함께 실행할 수 있다.
  `continue_independent`로 한 저장소 조회가 실패해도 다른 조회를 마친다.
- Memory는 전체 query 일치를 저장 순서로 먼저 보여 주고, 나머지에서 공백으로 나눈 term
  후보를 BM25 순위로 더한다. 짧은 ASCII 영숫자 term(1–2글자)은 ASCII 단어 경계를 확인한다.
  검색어는 관측한 짧은 오류 코드·도구 이름·파일 이름을 그대로 쓴다
  (`keeper_tool_memory_runtime.ml` `answering`, `keeper_memory_search.toml`).
- wiki와 보드는 대소문자를 가리지 않는 부분 문자열 일치다. wiki는 문서 내용에서 찾고
  제목·파일 이름을 돌려준다. 보드는 제목·본문·작성자·hearth(주제 이름)를 보고 댓글은
  보지 않는다 (`tool_wiki.ml` `handle_search`, `board_dispatch.ml` `search`).
- 빈 결과도 성공일 수 있다. 특히 Memory는 검증하지 못한 query 후보를 숨기고
  `source_verification.status = "incomplete"`와 빈 matches를 성공 결과로 돌려줄 수 있다.
  wiki도 읽지 못한 파일을 건너뛴다. 성공 여부만으로 전체 source 조회·검증이 끝났다고
  판단하지 않는다. 사용 가능한 결과와 실패·불완전한 source를 함께 보고하고, 검색이
  안 됐다는 사실만으로 새 문제라고 기록하지 않는다.

```toml composition
[[compositions]]
name = "prior-art"
description = "Looks one observed phrase up in your durable memory facts, wiki and board posts when the current task needs prior findings. Skip repeated lookup when the relevant finding is already available. Memory prioritizes whole-query matches, then term/BM25 candidates; 1-2 character ASCII alphanumeric terms require word boundaries. Wiki and board use case-insensitive substring matching. Pass a short observed error code, tool name or file name. Returns up to 5 memory facts, matching wiki titles and up to 10 compact board posts; board comments are not searched. Open needed details with keeper_wiki_read or masc_board_post_get. Empty results do not prove source verification completed or that the problem is new; Memory may succeed with source_verification.status=incomplete and no matches. Independent searches finish despite a failed node. Use available results and name failed or incomplete sources before retrying."
execution = "inline"
branch_failure_policy = "continue_independent"

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
id = "wiki"
tool = "keeper_wiki_search"
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
