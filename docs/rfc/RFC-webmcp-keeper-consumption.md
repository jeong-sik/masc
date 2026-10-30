---
rfc: "webmcp-keeper-consumption"
title: "keeper 의 WebMCP 소비 — Yolo Bash 브리지 lane(지금)과 typed 도구 모듈 lane(트리거 뒤)"
status: Active
created: 2026-08-29
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: ["webmcp-dashboard-agent-surface"]
---

# RFC: WebMCP Keeper Consumption (webmcp-keeper-consumption)

## 0. Summary

RFC-webmcp-dashboard-agent-surface 가 대시보드를 WebMCP provider 로 만들었다. 이 RFC 는
반대 방향 — **keeper 와 TUI 운영자가 WebMCP 도구를 소비하는 경로** — 를 두 lane 으로
나눈다.

- **Lane A (지금, 표면 추가 없음)**: Yolo keeper(`Native_full`)의 Bash 로
  `dashboard/scripts/webmcp-bridge.mjs` 를 부른다. 이미 머지된 CLI 가 그대로 keeper 의
  도구다. TUI 운영자도 같은 CLI 를 터미널에서 직접 쓴다.
- **Lane B (트리거 뒤, RFC 재검토)**: masc 도구 카탈로그에 `webmcp_list` /
  `webmcp_call` typed 도구 모듈을 추가해 일반 keeper 도 쓰게 한다. 승격 트리거는
  RFC-webmcp-dashboard-agent-surface §5 를 그대로 쓴다.

Lane B 를 지금 만들지 않는 이유가 이 문서의 절반이다.

## 1. 구조적 전제 (측정된 사실)

1. keeper 의 claude 런타임은 `--mcp-config` + `--strict-mcp-config` 로 **masc SDK
   서버 하나만** 마운트한다 (`lib/runtime/runtime_claude_code.ml:1177`). settings
   layer 도 비워진다. 외부 MCP 서버(예: 브리지를 stdio MCP 서버로 포장한 것)를
   keeper 옆에 끼우는 구성은 존재하지 않는다. keeper 에게 도구를 주는 정식 경로는
   masc 도구 카탈로그뿐이다.
2. `Native_full`(내장 도구 전체, Bash 포함)은 Yolo keeper 에만 허용된다
   (`runtime_claude_code.ml` command builder). 따라서 "코어 무접촉으로 keeper 가
   외부 CLI 를 쓴다" = Yolo keeper 한정이다.
3. WebMCP 는 headless Chrome 이 없다. 소비는 항상 headed Chrome + CDP 를 전제한다.
   Chrome 의 `--remote-debugging-port` 는 127.0.0.1 에 바인딩된다.
4. sandbox 경계: keeper 기본 프로필은 docker 다. macOS 에서 컨테이너는 호스트
   127.0.0.1 바인딩 포트(CDP 9222, vite 5173)에 닿지 못한다. 즉 **docker keeper 는
   Lane A 를 탈 수 없다**. Lane A 는 `local` 프로필
   (`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` fail-closed 해치) 또는 CDP 가 같은 네트워크
   네임스페이스에 있는 배치에서만 성립한다.
5. 브리지 계약 (Chrome 151 실측, 2026-08-29 evidence record):
   `executeTool(RegisteredTool 객체, JSON 문자열 인자)` → JSON 문자열 결과.

## 2. Lane A — Yolo Bash 브리지 (지금)

```
node dashboard/scripts/webmcp-bridge.mjs list       --page localhost:5173
node dashboard/scripts/webmcp-bridge.mjs call masc_status '{}' --page localhost:5173
node dashboard/scripts/webmcp-bridge.mjs loop-check --page localhost:5173
```

- 운영 전제 (keeper instructions 에 명시할 것):
  1. flagged Chrome 이 CDP 9222 로 떠 있다 (`--enable-features=WebMCP`).
  2. 표적 페이지가 열려 있다 (대시보드는 live 번들이 어댑터를 포함하기 전까지 dev
     서버 필요).
  3. 전제가 깨지면 브리지는 exit 2/3 으로 즉시 실패한다. 재시도 루프를 만들지
     않는다 — 전제 복구는 운영자 몫이다.
- 비용: 새 코드 0. 위험: Yolo keeper 에게만 열리는 경로라는 것 자체가 이 lane 의
  통제 장치다.
- TUI: TUI 는 터미널이므로 같은 CLI 를 직접 쓴다. TUI 안에 실행 표면을 새로 파지
  않는다 (Execute 폼 admission 전례 #29813→#31360).

## 3. Lane B — typed 도구 모듈 (구현됨)

처음에는 트리거 뒤로 미뤘으나 owner 결정(2026-08-29)으로 바로 구현했다.

구현된 모양:

- 도구 이름은 keeper 도구 matrix 의 접두사 계약(`keeper_*`)을 따라
  `keeper_webmcp_list` / `keeper_webmcp_call` 이다.
- 브리지 스크립트(`dashboard/scripts/webmcp-bridge.mjs`)는 dune rule 로 빌드 시
  바이너리에 임베드된다 (`lib/webmcp/`). 배포 바이너리가 repo 체크아웃이나 별도
  에셋에 의존하지 않는다 — 이 표면에서는 stale-asset 사고 계열이 성립하지 않는다.
- 실패는 전부 typed 다: 페이지/표면/도구 부재와 잘못된 인자는 결정론적 거절
  (`Workflow_rejection`), node 부재·CDP 다운·타임아웃은 `Dependency_unavailable`,
  브리지 자체 버그만 `Runtime_failure`.
- `keeper_webmcp_call` 실패는 `Effect_outcome_unknown` 을 실어 나른다 — 브리지가
  죽어도 페이지 도구는 이미 실행됐을 수 있다.
- 두 도구는 `execute`
  group 을 탄다 (외부 실행이라는 의미가 같다). `[keeper.tools] groups` 를 선언한
  keeper 는 `execute` 를 넣어야 받고, 선언이 없는 keeper 는 기본 전체 표면에
  포함된다 — 열한 번째 group 이나 per-tool gate 는 만들지 않았다.

- 도구 2종, 닫힌 계약:
  - `keeper_webmcp_list { page, cdp_port? }` → 페이지가 등록한 도구 목록 JSON
  - `keeper_webmcp_call { page, tool, args_json, cdp_port? }` → `{found, result}` JSON
- CDP WebSocket 클라이언트를 OCaml 로 새로 만들지 않고 node 브리지 subprocess 를
  탄다. CDP 엔드포인트 부재는 typed error 로 즉시 반환 — fallback, 재시도, 대체
  경로 없음.

원안의 "keeper row 명시적 opt-in (기본 미장착)" 은 구현하면서 버렸다. 당시
표면 의미론이 per-tool opt-in 을 제공하지 않고(그룹 선언이 없는 keeper 는 전체
표면), per-tool gate 를 새로 만드는 것은 게이트 추가 금지 원칙과 충돌한다. 대신
`execute` group 승차로 좁혔다. 노는 도구의 헛시도(#26057 계열)가 관측되면 그때
group 선언으로 좁히는 것이 운영 수단이다.

### 원래의 승격 트리거 (기록용)

owner 결정으로 트리거 전에 구현했지만, 외부 사이트 소비가 실제로 유의미해지는
시점의 신호로는 여전히 유효하다.

1. 발표 참여사(Expedia, Shopify, Target 등 9곳) 중 실배포 확인 1곳 이상
2. Gemini-in-Chrome 또는 Claude-in-Chrome 의 WebMCP 소비 개시
3. origin trial 종료 후 두 번째 브라우저 구현 착수

## 4. 비목표

- keeper 범용 브라우저 lane (DOM 자동화 포함) — 완전히 다른 규모의 설계다.
- masc 서버가 Chrome 프로세스를 소유/관리하는 구조 — 서버가 브라우저 수명에
  의존하는 경계 위반이다. Chrome 은 항상 운영자(또는 별도 sidecar)가 띄운다.
- 브리지의 CI 편입 — headless 부재 + aarch64-linux CI 라 수동 하네스 유지.

## 5. 검증 계획

- Lane A 실증: local 프로필 keeper 하나에 브리지 실행을 지시하고, keeper 의 Bash
  tool call 기록에서 `loop-check: ok` 를 확인한다. docker keeper 로는 §1-4 에 따라
  실패해야 정상이며, 그 실패도 기록한다 (경계 검증).
- Lane B 는 구현 시점에 도구 단위 테스트 + admission 테스트를 함께 낸다.
