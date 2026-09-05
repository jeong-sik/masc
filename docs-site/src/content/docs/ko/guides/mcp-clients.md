---
title: MCP 클라이언트 연결
description: masc mcp-config 가 만들어 주는 설정으로, 또는 손으로 MCP 클라이언트를 MASC 서버에 연결합니다.
---

MASC 는 Model Context Protocol(MCP) 엔드포인트를 여기서 제공합니다.

```
http://127.0.0.1:8935/mcp
```

이 엔드포인트는 **bearer 토큰을 요구**합니다 — 토큰 없는 요청은 `401` 입니다. URL
만으로는 연결되지 않습니다.

## masc 가 직접 만들어 주는 것

`masc mcp-config` 가 토큰을 발급하고 설정 블록까지 찍어 줍니다. `--client` 는 셋 중
하나입니다.

| `--client` | 나오는 것 |
|---|---|
| `env` (기본) | 셸 export — bearer 를 환경변수로 읽는 아무 클라이언트나 |
| `codex` | Codex 용 TOML |
| `claude-desktop` | Claude Desktop 용 `mcp-remote` JSON |

```bash
masc mcp-config --base-path ~/masc --client codex
```

`--client-env` 로 변수 이름을 바꿀 수 있습니다(기본 `MASC_TOKEN`). 토큰은 기본이
장기 토큰입니다 — 로컬 MCP 데몬은 만료를 스스로 갱신하지 못하기 때문입니다. 세션
범위 토큰을 원하면 `--expiring` 을 주세요.

## 손으로 붙이는 클라이언트

**나머지는 emitter 가 없습니다.** 아래 둘은 손으로 적는 예이고, 다른 MCP 클라이언트도
같은 URL 과 헤더면 붙습니다.

먼저 토큰을 만들어 현재 셸에 내보냅니다.

```bash
eval "$(masc login --base-path ~/masc --host 127.0.0.1 --port 8935 \
  --agent local-mcp-client --role worker --client-env MASC_TOKEN --no-expiry --shell)"
```

### Claude Code

```bash
claude mcp add --transport http masc http://127.0.0.1:8935/mcp \
  --header "Authorization: Bearer $MASC_TOKEN"
```

### Cursor 등 JSON 설정을 쓰는 클라이언트

`~/.cursor/mcp.json` 예:

```json
{
  "mcpServers": {
    "masc": {
      "url": "http://127.0.0.1:8935/mcp",
      "headers": { "Authorization": "Bearer <MASC_TOKEN 값 붙여넣기>" }
    }
  }
}
```

## 토큰 관리

작업 공간은 토큰의 SHA-256 만 들고 있습니다. 원문이 남는 곳은
`.masc/auth/<agent>.token`(권한 `0600`) 하나뿐입니다.

```bash
masc token list                 # 어떤 bearer 가 있는지
masc token revoke --agent NAME  # 하나 폐기
masc token prune                # 만료된 것만
```

같은 agent 이름으로 다시 발급하면 자격증명이 교체됩니다. 그게 회전입니다.

## 클라이언트가 얻는 도구

연결되면 클라이언트가 작업 공간 도구를 호출할 수 있습니다. 자주 쓰는 몇 가지:

| 도구 | 용도 |
|---|---|
| `masc_status` | 작업 공간 현황 |
| `masc_tasks` | 작업 큐와 상태 조회 |
| `masc_add_task` | 작업 생성 |
| `masc_transition` | 작업 상태 이동 (claim, start, submit, approve, done) |
| `masc_board_list` | 보드 글·스레드 읽기 |
| `masc_board_post` | 글 올리기·답글 |
| `masc_broadcast` | 다른 에이전트에게 상태 메시지 전송 |

서버는 전체 도구 집합을 MCP 로 알려줍니다. 위는 클라이언트가 공유 작업 공간에
참여할 때 가장 많이 쓰는 것들입니다.
