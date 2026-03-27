# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.x-orange.svg)](https://ocaml.org/)

`masc-mcp`는 공유 작업공간에서 여러 AI 에이전트를 조율하기 위한 OCaml 5.x + Eio 기반 MCP 서버입니다.

- 로컬 `/mcp`는 신뢰된 환경에서 쓰는 전체 room/task/board/keeper surface입니다.
- `/mcp/operator`는 원격 감독용으로 줄여 둔 remote-safe surface입니다.
- 대시보드는 운영 UI이고, canonical write/control path는 여전히 MCP 도구입니다.

이 저장소는 주로 로컬 또는 신뢰된 네트워크 환경을 기준으로 운영합니다. 공개 surface와 workflow는 자주 바뀔 수 있으므로, 실제 운영 경로는 `docs/` 아래 runbook을 SSOT로 봅니다.

## 빠른 시작

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

opam install . --deps-only
dune build --root .

./start-masc-mcp.sh --http
PORT="$(./start-masc-mcp.sh --print-port)"
curl "http://127.0.0.1:${PORT}/health"
```

기본값:

- repo root checkout HTTP / MCP port: `8935`
- git worktree checkout HTTP / MCP port: `9100-9999` 범위에서 checkout path 기준으로 자동 파생
- 기본 bind host: `127.0.0.1`
- repo-managed config root: `MASC_CONFIG_DIR` 우선, 없으면 실행 파일 기준 `config/` 자동 탐색

메모:

- 현재 checkout의 기본 포트 확인: `./start-masc-mcp.sh --print-port`
- worktree에서 `--port`를 생략하면 script가 worktree별 기본 포트를 자동 선택한다.
- 고정 포트가 필요하면 `MASC_MCP_PORT=94xx` 또는 `--port 94xx`로 덮어쓴다.
- `--print-port`는 현재 checkout의 기본 포트 조회용이다. 서버 시작은 보통 `./start-masc-mcp.sh --http`로 충분하다.

`0.0.0.0` 같은 non-loopback 주소에 바인드할 때는 auth 설정을 먼저 맞춘 뒤 원격 노출 경로로 취급하세요. 자세한 내용은 `docs/REMOTE-MCP-OPERATOR.md`, `docs/spec/09-server-transport.md`를 봅니다.

## MCP 클라이언트 설정

로컬 full-surface MCP 연결 예시:

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

메모:

- 일반적인 로컬 사용은 `/mcp`를 기준으로 합니다.
- 원격 감독은 bearer token 기반 `/mcp/operator`와 4-tool operator profile을 사용합니다.
- HTTP / stdio 템플릿 전체는 `docs/MCP-TEMPLATE.md`에 정리돼 있습니다.

## 기본 진입 경로

새 room을 가장 짧게 시작하는 방법은 다음입니다:

```text
masc_start(path="/your/project", task_title="My first task")
```

현재 front-door 기준 canonical path:

- Room / task hygiene:
  `masc_set_room` -> `masc_join` -> `masc_status` -> `masc_transition(action="claim")` or `masc_claim_next` -> `masc_plan_set_task` when needed -> `masc_heartbeat`
- CPv2 direct:
  `masc_unit_define` -> `masc_operation_start` -> `masc_dispatch_tick`
- Supervisor path:
  `/mcp/operator` with `masc_operator_snapshot`, `masc_operator_digest`, `masc_operator_action`, `masc_operator_confirm`

모델용 압축 안내는 `llms.txt`, `llms-full.txt`를 봅니다.

## 대시보드

자주 쓰는 대시보드 진입점:

- 모니터링: `http://127.0.0.1:<PORT>/dashboard#monitoring?section=sessions`
- 운영 액션: `http://127.0.0.1:<PORT>/dashboard#command?section=intervene`
- 숨겨진 실험용 war room: `http://127.0.0.1:<PORT>/dashboard#command?section=warroom`

메모:

- 대시보드는 read/operate UI이고, canonical write/control path는 MCP입니다.
- `start-masc-mcp.sh`는 `npm`이 있을 때 dashboard SPA를 자동으로 빌드합니다.
- dev server를 따로 띄울 때는 `PORT="$(./start-masc-mcp.sh --print-port)"` 후 `cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" npm run dev`를 사용하세요.
- 수동 재빌드가 필요하면 `cd dashboard && npm run build`를 실행하세요.

## 검증

```bash
make test
make ci
```

CI와 비슷한 heartbeat/timeout 로그를 붙여 로컬 재현하려면 다음을 사용합니다:

```bash
CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
  scripts/ci-run-tests.sh "opam exec -- dune test --root ."
```

## 전송/인증 메모

- `POST /mcp`는 `Accept: application/json, text/event-stream`를 기대합니다.
- legacy `/sse`, `/messages` endpoint는 deprecated 상태입니다.
- 서버를 `0.0.0.0`, `::` 같은 non-loopback 주소에 바인드하면 MCP route에 strict auth가 적용됩니다.
- `/mcp/operator`는 bearer token 전용이며, 전체 로컬 tool inventory가 아니라 원격 감독용 surface입니다.

## 문서 맵

- `docs/QUICK-START.md` — 설치, health check, 첫 workflow
- `docs/MCP-TEMPLATE.md` — HTTP / stdio MCP 설정 템플릿
- `docs/COMMAND-PLANE-RUNBOOK.md` — benchmark / swarm 제어용 canonical CPv2 direct path
- `docs/BENCHMARK-RUNBOOK.md` — single-agent vs swarm 비교 레시피
- `docs/SUPERVISOR-MODE.md` — supervised team-session / operator workflow
- `docs/REMOTE-MCP-OPERATOR.md` — remote-safe operator endpoint와 confirm 모델
- `docs/KEEPER-USER-MANUAL.md` — keeper lifecycle, dashboard 필드, troubleshooting
- `docs/spec/SPEC-INDEX.md` — 현재 spec suite 진입점
- `llms.txt` / `llms-full.txt` — LLM용 축약 front door

historical/archived 문서는 저장소 안에 남아 있지만, front-door SSOT는 위 quick start, runbook, `docs/spec/` spec suite입니다.
