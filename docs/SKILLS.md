# Skills — SKILL.md 로 능력을 선언한다

masc 의 스킬은 파일 하나로 선언되는 능력이다. `runtime.toml`의 `[[skills.sources]]`가
가리키는 `<source>/<name>/SKILL.md` 한 장이 스킬 하나다. 기본 source는 프로젝트와 사용자
각각의 `.masc/skills`, `.agents/skills`다. Keeper 턴과 `/api/v1/skills`는 같은 발행
스냅샷을 새로 고쳐 읽으므로 source 우선순위·shadow·거부 결과가 서로 갈리지 않는다.

관련 RFC: `docs/rfc/RFC-skills-as-tools.md` (합성·도구 승격),
`#30156` skills-declared-not-discovered (task 라우팅). 파서는
`packages/agent_core/lib/skill_document.ml` (frontmatter 계약) + `lib/keeper/keeper_skill_catalog.ml` (fence·카탈로그)다.

런타임에서 **어떻게 도는가**(순서도 + 코드 경로)는 `docs/SKILLS-FLOW.md`.

### Memory에서 Skill을 만드는 경로의 현재 상태

Librarian이 남기는 `validated_approach`·`lesson`과 `absorbs`는 Memory OS의 Fact를
바꾼다. SKILL.md나 composition을 발행하지 않는다. 현재 Skill은 선언된 source의
파일을 읽어 발행하며, TUI·Dashboard의 생성·저장은 `CanAdmin` 편집기 API를 쓴다
(`Server_skill_editor`, `Server_routes_http_routes_dashboard`).

Keeper는 새 `SKILL.md`를 `keeper_artifact_transfer`로 export한 뒤, 반환된 정확한
`artifact` 객체와 제안하는 package 디렉터리 이름 `package_id`를
`keeper_skill_validate`에 전달할 수 있다. 기존 문서·composition 계획 parser와
편집기의 크기 제한으로 원문 bytes를 읽기 전용 검증한다. 결과의 artifact와
package 이름은 검증한 입력을 가리키며, 발행된 Skill Reference가 아니다.
정적 검증은 실행 성공이나 안전성을 증명하지 않고 source·snapshot도 변경하지
않는다. 발행은 기존 관리자 편집기 경로를 따른다.

Keeper가 직접 발행하는 `keeper_skill_publish`와 `keeper_compose_save`는 각각
[self-authored-skills](rfc/RFC-keeper-self-authored-skills.md)와
[writes-own-compositions](rfc/RFC-keeper-writes-own-compositions.md)의 제안이다.
현재 도구가 아니다. 실행 기록에서 후보를 찾고 검증해 발행하는
[Tool Librarian 제안](https://github.com/jeong-sik/masc/pull/36925)도 구현된 자동
생산 경로로 취급하지 않는다. 발행된 Skill의 사용 기록은 그 Skill이 자동으로
생성됐거나 작업을 성공시켰다는 증거와 구분한다.

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
- composition의 존재와 표면은 본문 fence 하나가 전부 결정한다. 이 결정을 바꾸는
  frontmatter 필드는 없으므로 선언과 본문이 서로 다른 상태도 없다. 문서용 fence 예시는
  더 긴 CommonMark 외부 fence로 감싼다.
- Agent Skills의 실험적 선택 필드 `allowed-tools`는 문법만 검증하고 즉시 버린다.
  MASC에서는 사전 승인이나 도구 제한이 아니며 AST, registry, prompt, Gate, Keeper
  effective surface, immutable snapshot entry 어디에도 값이 남지 않는다. 실행 권한의
  권위는 MASC 승인 정책이다. 이식 가능한 원본 `SKILL.md`와 편집기 source round-trip은
  원문을 그대로 보여 주지만 정책 상태로 해석하지 않는다.
- frontmatter가 잘못된 스킬은 snapshot에서 거부된다. Task가 해소할 수 없는 exact
  reference를 지명하면 admission이 typed 오류를 반환한다. source에서 읽은 문서의
  frontmatter는 유효하고 composition만 잘못됐으면, 합성 도구 없이 frozen Instruction과
  typed projection diagnostic으로 남는다(`Keeper_skill_catalog.of_snapshot`).
  편집기의 생성·저장·preview는 `parse_skill`로 composition까지 검사해 후보를 거절한다.
- 본문은 frozen snapshot bytes로 보존된다. Keeper는 `keeper_skill`에 canonical exact
  reference를 전달해 본문을 받는다.

## 2. Skill 로 둘 것과 Tool 로 둘 것

| 필요한 것 | 둘 곳 |
|---|---|
| 없는 능력 / 스키마·권한·typed 오류 계약 / 외부 호출 | Tool |
| 중간 판단 없는 고정 도구 사슬 | Composition skill (쓰임새는 TOML `description`) |
| 갈림길 판단·함정·절차 | Instruction skill |
| 런타임이 턴의 첫 요청에 이미 넣는 정보 (예: 현재 시각은 `[Temporal]` 로 들어간다. 도구 결과 뒤 요청에는 다시 넣지 않는다) | 두지 않는다 |
| 도구·하네스 결함을 피해 가는 절차 | 스킬로 만들지 않고 결함을 고친다 |

- 노드가 하나뿐인 합성은 그 도구를 직접 부르는 것과 같다. 스킬로 만들 이유가 없다.
- 결함을 피해 가는 절차를 스킬로 적으면 그 결함이 일하는 방법으로 굳고, 다음 작성자가
  그대로 따라 쓴다. 도구를 고치면 절차가 필요 없어진다.
- 모든 노드 입력이 실행 전에 정해지면(파라미터, 리터럴, 앞 노드 출력의 필드) 합성으로 쓴다.
  앞 단계 결과를 읽고 다음 단계를 골라야 하면 지시 스킬로 쓴다.

작성 절차 전체는 빌트인 `skill-authoring` 스킬에 있다.

## 3. 스킬의 두 종류 — 본문이 결정한다

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
| 2+ | 합성 읽기 오류 | 도구가 생기지 않고 본문은 지시 스킬로 남는다. 진단은 `/api/v1/skills` 에 남는다 |

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

노드가 부르는 도구가 그 턴의 도구 목록에 없으면 `keeper_compose_<name>` 도 목록에 뜨지 않는다.
노드는 직접 호출과 같은 목록 검사를 지나므로, 띄워 봐야 부를 때마다 그 노드에서 실패한다.
`keeper.tools.deny` 로 뺀 도구를 쓰는 합성 스킬이 이렇게 된다. 샌드박스 프로필이 microvm·remote_ssh 인
keeper 에게는 `keeper_spawn` 계열 도구가 목록에 없으므로(`Keeper_spawn_boundary`), 이를 쓰는 `run-and-read` 도
같다. task 가 지정한 스킬이면 프롬프트에도 사용할 수 없는 스킬로 실린다.
`keeper_tools_list`·`keeper_capability_search` 가 돌려주는 스킬 행에는
`availability = "node_tools_outside_surface"` 와 빠진 도구 이름 `outside_node_tools` 가 남는다.

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
- 노드가 실패하면 호출 전체가 실패하고 `cause` 에 그 노드가 실린다. 그 뒤 batch 는 돌지
  않는다. 성공하면 `actions` 에 노드마다 `node_id` 와 결과가 실린다.

### 합성 본문은 Keeper 에게 안 보인다

`keeper_compose_<name>` 도구 설명은 fence 안 `[[compositions]] description` 이 전부다
(`lib/keeper/keeper_tool_composition_surface.ml` `entry_description`). 입력 스키마에는
`[[compositions.params]]` 의 `description` 이 실린다. fence 밖 본문은 사람만 읽는다.
`keeper_skill` 의 Available 목록에는 지시 스킬만 오르므로 합성 본문을 열 경로도 없다.

- 언제 쓰는지, 언제 쓰면 안 되는지, 결과를 어떻게 읽는지는 TOML `description` 에 적는다.
  frontmatter 의 1024자 한도를 같이 지키고, frontmatter `description` 도 같은 값으로 둔다.
- TOML `description` 을 비우면 "Execute the validated Keeper composition <name>." 같은 일반
  문장이 대신 나간다. Keeper 는 그것만으로 이 도구를 언제 쓸지 알 수 없다.

### 노드 입력은 도구 기본값을 그대로 받는다

노드에 `{}` 나 필수 필드만 넘기면 개수·모양·요약 여부가 전부 그 도구 기본값이다. 합성은
돌 때마다 같은 입력을 되풀이하므로 기본값이 만든 응답 크기를 매번 그대로 치르고, 도구
기본값이 바뀌면 스킬을 고치지 않아도 응답이 달라진다.
2026-09-07 ~ 2026-09-15 `tool_calls` 기록에서 입력을 비운 합성 노드
`masc_schedule_list {}` 는 342번 불렸고, 결과 크기 중앙값이 135,286 byte 였다.
`limit`, `compact`, `projection` 처럼 도구가 받는 개수·모양 인자는 노드 입력에 적는다.
빌트인 `work-intake` 는 노드마다 개수·상태·모양을 적고, 본문에 노드별 결과 크기를 남긴다.

노드 입력은 스킬을 읽을 때가 아니라 노드가 돌 때 도구 스키마로 검사한다. 필드 이름을
틀려도 로드는 되고 첫 호출에서 실패하므로, `config/tools/<tool>.toml` 과 직접 대조한다.

## 4. 파라미터 — Parallel as a Tool 의 손잡이

`[[compositions.params]]` 가 파라미터(`string`/`integer`/`number`/`boolean`)를
선언하면 도구의 input schema 가 거기서 생성된다 — required·타입·설명이 그대로 실려
모델이 여느 도구처럼 검증받으며 인자를 넘긴다.

값을 몇 개로 정해 두려면 `type = "string"` 에 `enum` 을 붙인다. 키 이름과 목록 모양은
`config/tools/*.toml` 과 같지만, 받는 값은 아래처럼 더 좁다.

```toml
[[compositions.params]]
name = "mode"
type = "string"
enum = ["scene", "regions"]
description = "scene: 보이는 내용, regions: 이후 범위 읽기에 쓸 영역 목록."
```

- input schema 의 그 속성에 `"enum": ["scene", "regions"]` 이 실려 모델에게 선택지로
  보인다.
- 목록 밖 값은 Agent-Core 가 합성 도구를 실행하기 전에 이 input schema 로 인자를 검사할 때
  검증 오류로 돌려보낸다. 노드는 하나도 돌지 않는다. 노드 도구가 더 많은 값을 받아도
  (`BrowserRead` 는 `text` 도 받는다) 마찬가지다.
- `enum` 은 `string` 에만 붙는다. 빈 목록, 같은 값이 두 번 든 목록, 다른 타입에 붙은
  `enum` 은 로드 오류다. `config/tools` 의 도구 정의는 `integer` enum 과 같은 값이 두 번 든
  목록도 받는다.
- 값 하나하나도 모델이 그대로 되돌려 보낼 수 있어야 한다. `enum` 을 못 싣는 공급자에게는
  값이 따옴표 없이 ` | ` 로 이어져 파라미터 설명에 들어가기 때문이다. 빈 문자열, 앞뒤에
  공백이 붙은 값, 줄바꿈이 든 값, `|` 문자가 하나라도 든 값은 로드 오류다.
- 목록을 노드 도구 스키마의 `enum` 과 맞춰 보지는 않는다. 노드 도구가 모르는 값을 적어도
  로드는 된다.
- 선언과 참조는 정확히 일치해야 한다: 선언 안 된 `param` 참조도, 아무 노드도 안 읽는
  선언도 로드 오류다.
- 파라미터는 전부 required 다.
- async 합성도 파라미터를 선언할 수 있다 — 인자는 제출 시점에 plan 에 바인딩되고,
  broker 는 crash 후 worker closure 를 재생하지 않으므로 바인딩된 plan 은 어떤 async
  run 과도 정확히 같은 수명을 가진다. 정적 read-only 제약은 그대로다.

## 5. 오류는 그 스킬만 격리한다

Agent Skills frontmatter 계약을 어긴 문서와 중복 스킬은 그 source candidate를 typed
rejection으로 격리한다. 해당 Skill을 Task가 지명한 턴만 admission 오류를 받고, 올바른
형제 Skill은 계속 사용할 수 있다. `SKILL.md`가 없는 디렉토리는 스킬이 아니므로 그냥
건너뛴다.

fence 문법 오류, fence 두 개 이상, 이름 불일치, 합성 plan 거부는 문서를 버리지 않는다.
`keeper_compose_<name>` 도구는 생기지 않고, 본문은 지시 스킬로 `keeper_skill` 목록에 오르며,
이유는 projection 진단으로 남는다(`keeper_skill_catalog.ml` `project_entry_or_fallback`).
합성으로 쓴 스킬이 도구 목록에 없으면 먼저 `/api/v1/skills` 의 진단을 본다.

## 6. 관측

- `GET /api/v1/skills` — 발행 스냅샷의 valid entry와 typed rejection, 종류·합성 도구
  이름/실행 모드·최근 사용 및 완료 성공/실패 횟수를 함께 돌려준다.
- document rejection은 안정적인 diagnostic `code`와 사람용 `message`를 함께 내보낸다.
  Monitor › Skills는 valid Skill이 하나도 없어도 source candidate별 code를 표시하며,
  message 문자열을 재파싱해 상태를 추측하지 않는다.
- 합성 실행은 노드 단위로 `tool_calls` 스토어에 남는다 (`composition_tool`,
  `composition_run_id`, `composition_node_id`) — SSE
  `keeper_tool_call_evidence_committed` 로도 흐른다. 이벤트에는 `success`, `disposition`,
  `duration_ms`가 포함된다. run 전체는 `record_kind=composition_run` 종결 행으로 별도
  기록되며 async는 durable settlement 이후에만 종결된다.
