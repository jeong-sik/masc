> **상태 갱신 (2026-09-03)**: model-prose ratchet 게이트(`scripts/model-prose-{ratchet.sh,scan.py,baseline.json}`)는 제거됐다.
> allowlist 25파일·2만자가 상주하는 상태에서 게이트가 잡는 것은 신규 유입(+14자 수준)뿐이어서
> 유지 비용이 값보다 컸다. 프롬프트 외부화 원칙(RFC 본문)은 그대로 산다 — 게이트가 아니라
> 리뷰와 managed 파일 규칙(managed-assets.json)이 지킨다.

---
rfc: "prompts-and-tool-definitions-outside-ocaml"
title: "프롬프트와 도구 정의를 OCaml 밖으로 — 모델이 읽는 모든 글은 config 파일이 소유한다"
status: Draft
created: 2026-08-22
updated: 2026-08-27
author: claude
supersedes: ["0057", "0182"]
superseded_by: null
related: ["0080", "0233", "0386"]
---

# RFC: 프롬프트와 도구 정의를 OCaml 밖으로 (prompts-and-tool-definitions-outside-ocaml)

## 0. Summary

모델이 읽는 글(시스템 프롬프트 절, 턴 컨텍스트 머리말, 도구 설명과 파라미터 설명, 심판·요약
프롬프트, 도구 결과 안내문)은 지금 약 77% 가 OCaml 문자열 리터럴에 있다. 운영자는 그 글을
재빌드 없이 바꿀 수 없고, 대시보드는 그 글이 어디서 왔는지 보여줄 수 없다. 이 RFC 는 그 글
전부를 `<config-root>` 의 파일로 옮기고, OCaml 에는 **typed handler 바인딩만** 남기며,
"OCaml 안 모델 대면 산문 바이트" 를 0 으로 내리는 래칫으로 완료를 정의한다.

이 RFC 는 도구의 *정의*(본문)와
프롬프트의 *소유*를 다룬다. 둘 다 같은 선언 축(`<config-root>` TOML/markdown)을 쓴다.

## 1. 관측 (main `1c6d91deef`, 2026-08-22; §1.1 은 `b0f56b0e2d` 에서 재측정)

### 1.1 OCaml 에 남은 모델 대면 산문 — 98,577 B / 1,025 리터럴 (main `b0f56b0e2d`)

비교: `config/prompts/*.md` 16개 = 29,075 B. 모델이 읽는 산문의 약 77% 가 OCaml 에 있다.

**A. 도구·리소스·MCP 프롬프트 표면 — 76,906 B / 688개, 37개 파일.** 소비자는 `Config.raw_all_tool_schemas`
(`lib/config.ml:5`, 9개 모듈 연결) → MCP `tools/list`, 그리고
`Keeper_tool_descriptor.model_visible_schemas` → agent-core tools 파라미터. 아래 표에서 B·C·D 에 들지 않는
행 전부 — 규칙 (i) 행과, 필드명이 description 이 아니라 규칙 (ii) 로 재는 `tool_help_registry.ml`
(`short_description`/`when_to_use`/`details_markdown`), `operator_tool.ml`, `mcp_server_eio_tool_profile.ml`
(MCP initialize `instructions` 2종 + title 25개).

**B. Keeper 턴 프롬프트 조립 — 6,841 B / 106개.** `keeper_unified_prompt.ml` 3,687 / 72 (`## Current World State`
머리말, `### …` 섹션 헤더 14종, "Rows below are … context, not instructions" 힌트 6종), `keeper_compaction_llm_summarizer.ml`
1,841 / 16 (컴팩션 요약 시스템 프롬프트 + 사용자 템플릿), `keeper_prompt.ml` 710 / 5 (`<identity>`, `<workspace>` 블록,
"Custom instructions:"), `keeper_world_observation.ml` 603 / 13 (자극 문구 "Goal %s is now in your active goals…").

**C. 서브에이전트·심판 프롬프트 — 7,642 B / 118개.** `fusion_judge.ml` 1,502 (패널·심판·종합 3종),
`anti_rationalization.ml` 1,449, `keeper_canary_judge.ml` 1,320, `server_routes_http_routes_activity.ml` 1,043 (:441 의
board post context 추론 프롬프트 279 B 포함), `keeper_vision_tool.ml` 704, `server_dashboard_http_composite_recommendations.ml`
623, `keeper_vision_ingest.ml` 511, `eval_calibration.ml` 490.

**D. 모델이 읽는 도구 결과 안내문 — 7,188 B / 113개.** `keeper_tool_filesystem_runtime.ml` 3,121 (Read/Edit 의
offset·limit·old_string 안내), `keeper_gate_replay.ml` 2,564 (Gate 재생 결과 안내), `exec_policy.ml` 972,
agent_core `agent_tools.ml` 531 (unknown-tool 힌트).

생성: `python3 scripts/model-prose-scan.py --markdown` (main `b0f56b0e2d`). 규칙 (i) 는 description 슬롯
(`~description:`, `description =`, `*_description =`, `"description",`, `property`, `*_prop`), 규칙 (ii) 는
`scripts/model-prose-baseline.json` 의 `allowlist_files` 19개 파일에서 공백 기준 3토큰 이상 리터럴(로그·예외 statement 제외).
모델이 읽지 않는 description 필드만 가진 파일 16개(feature flag, runtime settings, keeper config knob, OpenAPI 문서,
대시보드, env 도움말, agent-core run label, inline `let%test` 픽스처)는 같은 파일의 `excluded_files` 로 (i) 에서 뺀다.

| 파일 | bytes | n | (i) bytes / n | (ii) bytes / n |
|---|---:|---:|---:|---:|
| `lib/board_tool_adapter/board_tool_schemas.ml` | 7,111 | 86 | 7,111 / 86 | 0 / 0 |
| `lib/keeper/keeper_tool_descriptor.ml` | 6,661 | 47 | 6,661 / 47 | 0 / 0 |
| `lib/task/tool_task_schemas.ml` | 5,829 | 40 | 5,829 / 40 | 0 / 0 |
| `lib/keeper/keeper_schema.ml` | 5,367 | 55 | 5,367 / 55 | 0 / 0 |
| `lib/tool_surface/tool_shard_types_board_keeper_projection.ml` | 4,367 | 40 | 4,367 / 40 | 0 / 0 |
| `bin/gen_tool_descriptors.ml` | 4,130 | 41 | 4,130 / 41 | 0 / 0 |
| `lib/keeper/keeper_tool_runtime_schemas.ml` | 4,081 | 14 | 4,081 / 14 | 0 / 0 |
| `lib/keeper/keeper_unified_prompt.ml` | 3,687 | 72 | 0 / 0 | 3,687 / 72 |
| `lib/tool_surface/tool_shard_types_schemas_taskboard.ml` | 3,634 | 24 | 3,634 / 24 | 0 / 0 |
| `lib/tool_surface/tool_shard_types_schemas_execute.ml` | 3,504 | 13 | 3,504 / 13 | 0 / 0 |
| `lib/tool_surface/tool_shard_types_schemas_surface.ml` | 3,328 | 20 | 3,328 / 20 | 0 / 0 |
| `lib/keeper/keeper_tool_filesystem_runtime.ml` | 3,121 | 48 | 0 / 0 | 3,121 / 48 |
| `lib/tool_surface/tool_help_registry.ml` | 3,052 | 43 | 277 / 5 | 2,775 / 38 |
| `lib/tool_schemas/tool_schemas_schedule.ml` | 2,872 | 30 | 2,872 / 30 | 0 / 0 |
| `lib/keeper/keeper_gate_replay.ml` | 2,564 | 48 | 0 / 0 | 2,564 / 48 |
| `lib/tool_surface/tool_shard_types_schemas_filesystem.ml` | 2,338 | 26 | 2,338 / 26 | 0 / 0 |
| `lib/mcp_server_eio_tool_profile.ml` | 2,201 | 24 | 0 / 0 | 2,201 / 24 |
| `lib/tool_surface/tool_shard_types_schemas_base.ml` | 2,125 | 10 | 2,125 / 10 | 0 / 0 |
| `lib/keeper/keeper_compaction_llm_summarizer.ml` | 1,841 | 16 | 0 / 0 | 1,841 / 16 |
| `lib/operator/operator_tool.ml` | 1,782 | 14 | 763 / 5 | 1,019 / 9 |
| `lib/tool_surface/tool_shard_types_schemas_voice.ml` | 1,642 | 14 | 1,642 / 14 | 0 / 0 |
| `lib/tool_schemas/tool_schemas_misc.ml` | 1,603 | 11 | 1,603 / 11 | 0 / 0 |
| `lib/board_tool_adapter/board_tool_registry.ml` | 1,561 | 21 | 1,561 / 21 | 0 / 0 |
| `lib/fusion/fusion_judge.ml` | 1,502 | 7 | 0 / 0 | 1,502 / 7 |
| `lib/task/anti_rationalization.ml` | 1,449 | 25 | 219 / 3 | 1,230 / 22 |
| `lib/tool_schemas/tool_schemas_local_runtime.ml` | 1,342 | 6 | 1,342 / 6 | 0 / 0 |
| `lib/keeper_canary/keeper_canary_judge.ml` | 1,320 | 20 | 0 / 0 | 1,320 / 20 |
| `lib/mcp_server.ml` | 1,174 | 23 | 1,174 / 23 | 0 / 0 |
| `lib/tool_schemas/tool_schemas_run.ml` | 1,131 | 9 | 1,131 / 9 | 0 / 0 |
| `lib/tool_schemas/tool_schemas_library.ml` | 1,075 | 10 | 1,075 / 10 | 0 / 0 |
| `lib/server/server_routes_http_routes_activity.ml` | 1,043 | 22 | 0 / 0 | 1,043 / 22 |
| `lib/exec_policy/exec_policy.ml` | 972 | 8 | 0 / 0 | 972 / 8 |
| `lib/tool_schemas/tool_schemas_workspace_extra.ml` | 866 | 6 | 866 / 6 | 0 / 0 |
| `lib/tool_surface/tool_shard_types_schemas_search_files.ml` | 811 | 6 | 811 / 6 | 0 / 0 |
| `lib/tool_schemas/tool_schemas_workspace_core.ml` | 780 | 5 | 780 / 5 | 0 / 0 |
| `lib/keeper/keeper_prompt.ml` | 710 | 5 | 0 / 0 | 710 / 5 |
| `lib/keeper/keeper_vision_tool.ml` | 704 | 14 | 0 / 0 | 704 / 14 |
| `lib/agent_core_tool_contract.ml` | 655 | 11 | 655 / 11 | 0 / 0 |
| `lib/server/server_dashboard_http_composite_recommendations.ml` | 623 | 11 | 0 / 0 | 623 / 11 |
| `lib/keeper/keeper_world_observation.ml` | 603 | 13 | 0 / 0 | 603 / 13 |
| `packages/agent_core/lib/agent/agent_tools.ml` | 531 | 9 | 0 / 0 | 531 / 9 |
| `lib/keeper/keeper_vision_ingest.ml` | 511 | 11 | 0 / 0 | 511 / 11 |
| `lib/tool_schemas/tool_schemas_agent.ml` | 511 | 9 | 511 / 9 | 0 / 0 |
| `lib/tool_surface/tool_shard_types_schemas_library.ml` | 507 | 4 | 507 / 4 | 0 / 0 |
| `lib/eval_calibration.ml` | 490 | 8 | 0 / 0 | 490 / 8 |
| `lib/tool_agent_timeline.ml` | 345 | 7 | 345 / 7 | 0 / 0 |
| `lib/keeper/keeper_tool_composition_surface.ml` | 177 | 2 | 177 / 2 | 0 / 0 |
| `lib/mcp_prompt_surface.ml` | 108 | 3 | 108 / 3 | 0 / 0 |
| `lib/verification_authority_tools.ml` | 61 | 1 | 61 / 1 | 0 / 0 |
| `packages/agent_core/lib/handoff.ml` | 56 | 3 | 56 / 3 | 0 / 0 |
| `packages/agent_core/lib/agent_tool.ml` | 45 | 8 | 45 / 8 | 0 / 0 |
| `lib/server/server_routes_http_runtime.ml` | 37 | 1 | 37 / 1 | 0 / 0 |
| `lib/tool_agent.ml` | 37 | 1 | 37 / 1 | 0 / 0 |
| **합계 (53개 파일)** | **98,577** | **1,025** | | |

### 1.2 도구 정의 — 한 도구의 속성이 최대 7개 파일에 흩어져 있다

| 속성 | 사는 곳 |
|---|---|
| name | `Tool_name` 변형 + 27개 스키마 파일의 문자열 + descriptor `~internal_name/~public_name` + `tool_catalog_surfaces.ml` 83개 + `mcp_server_eio_tool_profile.ml` title 25개 + `transport.ml` HTTP 경로 10개 |
| description / input_schema | 정의 지점 138곳, 도구 113개. **27개 도구는 설명이 두 곳에 따로** — Board 8개(`board_tool_schemas` ↔ `board_keeper_projection`), keeper_* 10개 + read/edit/write/search_files/execute 5개(`tool_shard_types_*` ↔ `keeper_tool_descriptor`), `masc_heartbeat`·`masc_add_task`·`masc_batch_add_tasks`·`masc_broadcast`(↔ `agent_core_tool_contract`) |
| execution policy | 3곳: `Tool_catalog.explicit_metadata` 132행, descriptor `policy` + `execution`, `Board_tool_registry.operation_policy` |
| permission | `Tool_catalog.explicit_metadata` 만 |
| visibility | `Tool_catalog.visibility` + descriptor `keeper_model_projection` 4종 + `Tool_catalog_surfaces` + `Mcp_server_eio_tool_profile` 프로파일 3종 |
| 이미 파일 선언인 것 | `runtime.toml [[skills.sources]]` 아래 `SKILL.md` composition fence (`Keeper_tool_composition_catalog`) — 독립 `tool-compositions.toml` 경로는 삭제됨 |

### 1.3 프롬프트 조립과 대시보드

- `Prompt_registry` 키 17개(라이브 `/api/v1/prompts`, 전부 `source=file`, override 0). Keeper 턴 경로에서
  실제로 resolve 되는 키는 5개(`keeper`, `keeper.observation.*` 4종). 나머지 12개는 심판·검증·librarian 호출자.
- 턴의 시스템 프롬프트 중 `keeper.md` 는 710 B 이고 나머지(identity/workspace/instructions/goals)는 OCaml 이
  조립한다 (와이어 실측 중앙값 1,572 B).
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

로더는 `lib/tool_surface/tool_definition_toml.ml`. 파일 하나가 도구 하나를 선언하고, 파일 이름(확장자
제외)과 `name` 키가 다르면 기동 오류다.

```toml
name = "masc_board_vote"
title = "Board vote"
description = "Vote a board post up or down."
permission = "can_vote"
visibility = "model"                # model | hidden | operator
additional_properties = false       # 있으면 JSON additionalProperties 로

[policy]
readonly = false
idempotent = true
execution = "serial"                # serial | concurrent | terminal

[[params]]
name = "post_id"
type = "string"                     # string|integer|number|boolean|object|array
required = true
pattern = "^p-[0-9a-f]+$"           # string 전용. max_length 도 (→ maxLength)
description = "Exact board post ID (p-xxxx) from masc_board_list or masc_board_search."

[[params]]
name = "direction"
type = "string"
enum = ["up", "down"]
required = true
description = "Vote direction."

[[params]]
name = "limit"
type = "integer"
default = 20                        # 선언한 type 과 같은 스칼라만 (integer/boolean)
minimum = 1                         # integer 전용. maximum 도
maximum = 100
description = "Max results."

# keeper 표면이 따로 좁힌 설명/스키마를 갖는 도구는 같은 파일의 테이블로.
[keeper_projection]
description = "Vote on one existing board post by exact post_id."
additional_properties = false
# [[keeper_projection.params]] — 형식은 [[params]] 와 동일

[help]
when_to_use = "..."
constraints = "..."
```

중첩 스키마(Board `sources[]` 등)는 사이드카 없이 같은 파일에서 표현한다: array param 의
`items = { type = "string" }` 인라인 테이블, 또는 `[params.items]` 테이블에 `type = "object"` 와
`[[params.items.params]]`(name/type/description) 를 둔다.

디코드 규칙:

- **모르는 키/값 = 기동 오류.** 로더는 소비자가 있는 키만 받는다. 위 예시 중 `title`/`group`/
  `permission`/`visibility`/`[policy]`/`[help]` 는 그 키를 읽는 마이그레이션 단계(§3 항목 3+)가
  로더 디코드를 같이 열기 전까지는 거부된다 — 조용히 무시되는 키는 소비자 없는 config 이기 때문.
- 발행 JSON 은 TOML 의 키 순서를 그대로 보존한다(`name`/`required` 메타 키 제외 — 이 둘은
  `properties`/`required` 집계로 들어간다). 마이그레이션 PR 은 이 성질로 이주 전 리터럴과
  바이트 동일함을 증명한다.
- 부팅 시 한 번 파싱하고(`Server_runtime_bootstrap.validate_embedded_tool_definitions`),
  이름은 기존 닫힌 타입으로 디코드한다 — `Tool_name.of_string`, `runtime_handler_of_string`,
  `tool_kind_of_string`(RFC-0386) 의 exhaustive match. OCaml 에는 handler 바인딩
  (`runtime_handler` → 함수)과 `readonly_of_input`·`input_translation` 같은 코드 값만 남는다.
- 코드가 SSOT 인 값(variant 파생 enum 목록, `Board.Limits` 류 한계값, id pattern)은 TOML 에
  리터럴로 적고, 발행된 스키마를 owner 와 대조하는 기존 동기화 테스트(`test_enum_mirror_sync`
  패턴)가 drift 를 잡는다. Printf 로 값을 끼워 넣던 description 은 리터럴 문장이 된다.
- `<config-root>/tool_policy.toml` 은 삭제한다(reader 0).

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
   `scripts/model-prose-scan.py` + `ci.yml` 배선(`stringly-boundary-ratchet.sh` 패턴). 기준선 98,577 B / 1,025
   (`b0f56b0e2d`). 파일별 bytes·count 증가 금지, 각 PR 이 `--update` 로 baseline 을 내려 갱신.
1. 로더: `lib/tool_surface/tool_definition_toml.ml(i)` + `embedded_config`(ocaml-crunch) 와 `sync_prompt_assets`
   (#20929) 를 `tools/` 에 일반화 + 테스트.
2. `board_tool_schemas.ml` + `board_keeper_projection.ml` (11.5 KB) → `config/tools/masc_board_*.toml`
   (`[keeper_projection]` 테이블로 8개 중복 해소).
3. `keeper_tool_descriptor.ml` 설명/파라미터 + shard filesystem/search_files/execute (13.3 KB).
4. `tool_task_schemas.ml` + `keeper_schema.ml` (11.2 KB).
5. `bin/gen_tool_descriptors.ml` (4.1 KB) → TOML; codegen 규칙과 `test_tool_descriptors_gen` 삭제 (RFC-0057 폐기).
6. shard taskboard/surface/base/voice/library + `keeper_tool_runtime_schemas` (15.3 KB).
7. `tool_schemas_*` 8개 + `operator_tool` + `agent_core_tool_contract` + `tool_agent_timeline` (13.0 KB).
8. `tool_help_registry` → `[help]`, `mcp_server` 리소스 → `config/mcp/resources.toml`, tool_profile
   instructions/title → `config/mcp/profiles.toml`, `mcp_prompt_surface` (6.5 KB).
9. `keeper_unified_prompt.ml` 섹션 헤더·힌트 + `keeper_prompt.ml` identity/workspace + extra 블록 머리말
   (B 6.8 KB) → `keeper.world.*.md`, `keeper.md` 의 `identity`·`workspace` 슬롯.
10. 서브에이전트 프롬프트 (C 7.6 KB) → `compaction.summarizer.md`, `fusion.{panel,judge,synthesis}.md`,
    `canary.judge.md`, `vision.*.md`.
11. 도구 결과 안내문 (D 7.2 KB): 닫힌 변형 `Tool_guidance.t` → 프롬프트 키 매핑, 본문은 md.
12. 대시보드 (§2.3).

의존: 0 → 1 → 2~8 (독립), 9~11 은 0 뒤 언제든. 12 는 2 와 9 뒤.

## 4. 수용 기준

- "OCaml 안 모델 대면 산문 바이트": (i) 구조 검출 — `description` 필드, JSON `description` 키, `~description:`,
  `*_prop`/`property`/`*_description`; (ii) allowlist 모듈의 3토큰 이상 리터럴(로그/예외 컨텍스트 제외).
  측정은 `scripts/model-prose-scan.py` 가 `lib/`·`packages/agent_core/lib/`·`bin/` 의 `.ml` 을 토큰화해 리터럴
  바로 앞 토큰으로 (i) 을, `scripts/model-prose-baseline.json` 의 `allowlist_files` 와 리터럴이 속한 statement 의
  `Log.`/`raise`/`failwith` 유무로 (ii) 를 판정하고, 모델이 읽지 않는 description 필드만 가진 파일은 같은 파일의
  `excluded_files` 로 (i) 에서 뺀 뒤 디코드된 바이트 길이를 더한다. 오늘 98,577 B / 1,025 (구조 71,130 B / 620 +
  allowlist 19개 파일 27,447 B / 405) → **0**, allowlist 는 빈 집합.
- 설명이 2곳 이상인 도구 수 27 → 0.
- 소비자 없는 config 파일(`tool_policy.toml`) 0.
- 대시보드 프롬프트 화면 4개 → 1개, "보낸 것" 은 턴 기록에서만.
- 동작 불변: 와이어에 나가는 시스템 프롬프트·도구 배열이 마이그레이션 전후 같음(
  wire capture 로 PR 마다 비교). 도구 스키마는 **JSON 객체 키 순서를 제외하고** 같음 — 설명, 타입,
  `required`, `default`, `enum`, `pattern`, 중첩 구조는 전부 고정한다.

  키 순서를 뺀 이유. JSON 객체는 순서 없는 멤버 집합이고(RFC 8259 §4) 이 스키마를 읽는 어떤 소비자도
  순서로 동작이 달라지지 않는다. 순서가 닿는 곳은 프롬프트 캐시 하나다 — 도구 정의는 시스템 프롬프트
  계층이고 매칭이 정확 일치라, 키가 움직이면 배포 후 첫 턴이 캐시 미스가 된다. 그 값은 **일회성**이며,
  Claude Code 가 자기 도구 정의를 바꾸는 업그레이드마다 치르는 것과 같은 종류다.

  반대로 순서를 고정하면 마이그레이션이 막힌다. TOML 은 서브테이블(`[params.items]`,
  `[[params.params]]`)을 부모의 스칼라 키 뒤에만 둘 수 있어서, 원본이 `items` 를 `description` 앞에
  쓴 경우를 표현할 방법이 없다. 그리고 그 위치는 설계가 아니라 손으로 쓴 흔적이다 —
  `masc_add_task.contract`(맨 뒤), `masc_batch_add_tasks.tasks`(`maxItems` 다음),
  `masc_transition.handoff_context`(`description` 다음)가 셋 다 다르다. 바이트를 지키는 것은 그 세
  임의 순서를 영구 보존하고 세 도구를 OCaml 에 남기는 것과 같다.

## 5. 기존 RFC 와의 관계

- RFC-0080 (Implemented) "no second policy TOML" 은 개정한다 — TOML 은 두 번째 정책 층이 아니라 descriptor 의
  선언 원본이고 등록은 여전히 한 번이다.
- RFC-0182 (Tool_spec SSOT, Draft) 는 흡수, RFC-0057 (codegen, Draft) 은 폐기.
- RFC-0386 (tool_kind 닫힌 합타입), RFC-0233 (Prompt_block_id 닫힌 합타입) 은 유지·확장.

## 6. 하지 않을 것

- 문자열 디스패치. TOML 의 이름은 전부 닫힌 합타입으로 디코드되고, 모르는 값은 기동 오류다.
- 런타임 hot-reload 로 도구 정의 바꾸기. 도구 본문은 부팅 시 한 번 읽는다(프롬프트 override 는 지금처럼
  런타임 편집 가능).
- 입력 검증 오류 문구("must be a string")의 외부화. 모델이 읽긴 하지만 스키마에서 기계적으로 파생되는
  문장이라 산문이 아니다. D 범주와의 경계는 §1.1 의 분류를 따른다.
