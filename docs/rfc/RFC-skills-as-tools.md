---
rfc: "skills-as-tools"
title: "Skill 과 Tool 은 한 카탈로그의 두 표면 — SKILL.md 가 지시·합성·비동기를 선언한다"
status: Active
created: 2026-08-25
updated: 2026-08-25
author: claude
supersedes: []
superseded_by: null
related: ["prompts-and-tool-definitions-outside-ocaml", "skills-declared-not-discovered"]
---

# RFC: Skills as Tools (skills-as-tools)

## 0. Summary

masc 는 도구 합성 DAG 실행기를 이미 갖고 있다. 그런데 그 위 표면이 둘로 갈라져 있고 둘 다
반쪽이다. 즉석 문법(`keeper_plan_execute`)은 368턴 동안 0번 선택됐고, 이름 붙은 카탈로그
합성(`keeper_compose_mission-snapshot`)은 같은 기간 8번 선택됐으며 지난 7일 노드 실행
500건을 만들었다. 모델은 문법이 아니라 **이름과 설명이 붙은 능력**을 고른다.

이 RFC 는 그 관측을 설계로 승격한다. `SKILL.md` 파일 하나가 능력 하나를 선언한다 —
지시문이면 task 라우팅(RFC skills-declared-not-discovered)과 `keeper_skill`로 keeper 에게
닿고, 합성이 담겼으면 `keeper_compose_<name>` 도구로 표면화된다. Skill 이 Tool 이
되고(합성 스킬), Tool 이 Skill 을 갖고(도구 도움말의 md 외부화), Async 와 Parallel 은
스킬 선언의 실행 모드가 된다. 지시 스킬 본문은 매 턴 싣지 않고, 이름과 설명만 담은
고정 `keeper_skill` 도구를 통해 필요할 때 읽는다.

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
  **정정 (2026-08-25 재측정, main `3dafed3f98`)**: 이 문서 초판은 08-21~23 의 수치
  (79,512 B / 88,138 B)를 인용했는데 그 뒤 표면이 줄었다. 현재
  `model_visible_schemas ()` 기준 **82개 / 69,282 B, 여유 15,718 B** — "도구로 넣는
  길이 막혀 있다" 는 초판의 압박 서술은 더 이상 사실이 아니다. 게이트는 양방향이라
  (여유가 상한의 1/3 을 넘어도 실패) 표면을 12,616 B 이상 더 줄이면 상한도 같이
  내려야 한다. 스킬의 근거는 예산 압박이 아니라 §1.1 의 선택 행동과, 지시 스킬의
  표면 비용이 0 B 라는 구조적 성질에 있다. 참고로 설명문은 표면의 28%뿐이고
  단일 최대 항목은 `Execute` 8,455 B (반복 문단 4,158 B — `$ref` 미검증이라 보류)다.
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

### 2.1 선언 — `<base_path>/.masc/skills/<name>/SKILL.md`

파일 하나가 능력 하나다. 위치는 RFC skills-declared-not-discovered 가 이미 배송한
관례를 따른다 — task 의 current-task 블록이 keeper 에게 가리키는 바로 그 경로다
(`Common.masc_dirname` SSOT). 스킬은 외부에서 설치되는 파일이므로 `config/` 트리
임베드는 하지 않는다.

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

- 파일 한 장의 frontmatter 계약은 **`Agent_core.Skill_document`가 단독 소유한다** (RFC
  skills-declared-not-discovered §4.1). 카탈로그 레이어(`Keeper_skill_catalog`)는
  frontmatter 를 직접 읽지 않고 그 위에서 합성 감지와 카탈로그 조립만 한다 —
  같은 SKILL.md 를 읽는 파서는 저장소에 하나다.
- 스킬의 종류는 frontmatter 키가 아니라 **본문 내용이 결정한다**:
  ```` ```toml composition ```` fenced block 이 0개면 지시 스킬, 1개면 합성 스킬,
  2개 이상이면 기동 오류. block 의 내용은 **기존
  `Keeper_tool_composition_catalog.parse` 가 그대로 읽는다** — 새 문법은 없고, kind
  선언과 실체가 어긋나는 상태 자체가 표현 불가능하다.
- Agent Skills frontmatter 계약을 어긴 문서와 composition/fence 오류는 그 문서만
  fail-closed다. 이름 누락·불일치·문법 오류, 길이 초과, 알 수 없는 top-level field,
  잘못된 metadata shape는 typed rejection으로 남는다. skills 디렉토리가 없거나 비어
  있는 것은 오류가 아니라 "스킬 0개"다.

### 2.2 표면 — 스킬 하나가 두 얼굴을 갖는다

```ocaml
type surface =
  | Instruction                                    (* task 라우팅 + keeper_skill *)
  | Composition of Keeper_tool_composition_catalog.entry
    (* 위에 더해 keeper_compose_<name> 도구로 승격 *)
```

1. **지시 스킬은 task 가 라우팅한다 (1·2단계).** RFC skills-declared-not-discovered 가
   배송한 그대로다: `task.skills` 가 이름을 지정하면 current-task 블록에 이름 한
   줄이 실린다. 전 카탈로그를 프롬프트에 늘어놓고 모델이 고르게 하는 방식은 쓰지
   않는다 — 이 RFC 초안에 있던 `## Skills` 전역 섹션은 만들지 않았다.
   (구현 정정: `keeper_skill` 읽기 도구는 결국 **만들었다** — #30635. `.masc/skills`
   가 샌드박스 루트 옆이라 `Read` 가 거의 실패했기 때문. 본문은 이제 경로+`Read` 가
   아니라 이 도구로 나간다.)
2. **합성 스킬 = 도구 (Skill as a Tool).** 합성 block 을 가진 스킬은 기존
   `make_tools` 경로로 `keeper_compose_<name>` 도구가 된다. 실행기·텔레메트리·async
   broker(status/cancel)는 재사용이고 변경이 없다. 도구는 턴 시작에 고정되는
   전역 표면이므로 합성 스킬은 task 라우팅과 무관하게 전원에게 실린다 —
   지시는 task 단위, 능력은 fleet 단위라는 분리다.
3. **참조 파일 (3단계).** 본문이 스킬 디렉토리의 상대 경로를 가리키면 기존 Read 도구로
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
- 병렬성은 plan과 descriptor의 성질이다. 같은 dependency layer에서 `Ordinary
  Concurrent`인 노드만 묶고 `Ordinary Serial`/`Terminal`은 직렬 실행한다. 스킬은 plan에
  이름·설명·파라미터를 붙여 모델이 실제로 고르게 만든다. §1.1 이 근거다.

### 2.6 관측성

- 스킬 본문 읽기는 `keeper_skill(name)` 호출로 `tool_calls` 스토어에 기록되고, 그
  `name` 인자로 스킬별 사용량을 집계한다.
- 합성 실행은 기존 `composition_run_id` 노드 텔레메트리 + SSE
  (`keeper_tool_call_evidence_committed`) 를 그대로 쓰며 SSE도 노드의 성공·duration을
  보존한다. inline/async 모두 `record_kind=composition_run` 종결 행을 남기고 async는
  durable settlement만 종결로 인정한다.
- 대시보드: `/api/v1/skills` (카탈로그: name, description, kind, source file, 최근 사용
  횟수와 완료 성공/실패 횟수) + Skills 패널. 합성 스킬 상세에서 노드 실행 흐름(run 별
  node_result)을 보인다.

### 2.7 하드 컷 — `tool-compositions.toml` 은 삭제한다

라이브 카탈로그의 합성 2개(`mission-snapshot`, `background-snapshot`)를 SKILL.md 로 옮기고
`<config-root>/tool-compositions.toml` 경로와 그 로더 진입점을 지운다. 도구 이름
(`keeper_compose_*`)과 wire 스키마는 이전 전후 동일해야 한다(§4). 합성 선언 표면은
skills 디렉토리 하나가 된다. 마이그레이션 코드·호환 reader 는 만들지 않는다.

## 3. 하지 않을 것

- **도구의 동적 탈착.** 표면은 턴 시작에 고정된다. 스킬 본문 로드는
  표면 변경이 아니라 도구 호출이다.
- **스킬 자동 생성·원격 설치.** 카탈로그는 운영자가 파일로 선언한다. pi 식 패키지 배포는
  이 RFC 밖이다.
- **`keeper_plan_execute` 제거.** 즉석 문법은 사용량이 0에 가깝지만, 스킬을 만들 가치가
  없는 1회성 조합의 유일한 통로다. 스킬 도입 후 사용량을 다시 재고 판단한다.
  같은 축으로 더한다. 이 RFC 는 전원 동일 카탈로그로 시작한다.
- **런타임(claude-code CLI) 스킬 로딩 켜기.** `--setting-sources=` 는 그대로 둔다.
  masc 의 스킬은 masc 카탈로그가 소유한다 — 런타임별 스킬 로더에 위임하면 non-claude
  런타임(codex/glm/kimi/ollama)과 표면이 갈라진다.

## 4. 마이그레이션 — PR 사슬

| # | 상태 | 내용 |
|---|---|---|
| 1 | 병합 (#30177) | 이 RFC |
| 2 | 병합 (#30183) | `Keeper_skill_catalog`: fenced composition 감지 + 카탈로그 조립 |
| 2b | 병합 (#30189, 병렬 세션) | `Agent_core.Skill_document` 파서 + `task.skills` 라우팅 + current-task 한 줄 |
| 3 | 병합 (#30205) | 파싱 SSOT 통합: 카탈로그가 한 파서에 위임 |
| 4 | 병합 (#30208) | 스킬 디렉토리 스캔 + 합성 스킬 → make_tools 배선 |
| 5 | 병합 (#30215) | `[[compositions.params]]` + input schema 생성 |
| 6 | 병합 (#30220) | `tool-compositions.toml` 경로·로더 삭제 (하드컷) |
| 7 | 대체 | 도구 도움말은 md 파일 대신 `config/tools/<name>.toml` `[help]` 로 externalize (§2.4 개정). 산문이 OCaml 밖이라는 목표는 달성 — md 파일 형식은 미채택 |
| 8 | 병합 (#30236 API, #30727 스냅샷, #30777 패널) | `/api/v1/skills` + Monitor › Skills 패널 (종류·도구·사용 횟수) |
| 9 | 병합 | 라이브 `<base_path>/.masc/skills/` 배치 (6개 스킬), keeper 재기동, 하루 수백 회 `keeper_compose_*`/`keeper_skill` 호출 |

후속: task 가 지명한 스킬의 프롬프트 주입은 보유한 모든 task 로 확장됨 (task-364, #30774) —
current task 뿐 아니라 함께 든 task 의 스킬도 프롬프트·admission 에 실린다.
2차(소스 정책·불변 스냅샷·영수증)는 #30680/#30691/#30697/#30727/#30732/#30745/#30752 로 진행.

## 5. 수용 기준

- 지시 스킬 N개는 도구 스키마 표면을 0 B 늘린다. 합성 스킬만 도구가 된다.
  `test_keeper_tool_schema_bytes` 상한 85,000 B 유지.
- Agent Skills frontmatter 계약을 어긴 SKILL.md와 fenced block/plan 오류는 source
  candidate와 content revision을 가진 rejection으로 격리된다. 올바른 형제 Skill은 계속
  발행된다.
- `mission-snapshot`/`background-snapshot` 이 SKILL.md 로 이전된 뒤 도구 이름·발행 스키마가
  이전과 동일하다(스키마 diff 테스트).
- 파라미터 합성: `[[compositions.params]]` 선언이 input schema 에 반영되고, 라이브에서
  인자 있는 호출이 `tool_calls` 에 기록된다.
- 라이브 실측: task 가 지정한 스킬을 keeper 가 `keeper_skill`로 실제로 열고, 합성 스킬 실행이
  대시보드에서 보인다(스크린샷 + `tool_calls` 발췌).

## 6. 기존 RFC 와의 관계

- **RFC skills-declared-not-discovered (#30156, 구현 #30189)**: 같은 파일 형식의 아랫층.
  그 RFC 가 파일 한 장의 파싱(`Agent_core.Skill_document`)과 지시 스킬의 task 라우팅을 소유하고,
  이 RFC 는 그 위에서 합성 스킬의 도구 승격과 파라미터를 소유한다. 초안에 있던
  `keeper_skill` 도구·`## Skills` 전역 섹션·`config/skills` 임베드는 그 설계에 맞춰
  제거했다 (§2.2).
  `[keeper.skills]` 를 같은 선언에 더한다.
- **RFC-prompts-and-tool-definitions-outside-ocaml (Draft)**: 같은 방향의 이웃. §3.8 의
  `tool_help_registry → [help]` 항목을 이 RFC §2.4 가 md 파일로 개정·흡수한다. 나머지
  항목(프롬프트 키, 도구 TOML)은 그대로다.
- **RFC-0386 (tool_kind 닫힌 합타입)**: 새 tool_kind 는 없다. 합성 스킬은 기존
  `Composition_tool`/`Async_composition_tool` 그대로.

## 7. 선행 사례 (2026-08-25 확인, 전부 공식 문서/원논문)

이 설계가 어디에 서 있는지의 기록이다. 수치는 각 출처의 것이다.

- **Agent Skills 스펙** (agentskills.io/specification): frontmatter 전체 필드는 6개
  (`name`, `description`, `license`, `compatibility`, `metadata`, 실험적 `allowed-tools`).
  3단계 progressive disclosure
  (메타 ~100토큰 상시 / 본문 <5k 토큰 / 참조 파일 필요 시). 채택 클라이언트 40+
  (Claude Code, Codex, Gemini CLI, Cursor, OpenClaw, pi 등). masc는 같은 portable
  frontmatter 계약을 admission에 사용하고, 클라이언트 확장은 `metadata` 아래에 둔다.
  `allowed-tools`는 문법만 검증하고 semantic AST와 snapshot entry에서 값을 버린다.
  편집기에서 보이는 원문은 portable source round-trip일 뿐이며, MASC 승인 정책만 실행
  권한의 권위다.
- **Anthropic Tool Search Tool (GA)**: `defer_loading: true` 도구는 컨텍스트에서
  빠지고 검색 시 `tool_reference` 로 인라인 확장(캐시 보존). 공식 수치 ~55k 토큰의
  85%+ 절감, 도구 30–50개 초과 시 선택 정확도 저하. 커스텀 검색 도구가
  `tool_result` 에 `tool_reference` 를 반환하는 확장점이 문서화돼 있다 — masc 가
  서버 수준에서 같은 패턴을 재현할 수 있는 근거.
- **Anthropic Programmatic Tool Calling (GA)** + **OpenAI Responses API**: 코드 실행
  안에서 도구를 함수로 호출(`allowed_callers`, `caller` 구분), OpenAI 도
  `defer_loading`/`allowed_callers` 라는 **같은 필드명**으로 수렴했다. 벤더 중립
  타입으로 정의해도 종속이 아니라는 뜻이다.
- **"Code execution with MCP"** (anthropic.com/engineering, 2025-11-04): 도구를
  파일시스템 위 코드 API 로 제시해 필요한 것만 로드 — 예시 150,000→2,000 토큰.
  keeper 의 Execute 표면과 스킬 참조 파일이 같은 노선의 자리다.
- **LLMCompiler** (arXiv:2312.04511, ICML 2024): planner→DAG→executor 와 `$N` 참조.
  masc 의 `Keeper_tool_plan` (`after` + `output` pointer) 이 같은 모양이며, 논문의
  근거 수치는 ReAct 대비 최대 3.7× 지연·6.7× 비용 절감(Table 1·2).
- **CodeAct** (arXiv:2402.01030, ICML 2024): 코드를 행동 공간으로 통일하면 최대
  20% 높은 성공률(abstract). Anthropic/OpenAI PTC 가 이 노선의 상용화다.
- **MCP 스펙 2025-11-25**: tool 배칭·합성·그룹은 스펙 관심사가 아니다(JSON-RPC
  batching 은 2025-06-18 개정에서 제거). 합성 도구를 일반 `tools/call` 로 노출하는
  masc 방식은 스펙과 충돌하지 않는다.
