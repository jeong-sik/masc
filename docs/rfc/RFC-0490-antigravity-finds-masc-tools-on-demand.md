---
rfc: "0490"
title: "antigravity 레인은 masc 도구를 eager 로 넘기지 않는다 — agy 가 지연 목록에서 찾고, masc 는 schema 읽기만 연다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0451", "0390", "attached-service-tool-scoping"]
---

# RFC-0490 — antigravity 레인은 도구를 지연 로딩으로 넘긴다

## 0. 요약

- 11-05 10:17Z 부터 msx-retro-mania 는 antigravity 턴마다 같은 말을 했다. "DOS 도구는 eject·inventory·meta·pass·peek·save·step 뿐이고 screen·press·type 이 없다." 그래서 삼국지 3 을 한 수도 두지 못했다.
- 서버 쪽 도구 목록은 온전했다. 10:26Z `keeper_tools_list` 는 DOS 도구 13개를 모두 `active` 로 보였다.
- 원인은 agy 1.5.1 이다. masc 는 도구 206개를 모두 `tools.<이름>.eager` 로 넘긴다. agy 는 작은 도구부터 공백 없는 JSON 으로 약 62,000 자까지만 등록한다. 나머지는 지연 목록에도 넣지 않고 말없이 버린다. 측정은 [근거](../evidence/2026-11-05-antigravity-mcp-tool-budget/README.md)에 있다.
- 제안은 셋이다.
  1. masc 는 antigravity 에 eager 표시를 하지 않는다. agy 가 모든 도구를 지연 목록에 싣고, 모델이 거기서 찾는다.
  2. settings 에서 지연 도구의 schema 폴더 읽기를 연다. 전체 읽기 거부(`read_file(*)`)는 빼고, 비밀이 있는 두 경로를 정확히 막는다.
  3. 거절만 내는 PreToolUse hook 을 둔다. 허용 밖 경로를 읽거나 쓰려 하면 그 호출만 오류로 돌아가고 턴은 이어진다. 다른 레인과 같은 동작이다.
- 결과 한도 변경은 필요 없다. 큰 결과 파일은 agy 가 스스로 연다(측정 8a).

## 1. 지금

### 1.1 masc 가 넘기는 것

`keeper_antigravity_runtime.ml:118` 의 `eager_tool_names` 는 턴의 모든 도구 이름을 돌려준다. `Runtime_official_client_mcp_http.mcp_config_json`(`runtime_official_client_mcp_http.ml:105`)은 그 이름마다 `{"eager": true}` 를 적는다. 주석의 이유는 이렇다. eager 가 아닌 도구는 schema 파일을 읽어야 부를 수 있다. masc home 은 `read_file(*)` 를 막는다. 그래서 그런 도구는 schema 없이 불린다.

이 판단은 agy 1.2.9 에서 측정했다(2026-09-24, `runtime_official_client_mcp_http.mli` 의 `mcp_config_json` 주석).

### 1.2 agy 1.5.1 이 하는 것

| 측정 | 결과 |
| --- | --- |
| 작은 도구 220개(44,880 자) 모두 eager | 220개 모두 등록 |
| 실제 206개 모두 eager | 116개만 등록. 0 부터 센 크기 순위 113(888 자)까지는 남고, 129(1,066 자)의 `masc_dos_screen` 부터 빠짐 |
| 같은 206개에 `_meta: {"antigravity/alwaysLoad": true}` | 같은 116개 |
| eager 표시 없음 | 206개 모두 지연 목록에 이름으로 오름. `call_mcp_tool` 이 서버에 도착 |

masc 가 `defer_loading` 없이 선언한 도구만 해도 64개, 79,991 자다(같은 재는 법). 선언을 따라 eager 를 고르는 것으로는 예산 안에 들지 않는다.

예산 값은 agy 문서에 없다. 버린 도구는 agy 로그에도 남지 않는다. agy 는 실행할 때마다 스스로 업데이트한다(`auto_updater.go: Spawned background update process`). 1.5.1 이전에도 이 예산이 있었는지는 모른다.

### 1.3 지연 로딩에 걸리는 것

agy 의 지연 목록에는 이름만 있다. 인자는 `<appDataDir>/mcp/<server>/<tool>.json` 을 읽어 안다. 여기서 appDataDir 은 `<HOME>/.gemini/antigravity-cli` 다.

- deny `read_file(*)` 는 allow `read_file(<schema 폴더>)` 를 이긴다(측정 4c). PreToolUse hook 의 `allow` 도 settings deny 를 이기지 못한다(측정 5a). 지금 `Native_none` home 에서는 schema 를 읽을 길이 없다.
- appDataDir 안의 다른 파일은 settings 와 관계없이 agy 가 거절한다. 오류는 "Matches hardcoded system protection boundary rule" 이다(측정 6·7·8b). masc 가 넣는 `antigravity-oauth-token` 도 이 폴더에 있다.
- 10 KB 넘는 지연 결과는 `<appDataDir>/brain/<대화>/.system_generated/steps/<n>/output.txt` 로 빠진다. 이 파일은 allow 없이 읽힌다(측정 8a).
- `<HOME>/.gemini/config/` 는 그 보호 밖이다. 이 폴더의 `mcp_config.json` 에는 bridge 의 `Authorization: Bearer` 가 있다.

### 1.4 허용 밖 읽기는 턴을 끝낸다

- 맞는 규칙이 없는 작업 폴더 밖 경로는 Ask 다. print mode 는 물을 수 없어 그 동작을 거절하고 실행을 끝낸다. 결과는 `status: SUCCESS` 이고 거절한 동작은 `denied_actions` 에 적힌다(측정 6·10, agy [headless 문서](https://antigravity.google/docs/cli/headless/)).
- 모델이 그 전에 쓴 글은 `response` 로 남는다(측정 10). masc 는 그 글을 답으로 받아 턴을 완료했다. #48773 이 이 실행을 `Actions_denied` 로 실패시킨다.
- 다른 레인은 다르다. Claude Code 와 Codex 는 거절된 도구 호출을 모델에게 오류 결과로 돌려주고, 모델은 하던 일을 잇는다. 두 CLI 의 이 동작은 이번에 다시 재지 않았다.
- settings 로는 이 Ask 를 거절로 바꿀 수 없다. 문서에 있는 규칙 목록은 Deny·Ask·Allow 뿐이고, 전체 거부(`read_file(*)`)는 schema allow 까지 이긴다(측정 4c). settings deny 나 hook `deny` 로 거절된 호출은 오류로 돌아가고 턴이 이어진다(측정 5b·6·8b).

## 2. 제안

### 2.1 eager 표시를 없앤다

- `eager_tool_names` 와 `mcp_config_json` 의 `~eager_tools` 인자를 지운다. `mcp_config.json` 에는 `tools` 맵을 쓰지 않는다.
- readiness 검사(`runtime_verification_antigravity.ml:28`)와 capability probe(`keeper_capability_probe.ml:669`)도 도구 하나를 eager 로 넘기지 않는다. 두 검사가 Keeper 턴과 같은 길(지연 목록 → schema 읽기 → `call_mcp_tool`)을 지나야 그 길이 깨졌을 때 잡힌다.
- 무엇을 목록에 올릴지는 지금처럼 bundle 이 정한다(RFC-0451 의 경계). 언제 schema 를 실을지는 agy 가 정한다. RFC-0451 §0 이 적은 "스키마를 언제 싣는지는 클라이언트가 스스로 한다" 가 이 레인에서도 참이 된다.
- `defer_loading` 은 지금처럼 Agent Core 레인만 읽는다(`tool_loading_declarations.mli:29`).

### 2.2 settings 에서 schema 폴더를 연다

`native_settings_json`(`runtime_antigravity_home.ml:231`)을 이렇게 바꾼다. schema 폴더는 `<appDataDir>/mcp/masc`, 설정 폴더는 `<HOME>/.gemini/config`, 토큰은 `<appDataDir>/antigravity-oauth-token` 이다.

| 자세 | allow | deny |
| --- | --- | --- |
| `Native_none` | `mcp(masc/*)`, `read_file(<schema 폴더>)` | `read_file(<설정 폴더>)`, `read_file(<토큰>)`, `write_file(*)`, `command(*)`, `read_url(*)`, `execute_url(*)` |
| `Native_read` | 위 + `read_file(<workspace>)` | `Native_none` 과 같다 |
| `Native_full` | 위 + `write_file(<workspace>)` | `read_file(<설정 폴더>)`, `read_file(<토큰>)`, `read_url(*)`, `execute_url(*)` |

- `read_file(*)` 전체 거부는 뺀다. 남기면 schema 를 읽을 수 없다(1.3).
- 설정 폴더 deny 가 없으면 그 폴더를 읽으려는 순간 턴이 끝난다. deny 가 있으면 그 읽기만 거절되고 턴은 이어진다(측정 6, 8b).
- 토큰은 agy 의 boundary 가 이미 막는다. 그래도 정확한 경로로 거부한다. boundary 는 agy 문서에 없는 동작이고, agy 는 스스로 업데이트한다. 이 deny 를 달아도 agy 로그인은 된다(측정 8b).
- `settings_json ()` 은 `Native_none` 줄을 쓴다. 사용량 조회·readiness·probe home 도 같은 줄을 받는다. 2.1 뒤에는 그 home 들도 schema 를 읽어야 하니 같은 줄이 맞다.
- 이 settings 는 권한 경계다. 구현 층에 `//HIGH-RISK-UNREVIEWED` 를 달고 사람 리뷰를 받는다.

### 2.3 거절만 내는 PreToolUse hook

목표는 다른 레인과 같은 동작이다. 허용 밖 경로를 읽거나 쓰려는 호출은 그 호출만 실패하고, 모델은 오류를 보고 하던 일을 잇는다.

- masc 는 Keeper·readiness·probe home 마다 `<HOME>/.gemini/config/hooks.json` 에 PreToolUse hook 을 건다. settings 를 쓰는 `prepare_native_tools`·`settings_json ()` 과 같은 자리에서 쓴다.
- hook 은 경로를 받는 내장 도구만 판정한다. 측정한 모델에게 보이는 것은 `read_file`·`write_file`·`edit_file` 이다(측정 9, 자기 보고).
  - 읽기는 schema 폴더와 그 자세의 workspace 안이어야 한다. 쓰기는 `Native_full` 의 workspace 안이어야 한다.
  - 경로는 realpath 로 풀고 경로 성분 단위로 비교한다. 문자열 접두어로 비교하지 않는다.
  - 밖이면 `deny` 를 낸다. 안이면 판정을 내지 않는다. 허가는 settings 가 한다.
- hook 은 허가하지 않는다. hook `allow` 가 settings deny 를 이기지 못하는 것(측정 5a)만 확인했다. Ask 를 건너뛰는지는 모른다. 그래서 경로 없는 도구와 판정 밖 호출에는 결정을 내지 않는 출력을 쓴다. 그 출력 모양은 L3 에서 측정해 정한다.
- 입력이 계약 모양(`toolCall.name`, `toolCall.args`)이 아니거나 경로 도구인데 경로를 못 읽으면 `deny` 다.
- hook 이 실패하면 agy 는 그 도구를 막는다(측정 5c). 고장은 닫히는 쪽이다.
- 이 hook 은 보안 경계다. 구현 층에 `//HIGH-RISK-UNREVIEWED` 를 달고 사람 리뷰를 받는다.
- hook 이 덮지 않는 Ask 는 남는다. `Native_full` 에서 sandbox 밖으로 나가려는 명령과 agy 가 나중에 더할 동작이다. 그런 실행은 #48773 이 `Actions_denied` 로 실패시킨다.

## 3. 바뀌는 것

- 모델이 도구를 처음 쓸 때 schema 를 한 번 읽는다. 대화를 이어 가면(`--conversation`) 읽은 schema 가 맥락에 남는다.
- 모든 masc 호출이 `call_mcp_tool` 을 거친다. `Runtime_antigravity_protocol` 은 이를 `Mcp_wrapper` 로 분류한다. masc 원장의 도구 이름은 bridge 의 `tools/call` 에서 오니 그대로다.
- schema 읽기는 `Built_in` native 단계다. `Native_none`·`Native_read` 에서 `observe_native_effect_unavailable`(`keeper_antigravity_runtime.ml:482`)은 아무것도 하지 않는다. `Native_full` 에서는 masc 도구만 쓴 턴도 효과를 "관측 불가" 로 판정한다. 지금도 `Native_full` 은 모든 내장 단계를 그렇게 판정하니 새 규칙을 더하지 않는다.
- 10 KB 넘는 결과는 agy 가 파일로 빼고, 모델이 그 파일을 한 번 더 읽는다(측정 8a). masc 결과 한도(16,384 B, `common.ml:214`)는 그대로 둔다.
- 허용 밖 경로 읽기는 모든 자세에서 그 호출만 실패한다(2.3). 지금은 `Native_read` 에서 턴이 끝나고(1.4), `Native_none` 에서만 이어진다.
- 모든 `read_file`·`write_file`·`edit_file` 호출마다 hook 실행 파일이 한 번 돈다.
- 첫 요청이 작아진다. 입력 토큰과 캐시 읽기 토큰을 더하면 eager 116개일 때 50,188(측정 2), 지연 206개일 때 13,876–14,204(측정 4b·4d)다. 같은 모델로 한 번씩 쟀다.

## 4. 하지 않는 것

- eager 예산 숫자를 masc 에 두지 않는다. agy 문서에 없는 내부 값이고 버전마다 바뀔 수 있다.
- `_meta: {"antigravity/alwaysLoad": true}` 를 쓰지 않는다. 예산을 넘지 못한다(측정 3).
- hook 으로 허가하지 않는다(2.3). 허가는 settings 만 한다.
- `--dangerously-skip-permissions` 나 `--mode auto` 로 Ask 를 없애지 않는다. 앞의 것은 모든 동작을 허가하고, 뒤의 것도 작업 폴더 밖 읽기는 묻는다(agy permissions 문서).
- masc 결과 한도를 바꾸지 않는다(3).
- Keeper 프롬프트에 도구 찾는 법을 적지 않는다. agy 가 지연 목록과 안내문을 직접 싣는다(측정 4b).
- 도구 목록을 줄이는 일은 이 RFC 몫이 아니다(RFC-0451).

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC 와 근거 | 리뷰 |
| L2 | settings 표(2.2) | 자세별 settings JSON 시험(allow·deny 경로, `read_file(*)` 없음). 일회용 HOME 에서 schema 읽힘·설정 폴더 거절·토큰 경로 거절 실측 |
| L3 | hook(2.3)과 `hooks.json` 게시 | hook 판정 시험(허용 루트 안·밖, symlink 탈출, 계약 밖 입력, 경로 없는 도구). 일회용 HOME 에서 결정 없는 출력의 모양, 허용 밖 읽기 뒤 턴이 이어지는지, `write_file`·`edit_file` 의 경로 인자 이름 실측 |
| L4 | eager 제거(2.1), readiness·probe 를 지연 길로 | type-check. readiness 가 `call_mcp_tool` 로 통과 |
| L5 | 실제 Keeper 턴 확인 | msx-retro-mania antigravity 턴에서 `masc_dos_screen`·`masc_dos_press` 가 bridge 에 도착 |

L2 를 먼저 낸다. L2 만 들어가도 eager 도구는 지금처럼 불린다. L4 가 L2 보다 먼저 들어가면 `Native_none` home 은 schema 를 못 읽는다. L3 는 L4 와 따로 들어가도 된다. #48773 은 이 스택과 관계없이 들어간다.

## 6. 열린 질문

1. hook 실행 파일. 서버 바이너리의 하위 명령으로 둘지, 작은 실행 파일을 따로 둘지. 어느 쪽이든 `hooks.json` 에는 절대 경로와 허용 루트를 인자로 적는다.
2. agy 자동 업데이트. 동작이 버전마다 바뀌는데 masc 는 버전을 고정하지 않는다. 턴마다 agy 버전을 raw trace 에 남길지, 업데이트를 끌 설정이 있는지 확인할지.
3. 토큰 파일. agy 는 keyring 으로도 로그인한다(측정 로그 `ChainedAuth: authenticated via keyring`). masc home 이 파일 없이 keychain 만으로 로그인할 수 있으면 appDataDir 에 평문 비밀이 남지 않는다. 그러면 2.2 의 토큰 deny 는 필요 없어진다.
