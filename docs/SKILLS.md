# Skills — SKILL.md 로 능력을 선언한다

masc 의 스킬은 파일 하나로 선언되는 능력이다. `runtime.toml`의 `[[skills.sources]]`가
가리키는 `<source>/<name>/SKILL.md` 한 장이 스킬 하나다. 기본 source는 프로젝트와 사용자
각각의 `.masc/skills`, `.agents/skills`다. Keeper 턴과 `/api/v1/skills`는 같은 발행
스냅샷을 새로 고쳐 읽으므로 source 우선순위·shadow·거부 결과가 서로 갈리지 않는다.

관련 RFC: `docs/rfc/RFC-skills-as-tools.md` (합성·도구 승격),
`#30156` skills-declared-not-discovered (task 라우팅). 파서는
`packages/agent_core/lib/skill_document.ml` (frontmatter 계약) + `lib/keeper/keeper_skill_catalog.ml` (fence·카탈로그)다.

런타임에서 **어떻게 도는가**(순서도 + 코드 경로)는 `docs/SKILLS-FLOW.md`.

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

- Agent Skills 표준상 `name`과 `description`은 필수이고 `name`은 디렉토리 이름과
  같아야 한다. 이름 누락·불일치·문법 오류, 필드 길이 초과, 알 수 없는 top-level field,
  잘못된 metadata 값은 그 Skill 하나를 거부한다. 클라이언트 확장은 공식 `metadata`
  string map 아래에 둔다.
- `masc-composition-tool`과 `disable-model-invocation` 같은 top-level field는 거부한다. composition의 존재와
  표면은 본문 fence 하나가 전부 결정한다. 별도 invocation-policy 스위치를 두지 않으므로
  선언과 본문이 서로 다른 상태도 없다. 문서용 fence 예시는 더 긴 CommonMark 외부
  fence로 감싼다.
- Agent Skills의 실험적 선택 필드 `allowed-tools`는 문법만 검증하고 즉시 버린다.
  MASC에서는 사전 승인이나 도구 제한이 아니며 AST, registry, prompt, Gate, Keeper
  effective surface, immutable snapshot entry 어디에도 값이 남지 않는다. 실행 권한의
  권위는 MASC 승인 정책이다. 이식 가능한 원본 `SKILL.md`와 편집기 source round-trip은
  원문을 그대로 보여 주지만 정책 상태로 해석하지 않는다.
- 잘못된 스킬 하나는 그 스킬만 Keeper 표면에서 제외한다. 다른 Keeper 턴은 계속 열리며,
  제외된 exact reference를 task가 지명한 경우에만 admission이 typed 오류를 반환한다.
  정확한 파싱 오류는 `/api/v1/skills`의 `rejections`와 exact surface diagnostic에 남는다.
- 본문은 frozen snapshot bytes로 보존된다. Keeper는 `keeper_skill`에 canonical exact
  reference를 전달해 본문을 받는다.

## 2. 스킬의 두 종류 — 본문이 결정한다

Keeper별 Skill 표면은 Keeper profile의 `[keeper.skills]`가 정한다.

```toml
[keeper.skills]
names = ["release-checklist", "memory-probe"]
```

- `[keeper.skills]`가 없으면 발행된 모든 Skill을 쓴다.
- `names = []`면 Skill을 하나도 싣지 않는다.
- 이름은 canonical Skill 이름과 정확히 같아야 한다. 부분 문자열, 대소문자 보정, 별칭은 없다.
- 같은 선택을 전역 Skill과 Task가 지명한 Skill에 모두 적용하므로 Task가 Keeper profile을
  우회하지 않는다.
- 설정에만 있고 발행된 turn catalog에는 없는 이름은 effective surface의
  `unavailable_skill_names`에 typed reason과 함께 남는다. 함께 지정한 알려진 이름은 계속
  동작한다.

`masc_keeper_up`의 `skills.names`도 같은 Keeper TOML 필드를 편집한다. `skills={}`는
선언을 지워서 all로 되돌리고 빈 배열은 none을 유지한다.

선언 필드가 아니라 **본문에 ` ```toml composition ` fence 가 있는지**가 종류를 정한다.

| fence 개수 | 종류 | 표면 |
|---|---|---|
| 0 | 지시 스킬 | task 라우팅 + `keeper_skill` 목록에 이름·설명 한 줄 |
| 1 | 합성 스킬 | `keeper_compose_<name>` 도구로 승격 |
| 2+ | 오류 | 턴이 typed config error 로 거부된다 |

frontmatter invocation-policy 필드는 이 결정을 덮어쓸 수 없다
(`keeper_skill_catalog.ml`).

### 지시 스킬 (instruction)

task 가 스킬을 지정하면 current-task 블록에 이름 한 줄이 실리고, keeper 가
`keeper_skill` 도구로 본문을 연다. 지정이 없는 task 의 프롬프트는 바이트 하나 변하지 않는다.

keeper 가 task 를 둘 이상 들고 있으면(Claimed/InProgress) current task 는 reconcile 이
고른 하나이고, 두 번째 task 를 claim 해도 바뀌지 않는다. 그래서 나머지 보유 task 가
지명한 스킬은 `Skills Named by Tasks You Hold` 블록에 task 별로 한 줄씩 따로 실린다
(직접 메시지 턴도 같다). 턴 admission도 같은 집합의 이름이 카탈로그에 있는지 검사한다.
지시 본문은 전용 `keeper_skill`이 서빙하므로 파일시스템 `Read` 도구 유무와는 무관하다.

### 합성 스킬 (composition) — Skill as a Tool

본문의 fence 안 문법은 `Keeper_tool_composition_catalog`의 닫힌 문법이다.
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

- 같은 dependency layer의 노드 중 descriptor가 `Ordinary Concurrent`인 것만 묶여
  실행된다. `Ordinary Serial`과 `Terminal` 노드는 의존이 없어도 각자 직렬 batch다.
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
- async 합성도 파라미터를 선언할 수 있다 — 인자는 제출 시점에 plan 에 바인딩되고,
  broker 는 crash 후 worker closure 를 재생하지 않으므로 바인딩된 plan 은 어떤 async
  run 과도 정확히 같은 수명을 가진다. 정적 read-only 제약은 그대로다.
- 모델이 즉석에서 짜는 `keeper_plan_execute` plan 에는 `param` 이 없다 — 즉석 호출은
  값을 `literal` 로 직접 쓰면 된다.

## 4. 오류는 턴을 막는다

Agent Skills frontmatter 계약을 어긴 문서, fence 문법/합성 plan 오류, 중복 스킬은 그
source candidate를 typed rejection으로 격리한다. 해당 Skill을 Task가 지명한 턴만 admission
오류를 받고, 올바른 형제 Skill은 계속 사용할 수 있다. `SKILL.md`가 없는 디렉토리는
스킬이 아니므로 그냥 건너뛴다.

## 5. 관측

- `GET /api/v1/skills` — 발행 스냅샷의 valid entry와 typed rejection, 종류·합성 도구
  이름/실행 모드·최근 사용 및 완료 성공/실패 횟수를 함께 돌려준다.
- 합성 실행은 노드 단위로 `tool_calls` 스토어에 남는다 (`composition_tool`,
  `composition_run_id`, `composition_node_id`) — SSE
  `keeper_tool_call_evidence_committed` 로도 흐른다. 이벤트에는 `success`, `disposition`,
  `duration_ms`가 포함된다. run 전체는 `record_kind=composition_run` 종결 행으로 별도
  기록되며 async는 durable settlement 이후에만 종결된다.
