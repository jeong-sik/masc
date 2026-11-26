---
rfc: "runtime-models-come-from-the-catalog"
title: "runtime.toml 의 모델은 카탈로그에서 오고, 계정은 바꾼 값만 적는다"
status: Draft
created: 2026-11-26
updated: 2026-11-26
author: claude
related: []
---

# RFC runtime-models-come-from-the-catalog: runtime.toml 의 모델은 카탈로그에서 오고, 계정은 바꾼 값만 적는다

- 상태: **초안.** 방향은 운영자가 정했다(2026-11-26, #52048 정리 중). 「모델 표 없애기」를 골랐고, 변형은 「쓰는 쪽에 둔다」를 골랐다. §6 의 열린 질문이 정해지면 승인으로 바꾼다.
- 계기: #52048. seed(`config/runtime.toml`)에 새 모델을 넣어도 이미 `runtime.toml` 이 있는 workspace 에는 생기지 않는다.
- 코드 좌표는 `origin/main` `3a92ce02eae7c` 에서 읽었다.
- 운영 workspace 숫자는 그 workspace 의 `runtime.toml` 을 2026-11-26 에 읽어 셌다. 계정 이름은 이 문서에서 `claude_a`·`claude_b` 처럼 가린다.

## 0. 요약

- `runtime.toml` 의 `[models.<id>]` 표는 카탈로그(`packages/agent_core/models.toml`)가 이미 아는 사실을 다시 적는다.
- 운영자는 계정을 더할 때마다 그 표를 한 벌 더 복사한다. 그래서 seed 와 workspace 의 id 가 서로 달라졌고, seed 에 새 모델을 넣어도 workspace 로 갈 길이 없다.
- 이 RFC 는 다섯 가지를 정한다.
  1. `[models.<id>]` 표를 없앤다(D1).
  2. 카탈로그가 아는 계정은 카탈로그 행을 그대로 런타임으로 내놓는다. 계정 묶음 `[<계정>.<모델>]` 은 바꾼 값이 있을 때만 쓴다(D2).
  3. 카탈로그가 모르는 모델은 계정 묶음 안에 적는다(D3).
  4. effort·temperature·cache 같은 변형은 쓰는 쪽(레인 후보)에 둔다(D4).
  5. 옛 모양을 읽는 코드는 만들지 않는다. 운영 파일은 새로 쓴다(D5).
- 새 바이너리에 카탈로그 행이 생기면 그 행은 모든 workspace 의 해당 계정에 바로 생긴다. seed 동기화나 비교 화면은 필요 없다.

## 1. 지금 모습

### 1.1 증상(#52048)

- seed 는 `runtime.toml` 이 없을 때만 쓰인다(`lib/server/server_runtime_config_root_bootstrap.ml:212`·`:233`, 부팅 점검 출력은 `bin/deployment_preflight_helper.ml:1248` `boot_writes_seed=yes`).
- 이미 파일이 있으면 운영자 파일로 보고 건드리지 않는다. 이 판단은 맞다.
- 그래서 11-14 에 seed 에 넣은 Fable 5.2·Gemini 4 Carbon 이 기존 workspace 에 생기지 않았다. 운영자가 표를 손으로 붙였다.
- 그 뒤 생긴 길이 하나 있다. 서버 config patch 가 없는 표를 새로 만들고(`lib/toml_line_editor/toml_line_editor.ml:647` `append_table`), `models.*` 와 계정 표는 재시작 없이 반영한다(`lib/server/server_dashboard_http_candle_config.ml:1326`). 그래도 표의 내용은 운영자가 직접 짜야 한다.

### 1.2 모델 표는 카탈로그를 다시 적는다

- 카탈로그는 모델 행 270개를 가진다. 창 크기(`max_context_tokens` 250행), 도구 지원(`supports_tools` 172행), 스트리밍, effort 사다리(`accepted_reasoning_efforts` 99행), 사고 제어 형식, 가격을 적는다.
- `docs/RUNTIME-TOML-REFERENCE.md` §1 은 이미 「창 크기·출력 상한·effort 사다리·가격·사고 제어 정책은 카탈로그가 답한다」고 나눠 둔다.
- 카탈로그 행이 있는 Agent Core 모델이면, 요청 능력값의 도구 지원·스트리밍은 카탈로그가 답한다(`lib/runtime/runtime_adapter.ml:541`~`583`). 그 경우 표에서 능력값으로 읽는 것은 사고 제어 형식·출력 상한·effort 목록·이미지 입력 같은 몇 가지 덮어쓰기뿐이다.
- 모델 표의 `tools-support` 를 읽는 곳은 따로 있다. 공식 client 의 도구 판단(`lib/runtime/runtime_tool_support.ml`)과 사람 연동 검증(`lib/server/server_person_integrations.ml:47`)이다.
- Agent Core 런타임은 카탈로그 행도 `[models.<id>.capabilities]` 블록도 없으면 꺼진다(`lib/runtime/runtime.ml:315` `missing_runtime_model_capabilities`, `:461` `active_runtimes`).
- 운영 workspace 의 `runtime.toml` 은 4,145줄이다. 비어 있지 않고 주석이 아닌 3,133줄 가운데 1,941줄(62%)이 `[models.*]` 표다.
- 모델 표 239개가 가리키는 실제 모델 이름(`api-name`)은 106가지다.

### 1.3 계정마다 또 복사한다

- 계정 묶음은 이미 `<provider>.<model>` 로 이어진다(`lib/runtime/runtime_toml.ml:573`). 같은 모델 id 를 여러 계정에 묶을 수 있다. 복사는 스키마가 요구한 것이 아니다.
- 그런데 운영 workspace 에서 둘 이상의 계정이 같이 묶은 모델 id 는 4개뿐이다(계정 묶음 204개).
- 대신 모델 표 60개가 내용이 똑같은 14가지 표를 나눠 가진다. 46개는 다른 표와 글자까지 같고 id 의 계정 꼬리표만 다르다. `claude-sonnet-5-5` 하나가 10벌이다.
- 복사가 생기는 이유는 두 가지다.
  - 계정을 더하는 화면이 그 파일에 이미 있는 표를 복사한다(#52048 본문).
  - `cache-retention` 은 계정 묶음 키다(`lib/runtime/runtime_toml_bindings.ml:192`). 같은 계정·같은 모델에 5분 캐시와 1시간 캐시를 함께 두려면 모델 id 를 하나 더 만들어야 한다. 운영 workspace 에서 `cache-retention` 을 쓴 계정 묶음은 20개다.
- 같은 이유로 effort 도 모델 id 로 갈라진다. 모델 표의 `efforts` 목록은 `<id>-low`·`<id>-medium` 같은 id 를 펼쳐 만든다(`lib/runtime/runtime_toml_models.ml:788`).

### 1.4 seed 와 비교하는 길은 이미 막혔다

- seed 의 모델 표는 129개다. id 로 비교하면 seed 에만 있는 id 가 66개, workspace 에만 있는 id 가 176개다.
- 두 파일이 같은 모델을 다른 이름으로 부른다. 「seed 에는 있고 workspace 에는 없는 모델」을 id 로 찾을 수 없다.

## 2. 결정

### D1. `[models.<id>]` 표를 없앤다

- `runtime.toml` 은 「어디로, 무슨 자격으로 보내는가」(계정)와 「운영자가 바꾼 값」만 적는다.
- 모델이 무엇인지는 카탈로그가 답한다. 카탈로그가 모르는 모델만 D3 으로 적는다.
- `[models]` 표가 남은 파일은 읽기를 거절한다. 옛 모양을 조용히 건너뛰지 않는다.

### D2. 카탈로그가 아는 계정은 카탈로그 행을 그대로 내놓는다

- 카탈로그가 아는 계정은 그 계정이 받는 카탈로그 행마다 런타임 `<계정>.<카탈로그 model_id>` 를 갖는다. 표를 쓰지 않아도 생긴다.
  - 「카탈로그가 아는 계정」은 지금 정의 그대로다. 계정 id 가 카탈로그 `[[providers]]` id 와 같거나 `catalog-provider` 를 적은 계정이다(`docs/RUNTIME-TOML-REFERENCE.md` §1).
- 계정 묶음 `[<계정>.<모델>]` 은 그 계정에서 정말 다른 값이 있을 때만 쓴다. 남는 키는 지금 계정 묶음 키와 같다. `max-concurrent`, 계정의 `max-context` 상한, `max-tokens`, 가격 덮어쓰기, Ollama 값들이다.
- 운영 예:

  ```toml
  [providers.claude_a]
  catalog-provider = "claude"
  # 모델 목록은 바이너리 카탈로그에서 온다

  [claude_a.claude-sonnet-5-5]
  max-context = 400000   # 바꾼 값만
  max-concurrent = 4
  ```

- 카탈로그 `model_id` 270개 가운데 73개는 런타임 id 글자(`[A-Za-z0-9._-]+`, `lib/runtime/runtime_toml_base.ml:217`)에 맞지 않는다. `/`·`:` 가 들어 있다(예: `gpt-oss:120b`). 이 행의 런타임 id 를 어떻게 만들지는 §6 질문 1 이다.

### D3. 카탈로그가 모르는 모델은 계정 묶음 안에 적는다

- 운영자 자신의 endpoint(llama-server, 마법사가 만든 계정, OpenRouter 의 카탈로그 밖 모델)는 카탈로그가 답하지 못한다. 지금은 `[models.<id>]` 와 그 `.capabilities` 블록이 답한다(`lib/runtime/runtime_adapter.ml:608` `No_catalog_answer`).
- 이 선언을 계정 묶음으로 옮긴다. `api-name`, `max-context`, `tools-support`, `[<계정>.<모델>.capabilities]` 를 그 자리에 적는다.
- 카탈로그가 답하는 모델의 계정 묶음에 같은 선언을 적으면 읽기를 거절한다. 지금 `kind` 를 카탈로그 계정에 적으면 거절하는 것과 같은 규칙이다(`docs/RUNTIME-TOML-REFERENCE.md` §1).
- 규모: 운영 workspace 모델 표 239개 중 8개가 카탈로그 밖으로 보인다. seed 는 129개 중 12개다.
  - 이 숫자는 어림이다. 카탈로그 `model_id` 가 `api-name` 마지막 조각의 앞부분과 맞는지로 셌다. 실제 매칭은 계정을 함께 보는 가장 긴 `id_prefix` 다.

### D4. 변형은 쓰는 쪽에 둔다

- effort, temperature, cache 유지 시간, 쓸 창 크기는 모델의 사실이 아니다. 요청을 보내는 방식이다.
- `[runtime.lanes.<name>].candidates` 는 문자열 대신 표를 받는다. 값이 없는 후보도 같은 표 모양으로 쓴다.

  ```toml
  [runtime.lanes.sonnet-medium-then-glm-1h]
  candidates = [
    { runtime = "claude_a.claude-sonnet-5-5",
      effort = "medium", max-context = 400000,
      cache-retention = "1h" },
    { runtime = "glm-coding.glm-5.3-flash" },
  ]
  ```

- 후보로 옮기는 값은 지금 모델 표와 계정 묶음에 흩어진 요청 값이다. `temperature`·`top-p`·`top-k`·`min-p`, `reasoning-effort`, `turn-timeout-s`, 압축 값(`context-rollover-threshold`·`tail-window-atoms`·`compaction-keep-ratio`), `cache-retention`, 쓸 `max-context` 다.
- 후보의 `max-context` 는 계정 상한과 카탈로그 창을 넘지 못한다. 지금 `Binding_override_clamped_by_capability` 와 같은 순서로 깎는다(`lib/runtime/runtime_instance.ml`).
- 후보의 `effort` 는 카탈로그 `accepted_reasoning_efforts` 에 없으면 읽기를 거절한다.
- 모델 표의 `efforts` 펼치기(`<id>-low` 등)는 없어진다. 같은 모델을 effort 별로 쓰려면 후보를 여럿 둔다.
- `[runtime.assignments]` 는 지금처럼 런타임 id 나 레인 이름을 가리킨다. 값이 필요한 배정은 후보 하나짜리 레인을 가리킨다.

### D5. hard cut 이다

- 옛 `[models]` 모양을 읽는 reader·converter·migration 은 만들지 않는다(헌법 `legacy_residue`).
- 운영 `runtime.toml` 은 새로 쓴다. 운영 workspace 에서는 배정 28건과 레인 9개(후보 57개)가 옛 id 를 부른다. 같이 바꾼다.
- 런타임 id 를 부르는 곳은 이 밖에도 있다. exact-output 레인 6개의 `slots`·`cli_slots` 22개, `media_failover` 3개, `default` 1개다(`[runtime]` 아래, 11-26 운영 파일 기준). 같이 바꾼다.
- 장부·턴 기록에 남은 옛 런타임 id 는 과거 사실이다. 바꾸지 않는다.
- 이 변경의 changelog 는 `Fresh state required` 로 적는다.

## 3. 고르지 않은 길

### 3.1 seed 와 workspace 를 비교해 빠진 모델을 보여 준다(#52048 본문 후보)

- §1.4 대로 두 파일은 같은 모델을 다른 id 로 부른다. id 비교는 답을 못 낸다.
- `api-name` 으로 비교해도 복사본 문제는 남는다. 새 모델을 더할 때마다 운영자가 계정 수만큼 표를 또 만든다.

### 3.2 계정 안에 이름 붙인 preset 을 둔다

- `[claude_a.presets.sonnet-medium-1h] model = "claude-sonnet-5-5"` 처럼 변형마다 이름을 붙인다. 레인은 지금처럼 문자열 id 를 쓴다.
- 레인 모양이 그대로라는 장점이 있다.
- 그러나 「모델 × 값」 조합마다 이름이 다시 생긴다. 지금 복사본이 preset 으로 옮겨 갈 뿐이다. 운영자가 고르지 않았다.

### 3.3 운영자 카탈로그를 덧붙인다

- 카탈로그 밖 모델을 위해 운영자 카탈로그 파일을 따로 둔다.
- 지금 `AGENT_CORE_MODEL_CATALOG` 는 카탈로그 전체를 바꾸는 길이다(`lib/runtime/runtime.mli:49`). 덧붙이는 길이 없다.
- 카탈로그 밖 모델은 대개 한 계정에만 묶인다. 계정 묶음 안에 적는 D3 이 파일 하나를 덜 만든다.

## 4. 장점과 단점

장점:

- 새 바이너리의 카탈로그 행이 모든 workspace 에 바로 생긴다. #52048 의 증상이 사라진다.
- 운영 파일의 62% 를 차지하는 `[models.*]` 표가 없어진다. 남는 것은 계정마다 다른 값과 카탈로그 밖 모델 8개쯤의 선언이다.
- 같은 내용의 복사본 46개가 없어진다. 변형 때문에 모델 id 를 새로 만들 일이 없다.
- `lib/runtime/runtime_toml_models.ml`(843줄)과 `lib/runtime/runtime_config_models.ml`(157줄)이 읽던 표가 없어진다. 대신 레인 후보를 표로 읽는 코드가 생긴다.

단점:

- 운영 파일을 새로 써야 한다. 배정 28건과 레인 후보 57개의 id 가 바뀐다.
- 카탈로그가 아는 계정은 그 계정이 실제로 못 쓰는 모델도 목록에 내놓는다. 그런 모델을 고르면 provider 가 거절한다. 지금 계정 권한 밖 모델을 고를 때와 같은 거절 경로다.
- 카탈로그 행이 틀리면 운영자는 계정 묶음 덮어쓰기로만 고칠 수 있다. 어디까지 덮어쓸 수 있는지는 §6 질문 3 이다.
- 값을 보려면 계정 묶음과 레인 후보 두 곳을 본다. 지금도 모델 표와 계정 묶음 두 곳을 보므로 볼 곳의 수는 같다.

## 5. 층

- 각 층은 같은 native stack 에 쌓는다. 맨 아래 층만 `main` 을 base 로 삼는다.
- 모델 표에 기대는 파일은 18개다. `rg -l "Runtime_schema\.model_spec|model_of_id|key Models" lib bin --type ocaml` 로 셌다.
  - `lib/runtime/`: `runtime_adapter.ml`·`.mli`, `runtime_config_models.ml`, `runtime_instance.ml`, `runtime_schema.ml`·`.mli`, `runtime_setup_spec.ml`, `runtime_thinking_seed.ml`·`.mli`, `runtime_toml.ml`, `runtime_toml_models.ml`·`.mli`, `runtime_verification.ml`·`.mli`, `runtime_wizard_inventory.ml`
  - `lib/server/`: `server_dashboard_http_candle_config.ml`, `server_person_integrations.ml`, `server_runtime_setup_actions.ml`
  - 이 검색에 안 걸리지만 `models.` 을 직접 읽는 곳: `lib/masc_tui/store/config_store.ml:609`(설정 화면의 모델 분류)
- 제안 순서:
  1. 레인 후보가 표를 받고, D4 의 요청 값을 후보에서 읽는다.
  2. 카탈로그 밖 모델의 선언을 계정 묶음에서 읽는다(D3).
  3. 카탈로그가 아는 계정이 카탈로그 행을 런타임으로 내놓는다(D2). `[models]` 파서와 스키마를 지운다(D1).
  4. 서버 설정 편집·설치 마법사·TUI 설정 화면에서 `models.` 갈래를 지운다.
  5. seed(`config/runtime.toml`)를 새 모양으로 바꾸고 문서를 고친다(§7).
- 한 층이 20k token 출력을 넘으면 더 나눈다(헌법 `work_unit`).

## 6. 열린 질문

1. **카탈로그 id 가 런타임 id 글자에 맞지 않을 때.** 73개 행이 `/`·`:` 를 가진다. 후보는 두 가지다.
   - 런타임 id 의 모델 조각에 `/`·`:` 를 허용한다. 런타임 id 가 파일 경로나 URL 에 들어가는 곳을 먼저 찾아야 한다.
   - 운영자가 계정 묶음에 이름을 붙이고 `api-name` 을 적는다. 이 경우 그 행은 D2 의 「표 없이 생김」에서 빠진다.
2. **사고 관련 세 값의 자리.** 카탈로그에서 찾은 것과 못 찾은 것이 다르다.
   - 찾은 것: `supports_reasoning`(154행), `thinking_control_format`(117행), `reasoning_replay`(74행), `preserve_thinking_control_format`(23행). 모두 「모델이 무엇을 받는가」다.
   - 못 찾은 것: `reasoning_uncontrolled`, 사고를 켜고 끄는 선택(`thinking-support`), 지난 사고를 다시 보내는 선택(`preserve-thinking`). 카탈로그에 그 이름의 필드가 없다.
   - 그래서 세 값은 운영자 선택으로 보고 레인 후보로 옮기는 것이 D4 와 맞다. 다만 `reasoning-uncontrolled` 는 「이 endpoint 는 사고 제어를 받지 않는다」는 카탈로그 밖 모델의 사실일 수도 있다. 그 경우는 D3 의 계정 묶음에 둔다. 운영 workspace 에서 이 키를 쓴 표는 19개다.
3. **카탈로그 행이 틀렸을 때 고치는 범위.** 지금은 카탈로그 행이 있어도 모델 표가 사고 제어 형식·출력 상한·effort 목록·이미지 입력·여러 매체 입력을 덮어쓴다(`lib/runtime/runtime_adapter.ml:546`~`552`). 이 덮어쓰기를 계정 묶음에 그대로 옮길지, 카탈로그를 고치는 것만 길로 둘지 정해야 한다.
4. **공식 client 의 모델 목록.** Codex·Claude Code·Antigravity·ACP 계정의 모델은 어디서 오는가.
   - 카탈로그에는 `suggested_clients` 가 붙은 행이 있다(`codex` 29행, `claude_code` 9행). `masc runtime-model-list` 가 이것을 읽는다.
   - Codex app server·Antigravity·Muse 는 자기 목록을 보고한다(`masc runtime-codex-models`·`runtime-antigravity-models`·`runtime-muse-models`).
   - 지금 공식 client 행의 `tools-support` 는 모델 표가 답한다(`docs/RUNTIME-TOML-REFERENCE.md` §3, `lib/runtime/runtime_tool_support.ml`). 사람 연동 검증도 이 값을 읽는다(`lib/server/server_person_integrations.ml:47`). 모델 표가 없어지면 이 값의 출처도 정해야 한다.
5. **보이는 모델이 늘어날 때.** D2 로 카탈로그 계정마다 받는 행이 모두 런타임이 된다. 부팅 점검이나 상태 검사가 런타임마다 도는지 확인해야 한다. 돈다면 레인·배정·기본값이 부르는 런타임만 검사한다.
6. **계정에서 모델을 숨기기.** 운영자가 어떤 카탈로그 행을 그 계정 목록에서 빼고 싶을 때 계정 묶음 `enabled = false` 를 쓸지 정한다. 이 키는 지금 「손으로 쓰지 않는 내부 값」이다(`docs/RUNTIME-TOML-REFERENCE.md` §4).
7. **exact-output 레인 슬롯의 변형.** exact-output 레인의 `slots`·`cli_slots` 는 지금 런타임 id 문자열만 받고, 출력 상한은 레인 표의 `max_output_tokens` 가 정한다. 슬롯도 D4 의 레인 후보처럼 표를 받아 effort 같은 값을 실을지 정한다.
8. **사람 계정 만들기와의 관계.** `RFC-a-persons-api-key-is-their-own-provider-account` 는 사람의 계정을 운영자 provider 항목(template)에서 id 와 홈만 바꿔 만든다. 그때 모델 묶음을 어떻게 옮기는지 읽고, 계정 꼬리표 복사본(§1)이 그 길에서 생기는지 확인한다. 이 RFC 가 그 RFC 의 결정을 바꾸지 않는지도 같이 적는다.

## 7. 바뀌는 문서

이 PR 은 문서를 고치지 않는다. 구현 층에서 같이 고친다.

- `docs/RUNTIME-TOML-REFERENCE.md`: 머리말의 표 목록, §1 의 나눔 표에 「모델 목록」 행 추가, §3 `[models.<id>]` 삭제, §4 계정 묶음에 D3 선언 키 추가, §6 레인 후보를 표로, §8 예시에서 `[models.claude-sonnet-5-5]` 삭제.
- `[models.` 을 예시로 쓰는 문서: `docs/spec/14-configuration.md`, `docs/KEEPER-FILE-MODEL.md`, `docs/LLAMA-SERVER-RUNBOOK.md`, `docs/guides/provider-admission-fairness.md`, `docs/guides/minimax-responses.md`, `docs/guides/tinker-integration.md`.

## 8. 검증

- 읽기 시험:
  - seed 가 `[models]` 표 없이 읽히고, 카탈로그 계정의 런타임이 카탈로그 행 수만큼 생긴다.
  - 카탈로그 밖 모델이 선언 없이 묶이면 거절된다. 카탈로그가 답하는 모델에 선언을 적어도 거절된다.
  - 후보 `effort` 가 카탈로그 effort 목록 밖이면 거절된다. 후보 `max-context` 는 계정 상한으로 깎인다.
  - `[models]` 표가 남은 파일은 거절된다.
- 실측:
  - 운영 파일을 새 모양으로 다시 쓰고 줄 수를 센다. 지금 4,145줄과 비교한다.
  - 레인마다 맨 앞 후보로 Keeper 턴 한 번씩 돈다.
  - 카탈로그에 행 하나를 더한 빌드로 서버를 띄운다. 운영 파일을 건드리지 않고 그 모델이 해당 계정 목록과 TUI 고르기 화면에 나오는지 본다.

## 9. 하지 않는 것

- 카탈로그 자체의 행을 고치거나 늘리지 않는다.
- 계정이 실제로 그 모델을 쓸 수 있는지 미리 묻는 검사를 더하지 않는다. 거절은 provider 가 한다.
- 옛 `[models]` 파일을 새 모양으로 바꿔 주는 도구를 만들지 않는다.
