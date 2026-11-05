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
- 서버 쪽 도구 목록은 온전했다. 같은 Keeper 의 glm 턴은 `masc_dos_screen` 을 정상 호출했다.
- 원인은 agy 1.5.1 이다. masc 는 도구 206개(약 267 KB)를 모두 `tools.<이름>.eager` 로 넘긴다. agy 는 작은 도구부터 약 62 KB 까지만 등록한다. 나머지는 지연 목록에도 넣지 않고 말없이 버린다. 측정은 [근거](../evidence/2026-11-05-antigravity-mcp-tool-budget/README.md)에 있다.
- 제안은 셋이다.
  1. masc 는 antigravity 에 eager 표시를 하지 않는다. agy 가 모든 도구를 지연 목록에 싣고, 모델이 거기서 찾는다.
  2. 지연 도구의 schema 파일만 읽을 수 있게 연다. 경로 판정은 masc 가 쓰는 PreToolUse hook 이 한다.
  3. antigravity 의 masc 결과 한도를 agy 의 지연 결과 inline 한도에 맞춘다. 넘는 결과는 지금처럼 masc blob 으로 간다.

## 1. 지금

### 1.1 masc 가 넘기는 것

`keeper_antigravity_runtime.ml:118` 의 `eager_tool_names` 는 턴의 모든 도구 이름을 돌려준다. `Runtime_official_client_mcp_http.mcp_config_json`(`runtime_official_client_mcp_http.ml:105`)은 그 이름마다 `{"eager": true}` 를 적는다. 주석의 이유는 이렇다. eager 가 아닌 도구는 schema 파일을 읽어야 부를 수 있다. masc home 은 `read_file(*)` 를 막는다. 그래서 그런 도구는 schema 없이 불린다.

이 판단은 agy 1.2.9 에서 측정했다(2026-09-24, `runtime_official_client_mcp_http.mli` 의 `mcp_config_json` 주석).

### 1.2 agy 1.5.1 이 하는 것

| 측정 | 결과 |
| --- | --- |
| 작은 도구 220개(45 KB) 모두 eager | 220개 모두 등록 |
| 실제 206개 모두 eager | 116개만 등록. 크기 순위 113위(888 B)까지 남고 129위(1,066 B)부터 빠짐 |
| 같은 206개에 `_meta: {"antigravity/alwaysLoad": true}` | 같은 116개 |
| eager 표시 없음 | 206개 모두 지연 목록에 이름으로 오름. `call_mcp_tool` 이 서버에 도착 |

masc 가 "항상 싣는다" 고 선언한 도구(`defer_loading` 없음)만 해도 64개, 82,517 B 다. 선언을 따라 eager 를 고르는 것으로는 예산 안에 들지 않는다.

예산 값은 agy 문서에 없다. 버린 도구는 agy 로그에도 남지 않는다. agy 는 실행할 때마다 스스로 업데이트한다(`auto_updater.go: Spawned background update process`). 1.5.1 이전에도 이 예산이 있었는지는 모른다.

### 1.3 지연 로딩을 막는 것

agy 의 지연 목록에는 이름만 있다. 인자는 `<appDataDir>/mcp/<server>/<tool>.json` 을 읽어 안다. 여기서 appDataDir 은 `<HOME>/.gemini/antigravity-cli` 다.

- deny `read_file(*)` 는 allow `read_file(<schema 폴더>)` 를 이긴다(측정 4c).
- PreToolUse hook 의 `allow` 도 settings deny 를 이기지 못한다(측정 5a).
- deny 를 빼면 schema 는 읽힌다. 그런데 appDataDir 안의 다른 파일도 읽힌다(측정 4d). 그 폴더에는 masc 가 넣은 `antigravity-oauth-token` 이 있다.
- 10 KB 넘는 지연 결과는 `<appDataDir>/brain/<대화>/.system_generated/steps/<n>/output.txt` 로 빠진다(측정 5b). 읽으려면 그 경로도 열어야 한다.

## 2. 제안

### 2.1 eager 표시를 없앤다

- `eager_tool_names` 와 `mcp_config_json ~eager_tools` 를 지운다. Keeper 턴의 `mcp_config.json` 에는 `tools` 맵을 쓰지 않는다.
- 무엇을 목록에 올릴지는 지금처럼 bundle 이 정한다(RFC-0451 의 경계). 언제 schema 를 실을지는 agy 가 정한다. RFC-0451 §0 이 적은 "스키마를 언제 싣는지는 클라이언트가 스스로 한다" 가 이 레인에서도 참이 된다.
- `defer_loading` 은 지금처럼 Agent Core 레인만 읽는다(`tool_loading_declarations.mli:29`).
- readiness 검사(`runtime_verification_antigravity.ml:28`)와 capability probe(`keeper_capability_probe.ml:669`)는 도구 하나만 eager 로 넘긴다. 예산과 관계없으니 그대로 둔다.

### 2.2 schema 읽기만 연다

settings(`native_settings_json`, `runtime_antigravity_home.ml:231`)를 이렇게 바꾼다.

| 자세 | allow | deny |
| --- | --- | --- |
| `Native_none` | `mcp(masc/*)`, `read_file(<schema 폴더>)` | `read_file(<oauth 파일>)`, `write_file(*)`, `command(*)`, `read_url(*)`, `execute_url(*)` |
| `Native_read` | 위 + `read_file(<workspace>)` | `read_file(<oauth 파일>)`, `write_file(*)`, `command(*)`, `read_url(*)`, `execute_url(*)` |
| `Native_full` | 위 + `write_file(<workspace>)` | `read_file(<oauth 파일>)`, `read_url(*)`, `execute_url(*)` |

- `read_file(*)` 전체 거부는 뺀다. 남기면 schema 를 읽을 방법이 없다(1.3).
- oauth 파일은 정확한 경로로 거부한다. settings 의 `read_file(...)` 이 도구 이름이 아니라 읽기 동작의 권한이라면, agy 가 나중에 읽기 도구를 더해도 이 거부가 걸린다. 이 점과, 정확한 파일 deny 가 appDataDir 의 암묵 허용을 이기는지는 L2 에서 측정한다.
- 경로 판정은 masc 가 쓰는 PreToolUse hook 이 한다. `<HOME>/.gemini/config/hooks.json` 에 matcher `read_file` 로 건다.
  - 허용 루트 안의 경로면 `allow`, 아니면 `deny` 를 낸다. 허용 루트는 schema 폴더와 그 자세의 workspace 다.
  - 경로는 realpath 로 풀고 경로 성분 단위로 비교한다. 문자열 접두어로 비교하지 않는다.
  - 입력이 계약 모양(`toolCall.name`, `toolCall.args.Path`)이 아니면 `deny` 다.
  - hook 이 실패하면 agy 는 그 도구를 막는다(측정 5c). 고장은 닫히는 쪽이다.
- appDataDir 과 workspace 밖의 경로는 hook 이 없어도 거절됐다(측정 4d). hook 이 새로 막는 것은 그 둘 안의 허용 밖 경로다.
- 이 코드는 보안 경계다. 구현 층에 `//HIGH-RISK-UNREVIEWED` 를 달고 사람 리뷰를 받는다.

### 2.3 결과 한도를 agy 지연 inline 한도에 맞춘다

- antigravity 의 masc 결과 한도는 16,384 B 다(`Runtime_execution.tool_result_inline_ceiling_bytes` → `Common.max_tool_result_wire_bytes`, `common.ml:214`). 기본 projection(`Store_above`)인 도구는 이보다 큰 결과를 bundle 이 masc blob 참조로 바꾼다(`keeper_tools_agent_core_bundle.ml:121` 의 `threshold_bytes`).
- 자기 projection 을 고른 도구(`Inline_up_to`, 지금은 `keeper.artifact.read`)는 자기 한도를 따른다. 그 한도가 agy 의 지연 inline 한도보다 크면 그 결과도 brain 폴더로 빠진다. L3 에서 그런 도구가 있는지 보고, 있으면 그 도구의 쪽 크기를 이 레인에서 agy 한도 아래로 둔다.
- agy changelog 1.4.7 은 지연 도구 결과를 10 KB 까지 바로 돌려준다고 적는다. 그 사이(10–16 KB) 결과는 agy 가 brain 폴더 파일로 뺀다.
- antigravity 한도를 agy 의 그 한도로 낮춘다. 그러면 큰 결과는 모두 masc blob 으로 가고, hook 은 brain 폴더를 열지 않는다.
- 정확한 경계는 L3 에서 크기를 바꿔 가며 측정하고, 상수 옆에 측정값과 agy 버전을 적는다.

## 3. 바뀌는 것

- 모델이 도구를 처음 쓸 때 schema 를 한 번 읽는다. 대화를 이어 가면(`--conversation`) 읽은 schema 가 맥락에 남는다.
- 모든 masc 호출이 `call_mcp_tool` 을 거친다. `Runtime_antigravity_protocol` 은 이미 이를 `Mcp_wrapper` 로 분류한다. masc 원장의 도구 이름은 bridge 의 `tools/call` 에서 오니 그대로다.
- schema `read_file` 단계는 native 도구 단계로 보인다. `Native_none`·`Native_read` 에서 `observe_native_effect_unavailable`(`keeper_antigravity_runtime.ml:482`)은 아무것도 하지 않으니 턴의 효과 판정은 바뀌지 않는다.
- 요청 크기가 준다. agy 가 보고한 입력 토큰은 eager 116개일 때 50,188, 지연 206개일 때 8,260–11,326 이다(같은 모델, 한 번씩). 요청마다 나눠 보지는 않았다.

## 4. 하지 않는 것

- eager 예산 숫자를 masc 에 두지 않는다. agy 문서에 없는 내부 값이고 버전마다 바뀔 수 있다.
- `_meta: {"antigravity/alwaysLoad": true}` 를 쓰지 않는다. 예산을 넘지 못한다(측정 3).
- agy 의 brain 폴더 읽기를 열지 않는다(2.3).
- Keeper 프롬프트에 도구 찾는 법을 적지 않는다. agy 가 지연 목록과 안내문을 직접 싣는다(측정 4b).
- 도구 목록을 줄이는 일은 이 RFC 몫이 아니다(RFC-0451).

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC 와 근거 | 리뷰 |
| L2 | settings 표(2.2)와 PreToolUse hook 프로그램, `hooks.json` 게시 | hook 판정 시험(허용 루트 안·밖, symlink 탈출, 계약 밖 입력, oauth 경로). 일회용 HOME 에서 schema 읽힘·oauth 거절 실측 |
| L3 | `eager_tool_names` 제거, antigravity 결과 한도(2.3) | type-check. 한도 경계 실측 |
| L4 | 실제 Keeper 턴 확인 | msx-retro-mania antigravity 턴에서 `masc_dos_screen`·`masc_dos_press` 가 bridge 에 도착 |

## 6. 열린 질문

1. hook 실행 파일. 서버 바이너리의 하위 명령으로 둘지, 작은 실행 파일을 따로 둘지. 어느 쪽이든 `hooks.json` 에는 절대 경로와 허용 루트를 인자로 적는다.
2. agy 자동 업데이트. 동작이 버전마다 바뀌는데 masc 는 버전을 고정하지 않는다. 턴마다 agy 버전을 raw trace 에 남길지, 업데이트를 끌 설정이 있는지 확인할지.
3. oauth 파일. agy 는 keyring 으로도 로그인한다(측정 로그 `ChainedAuth: authenticated via keyring`). masc home 이 파일 없이 keychain 만으로 로그인할 수 있으면 appDataDir 에 평문 비밀이 남지 않는다. 그러면 2.2 의 정확한 경로 deny 는 필요 없어진다.
