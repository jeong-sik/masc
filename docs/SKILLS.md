# Skills — SKILL.md 로 능력을 선언한다

masc 의 스킬은 파일 하나로 선언되는 능력이다. `<base_path>/.masc/skills/<name>/SKILL.md`
한 장이 스킬 하나다. Keeper 턴은 **턴 시작마다** 이 디렉토리를 다시 읽으므로 파일을
고치면 다음 턴부터 반영된다. `/api/v1/skills`는 별도의 발행 스냅샷이므로 부팅 또는
runtime config 재적용 때 갱신된다.

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
  같아야 한다. MASC는 복구 가능한 편차를 `runtime_compatible`로 로드한다: `name`이
  없거나 선언 이름이 잘못됐어도 디렉토리 이름이 유효하면 그 이름을 쓰며, 이름 불일치·
  길이 초과·확장 키는 진단으로 남긴다. 양쪽 이름이 모두 잘못됐거나 `description`이
  없거나 frontmatter 구조를 읽을 수 없을 때만 문서를 거부한다.
- `metadata.openclaw` 같은 다른 런타임의 네임스페이스도 문서를 막지는 않는다. 편차의
  정확한 이유는 `/api/v1/skills`와 Monitor › Skills에 표시된다.
- `masc-composition-tool`과 `disable-model-invocation`은 모두 거부한다. composition의
  존재와 표면은 본문 fence 하나가 전부 결정한다. 별도 invocation-policy 스위치를 두지
  않으므로 선언과 본문이 서로 다른 상태도 없다. 문서용 fence 예시는 더 긴 CommonMark
  외부 fence로 감싼다.
- 실험적 `allowed-tools`도 MASC에서 거부한다. 표준의 이 필드는 도구 제한이 아니라
  사전 승인 힌트인데 MASC의 승인 정책과 결합돼 있지 않다. 읽고 무시하거나 API에 노출해
  허용된 권한처럼 보이게 하지 않는다. 모든 도구 호출은 기존 MASC 승인 게이트를 따른다.
- 본문은 통째로 보존된다. keeper 는 `keeper_skill` 도구로 이름을 대고 본문을 통째 받는다 (#30635 이전에는 경로+`Read` 였다 — `.masc/skills` 가 샌드박스 루트 옆이라 `Read` 가 거의 실패해서 도구로 바꿨다).

## 2. 스킬의 두 종류 — 본문이 결정한다

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

구조적으로 읽을 수 없는 frontmatter, 유효한 runtime 이름이 전혀 없는 문서,
`description` 누락, fence 문법/합성 plan 오류, 중복 스킬은 그 턴을 typed config
error로 거부한다. 반면 이름 불일치·한계 초과·확장 키는 `runtime_compatible` 진단이며
턴을 막지 않는다. `SKILL.md`가 없는 디렉토리는 스킬이 아니므로 그냥 건너뛴다.

## 5. 관측

- `GET /api/v1/skills` — 발행 스냅샷의 이름·설명·conformance·diagnostics와, 턴 파서가
  만든 종류·합성 도구 이름/실행 모드·최근 사용 및 완료 성공/실패 횟수를 함께 돌려준다.
- 합성 실행은 노드 단위로 `tool_calls` 스토어에 남는다 (`composition_tool`,
  `composition_run_id`, `composition_node_id`) — SSE
  `keeper_tool_call_evidence_committed` 로도 흐른다. 이벤트에는 `success`, `disposition`,
  `duration_ms`가 포함된다. run 전체는 `record_kind=composition_run` 종결 행으로 별도
  기록되며 async는 durable settlement 이후에만 종결된다.

## 6. 배포 주의 — #30208~#30220 창

skills 스캔(#30208)과 toml 경로 삭제(#30220) 사이의 바이너리는 **양쪽을 다 읽고
이름 충돌을 거부**한다. 그 창의 바이너리가 도는 동안 같은 이름을 skills 에 미리
놓으면 모든 턴이 막힌다 — 실제로 키퍼 7명이 4.5분 막혔다 (#30238). 런타임 파일
플립은 `/health` 의 `binary_commit` 으로 실행 중 바이너리를 확인하고 하라.
