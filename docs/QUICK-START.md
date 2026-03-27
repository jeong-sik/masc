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

curl -sS "http://127.0.0.1:${PORT}/mcp" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
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

이 호출은 room 설정, agent join, task 생성, claim, `current_task` 바인딩까지 한 번에 처리한다.

수동 제어가 필요하면:

```text
masc_set_room(path="/your/project")
masc_join()
masc_add_task(title="My task")
masc_claim_next()
# masc_claim_next auto-binds current_task in current builds
# masc_plan_set_task(task_id="task-001")  # only if current_task is still missing
```

## 5. Tool Surface

`tools/list`는 기본 공개 surface만 보여준다. hidden/internal tool도 `tools/call`로는 호출 가능하다.

```bash
# Add specific tools to the public surface
MASC_PUBLIC_TOOLS_EXTRA=masc_goal_upsert,masc_pause

# Restore the full inventory (debugging)
MASC_FULL_SURFACE=1

# Query all tools via API
{"method": "tools/list", "params": {"include_hidden": true}}
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

Keeper를 시작하려면:

```text
masc_keeper_up(name: "sangsu")
```

전제조건:
- `config/personas/<name>/profile.json`이 존재해야 한다 (또는 `config/keepers/<name>.toml`)
- 서버가 **repo root**에서 실행되어야 `.masc/` 디렉토리에 접근 가능. worktree에서 실행하면 keeper 상태를 찾지 못한다. 필요 시 `--base-path`를 repo root로 지정.
- repo-managed config root는 `MASC_CONFIG_DIR` 우선이며, 없으면 실행 파일 기준 `config/` 자동 탐색을 사용한다.
- `MASC_PERSONAS_DIR` 환경변수로 커스텀 persona 경로 지정 가능.

상세: `docs/KEEPER-USER-MANUAL.md`

## References

- `docs/COMMAND-PLANE-RUNBOOK.md` — CPv2 benchmark/swarm path
- `docs/BENCHMARK-RUNBOOK.md` — single-agent vs swarm recipes
- `docs/INTEGRATED-BENCHMARK-RUNBOOK.md` — control/search/local64 wrapper
- `docs/SUPERVISOR-MODE.md` — supervised team session path
- `docs/SWARM-DELIVERY-RUNBOOK.md` — implementation delivery path
- `README.md` — canonical public overview
