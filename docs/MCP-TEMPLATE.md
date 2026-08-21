---
status: reference
last_verified: 2026-08-21
code_refs:
  - quickstart.sh
  - bin/main_eio.ml
  - lib/auth/auth_login.ml
  - lib/server/server_auth.ml
---

# MCP 클라이언트 연결

MASC의 공개 MCP 경로는 `http://127.0.0.1:8935/mcp`입니다. 기본 로컬 실행도
bearer 인증을 요구합니다. URL만 등록하면 `401 Unauthorized`가 정상 동작입니다.

## quickstart로 실행한 경우

`quickstart.sh`는 `quickstart-mcp-client`라는 worker credential을 만들고 raw
token을 작업 공간 밖에 출력하지 않습니다. MASC를 실행한 셸과 MCP 클라이언트를
실행할 셸이 다르면 다음 env 파일을 먼저 읽습니다.

```bash
BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
source "$BASE_PATH/.masc/config/mcp-client.env"
```

다른 `--base-path`를 사용했다면 그 경로 아래
`.masc/config/mcp-client.env`를 읽습니다. 파일 권한은 `0600`이며 Git에 넣으면 안
됩니다.

Codex처럼 bearer 환경 변수를 지원하는 클라이언트에는 다음 형태로 등록합니다.

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream" }
```

다른 클라이언트에서는 해당 클라이언트의 secret 또는 environment-variable
기능으로 `Authorization: Bearer <MASC_TOKEN>`을 전달합니다. raw token을 저장소의
JSON이나 TOML에 직접 쓰지 않습니다.

## 설치한 바이너리나 수동 실행을 사용하는 경우

서버를 시작할 base path와 port를 그대로 사용해 worker bearer를 만듭니다.

```bash
BASE_PATH=/path/to/project

eval "$(masc login \
  --base-path "$BASE_PATH" \
  --host 127.0.0.1 \
  --port 8935 \
  --agent local-mcp-client \
  --role worker \
  --client-env MASC_TOKEN \
  --no-expiry \
  --shell)"
```

`login`은 credential과 private raw-token 파일을
`<base-path>/.masc/auth`에 저장하고 현재 셸에 필요한 export 문장을 출력합니다.
일반 MCP 도구에는 worker 역할을 사용합니다. Keeper lifecycle 같은 admin 전용
작업이 필요할 때만 별도의 admin credential을 만듭니다.

## 연결 확인

다음 요청은 HTTP `200`과 `result.serverInfo.name = "masc"`를 반환해야 합니다.

```bash
curl -sS \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "Authorization: Bearer ${MASC_TOKEN}" \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"local-smoke","version":"1.0"}}}' \
  http://127.0.0.1:8935/mcp
```

연결 후 첫 작업은 다음 두 도구로 시작합니다.

```text
masc_start(path="/path/to/project", task_title="첫 작업 설명")
masc_status()
```

OAuth와 admin dashboard 인증은
[`LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md)를 참고하세요.
