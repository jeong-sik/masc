---
status: reference
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

## 서버 재시작과 클라이언트 자격증명

외부 MCP 클라이언트는 `login`이나 `mcp-config`로 만든 전용 credential을
사용합니다. `MASC_INTERNAL_MCP_TOKEN`은 서버 내부 Keeper용이며 외부 설정에
복사하지 않습니다. 내부 토큰이 새 프로세스에서 바뀌어도 외부 클라이언트의
전용 credential은 별도로 저장되어 있습니다.

설정 블록까지 출력하려면 같은 작업 공간과 포트를 지정합니다.

```bash
masc mcp-config --base-path /path/to/project --port 8935 \
  --agent codex-client --client codex
masc mcp-config --base-path /path/to/project --port 8935 \
  --agent claude-desktop-client --client claude-desktop
```

출력에는 비밀 bearer가 포함됩니다. 클라이언트의 개인 설정에 적용하고,
저장소나 이슈에 붙여 넣지 않습니다. 서로 다른 클라이언트에는 서로 다른
`--agent`를 사용합니다. 같은 agent로 명령을 다시 실행하면 그 credential을
교체하므로 이전 설정도 갱신해야 합니다. 서버 재시작마다 다시 발급할 필요는
없습니다. `mcp-config`는 기본으로 만료 없는 Worker credential을 발급하며,
세션용 만료 정책은 `--expiring`으로 선택합니다. 명시적 회수나 재발급은
서버 재시작과 별개입니다.

bearer의 수명과 MCP 세션의 수명도 별개입니다. 연결이 끊겼거나 서버가 이전
세션을 받지 않으면 클라이언트는 같은 bearer로 새 `initialize`를 보내고,
반환된 `Mcp-Session-Id`를 후속 요청에 사용합니다. 서버가 시작 중에 반환한
`503`을 토큰 만료로 해석하지 않습니다. 준비 상태는 `/health/ready`, 실제
작업 공간은 `/health?full=1`의 `paths`로 확인합니다.

[설치 바이너리의 격리 재시작 검증](evidence/2026-10-25-mcp-client-restart/README.md)은
발급한 동일 Worker bearer의 HTTP 검증과, 생성된 설정 그대로 실행한
실제 `mcp-remote` 프로세스의 재시작 전후 도구 조회·호출을 기록합니다. Codex나 Claude Desktop 앱 자체의 자동
재연결 동작을 대신하는 증거는 아닙니다.

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
