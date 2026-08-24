---
rfc: "skills-as-tools"
title: "Skill 과 Tool 은 한 카탈로그의 두 표면 — SKILL.md 가 지시·합성·비동기를 선언한다"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: claude
supersedes: []
superseded_by: null
related: ["0389", "prompts-and-tool-definitions-outside-ocaml"]
implementation_prs: []
---

# RFC: Skills as Tools (skills-as-tools)

## 0. Summary

masc 는 도구 합성 DAG 실행기를 이미 갖고 있다. 그런데 그 위 표면이 둘로 갈라져 있고 둘 다
반쪽이다. 즉석 문법(`keeper_plan_execute`)은 368턴 동안 0번 선택됐고, 이름 붙은 카탈로그
합성(`keeper_compose_mission-snapshot`)은 같은 기간 8번 선택됐으며 지난 7일 노드 실행
500건을 만들었다. 모델은 문법이 아니라 **이름과 설명이 붙은 능력**을 고른다.

이 RFC 는 그 관측을 설계로 승격한다. `SKILL.md` 파일 하나가 능력 하나를 선언한다 —
지시문이면 프롬프트 카탈로그와 `keeper_skill` 도구로, 합성이 담겼으면
`keeper_compose_<name>` 도구로 표면화된다. Skill 이 Tool 이 되고(합성 스킬), Tool 이
Skill 을 갖고(도구 도움말의 md 외부화), Async 와 Parallel 은 스킬 선언의 실행 모드가 된다.
도구 스키마 표면(현재 상한 85,000 B)은 스킬을 아무리 늘려도 `keeper_skill` 도구 1개분만
쓴다 — 새 능력의 비용이 스키마 표면에서 프롬프트 한 줄로 이동한다.

## 1. 관측

수치는 전부 아래 명령으로 다시 잴 수 있다. 날짜가 붙지 않은 수치는 이 문서에 없다.

### 1.1 즉석 문법은 안 쓰이고, 이름 붙은 합성은 쓰인다 (2026-08-18 ~ 24)

`<base-path>/tool_calls/2026-08/*.jsonl` 의 `composition_tool` 필드 집계:

| 합성 | 노드 실행 (7일) |
|---|---:|
| `keeper_compose_mission-snapshot` (4노드, inline) | 500 |
| `keeper_compose_background-snapshot` (2노드, async) | 30 |
| `keeper_plan_execute` (모델 즉석 DAG) | 4 |

`keeper_tool_composition_surface.ml` 의 설명 리라이트 주석에 남은 선행 실측(2026-08-21~23):
87개 도구 표면 × 368턴에서 `keeper_plan_execute` 선택 0회, `keeper_compose_mission-snapshot`
선택 8회. 문법을 가르치는 254바이트보다 "무엇을 얻는가" 를 말하는 254바이트가 이겼다.

```sh
python3 - <<'PY'
import json, glob, collections
c = collections.Counter()
for f in glob.glob('<base-path>/tool_calls/2026-08/*.jsonl'):
    for line in open(f):
        r = json.loads(line)
        if r.get('composition_tool'): c[r['composition_tool']] += 1
print(c)
PY
```

### 1.2 카탈로그 합성은 인자를 받을 수 없다

`Keeper_tool_composition_surface.make_tools` 는 카탈로그 항목 전부에
`empty_input_schema`(properties 없는 object) 를 붙인다. `mission-snapshot` 의
`keeper_memory_search` 노드는 clock 출력만 query 로 쓸 수 있고, 호출하는 Keeper 가
"이걸 검색해" 라고 넘길 방법이 없다. 즉 지금 카탈로그 합성은 전부 0-인자 스냅샷이다.
파라미터가 없으니 능력 하나당 TOML 항목 하나를 복제하는 것 말고는 변형이 없다.

### 1.3 스킬은 일부러 꺼져 있고, 도구 표면은 상한 근처다

- Keeper 의 claude-code 런타임 스폰은 `--setting-sources=` (빈 값) 으로 스킬 로딩을 끈다.
  같은 환경에서 플래그만 빼면 빌트인+플러그인 91개 스킬이 로드된다 (2026-08-24 실측,
  아티팩트 "스킬은 어떻게 로드되는가"). 지금 masc 에는 SKILL.md 를 읽는 코드가 없다.
- 도구 스키마 표면 상한은 `test/test_keeper_tool_schema_bytes.ml:44` 의 85,000 B.
  2026-08-21 wire capture 기준 라이브 중앙값 78,916 B / 최대 79,512 B (RFC-0389 §1.1).
  도구 하나가 평균 약 780 B 이므로 남은 여유는 도구 예닐곱 개분이다.
- 도구 *정의* 는 이미 밖에 있다: `config/tools/*.toml` 113개
  (`Tool_definition_toml` 로더). 도구 *도움말* 은 아직 안이다:
  `tool_help_registry.ml` 의 `short_description`/`when_to_use`/`details_markdown` 은
  OCaml 문자열이고, `config/tools/*.toml` 에 `[help]` 테이블은 0개다.

### 1.4 Agent Skills 는 표준이고, 로딩 규약은 세 단계다

Anthropic 이 2025-12-18 공개한 Agent Skills 오픈 표준(agentskills.io)은 frontmatter 의
`name`/`description` 만 강제하고 나머지는 런타임 재량이다. 규약의 핵심은 점진 로딩:
(1) 세션 시작에 이름+한 줄 설명만, (2) 선택되면 본문, (3) 본문이 가리킬 때 참조 파일.
같은 파일이 Claude Code·OpenClaw·pi·Hermes 에서 동시에 동작하는 근거이고, masc 가
SKILL.md 를 읽으면 기존 생태계의 스킬 파일을 그대로 가져올 수 있다.

## 2. 설계

### 2.1 선언 — `<config-root>/skills/<name>/SKILL.md`

파일 하나가 능력 하나다. 저장소 기본값은 `config/skills/<name>/SKILL.md` 로 둔다 —
`config/` 트리는 이미 ocaml-crunch 로 바이너리에 임베드되고(`lib/embedded_config`),
`Managed_asset_sync` 가 부팅 때 `<config-root>` 로 수렴시키므로 새 동기화 코드는 없다.
`Config_dir_resolver` 에 `skills_dir` 를 더한다.

```markdown
---
name: mission-snapshot
description: Read clock, board, and tool state concurrently, then search durable memory.
---

# Mission snapshot

시계·보드·도구 상태를 동시에 읽고, 시계 출력으로 durable memory 를 검색한다.
결과를 요약할 때는 board 통계의 delta 를 먼저 본다.

```toml composition
[[compositions]]
name = "mission-snapshot"
description = "Read clock, board, and tool state concurrently, then search durable memory."
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
required = false
description = "Memory search query. Defaults to the clock output."

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
# … 이하 기존 tool-compositions.toml 문법 그대로
```

디코드 규칙:

- frontmatter 는 기존 `lib/core/frontmatter` (평면 key:value) 로 읽는다. Agent Skills
  표준의 필수 두 키 `name`/`description` 이 없거나 비면 기동 오류, 디렉토리 이름과
  `name` 불일치도 기동 오류(`config/tools/<name>.toml` 과 같은 규칙). 표준대로 모르는
  frontmatter 키는 무시한다 — 다른 런타임의 네임스페이스가 섞인 파일도 그대로 동작한다.
- 스킬의 종류는 frontmatter 키가 아니라 **본문 내용이 결정한다**:
  ```` ```toml composition ```` fenced block 이 0개면 지시 스킬, 1개면 합성 스킬,
  2개 이상이면 기동 오류. block 의 내용은 **기존
  `Keeper_tool_composition_catalog.parse` 가 그대로 읽는다** — 새 문법은 없고, kind
  선언과 실체가 어긋나는 상태 자체가 표현 불가능하다.
- 실패는 전부 기동 오류다(fail-closed, 기존 TOML 정책과 동일). 단 skills 디렉토리가
  없거나 비어 있는 것은 오류가 아니라 "스킬 0개" 다 — 섹션 미주입, 정상 부팅.

### 2.2 표면 — 스킬 하나가 두 얼굴을 갖는다

```ocaml
type surface =
  | Instruction                                    (* 프롬프트 카탈로그 + keeper_skill *)
  | Composition of Keeper_tool_composition_catalog.entry
    (* 위에 더해 keeper_compose_<name> 도구로 승격 *)
```

1. **프롬프트 카탈로그 (1단계).** `keeper_unified_prompt` 가 `## Skills` 섹션에
   스킬당 한 줄(`name — description`)을 넣는다. 비용은 프롬프트 쪽이고 스킬당 수십 B 다.
2. **`keeper_skill` 도구 (2단계).** 입력 `{ name }`, 출력은 해당 SKILL.md 본문(frontmatter
   제외). 스킬이 몇 개든 도구 스키마 표면 비용은 이 도구 1개분으로 고정된다.
3. **합성 스킬 = 도구 (Skill as a Tool).** `kind = "composition"` 스킬은 기존
   `make_tools` 경로로 `keeper_compose_<name>` 도구가 된다. 실행기·텔레메트리·async
   broker(status/cancel)는 재사용이고 변경이 없다.
4. **참조 파일 (3단계).** 본문이 스킬 디렉토리의 상대 경로를 가리키면 기존 Read 도구로
   읽는다. 새 도구는 없다.

### 2.3 파라미터 — 카탈로그 합성의 0-인자 제한을 푼다

`Json_template` 에 생성자 하나를 더한다.

```ocaml
type t = private
  | Literal of Yojson.Safe.t
  | Output of { node_id : Node_id.t; pointer : Json_pointer.t }
  | Param of { name : string }          (* NEW: 호출 인자 참조 *)
  | Object of (string * t) list
  | Array of t list
```

- `[[compositions.params]]` 가 (name/type/required/description) 를 선언하고, 도구의
  input schema 는 params 에서 생성된다 — `empty_input_schema` 는 params 없는 합성에만 남는다.
- `Param` 참조가 선언 안 된 이름이면 plan 생성 시점 오류. required param 누락은 기존
  `Tool_input_validation.validate_args` 가 스키마로 거른다.
- `keeper_plan_execute` 의 즉석 plan 에는 `Param` 이 없다 — 즉석 호출은 인자를 literal 로
  직접 쓰면 되므로 참조할 "바깥" 이 없다.

### 2.4 Tool as a Skill — 도움말의 md 외부화

`tool_help_registry.ml` 의 도구별 `short_description`/`when_to_use`/`details_markdown` 을
`config/tools/<name>.help.md` (frontmatter: `when_to_use`; 본문: details) 로 옮기고
`masc_tool_help` 는 파일에서 서빙한다. RFC-prompts-and-tool-definitions-outside-ocaml §3.8 은
같은 내용을 TOML `[help]` 로 계획했는데, `details_markdown` 이 이미 markdown 이므로 이 RFC 가
그 항목을 md 파일로 개정·흡수한다. 이로써 도구는 (정의 = TOML) + (사용 지식 = md) 를 갖는다 —
도구가 스킬 카드를 갖는 것이고, 운영자는 재빌드 없이 도움말을 고친다.

### 2.5 Async as a Skill / Parallel as a Tool

- 합성 스킬의 `execution = "async"` 는 기존 durable broker 로 그대로 흐른다.
  status/cancel 도구, "정적 read-only 노드만" 제약도 그대로다 — 이 제약은 게이트가 아니라
  effect 재실행 안전이다.
- 병렬성은 이미 plan 의 성질이다(의존 없는 노드는 동시 실행). 스킬은 그 plan 에
  이름·설명·파라미터를 붙여 모델이 실제로 고르게 만든다. §1.1 이 근거다.

### 2.6 관측성

- `keeper_skill` 호출은 도구 호출이므로 `tool_calls` 스토어에 자동 기록된다 — 스킬별
  사용 횟수는 추가 생산자 없이 집계된다.
- 합성 실행은 기존 `composition_run_id` 노드 텔레메트리 + SSE
  (`keeper_tool_call_evidence_committed`) 를 그대로 쓴다.
- 대시보드: `/api/v1/skills` (카탈로그: name, description, kind, source file, 최근 사용
  횟수) + Skills 패널. 합성 스킬 상세에서 노드 실행 흐름(run 별 node_result)을 보인다.

### 2.7 하드 컷 — `tool-compositions.toml` 은 삭제한다

라이브 카탈로그의 합성 2개(`mission-snapshot`, `background-snapshot`)를 SKILL.md 로 옮기고
`<config-root>/tool-compositions.toml` 경로와 그 로더 진입점을 지운다. 도구 이름
(`keeper_compose_*`)과 wire 스키마는 이전 전후 동일해야 한다(§4). 합성 선언 표면은
skills 디렉토리 하나가 된다. 마이그레이션 코드·호환 reader 는 만들지 않는다.

## 3. 하지 않을 것

- **도구의 동적 탈착.** 표면은 턴 시작에 고정된다(RFC-0389 §3.3 유지). 스킬 본문 로드는
  표면 변경이 아니라 도구 호출이다.
- **스킬 자동 생성·원격 설치.** 카탈로그는 운영자가 파일로 선언한다. pi 식 패키지 배포는
  이 RFC 밖이다.
- **`keeper_plan_execute` 제거.** 즉석 문법은 사용량이 0에 가깝지만, 스킬을 만들 가치가
  없는 1회성 조합의 유일한 통로다. 스킬 도입 후 사용량을 다시 재고 판단한다.
- **keeper 별 스킬 표면.** RFC-0389 의 `[keeper.tools]` 가 구현될 때 `[keeper.skills]` 를
  같은 축으로 더한다. 이 RFC 는 전원 동일 카탈로그로 시작한다.
- **런타임(claude-code CLI) 스킬 로딩 켜기.** `--setting-sources=` 는 그대로 둔다.
  masc 의 스킬은 masc 카탈로그가 소유한다 — 런타임별 스킬 로더에 위임하면 non-claude
  런타임(codex/glm/kimi/ollama)과 표면이 갈라진다.

## 4. 마이그레이션 — PR 사슬

| # | 브랜치 | 내용 | 크기 |
|---|---|---|---|
| 1 | `rfc/agent-skills-duality` | 이 RFC | docs만 |
| 2 | `feat/skill-catalog` | `Keeper_skill_catalog` 로더: frontmatter + fenced composition 파싱(기존 Catalog.parse 재사용), 오류 합타입, 픽스처 테스트 | lib 1 + test 1 |
| 3 | `feat/skill-surface` | boot 배선 + `keeper_skill` 도구 + `## Skills` 프롬프트 섹션 + 합성 스킬 → make_tools | lib 3-4 + test |
| 4 | `feat/composition-params` | `Json_template.Param` + `[[compositions.params]]` + input schema 생성 | lib 2 + test |
| 5 | `feat/skills-hard-cut` | 라이브 합성 2개 이전, `tool-compositions.toml` 경로 삭제 | lib 1 + config |
| 6 | `feat/tool-help-md` | `config/tools/<name>.help.md` + registry 서빙 전환 | lib 1 + config 다수 |
| 7 | `feat/dashboard-skills` | `/api/v1/skills` + Skills 패널 + 합성 run 뷰 | server + dashboard |
| 8 | (runtime) | 라이브 `<config-root>/skills/` 배치, keeper 재기동, 사용 실측·스크린샷 | 코드 없음 |

2→3→4→5 는 순서 의존(stacked), 6·7 은 2 이후 독립.

## 5. 수용 기준

- 스킬 N개를 추가해도 도구 스키마 표면 증가분은 `keeper_skill` 1개 + 합성 스킬 도구뿐이다.
  `test_keeper_tool_schema_bytes` 상한 85,000 B 유지.
- 깨진 SKILL.md(frontmatter 필수 키 누락, name 불일치, fenced block 문법 오류, block
  2개 이상)는 각각 파일·위치를 가리키는 기동 오류다 — 테스트로 고정.
- `mission-snapshot`/`background-snapshot` 이 SKILL.md 로 이전된 뒤 도구 이름·발행 스키마가
  이전과 동일하다(스키마 diff 테스트).
- 파라미터 합성: `[[compositions.params]]` 선언이 input schema 에 반영되고, 라이브에서
  인자 있는 호출이 `tool_calls` 에 기록된다.
- 라이브 실측: keeper 가 `keeper_skill` 를 최소 1회 자발 호출하고, 합성 스킬 실행이
  대시보드에서 보인다(스크린샷 + `tool_calls` 발췌).

## 6. 기존 RFC 와의 관계

- **RFC-0389 (Keeper 별 도구 표면, Draft)**: 충돌 없음. 이 RFC 의 스킬 카탈로그는 0389 의
  `compositions = [...]` 선언이 참조할 이름 공간을 skills 로 바꾼다. 0389 구현 시
  `[keeper.skills]` 를 같은 선언에 더한다.
- **RFC-prompts-and-tool-definitions-outside-ocaml (Draft)**: 같은 방향의 이웃. §3.8 의
  `tool_help_registry → [help]` 항목을 이 RFC §2.4 가 md 파일로 개정·흡수한다. 나머지
  항목(프롬프트 키, 도구 TOML)은 그대로다.
- **RFC-0386 (tool_kind 닫힌 합타입)**: `keeper_skill` 은 새 tool_kind 가 아니라 기존
  분류를 따른다. 합성 스킬은 기존 `Composition_tool`/`Async_composition_tool` 그대로.
