---
rfc: "acp-hosts-offer-only-what-the-keeper-may-use"
title: "MASC 가 띄운 ACP 호스트는 Keeper 가 쓸 수 있는 것만 싣는다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
supersedes: []
superseded_by: null
related: ["vibe-holds-the-native-posture-with-its-own-tool-allowlist"]
---

# MASC 가 띄운 ACP 호스트는 Keeper 가 쓸 수 있는 것만 싣는다

- 코드 기준: main `a8a00684072d1`.
- 호스트 기준: Muse Code 1.4.25(R9361.1), Kimi Code 2.7.3(운영 설치본), 오프라인 실험(§5).
- **정한 것**: Muse 는 설치된 플러그인의 runtime capability 를 끄고 뜬다(D1). Kimi 는 `none` 일 때 MASC 도구만 내놓는다(D2). 준비가 실패하면 호스트를 띄우지 않는다(D3).

## 0. 요약

TUI 도구 행에 오류가 두 가지로 쌓인다. Muse Keeper 에는 `omm:` 오류가, Kimi Keeper 에는 `Bash` 오류가 나온다.

둘 다 Keeper 가 쓸 수 없는 것을 호스트가 싣고 뜬 탓이다. Muse 는 운영자가 설치한 플러그인의 hook 을 Keeper 세션에서 돌린다. Kimi 는 `none` 인 Keeper 에게 내장 도구를 내놓고, MASC 는 그 호출을 나중에 거절한다. Kimi 의 내장 도구 대부분은 허락을 묻지 않아서 거절도 닿지 않는다.

이 RFC 는 판단을 호스트가 뜨는 순간으로 옮긴다. Muse 에는 끌 capability 를 시작 인자로 넘긴다. Kimi 에는 허용 도구 목록을 작업 폴더의 profile 로 넘긴다.

## 1. 지금 동작

### 1.1 Muse: 운영자 플러그인이 Keeper 세션에서 돈다

- 운영자는 11-03 에 `oh-my-musecode` 1.0.1 을 설치했다. runtime capability 는 10개다. hook 8, reminder 1, MCP server 1 이다.
- hook 8개는 모두 `omm hook ...` 을 실행한다. 이 장비에는 `omm` 명령이 없다. 그래서 hook 이 돌 때마다 "No such file or directory (os error 2)" 로 실패한다.
- Muse 는 hook 이 실패해도 도구 호출을 계속한다. 대신 실패가 TUI 에 오류 행으로 남는다.
- MASC 는 `muse_observer_capability_ids` 에 적은 6개만 끈다. 모두 Muse 에 들어 있는 `tbh-reminders` 의 reminder 다. 운영자가 설치한 플러그인은 이 목록에 없다.
- 11-26~27 하루치 Muse 기록을 셌다. Keeper 세션 50개에서 운영자 hook 이 8,013번 돌았고 8,013번 모두 실패했다. 실패에 쓴 시간은 합쳐서 186초다.
- 가장 많이 돈 hook 은 `omm-guard`·`omm-intent-gate`·`omm-skill-gate`(각 1,992번)와 `omm-subagent-start`(1,888번)다. 도구 호출 한 번마다 돈다.
- `muse acp` 에는 플러그인을 통째로 끄는 인자가 없다(실험 M1·M2).
- capability 를 하나씩 끄면 hook 이 돌지 않는다. 10개를 모두 끈 세션은 hook 을 한 번도 돌리지 않았다(실험 M3).
- 설치된 플러그인 목록은 `muse plugins list --json` 이 준다. 한 플러그인의 capability id 는 `muse plugins inspect <id> --json` 의 `runtime_capabilities[].candidate.stable_id` 다. 한 번에 0.13초 걸린다.
- Muse 에 들어 있는 `tbh-reminders` 는 이 목록에 없다. `inspect tbh-reminders` 는 `unknown-plugin` 이다.

### 1.2 Kimi: `none` 인 Keeper 에게 내장 도구를 내놓는다

- MASC 는 Kimi 에 수준을 ACP mode 로만 넘긴다(`none` 은 `default`). 그리고 허락 요청을 수준대로 거절한다(`Allow_masc_mcp_only`).
- Kimi 의 기본 profile `agent` 는 내장 도구 약 30개와 `mcp__*` 를 켠다. 운영 Keeper 세션의 `profile.bind` 기록에서 읽었다.
- 11-26~27 하루치 Kimi Keeper 세션의 내장 도구 호출을 셌다.
  - `TodoList` 721, `FetchURL` 548, `Skill` 232, `Read` 93, `Grep` 91, `Bash` 75, `Glob` 56, `AskUserQuestion` 13, `WebSearch` 7, `Write` 1.
  - 허락 요청은 `Bash` 75건과 `Write` 1건뿐이다. MASC 가 모두 거절했다. TUI 의 `Bash` 오류가 이 75건이다.
  - 나머지는 묻지 않고 실행됐다. `Read` 는 `~/.kimi-code/bin/kimi` 같은 호스트 파일을 읽었고, `FetchURL` 은 웹 페이지를 가져왔다. `none` 이 허락하지 않는 일이다.
- `kimi acp` 는 `--login`·`--region` 만 받는다.
- Kimi 는 작업 폴더의 `.kimi-code/agents/*.md` 에서 agent profile 을 읽는다. frontmatter `tools` 는 허용 목록이다. `override: true` 면 기본 profile `agent` 를 바꾼다.
- profile 출처의 우선순위는 작업 폴더(30)가 사용자 폴더(10)와 기본값(0)보다 높다(2.7.3 코드 `AGENT_PROFILE_SOURCE_PRIORITY`).
- 작업 폴더 profile 로 `tools: ["mcp__masc__*"]` 를 주면 세션의 도구 목록이 그것 하나가 된다(실험 K1).
- Kimi 는 profile 을 세션을 만들 때 한 번 기록한다. 다시 불러온 세션은 그 기록을 따른다(실험 K2).
- Kimi 의 도구 찾기 `select_tools` 는 `tools` 가 아니라 `disallowedTools` 로만 가린다. 그래서 허용 목록을 줘도 남는다(2.7.3 코드 `isToolActiveForDisclosure`).

## 2. 결정

### D1. Muse 호스트는 설치된 플러그인의 runtime capability 를 끄고 뜬다

- `Runtime_acp_client.start` 가 Muse 를 띄우기 전에 `<cli> plugins list --json` 을 돌린다. 나온 플러그인마다 `<cli> plugins inspect <id> --json` 을 돌린다. 환경 변수와 작업 폴더는 호스트와 같다.
- 나온 capability id 마다 `-c runtime_capabilities.<id>.enabled=false` 를 넘긴다. Muse 에 들어 있는 observer 6개도 지금처럼 넘긴다. 같은 id 는 한 번만 넘긴다. 같은 `-c` 키가 두 번 나오면 Muse 가 뜨지 않기 때문이다.
- hook, reminder, MCP server 를 가리지 않고 끈다. 운영자 플러그인이 Keeper 세션에 들어갈 이유가 없다.
- `start` 를 부르는 곳(Keeper, 검증자, fusion, probe)이 모두 이 규칙을 따른다.
- 플러그인의 skill 과 command 는 runtime capability 가 아니라서 이 결정 밖이다. 모델이 skill 도구를 받는지는 `run.toolset` 이 정한다.
- 운영자의 `settings.json` 과 플러그인 켜짐 상태는 건드리지 않는다. 운영자가 직접 여는 Muse 세션은 그대로다.

### D2. Kimi `none` 호스트는 작업 폴더의 profile 로 MASC 도구만 내놓는다

- `start` 가 Kimi 를 `none` 으로 띄우기 전에 `<cwd>/.kimi-code/agents/agent.md` 를 만든다.
  - `name: agent`, `override: true`, `tools: ["mcp__<server>__*"]` 이다. MCP 서버가 없으면 `tools: []` 이다.
  - 본문은 `${base_prompt}` 하나다. Kimi 의 기본 system prompt 를 그대로 쓴다.
- 파일은 새로 만들기만 한다. 이미 있으면 호스트를 띄우지 않는다.
  - `none` 의 작업 폴더는 늘 `create_isolated_workspace` 가 만든 빈 폴더다. `start` 를 부르는 네 곳이 모두 그렇다.
  - 그래서 이미 있다는 것은 다른 폴더를 받았다는 뜻이다. 남의 폴더에 쓰지 않으려고 멈춘다.
- `read`·`full` 은 바꾸지 않는다. 이 둘은 Keeper 자기 폴더에서 돈다. 그 폴더가 호스트 트리일 수 있어서 MASC 가 파일을 쓰지 않는다.
- 이 결정으로 `none` Keeper 는 `TodoList`·`Skill`·`FetchURL`·`WebSearch`·`Read`·`Grep`·`Glob`·`AskUserQuestion`·`Agent` 를 잃는다. 같은 일은 MASC 도구로 한다. Muse `none` 이 이미 이렇게 돈다.
- 배포 전에 만든 Kimi 세션은 새 세션으로 바뀔 때까지 옛 도구 목록을 쓴다(실험 K2).

### D3. 준비가 실패하면 호스트를 띄우지 않는다

- 다음 경우에 `start` 는 오류를 돌려준다. 오류는 실패한 명령이나 파일과 이유를 담는다.
  - Muse 목록 명령이 0 이 아닌 값으로 끝났다.
  - 그 출력이 위의 JSON 모양이 아니다.
  - Kimi profile 파일을 만들지 못했다.
- 그 Keeper lane 은 시작 실패로 보인다. 운영자는 오류를 보고 플러그인 저장소나 폴더를 고친다.
- 조용히 넘어가면 운영자 플러그인이나 내장 도구가 다시 Keeper 세션에 들어간다. 운영자 결정(2026-11-27)이다.

## 3. 바뀌지 않는 것

- MASC 의 허락 요청 판정(`permission_policy_of_posture`)은 그대로 두 번째 벽으로 남는다.
- Vibe 와 Antigravity 는 바뀌지 않는다.
- 비용: Muse 호스트가 뜰 때마다 명령이 `1 + 플러그인 수` 번 더 돈다. 지금 장비에서는 2번, 약 0.26초다.

## 4. 확인

- 시험
  - 목록과 inspect 출력의 JSON 을 읽는다. 모양이 다르면 오류다.
  - Muse argv 에 capability id 마다 `-c` 가 한 번씩 들어간다. observer 와 겹치는 id 도 한 번이다.
  - 목록 명령이 실패하면 `start` 가 호스트를 띄우지 않는다.
  - Kimi profile 의 내용과, 파일이 이미 있으면 멈추는 동작을 본다.
- 배포 뒤
  - Muse Keeper 세션 기록에 운영자 플러그인의 `hook_run_started` 가 0건이다.
  - 새로 만든 Kimi Keeper 세션의 `profile.bind` 가 `activeToolNames: ["mcp__masc__*"]` 다.
  - MASC 가 거절한 Kimi `Bash` 허락 요청이 새 세션에서 0건이다.

## 5. 실험 기록

모두 2026-11-27 운영 장비에서 했다. Muse 는 echo provider 라 모델을 부르지 않았다. Kimi 는 `session/new`·`session/load` 만 보내 모델을 부르지 않았다.

- **M0** 인자 없이 `muse acp --provider echo --trust-workspace` 로 한 턴을 돌렸다. `omm-session-start`·`omm-stop`·`omm-subagent-start` 2번, 모두 4번 돌았다.
- **M1** `-c` 후보를 넣었다.
  - `extensions.hooks.fallback_enabled`·`extensions.plugins.fallback_enabled`·`extensions.runtime_capabilities.fallback_enabled` 는 "unknown key" 로 시작을 거부했다.
  - `plugins.skip=true`·`plugins.skip=["oh-my-musecode"]`·`plugins.enabled=false`·`hooks.enabled=false`·`plugins.oh-my-musecode.enabled=false` 는 받았지만 hook 4번이 그대로 돌았다.
- **M2** 환경 변수 `MUSE_EXPERIMENTAL_PLUGINS` 를 `0`·`false`·`off` 로 두었다. hook 4번이 그대로 돌았다.
- **M3** `oh-my-musecode` 의 capability 10개를 `-c runtime_capabilities.<id>.enabled=false` 로 껐다. hook 이 0번 돌았다.
- **K1** 빈 폴더에서 `kimi acp` 세션을 만들었다.
  - profile 이 없으면 `activeToolNames` 가 `Read`·`Write`·`Edit`·`Grep`·`Glob`·`Bash`… 다.
  - 폴더에 `tools: ["mcp__masc__*"]` profile 을 두면 `["mcp__masc__*"]` 다.
- **K2** 폴더 A 에서 세션을 만들고 호스트를 끈 뒤 A 를 지웠다. profile 이 있는 폴더 B 에서 새 호스트로 그 세션을 불러왔다.
  - A 에 profile 이 있었으면 기록은 `["mcp__masc__*"]` 하나다.
  - A 에 없었으면 기록은 기본 목록 하나다. 불러올 때 새 기록이 생기지 않았다.

## 6. 남은 것

- Kimi `read`·`full`: 허용 목록을 넘길 길이 작업 폴더 profile 밖에 없다. 운영 Keeper 31개 중 native 수준을 적은 파일은 없다(11-26). 별도 이슈로 둔다.
- Muse 플러그인의 skill·command 가 Keeper 세션에 보이는지는 재지 않았다.
