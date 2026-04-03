# MASC Quick Start

이 문서는 `처음 띄우고`, `연결하고`, `첫 작업을 시작하는` 데 필요한 최소 절차만 모은다.
세부 운영 규칙은 runbook 문서를 SSOT로 본다.

## 1. 설치와 서버 시작

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

opam install . --deps-only
dune build --root .

./start-masc-mcp.sh --http
PORT="$(./start-masc-mcp.sh --print-port)"  # query the effective port for this checkout
```

기본 포트:

- repo root checkout: `8935`
- git worktree checkout: `9100-9999` 범위에서 checkout path 기준 자동 파생
- 기본 bind host: `127.0.0.1`

메모:

- 현재 checkout의 기본 포트 확인: `./start-masc-mcp.sh --print-port`
- worktree에서 `--port`를 생략하면 script가 worktree별 기본 포트를 자동 선택한다.
- `--print-port`는 현재 checkout의 기본 포트 조회용이다. 서버 시작은 보통 `./start-masc-mcp.sh --http`로 충분하다.

## 2. Health Check

```bash
curl "http://127.0.0.1:${PORT}/health"

INIT_HEADERS="$(mktemp)"
curl -sS -D "$INIT_HEADERS" "http://127.0.0.1:${PORT}/mcp" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual-check","version":"0.1"}}}'

SESSION_ID="$(awk -F': ' 'tolower($1)=="mcp-session-id"{gsub("\r", "", $2); print $2}' "$INIT_HEADERS")"
curl -sS "http://127.0.0.1:${PORT}/mcp" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
rm -f "$INIT_HEADERS"
```

## 3. MCP 연결

HTTP가 canonical public path다. 템플릿 전체는 `docs/MCP-TEMPLATE.md`를 본다.

```json
{
  "mcpServers": {
    "masc": {
      "type": "http",
      "url": "http://127.0.0.1:8935/mcp"
    }
  }
}
```

worktree에서는 `8935` 대신 `./start-masc-mcp.sh --print-port` 출력값으로 바꾼다.

## 4. 첫 Workflow

가장 짧은 진입:

```text
masc_start(path="/your/project", task_title="My first task")
```

이 호출은 project scope 설정, default namespace join, task 생성, claim, `current_task` 바인딩까지 한 번에 처리한다.

수동 제어가 필요하면:

```text
masc_start(path="/your/project")
masc_join(agent_name="codex")
masc_status()
masc_add_task(title="My task")
masc_claim_next()
# masc_claim_next auto-binds current_task in current builds
# masc_plan_set_task(task_id="task-001")  # only if current_task is still missing
```

`masc_set_room(path=...)` 는 여전히 호출 가능하지만 compatibility alias 이고, project scope 만 고른다. 기본 온보딩은 `masc_start(...)` 를 쓴다.

## 5. Tool Surface

`tools/list`는 기본 공개 surface만 보여준다. hidden/internal tool도 `tools/call`로는 호출 가능하다.

```bash
# Add specific tools to the public surface
MASC_PUBLIC_TOOLS_EXTRA=masc_board_search,masc_pause

# Restore the full inventory (debugging)
MASC_FULL_SURFACE=1

# Query all tools via API after initialize
curl -sS "http://127.0.0.1:${PORT}/mcp" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"include_hidden":true}}'
```

Allowlist SSOT: `lib/tool_catalog.ml` > `public_mcp_tools`

## 6. Error Recovery

Failed tool calls include recovery hints automatically. Common patterns:

| Error | Recovery |
|-------|----------|
| "not initialized" | `masc_init` or `masc_start(path=...)` |
| "not joined" | `masc_join` or `masc_start(...)` |
| "no unclaimed tasks" | `masc_add_task(title="...")` |
| "task not found" | `masc_status` to see available tasks |

## 7. Keeper Bootstrap

Persona blueprint에서 keeper를 명시적으로 만들려면:

```text
masc_keeper_create_from_persona(persona_name: "sangsu")
```

이미 등록된 keeper를 다시 올리거나, template 기준으로 fresh 재생성하려면:

```text
masc_keeper_up(name: "sangsu")
```

전제조건:
- `PERSONAS_ROOT/<name>/profile.json`이 존재해야 한다 (또는 `CONFIG_ROOT/keepers/<name>.toml`)
- `PERSONAS_ROOT`는 `MASC_PERSONAS_DIR` 우선, 없으면 resolved `CONFIG_ROOT/personas`를 사용한다.
- 기본적으로 git repo root를 `MASC_BASE_PATH`로 자동 해석한다.
- `start-masc-mcp.sh`는 worktree에서 실행해도 위 규칙을 그대로 따른다.
- shared keeper 상태 대신 별도 `.masc/`를 쓰고 싶을 때만 `--base-path`를 명시적으로 덮어쓴다.
- repo-managed config root는 `MASC_CONFIG_DIR` 우선이며, 없으면 `~/.masc/config`를 먼저 보고, 없을 때만 repo `config/` 자동 탐색을 사용한다.
- `MASC_PERSONAS_DIR` 환경변수로 persona만 repo 밖 경로로 분리할 수 있다.

공유 config/persona를 repo 밖에 두고 실행하는 예시:

```bash
export MASC_CONFIG_DIR=/srv/masc/config
export MASC_PERSONAS_DIR=/srv/masc/personas
./start-masc-mcp.sh --http --port 8935 --base-path /srv/masc/runtime
```

상세: `docs/KEEPER-USER-MANUAL.md`

## References

- `docs/COMMAND-PLANE-RUNBOOK.md` — CPv2 benchmark/swarm path
- `docs/BENCHMARK-RUNBOOK.md` — single-agent vs swarm recipes
- `docs/INTEGRATED-BENCHMARK-RUNBOOK.md` — control/search/local64 wrapper
- `docs/SUPERVISOR-MODE.md` — supervised team session path
- `docs/SWARM-DELIVERY-RUNBOOK.md` — implementation delivery path
- `README.md` — canonical public overview
