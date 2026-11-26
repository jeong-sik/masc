---
rfc: "vibe-holds-the-native-posture-with-its-own-tool-allowlist"
title: "Vibe 는 native 수준을 자기 도구 허용 목록으로 지킨다"
status: Draft
created: 2026-11-26
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: []
---

# Vibe 는 native 수준을 자기 도구 허용 목록으로 지킨다

- 코드 기준: main `0ab05798e9a5b`.
- Vibe 기준: Mistral Vibe 3.1.0(운영 설치본)과 3.1.5 의 소스, 오프라인 실험(§5).
- **정한 것**: 수준을 Vibe 에 넘기는 법(D1), ACP `read`·`full` 의 작업 폴더와 skill 폴더(D2).
- **배포 뒤 정할 것**: Keeper 에게 주는 안내(D3).

## 0. 요약

MASC 는 Keeper 마다 native 수준(`none`·`read`·`full`)을 정한다. Muse 는 이 수준을 시작 인자 `run.toolset` 으로 받는다. Codex 는 권한 profile 로 받는다. Vibe 는 수준과 상관없이 같은 인자와 환경으로 뜬다. MASC 는 Vibe 가 보낸 허락 요청만 거절한다.

Vibe 는 묻지 않고 실행하는 호출이 있다. 그래서 `none` 인 Keeper 의 Vibe 가 `echo` 같은 명령을 호스트에서 실행한다. 이 RFC 는 수준을 Vibe 의 문서화된 설정 `enabled_tools` 로 넘긴다. 허용 목록이라 이름이 없는 도구는 Vibe 안에서 꺼진다.

## 1. 지금 동작

### 1.1 수준이 Vibe 에 닿지 않는다

- `Runtime_acp_client.build_argv` 의 `Mistral_vibe` 갈래는 `cli_path :: base_args` 다.
- `build_environment` 는 driver profile 의 고정값만 더한다. Vibe 의 고정값은 비어 있다(`env_set = []`).
- MASC 는 허락 요청에만 수준을 적용한다(`permission_policy_of_posture`, `should_allow_tool_call`).
- Vibe 는 내장 도구 호출을 자기 판정기로 먼저 정한다. 허용 명령 목록 같은 규칙이 호출마다 적용된다(3.1.5 `vibe/app_server/_runtime.py` 의 `_rust_tool_modes` 설명). 판정기가 허락한 호출은 클라이언트에 묻지 않는다.
- 실험 A1: 클라이언트가 허락 요청을 모두 거절해도 `bash` 의 `echo probe-leak` 이 호스트에서 돌았다. 그 출력이 모델에 갔고 허락 요청은 0건이었다.
- 운영 서버 로그(`<base-path>/.masc/logs/system_log_*.jsonl`)에서 MASC 가 거절한 Vibe 허락 요청을 셌다. 11-24 은 12건, 11-25 는 92건, 11-26 은 10:50:38Z 까지 38건이다.
- 11-25~26 의 130건을 요청한 Vibe 도구로 나누면 `bash` 68, `read_file` 29, `write_file` 24, `process.start` 9 다. 묻지 않고 실행된 호출은 이 수에 없다.
- 운영 Keeper 파일 31개 중 native 수준을 적은 파일은 없다(11-26 확인). 모두 ACP 기본값 `none` 으로 돈다.

### 1.2 `read`·`full` 이 운영자 체크아웃에서 돈다

- ACP 의 `none` 은 빈 격리 폴더(`create_isolated_workspace`)에서 돈다.
- `read`·`full` 은 pool key 의 `cwd = base_path` 에서 돈다(`keeper_acp_runtime.ml`).
- Vibe 는 작업 폴더 안 읽기를 묻지 않는다(실험 C1). `full` 에서는 쓰기도 묻지 않는다(실험 F1). 작업 폴더가 base path 면 그 자리가 운영자 체크아웃이다.
- `read`·`full` host 는 base path 의 `.masc/skills`·`.agents/skills` 도 받는다(`discover_skills_dirs`). Kimi 는 `--skills-dir` 로, Vibe 는 세션 폴더(`additionalDirectories`)로 받는다.
- Vibe 는 세션 폴더를 작업 폴더처럼 다룬다. `read` 는 그 안을 묻지 않고 읽고, `full` 은 묻지 않고 쓴다(실험 X1·X2). 두 폴더 밖을 읽을 때는 허락 요청을 보낸다(실험 X0).
- `.agents/skills` 는 운영자의 skill 이다. `.masc/skills` 는 MASC skill 목록의 원본이고, Keeper 는 그 목록을 `keeper_skill` 로 받는다.
- Codex 는 다른 규칙을 쓴다(`Keeper_codex_runtime.native_cwd` 주석, #39444). base path 는 운영자의 AGENTS.md 와 skill 이 있는 체크아웃이라 작업 폴더로 쓰지 않는다. 샌드박스가 호스트 트리를 붙이는 Keeper 는 그 트리에서 돈다. 나머지 Keeper 는 MASC 런타임 루트 아래 자기 폴더에서 돈다.
- 그 주석은 이 규칙을 Muse 와 Antigravity 가 쓴다고 적는다. ACP 로 도는 Muse 는 지금 이 규칙을 따르지 않는다.
- Vibe 는 신뢰한 폴더에서만 프로젝트 파일을 싣는다. 작업 폴더의 `.vibe/config.toml`·`.vibe/agents/`(`vibe/core/config/layers/project.py`), 작업 폴더에서 저장소 루트까지의 `AGENTS.md`(`vibe/core/trusted_folders.py`)다.
- 신뢰는 ACP 확장 `trust/decision` 으로 정한다. MASC 는 이 요청을 보내지 않는다. 운영자의 Vibe 신뢰 목록도 비어 있다(11-26). 그래서 지금은 운영자의 `AGENTS.md` 가 실리지 않는다.

### 1.3 모델이 보는 도구

- 3.1.0 이 모델에 바로 주는 도구는 11개다. `bash`, `cron`, `edit`, `read_file`, `run_typescript`, `search_tool_functions`, `skill`, `todo`, `unified_harness_scratchpad`, `wait`, `write_file` 이다.
- 3.1.5 는 `create_goal`·`get_goal`·`update_goal` 을 더해 14개다(실험 N0).
- 운영 Keeper 세션 하나를 읽었다. 11-26 08:55~09:16Z 에 MASC 격리 폴더(`none`)에서 돈 세션이다.
- 그 세션의 도구 목록은 세 묶음이다. `vibe`(3개: `cron`·`todo`·`unified_harness_scratchpad`), `mcp_masc`(158개), `connector_web_search`(5개)다. `none` 인데도 웹 도구가 모델 손에 있다.
- 모델은 MASC 도구를 `run_typescript` 안에서 `tools.mcp_masc.Execute(...)` 처럼 부르거나 바로 부른다.
- 같은 세션 기록에 `tools.mcp_masc.Execute` 참조가 192번, toolName 이 `mcp_masc.Execute` 인 기록이 27건 있다. `tools.web_search.web_search` 참조도 2번 있다.

## 2. Vibe 가 주는 수단

| 수단 | 근거 | 결과 |
|---|---|---|
| `enabled_tools` (환경 변수 `VIBE_ENABLED_TOOLS`) | 설정 설명: "If set, only these tools will be active." | 이름을 적은 도구만 켜진다. 자세한 결과는 표 아래에 적는다 |
| `disabled_tools` | "disable after 'enabled_tools' filtering" | 거부 목록이다. Vibe 가 나중에 더한 도구는 켜진 채로 온다 |
| `[tools.<name>] permission = "never"` | `_allowlist_exempts` | 허용 명령 목록이 있는 도구는 `never` 가 `ask` 로 올라간다. 목록에 든 명령은 그대로 실행된다 |
| 세션 설정 `sandbox_access`·`builtins` | Python SDK 문서는 `access` 의 `none`·`files`·`full` 만 적는다 | 내장 도구를 모델 목록에서 빼는 유일한 수단이다. `vibe-app-server` 의 wire 프로토콜은 문서가 없다 |

`enabled_tools` 가 하는 일:

- 이름이 없는 내장 도구는 허락 요청 없이 Vibe 안에서 `tool_denied` 로 끝난다(실험 B1·B2·C2).
- `cron`·`unified_harness_scratchpad`·`todo` 와 3.1.5 의 goal 도구 셋은 목록에서 빠진다(실험 B0·B1).
- MCP 도구는 표시 이름 `{server}_{tool}` 로 맞춘다(`MCPToolFilter`, `vibe/app_server/_unified_harness_backend_adapter.py`).
- 커넥터 도구도 같은 목록으로 거른다(`vibe/app_server/connector_catalog.py`). 이 줄은 소스로만 확인했다.

- 환경 변수를 쓰는 이유(헌법 `env_var_sprawl`): MASC 가 새로 만드는 설정이 아니다. Vibe 가 문서로 정한 설정 덮어쓰기 길이다.
- 운영자의 `~/.vibe/config.toml` 은 다른 세션과 같이 쓰는 파일이라 고치지 않는다. 별도 `VIBE_HOME` 을 주면 운영자 로그인과 설정이 끊긴다.
- 환경 변수는 설정 파일의 `enabled_tools` 를 이긴다(실험 B4).
- 3.1.5 의 goal 도구 셋은 3.1.0 에 없던 도구다. 허용 목록은 이것도 껐다. 거부 목록이었다면 켜진 채로 왔다.

## 3. 정한 것

### D1. 수준을 `VIBE_ENABLED_TOOLS` 로 넘긴다

| 수준 | 값 | Vibe 가 하는 일 |
|---|---|---|
| `none` | `["<bridge>_*", "todo"]` | 내장 파일·셸·`skill`·process 도구를 거절한다. 나머지 Vibe 도구와 커넥터를 뺀다. MASC 도구는 동작한다(실험 B3) |
| `read` | `["<bridge>_*", "todo", "read_file"]` | 위와 같고 `read_file` 을 더 쓴다(실험 C1) |
| `full` | 넣지 않는다 | Vibe 가 자기 설정대로 도구를 켠다. 모드 `auto-approve` 는 지금과 같다(실험 F1) |

- `<bridge>` 는 그 세션 MCP bridge 의 이름이다. bridge 없이 뜨면 그 항목을 뺀다.
- 도구가 없는 bridge 의 glob 은 아무것도 켜지 않으니 그대로 둔다. Muse 는 맞는 도구가 없는 이름을 거절해서 빼야 하지만 Vibe 는 아니다.
- 수준이 주어지지 않으면 `none` 과 같다. Muse 와 같다.
- 부모 환경의 `VIBE_ENABLED_TOOLS` 는 모든 수준에서 지운다. `none`·`read` 는 그 자리에 이 값을 넣는다.
- 허락 요청 거절(`permission_policy_of_posture`)은 그대로 둔다.

도구별 이유:

- `todo` 는 세션 안의 계획표다. 호스트에 효과가 없어서 모든 수준에 둔다.
- `unified_harness_scratchpad` 는 Vibe 세션 저장소 아래에 파일을 쓴다(`vibe/app_server/_unified_scratchpad.py`). `none`·`read` 에서는 끈다.
- `cron` 은 Vibe 가 세션 옆에 두는 반복 일정이다. 쉬는 틈에 프롬프트를 스스로 띄운다(`vibe/app_server/_unified_scheduled_loops.py`). MASC 가 모르는 턴이 생겨서 `none`·`read` 에서는 끈다.
- Vibe 에는 읽기 전용 검색 도구가 없다. 런타임 내장 도구 중 `read_file` 에 묶인 것은 `file_system.read_file` 하나다(`RUST_BUILTIN_TOOL_SOURCES`). 검색은 MASC `Grep` 으로 한다.
- 웹 검색은 MASC `WebSearch`·`WebFetch` 로 한다. Vibe 커넥터와 달리 MASC 기록에 남는다.
- 허용 목록이다. Vibe 가 새 도구를 더해도 이 표에 이름을 적기 전까지 꺼져 있다.

### D2. ACP `read`·`full` 의 작업 폴더는 Codex 와 같은 규칙을 따른다

- 샌드박스가 호스트 트리를 붙이는 Keeper 는 그 트리에서 돈다. 나머지 Keeper 는 `<base-path>/.masc/official-clients/acp-workspaces/<sha256(keeper)>` 에서 돈다. base path 는 작업 폴더가 아니다.
- 규칙은 `Keeper_codex_runtime.native_cwd` 에서 모듈 하나로 뽑는다. Codex 와 ACP 가 같이 부른다. 복사하지 않는다.
- 폴더 이름은 클라이언트의 닫힌 합으로 정한다. Codex 는 지금 폴더(`codex-workspaces`)를 그대로 쓴다.
- `none` 은 지금처럼 빈 격리 폴더에서 돈다.
- `read`·`full` host 에 주는 폴더는 바인딩이 적은 `skills-dirs` 뿐이다. base path 의 폴더는 넘기지 않는다. Codex 도 운영자 skill 을 받지 않는다(#39444). MASC skill 은 모든 수준에서 `keeper_skill` 로 간다.
- pool key 는 host 폴더를 `Isolated_per_spawn`·`Keeper_folder of string` 으로 든다. 두 spawn 자리는 수준을 다시 보지 않고 key 를 읽는다.
- 개인 폴더도 base path 의 `.masc` 안에 있다. 저장소 루트까지 올라가 파일을 읽는 host 는 base path 저장소의 파일을 여전히 본다.
- Codex 는 `project_root_markers=[]` 로 이 길을 끊는다. Muse 가 저장소의 `.mcp.json` 을 싣는 일은 이 RFC 가 바꾸지 않는다. Vibe 는 신뢰하지 않은 폴더라 싣지 않는다(§1.2).
- ACP driver 넷(Antigravity, Kimi Code, Mistral Vibe, Muse Code)에 같이 적용된다. 지금 `read`·`full` 을 선언한 운영 Keeper 는 없다(§1.1).

### D3. 꺼진 내장 도구 안내는 배포 뒤 잰 다음 정한다

- Vibe 는 꺼진 내장 도구(`bash`·`read_file`·`write_file`·`edit`·`skill`)를 모델 목록에 남긴다. 부르면 "Tool execution denied by approval policy" 로 끝난다.
- 11-26 운영 세션에서 모델은 이미 MASC `Execute` 를 주로 썼다(§1.3). 안내 문장의 효과는 아직 모른다.
- 배포 뒤 Vibe Keeper 세션의 `tool_denied` 수를 잰다. 모델이 꺼진 도구를 계속 부르면 Codex `read` 의 `keeper.codex.native_read` 처럼 사실 안내를 더한다.

## 4. 하지 않는 것

- `vibe-app-server` 로 옮기지 않는다. wire 프로토콜 문서가 없다.
- 운영 Vibe 를 업그레이드하지 않는다. 실험 결과는 3.1.0 과 3.1.5 가 같다.
- 운영 Keeper 파일과 `runtime.toml` 은 고치지 않는다. 수준 선언은 운영자가 한다.
- `full` 의 `cron`·goal 도구가 MASC 턴과 겹치는 일은 이 RFC 범위 밖이다.

## 5. 확인 방법

오프라인 실험이다. 쓰는 것은 아래 넷이다.

- 임시 `HOME`·`VIBE_HOME`
- 가짜 OpenAI 호환 모델 서버
- `masc` 라는 이름의 가짜 MCP 서버(`keeper_ping`·`Execute`)
- 스크립트 ACP 클라이언트(`clientCapabilities` 는 MASC 처럼 비운다)

운영자 자격 증명과 설정은 읽지 않고 유료 호출도 없다. 가짜 모델은 첫 요청에서 정해진 도구를 한 번 부르고 다음 요청에서 답을 끝낸다. 모드는 MASC 가 수준마다 고르는 값이다. 스크립트와 결과 기록은 PR 본문에 둔다.

| 실험 | 조건 | 결과 (3.1.0·3.1.5 같음) |
|---|---|---|
| N0 | 목록 없음, 모드 `ask` | 바로 주는 도구 11개(3.1.0)·14개(3.1.5) |
| A1 | 목록 없음, 모드 `ask`, 클라이언트가 모두 거절 | `bash` `echo` 가 호스트에서 실행됐다. 허락 요청 0건 |
| B0 | `["masc_*"]` | 바로 주는 도구 8개. `todo` 도 빠진다 |
| B1 | `["masc_*","todo"]`, 클라이언트가 모두 허락 | 도구 9개. `bash` 가 `tool_denied`. 허락 요청 0건 |
| B2 | B1 과 같다 | `run_typescript` 안의 `tools.file_system.read_file` 이 거절됐다. 허락 요청 0건 |
| B3 | B1 과 같다 | `run_typescript` 안의 `tools.mcp_masc.keeper_ping` 이 허락 요청 1건 뒤 MCP 서버에 닿았다 |
| B4 | 설정 파일 `enabled_tools = ["bash","masc_*"]` + B1 의 환경 변수 | `bash` 가 `tool_denied` |
| C1 | `["masc_*","todo","read_file"]`, 클라이언트가 모두 거절 | 작업 폴더의 `read_file` 이 내용을 돌려줬다. 허락 요청 0건 |
| C2 | C1 의 목록, 클라이언트가 모두 허락 | `write_file` 이 `tool_denied`. 허락 요청 0건 |
| F1 | 목록 없음, 모드 `auto-approve`, 클라이언트가 모두 거절 | `write_file` 이 작업 폴더에 썼다. 허락 요청 0건 |
| X0 | C1 의 목록, 세션 폴더 하나, 클라이언트가 모두 거절 | 작업 폴더와 세션 폴더 밖 파일의 `read_file` 이 허락 요청 1건 뒤 `tool_denied` |
| X1 | X0 과 같다 | 세션 폴더 안 `read_file` 이 내용을 돌려줬다. 허락 요청 0건 |
| X2 | 목록 없음, 모드 `auto-approve`, 세션 폴더 하나, 클라이언트가 모두 거절 | 세션 폴더 안에 `write_file` 이 썼다. 허락 요청 0건 |

시험과 배포 뒤 측정:

- 시험: ACP client 가 수준마다 Vibe 에 주는 환경과 ACP `read`·`full` 의 작업 폴더를 본다.
- 배포 뒤 하루를 잰다. Vibe Keeper 세션 기록의 `tool_denied` 수, MASC 가 거절한 허락 요청 수, `tools.mcp_masc.*` 호출 수를 배포 전과 견준다.

## 6. 묶음 순서

1. 이 RFC
2. D1, 시험, `docs/RUNTIME-TOML-REFERENCE.md` 의 Vibe 수준 표
3. D2 와 시험
