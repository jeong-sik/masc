---
rfc: "webmcp-dashboard-agent-surface"
title: "대시보드를 WebMCP 도구 표면으로 — 읽기 전용 MCP allowlist relay 와 CDP 소비 브리지"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: ["0100"]
---

# RFC: WebMCP Dashboard Agent Surface (webmcp-dashboard-agent-surface)

## 0. Summary

WebMCP 는 웹 페이지가 `document.modelContext.registerTool()` 로 자기 기능을 JSON schema
도구로 등록하고, 브라우저 안의 에이전트가 `getTools()` / `executeTool()` 로 그 도구를
호출하게 하는 W3C 초안이다 (Chrome 149–156 origin trial). 이 RFC 는 두 가지를 실험
lane 으로 도입한다.

1. **Inbound (provider)** — 대시보드가 masc MCP 카탈로그(tools/list)에서 읽기 전용
   닫힌 allowlist 8종을 그대로 `document.modelContext` 에 relay 한다. 설명과
   inputSchema 는 서버 카탈로그를 재사용하므로 WebMCP 투영이 MCP 표면에서 표류할 수
   없다. 브라우저 상주 에이전트(향후 Gemini-in-Chrome, Claude-in-Chrome 등)가 DOM
   자동화 없이 masc 를 읽는 통로다.
2. **Outbound (consumer)** — CDP 로 headed Chrome 을 몰아 페이지의 WebMCP 도구를
   호출하는 브리지(`dashboard/scripts/webmcp-bridge.mjs`). 첫 표적은 대시보드 자신이라
   외부 사이트 채택 없이도 파이프라인 전체가 검증된다:
   `bridge → CDP → executeTool → dashboard MCP relay → masc 서버`.

2026-08-29 실측: Chrome 151 + `--enable-features=WebMCP` 에서 8개 도구 등록,
`masc_status` 5,414 bytes / `masc_tasks` 31,350 bytes 왕복, `loop-check: ok`.

## 1. 왜 지금 하는가 (그리고 왜 이것만 하는가)

- masc 의 keeper 는 CLI 런타임이고 이미 진짜 MCP 서버를 쓴다. masc 조작에 WebMCP 가
  주는 신규 가치는 **브라우저 상주 에이전트의 유입 통로** 하나뿐이다.
- 2026-07 기준 WebMCP 실사이트 채택과 메인스트림 소비 에이전트는 모두 사실상 0 이다.
  따라서 outbound 를 외부 사이트용 keeper lane 으로 만드는 것은 지금은 표적이 없다.
  브리지는 수동 하네스로만 두고, keeper lane 승격은 §5 의 트리거 조건 이후 별도
  RFC 로 다룬다.
- 그럼에도 지금 붙이는 이유: 어댑터가 한 파일이고(코어 무접촉), 대시보드는 이미
  `callMcpTool` / `listAllMcpTools` 를 갖고 있어 relay 비용이 낮으며, 스펙 open issue
  (tool progress, skills abstraction, service worker discovery)가 masc 가 서버 측에서
  이미 푼 문제들이라 선점·피드백 가치가 있다.

## 2. 설계

### 2.1 Provider — `dashboard/src/api/webmcp.ts`

- `WEBMCP_READONLY_TOOLS`: 닫힌 allowlist (masc_status, masc_tasks, masc_task_history,
  masc_keeper_list, masc_goal_list, masc_board_search, masc_messages,
  masc_schedule_list). 여기에 이름을 추가하는 것이 곧 표면 결정이다. 변경(mutating)
  도구는 승인 UX 설계 전까지 등록하지 않는다.
- `installWebmcpAgentSurface(context, deps)`: tools/list 로 카탈로그를 받아
  allowlist ∩ 카탈로그만 등록. allowlist 에 있는데 카탈로그에 없는 이름은 silent
  하게 버리지 않고 `missing` 으로 보고한다 (main.ts 가 console.warn).
- feature detect: `document.modelContext` 에 `registerTool` 함수가 있을 때만 동작.
  polyfill 없음, deprecated 된 `navigator.modelContext` fallback 없음. 표면이 없으면
  전체가 no-op 이다.
- 인증: 기존 `callMcpTool` 경로를 그대로 탄다. 페이지가 가진 권한(bearer/dev token,
  actor 바인딩, 403 차단, dev token 복구) 이상도 이하도 아니다. WebMCP 기본
  노출 범위는 same-origin (`exposedTo` 미사용) 이다.

### 2.2 Consumer 브리지 — `dashboard/scripts/webmcp-bridge.mjs`

- node 22+ 단일 파일, 의존성 없음 (global fetch/WebSocket).
- `list` / `call <tool> [jsonArgs]` / `loop-check` 서브커맨드.
- Chrome 151 실측 계약을 따른다: `executeTool(RegisteredTool 객체, JSON 문자열 인자)`
  → JSON 문자열 결과. 이름 문자열이나 객체 인자는 TypeError/UnknownError 로 거절된다.
- `loop-check` 는 결정론적 판정만 한다: 표면 존재, `masc_status` 등록 여부,
  status/tasks 왕복 텍스트 비어있지 않음. 실패는 exit 3.
- CI 미편입: WebMCP 는 headless 미지원이고 masc CI 는 aarch64-linux 다. 수동
  런북(스크립트 헤더에 기재)으로만 돈다. vitest 단위 테스트(`webmcp.test.ts`)가
  CI 가능한 부분(allowlist 교차, relay, 실패 전파)을 커버한다.

## 3. 경계와 비목표

- masc 코어(OCaml)는 이 변경을 모른다. 계약·Gate·store 어디에도 WebMCP 의존이 없다.
- origin trial 이 끝나고 API 가 바뀌면 어댑터 한 파일과 브리지만 버리면 된다
  (롤백 = 파일 삭제 + main.ts 배선 제거).
- 변경 도구 노출, tunnel origin(masc.crying.pictures) origin-trial 토큰 등록,
  keeper 용 외부 사이트 소비 lane 은 이 RFC 범위 밖이다.

## 4. 검증

- 단위: `dashboard/src/api/webmcp.test.ts` 8건 green (allowlist ∩ 카탈로그, 스키마
  보존, relay, 실패 전파, missing 보고, mutating 이름 부재).
- 통합(수동): dev 서버 + flagged Chrome 에서 `webmcp-bridge.mjs loop-check` ok
  (2026-08-29, Chrome 151.0.7922.174).
- 플랫폼 근거: `~/me/memory/procedural-memory/2026-08-29-webmcp-status-evidence-record.md`.

## 5. 재평가 트리거 (outbound 승격 조건)

다음 중 하나가 확인되면 keeper 소비 lane RFC 를 새로 쓴다.

1. I/O 2026 발표 참여사(Expedia, Shopify, Target 등 9곳) 중 실배포 확인 1곳 이상.
2. Gemini-in-Chrome 또는 Claude-in-Chrome 이 WebMCP 도구 소비를 실제로 시작.
3. origin trial 종료 후 표준 궤도(브라우저 2개째 구현 착수) 진입.
