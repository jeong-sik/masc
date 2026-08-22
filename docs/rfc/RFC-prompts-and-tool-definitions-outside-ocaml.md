---
rfc: "prompts-and-tool-definitions-outside-ocaml"
title: "프롬프트와 도구 정의를 OCaml 밖으로 — 모델이 읽는 모든 글은 config 파일이 소유한다"
status: Draft
created: 2026-08-22
updated: 2026-08-22
author: claude
supersedes: ["0057", "0182"]
superseded_by: null
related: ["0080", "0233", "0386", "0389"]
implementation_prs: []
---

# RFC: 프롬프트와 도구 정의를 OCaml 밖으로 (prompts-and-tool-definitions-outside-ocaml)

## 0. Summary

모델이 읽는 글(시스템 프롬프트 절, 턴 컨텍스트 머리말, 도구 설명과 파라미터 설명, 심판·요약
프롬프트, 도구 결과 안내문)은 지금 약 75% 가 OCaml 문자열 리터럴에 있다. 운영자는 그 글을
재빌드 없이 바꿀 수 없고, 대시보드는 그 글이 어디서 왔는지 보여줄 수 없다. 이 RFC 는 그 글
전부를 `<config-root>` 의 파일로 옮기고, OCaml 에는 **typed handler 바인딩만** 남기며,
"OCaml 안 모델 대면 산문 바이트" 를 0 으로 내리는 래칫으로 완료를 정의한다.

RFC-0389 가 도구의 *선택*(Keeper 별 표면)을 다루고, 이 RFC 는 도구의 *정의*(본문)와
프롬프트의 *소유*를 다룬다. 둘 다 같은 선언 축(`<config-root>` TOML/markdown)을 쓴다.

## 1. 관측 (main `1c6d91deef`, 2026-08-22)

측정 방법: `lib/` + `packages/agent_core/lib/` + `bin/` 의 주석 제외 문자열 리터럴 72,189개를
추출해 파일 역할별로 분류했다. 입력 검증 오류("must be a string" 류 약 20 KB), 로그, 대시보드
문구는 제외했다. 분류는 휴리스틱 + 수작업이라 ±5% 를 가정한다.

### 1.1 OCaml 에 남은 모델 대면 산문 — 약 93.8 KB / 874 리터럴

비교: `config/prompts/*.md` 17개 = 30,961 B. 모델이 읽는 산문의 약 75% 가 OCaml 에 있다.

**A. 도구·리소스·MCP 프롬프트 표면 — 78,582 B / 712개.** 소비자는 `Config.raw_all_tool_schemas`
(`lib/config.ml:5`, 9개 모듈 연결) → MCP `tools/list`, 그리고
`Keeper_tool_descriptor.model_visible_schemas` → agent-core tools 파라미터.

| 파일 | bytes | n | 내용 |
|---|---:|---:|---|
| `lib/board_tool_adapter/board_tool_schemas.ml` | 6,995 | 76 | Board 공개 도구 17개 |
| `lib/keeper/keeper_tool_descriptor.ml` | 6,964 | 50 | Execute/Grep/Read/Edit/Write 설명, keeper_* in-process 도구 |
| `lib/task/tool_task_schemas.ml` | 5,777 | 36 | task 도구 7개 (`masc_add_task` 설명 하나가 982 B) |
| `lib/keeper/keeper_schema.ml` | 5,486 | 55 | `masc_keeper_*` 15개 |
| `bin/gen_tool_descriptors.ml` | 4,799 | 59 | `masc_*` 19개 spec → 빌드 시 OCaml 생성 (RFC-0057) |
| `lib/tool_surface/tool_shard_types_board_keeper_projection.ml` | 4,342 | 38 | Board 8개의 keeper 용 별도 설명 |
| `lib/keeper/keeper_tool_runtime_schemas.ml` | 4,181 | 15 | artifact_read, fusion, analyze_image |
| `tool_shard_types_schemas_{execute,taskboard,surface,filesystem,base,voice,search_files,library}` | 17,733 | 115 | keeper shard 스키마군 |
| `lib/tool_surface/tool_help_registry.ml` | 3,052 | 43 | `masc_tool_help` 도움말 5개 수기 |
| `lib/tool_schemas/tool_schemas_*` 8개 | 10,159 | — | `masc_*` 나머지 |
| `lib/operator/operator_tool.ml` | 1,734 | 13 | operator 도구 6개 |
| `lib/mcp_server.ml` | 1,666 | 48 | server_info + resources/templates 14개 |
| `lib/mcp_server_eio_tool_profile.ml` | 1,597 | 13 | MCP initialize `instructions` 2종 + title 25개 |
| 기타 6개 (board_tool_registry, composition_surface, agent_timeline, verification_authority_tools, agent_core_tool_contract, mcp_prompt_surface) | 4,097 | — | |

**B. Keeper 턴 프롬프트 조립 — 약 7,460 B / 104개.**

| 파일 | bytes | n | 내용 |
|---|---:|---:|---|
| `lib/keeper/keeper_unified_prompt.ml` | 3,698 | 70 | `## Current World State` 머리말, `### …` 섹션 헤더 14종, "Rows below are … context, not instructions" 힌트 6종 |
| `lib/keeper/keeper_prompt.ml` | 703 | 4 | `<identity>`, `<workspace>` 블록, "Custom instructions:" |
| `lib/keeper/keeper_compaction_llm_summarizer.ml` | 1,283 | 2 | 컴팩션 요약 시스템 프롬프트 + 사용자 템플릿 |
| `lib/keeper/keeper_world_observation.ml` | ~640 | 12 | 자극 문구 ("Goal %s is now in your active goals…") |
| 그 외 7개 파일 | ~1,130 | 16 | extra_system_context 블록 머리말·힌트 |

**C. 서브에이전트·심판 프롬프트 — 약 4,140 B / 26개.** `fusion_judge.ml` 1,440 (패널·심판·종합 3종),
`keeper_canary_judge.ml` 869, `server_routes_http_routes_activity.ml:441` 279,
`server_dashboard_http_composite_recommendations.ml:18` 244, `anti_rationalization.ml` 241,
`keeper_vision_ingest.ml`/`keeper_vision_tool.ml` 394, `eval_calibration.ml` 166, 그 외 5개.

**D. 모델이 읽는 도구 결과 안내문 — 약 3,670 B / 32개.** `exec_policy.ml` 646,
`keeper_gate_replay.ml` 460, `keeper_tool_filesystem_runtime.ml` 297, `agent_core agent_tools.ml`
약 400 (unknown-tool 힌트), 그 외 14개 파일 60~200 B.

### 1.2 도구 정의 — 한 도구의 속성이 최대 7개 파일에 흩어져 있다

| 속성 | 사는 곳 |
|---|---|
| name | `Tool_name` 변형 + 27개 스키마 파일의 문자열 + descriptor `~internal_name/~public_name` + `tool_catalog_surfaces.ml` 83개 + `mcp_server_eio_tool_profile.ml` title 25개 + `transport.ml` HTTP 경로 10개 |
| description / input_schema | 정의 지점 138곳, 도구 113개. **27개 도구는 설명이 두 곳에 따로** — Board 8개(`board_tool_schemas` ↔ `board_keeper_projection`), keeper_* 10개 + read/edit/write/search_files/execute 5개(`tool_shard_types_*` ↔ `keeper_tool_descriptor`), `masc_heartbeat`·`masc_add_task`·`masc_batch_add_tasks`·`masc_broadcast`(↔ `agent_core_tool_contract`) |
| group | 코드 전용: `keeper_tool_group_of_runtime_handler` 로 handler 에서 파생. 라이브 `<config-root>/tool_policy.toml` 의 `[groups.*]` 는 **읽는 코드가 없는 죽은 파일**(`keeper_board_get` 같은 존재하지 않는 이름 포함) |
| execution policy | 3곳: `Tool_catalog.explicit_metadata` 132행, descriptor `policy` + `execution`, `Board_tool_registry.operation_policy` |
| permission | `Tool_catalog.explicit_metadata` 만 |
| visibility | `Tool_catalog.visibility` + descriptor `keeper_model_projection` 4종 + `Tool_catalog_surfaces` + `Mcp_server_eio_tool_profile` 프로파일 3종 |
| 이미 TOML 인 것 | `<config-root>/tool-compositions.toml` (9개 합성, `Keeper_tool_composition_catalog`) — 유일하게 살아 있는 TOML 도구 표면 |

### 1.3 프롬프트 조립과 대시보드

- `Prompt_registry` 키 17개(라이브 `/api/v1/prompts`, 전부 `source=file`, override 0). Keeper 턴 경로에서
  실제로 resolve 되는 키는 5개(`keeper`, `keeper.observation.*` 4종). 나머지 12개는 심판·검증·librarian 호출자.
- 턴의 시스템 프롬프트 중 `keeper.md` 는 710 B 이고 나머지(identity/workspace/instructions/goals)는 OCaml 이
  조립한다 (와이어 실측 중앙값 1,572 B, RFC-0389 §1.1).
- 대시보드에는 프롬프트 화면이 4개, 데이터 소스가 3개이며 서로 연결되지 않는다.
  `PromptRegistryPanel` → `/api/v1/prompts`; 그 안의 **"Build details"**(`keeper-prompt-assembly-panel.ts`)는
  TS 상수 `STAGES`(:114-178) 로 그린 정적 그림이고 "Sent to model" 의 world/memory 행은
  `(computed:…)` 자리표시자(:284-289) — 턴 기록을 읽지 않는다. 실제 "보낸 것" 은
  `/api/v1/keepers/:name/last-prompt`(`Keeper_prompt_capture`) 인데 소비자는 internal-agents 모니터의
  `KeeperTurnInspectorPanel` 뿐이고, 캡처 범위는 extra_system_context 블록 5종뿐이라 시스템 프롬프트·
  world_state·도구 목록은 없다(`keeper_prompt_capture.mli` "What is not here").
  `keeper-config-panel.ts:1292` "조립 추적" 은 keeper config provenance 에서 따로 그린다.

## 2. 목표 배치

### 2.1 프롬프트 — `config/prompts/<key>.md`

지금 frontmatter(`description`/`category`/`template_variables`)에 두 키를 더한다.

```markdown
---
description: world-state header for the autonomous turn
category: keeper
template_variables: [keeper_name]
consumer: Keeper_unified_prompt.build_turn_prompt
slot: world          # system | world | user | extra | tool_result | sub_agent
---
```

B·C·D 의 산문 전부가 키가 된다. 반복 행(`key=value` 직렬화)은 데이터라 OCaml 에 남고, 헤더·힌트·
지시문만 템플릿으로 옮긴다. 키 이름은 `Prompt_names` 의 닫힌 목록에만 추가한다 — 파일은 있는데
이름이 없으면 기동 오류, 이름은 있는데 파일이 없어도 기동 오류(RFC-0080 fail-closed 유지).

### 2.2 도구 — `config/tools/<name>.toml`

`bin/gen_tool_descriptors.ml` 의 spec 형식(`p_name/p_type/p_description/p_required`)을 그대로 승격한다.

```toml
name = "masc_board_vote"
title = "Board vote"
description = "Vote a board post up or down."
group = "board"                     # keeper_tool_group wire 이름 (RFC-0389)
permission = "can_vote"
visibility = "model"                # model | hidden | operator
keeper_projection = "board"         # 있으면 keeper 표면용 설명/스키마 테이블

[policy]
readonly = false
idempotent = true
execution = "serial"                # serial | concurrent | terminal

[[params]]
name = "post_id"
type = "string"
required = true
description = "Exact board post ID (p-xxxx) from masc_board_list or masc_board_search."

[[params]]
name = "direction"
type = "string"
enum = ["up", "down"]
required = true
description = "Vote direction."

[help]
when_to_use = "..."
constraints = "..."
```

중첩 스키마(Board `sources[]` 등, 전체의 약 10%)는 `schema = "<name>.schema.json"` 사이드카로 둔다.
부팅 시 한 번 파싱해 기존 닫힌 타입으로 디코드한다 — `Tool_name.of_string`, `runtime_handler_of_string`,
`tool_kind_of_string`(RFC-0386) 의 exhaustive match. 모르는 이름·누락 축은 기동 오류. OCaml 에는
handler 바인딩(`runtime_handler` → 함수)과 `readonly_of_input`·`input_translation` 같은 코드 값만 남는다.
`<config-root>/tool_policy.toml` 은 삭제한다(reader 0).

### 2.3 대시보드 — 화면 하나, 소스 둘

1. **키별**: `/api/v1/prompts` 와 새 `/api/v1/tools` 가 resolved 텍스트 + `source`(default file / override) +
   `file_path` 를 돌려준다. 편집은 override 로, 저장은 지금의 `prompt_overrides.json` 경로.
2. **턴별 "보낸 것"**: `Keeper_prompt_capture` 를 확장해 `Keeper_unified_prompt.build_turn_prompt` 의
   system_prompt / world_state / user_message(이미 `keeper_unified_prompt.ml:1362-1370` 에서 세그먼트별
   바이트를 계측 중)와 도구 목록 digest·bytes 까지 한 턴 단위로 기록한다(RFC-0233 `Prompt_block_id` 에
   `System_prompt`/`World_state`/`Tool_surface` 생성자 추가). 프롬프트 페이지의 keeper 선택 → `/last-prompt`.
3. 삭제: `KeeperPromptAssemblyPanel` 의 `STAGES` 그림과 `(computed:…)` 자리표시자, keeper-config-panel 의
   별도 조립 추적. "Build details" 와 paper 뷰는 (1) 하나로 합친다.

## 3. 마이그레이션 — PR 당 ≤ 8파일, 바이트 큰 순

0. **하네스 먼저**: `scripts/model-prose-ratchet.sh` + `scripts/model-prose-baseline.json` +
   `scripts/model-prose-scan.py` + `ci.yml` 배선(`stringly-boundary-ratchet.sh` 패턴). 기준선 106,315 B / 1,162
   (`b0f56b0e2d`). 파일별 bytes·count 증가 금지, 각 PR 이 `--update` 로 baseline 을 내려 갱신.
1. 로더: `lib/tool_surface/tool_definition_toml.ml(i)` + `embedded_config`(ocaml-crunch) 와 `sync_prompt_assets`
   (#20929) 를 `tools/` 에 일반화 + 테스트.
2. `board_tool_schemas.ml` + `board_keeper_projection.ml` (11.3 KB) → `config/tools/masc_board_*.toml`
   (`[keeper_projection]` 테이블로 8개 중복 해소).
3. `keeper_tool_descriptor.ml` 설명/파라미터 + shard filesystem/search_files/execute (13.6 KB).
4. `tool_task_schemas.ml` + `keeper_schema.ml` (11.3 KB).
5. `bin/gen_tool_descriptors.ml` (4.8 KB) → TOML; codegen 규칙과 `test_tool_descriptors_gen` 삭제 (RFC-0057 폐기).
6. shard taskboard/surface/base/voice/library + `keeper_tool_runtime_schemas` (15.3 KB).
7. `tool_schemas_*` 8개 + `operator_tool` + `agent_core_tool_contract` + `tool_agent_timeline` (12.0 KB).
8. `tool_help_registry` → `[help]`, `mcp_server` 리소스 → `config/mcp/resources.toml`, tool_profile
   instructions/title → `config/mcp/profiles.toml`, `mcp_prompt_surface` (6.6 KB).
9. `keeper_unified_prompt.ml` 섹션 헤더·힌트 + `keeper_prompt.ml` identity/workspace + extra 블록 머리말
   (B 7.5 KB) → `keeper.world.*.md`, `keeper.identity.md`, `keeper.workspace.md`.
10. 서브에이전트 프롬프트 (C 4.1 KB) → `compaction.summarizer.md`, `fusion.{panel,judge,synthesis}.md`,
    `canary.judge.md`, `vision.*.md`.
11. 도구 결과 안내문 (D 3.7 KB): 닫힌 변형 `Tool_guidance.t` → 프롬프트 키 매핑, 본문은 md.
12. 대시보드 (§2.3).

의존: 0 → 1 → 2~8 (독립), 9~11 은 0 뒤 언제든. 12 는 2 와 9 뒤.

## 4. 수용 기준

- "OCaml 안 모델 대면 산문 바이트": (i) 구조 검출 — `description` 필드, JSON `description` 키, `~description:`,
  `*_prop`/`property`/`*_description`; (ii) allowlist 파일의 공백 기준 3토큰 이상 리터럴 전부.
  측정은 `scripts/model-prose-scan.py` 가 `lib/`·`packages/agent_core/lib/`·`bin/` 의 `.ml` 을 토큰화해 리터럴
  바로 앞 토큰으로 (i) 을, `scripts/model-prose-baseline.json` 의 `allowlist_files` 로 (ii) 를 판정하고 디코드된
  바이트 길이를 더한다. 오늘 106,315 B / 1,162 (구조 74,615 B / 698 + allowlist 19개 파일 31,700 B / 464) → **0**,
  allowlist 는 빈 집합.
- 설명이 2곳 이상인 도구 수 27 → 0.
- 소비자 없는 config 파일(`tool_policy.toml`) 0.
- 대시보드 프롬프트 화면 4개 → 1개, "보낸 것" 은 턴 기록에서만.
- 동작 불변: 와이어에 나가는 시스템 프롬프트·도구 배열 바이트가 마이그레이션 전후 같음(RFC-0389 §1.1 의
  wire capture 로 PR 마다 비교).

## 5. 기존 RFC 와의 관계

- RFC-0080 (Implemented) "no second policy TOML" 은 개정한다 — TOML 은 두 번째 정책 층이 아니라 descriptor 의
  선언 원본이고 등록은 여전히 한 번이다.
- RFC-0182 (Tool_spec SSOT, Draft) 는 흡수, RFC-0057 (codegen, Draft) 은 폐기.
- RFC-0386 (tool_kind 닫힌 합타입), RFC-0233 (Prompt_block_id 닫힌 합타입) 은 유지·확장.
- RFC-0389 (Keeper 별 표면) 의 `[keeper.tools]` 선언은 이 RFC 의 `group` 값을 참조한다.

## 6. 하지 않을 것

- 문자열 디스패치. TOML 의 이름은 전부 닫힌 합타입으로 디코드되고, 모르는 값은 기동 오류다.
- 런타임 hot-reload 로 도구 정의 바꾸기. 도구 본문은 부팅 시 한 번 읽는다(프롬프트 override 는 지금처럼
  런타임 편집 가능).
- 입력 검증 오류 문구("must be a string")의 외부화. 모델이 읽긴 하지만 스키마에서 기계적으로 파생되는
  문장이라 산문이 아니다. D 범주와의 경계는 §1.1 의 분류를 따른다.
