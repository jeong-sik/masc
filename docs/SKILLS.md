# Skills — SKILL.md 로 능력을 선언한다

masc 의 스킬은 파일 하나로 선언되는 능력이다. `<base_path>/.masc/skills/<name>/SKILL.md`
한 장이 스킬 하나이고, 서버는 **턴 시작마다** 이 디렉토리를 다시 읽는다 — 파일을 고치면
다음 턴부터 반영되고, 재시작은 필요 없다.

관련 RFC: `docs/rfc/RFC-skills-as-tools.md` (합성·도구 승격),
`#30156` skills-declared-not-discovered (task 라우팅). 파서는
`lib/skill/skill_definition.ml` (파일 한 장) + `lib/keeper/keeper_skill_catalog.ml` (카탈로그)다.

## 1. 파일 규칙

```markdown
---
name: release-checklist
description: Walk the release checklist before shipping.
---

# Release checklist

1. Read the diff.
2. Check CI.
```

- `name` 과 `description` 은 필수다. `name` 은 **디렉토리 이름과 정확히 같아야** 한다 —
  task 가 스킬을 디렉토리 이름으로 가리키기 때문이다.
- 그 밖의 frontmatter 키는 Agent Skills 표준대로 무시한다. `metadata.openclaw` 같은
  다른 런타임의 네임스페이스가 있어도 그대로 동작한다 — 공개된 스킬 파일을 수정 없이
  설치할 수 있다.
- 본문은 통째로 보존된다. keeper 는 본문을 `Read` 로 읽는다.

## 2. 스킬의 두 종류 — 본문이 결정한다

선언 필드가 아니라 **본문에 ` ```toml composition ` fence 가 있는지**가 종류를 정한다.

| fence 개수 | 종류 | 표면 |
|---|---|---|
| 0 | 지시 스킬 | task 라우팅 + `Read` (도구 표면 0 B) |
| 1 | 합성 스킬 | `keeper_compose_<name>` 도구로 승격 |
| 2+ | 오류 | 턴이 typed config error 로 거부된다 |

### 지시 스킬 (instruction)

task 가 스킬을 지정하면 current-task 블록에 이름과 경로 한 줄이 실리고, keeper 가
필요할 때 본문을 연다. 지정이 없는 task 의 프롬프트는 바이트 하나 변하지 않는다.

### 합성 스킬 (composition) — Skill as a Tool

본문의 fence 안 문법은 `tool-compositions.toml` 이 쓰던 카탈로그 문법 **그대로**다.
fence 는 정확히 하나의 composition 을 선언하고, 그 `name` 은 스킬 이름과 같아야 한다.

````markdown
---
name: memory-probe
description: Search durable memory for the caller's query.
---

호출자가 준 query 로 durable memory 를 검색한다.

```toml composition
[[compositions]]
name = "memory-probe"
description = "Search durable memory for the caller's query."
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
description = "What to search durable memory for."

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
```
````

- 의존 없는 노드는 동시에 실행된다. 순서는 `after` 와 `output` 참조에서만 나온다.
- input template 의 `kind` 는 `literal` / `output` / `param` / `object` / `array` 다.
- `execution = "inline"` 은 결과를 그 자리에서 돌려주고, `"async"` 는 durable broker 로
  넘긴 뒤 `keeper_composition_status` / `keeper_composition_cancel` 로 조회·취소한다.

## 3. 파라미터 — Parallel as a Tool 의 손잡이

`[[compositions.params]]` 가 스칼라 파라미터(`string`/`integer`/`number`/`boolean`)를
선언하면 도구의 input schema 가 거기서 생성된다 — required·타입·설명이 그대로 실려
모델이 여느 도구처럼 검증받으며 인자를 넘긴다.

- 선언과 참조는 정확히 일치해야 한다: 선언 안 된 `param` 참조도, 아무 노드도 안 읽는
  선언도 로드 오류다.
- 파라미터는 전부 required 다.
- **async 합성은 파라미터를 선언할 수 없다** — durable broker 가 호출 입력을 실어
  나르지 않기 때문이다 (Async as a Skill 은 0-인자 스냅샷에 쓴다).
- 모델이 즉석에서 짜는 `keeper_plan_execute` plan 에는 `param` 이 없다 — 즉석 호출은
  값을 `literal` 로 직접 쓰면 된다.

## 4. 오류는 턴을 막는다

깨진 SKILL.md (필수 키 누락, 이름 불일치, fence 문법 오류, 중복 스킬)는 그 턴을
typed config error 로 거부한다 — 조용히 빠지는 스킬은 없다. `SKILL.md` 가 없는
디렉토리는 스킬이 아니므로 그냥 건너뛴다.

## 5. 관측

- `GET /api/v1/skills` — 턴 시작과 같은 로드를 JSON 으로: 이름·설명·종류·합성이면
  도구 이름/실행 모드/파라미터까지. 디렉토리가 깨져 있으면 턴을 막는 오류 문자열
  그대로를 돌려준다.
- 합성 실행은 노드 단위로 `tool_calls` 스토어에 남는다 (`composition_tool`,
  `composition_run_id`, `composition_node_id`) — SSE
  `keeper_tool_call_evidence_committed` 로도 흐른다.

## 6. 배포 주의 — #30208~#30220 창

skills 스캔(#30208)과 toml 경로 삭제(#30220) 사이의 바이너리는 **양쪽을 다 읽고
이름 충돌을 거부**한다. 그 창의 바이너리가 도는 동안 같은 이름을 skills 에 미리
놓으면 모든 턴이 막힌다 — 실제로 키퍼 7명이 4.5분 막혔다 (#30238). 런타임 파일
플립은 `/health` 의 `binary_commit` 으로 실행 중 바이너리를 확인하고 하라.
