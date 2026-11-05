# agy 1.5.1 이 MCP 도구를 싣는 방식 측정 (2026-11-05)

RFC-0490 의 근거다. 가짜 MCP 서버와 일회용 HOME 으로 Antigravity CLI(`agy`)를 직접 돌렸다.

## 조건

| 항목 | 값 |
| --- | --- |
| agy | 1.5.1 (`~/.local/bin/agy`, 2026-11-05 08:17Z 에 자동 업데이트로 바뀜) |
| 모델 | `claude-sonnet-5-5-low` (msx-retro-mania 가 쓴 것과 같다) |
| 시각 | 2026-11-05 10:38Z – 11:01Z |
| 서버 | 아래 `server.py`. streamable HTTP, `tools/list`·`tools/call` 을 한 줄씩 기록한다 |
| HOME | 아래 `setup` 으로 만든 일회용 디렉터리. settings 는 masc 의 `Native_none` 과 같다 |
| 실제 도구 스펙 | msx-retro-mania 의 `keeper_tools_list` 결과(10:26Z, `descriptor_surface` 206개)에서 이름·설명을 받고, 인자는 `config/tools/<이름>.toml` 의 `[[params]]` 로 다시 만들었다. TOML 이 없는 5개는 `schema_shape` 의 속성 이름을 문자열로 두었다. 206개, 직렬화 266,592 바이트 |

모델에게는 "받은 함수 선언을 보고 JSON 으로 답하라" 고 시켰다. 모델 답은 자기 보고라서 서버 기록(`tools/call` 도착 여부)과 agy stream-json 의 `step_update`(도구 이름·상태)로 맞춰 봤다.

## 결과

| # | 설정 | 결과 |
| --- | --- | --- |
| 1 | 작은 도구 220개(합 44,880 B), 모두 `tools.<이름>.eager = true` | 220개 모두 직접 호출 가능. 함수 선언 234개(내장 14). `probe_219` 호출이 서버에 도착 |
| 2 | 실제 스펙 206개, 모두 eager (masc 가 지금 보내는 모양) | 직접 호출 가능 130개(masc 116 + 내장 14). DOS 는 `eject`·`inventory`·`meta`·`pass`·`peek`·`save`·`step` 만 남음. 지연 목록 0개. `masc_dos_screen` 은 "호출 불가", 서버에 `tools/call` 없음 |
| 3 | 2 와 같고, 모든 도구에 `_meta: {"antigravity/alwaysLoad": true}` | 2 와 같음(130개, 같은 7개) |
| 4a | 실제 스펙 206개, eager 표시 없음 | 직접 호출 0개, 지연 목록 206개. `call_mcp_tool` 로 `masc_dos_screen` 이 서버에 도착 |
| 4b | 4a 에서 모델에게 지연 목록 안내문을 그대로 옮기게 함 | 목록에는 이름만 있다. 안내문: "`<appDataDir>/mcp/<serverName>/<toolName>.json` schema 를 읽고 `call_mcp_tool` 로 부른다" |
| 4c | 4a + allow `read_file(<appDataDir>/mcp/masc)`, deny `read_file(*)` 유지 | schema 읽기 거절. 바깥 파일 거절 |
| 4d | 4c 에서 deny `read_file(*)` 만 뺌 | schema 읽힘. 바깥 파일 거절. **appDataDir 안 다른 파일도 읽힘**. workspace 파일 읽힘 |
| 5a | 4c + PreToolUse hook 이 schema 경로에 `allow` | schema 읽기 거절. hook `allow` 는 settings deny 를 이기지 못한다 |
| 5b | 4d + PreToolUse hook(아래 `hook.py`)이 schema 밖 경로를 `deny` | schema 읽힘(`masc_dos_press` 인자 4개 정확). 바깥 파일·appDataDir 안 다른 파일 거절. 20,300 B 결과는 `<appDataDir>/brain/<대화>/.system_generated/steps/<n>/output.txt` 로 빠졌고, hook 이 그 경로를 거절 |
| 5c | 5b 의 hook 을 `exit 1` 하는 명령으로 바꿈 | `read_file` 과 `call_mcp_tool` 이 모두 실패. hook 이 실패하면 agy 는 막는다 |

### 2 의 잘린 지점

실제 스펙을 직렬화 크기 순으로 세웠을 때 남은 것과 빠진 것이 크기로 갈린다.

| 크기 순위 | 크기(B) | 누적(B) | 도구 | 결과 |
| --- | --- | --- | --- | --- |
| 41 | 443 | — | `masc_dos_meta` | 남음 |
| 112 | 883 | 60,073 | `masc_dos_step` | 남음 |
| 113 | 888 | 60,961 | `keeper_artifact_transfer` | 남음 |
| 115 | 928 | 62,780 | — | 남음(116번째) |
| 129 | 1,066 | — | `masc_dos_screen` | 빠짐 |
| 132 | 1,119 | — | `masc_dos_click` | 빠짐 |
| 145 | 1,206 | — | `masc_dos_type` | 빠짐 |
| 162 | 1,504 | — | `masc_dos_press` | 빠짐 |

agy 는 작은 도구부터 누적 약 62–64 KB(이 직렬화 기준)까지 eager 로 등록하고 나머지는 등록하지 않는다. 예산이 바이트인지 토큰인지, 모델마다 다른지는 확인하지 않았다. agy 로그(`cli.log`)에는 버렸다는 줄이 없다.

## 실제 Keeper 기록과 맞춤

- msx-retro-mania 의 `antigravity_subscription.claude-sonnet-5-5-low` 턴(trace 8413–8421, 10:17Z–10:30Z)은 모두 위 7개만 있다고 보고했다. 측정 2 와 같은 집합이다.
- 같은 Keeper 의 glm 턴(trace 8389, 11-04 23:18Z)은 `masc_dos_screen`·`masc_dos_press` 를 정상 호출했다.
- 10:26Z `keeper_tools_list` 는 13개 DOS 도구를 모두 `availability: active` 로 보였다. 서버 쪽 목록은 온전하다.

## 확인하지 않은 것

- agy 1.5.1 이전 버전에도 같은 예산이 있었는지. masc 의 eager 결정(`keeper_antigravity_runtime.ml` `eager_tool_names`)은 1.2.9 에서 측정했다.
- 예산의 정확한 단위와 값.
- `call_mcp_tool` 결과의 inline 상한. changelog 1.4.7 은 10 KB 라고 적는다. 이번에는 20,300 B 가 파일로 빠지는 것만 봤다.

## 스크립트

측정에 쓴 스크립트를 줄인 판이다. 서버의 `Mcp-Session-Id` 헤더와 `DELETE` 처리, hook 의 `AbsolutePath`·`path` 인자 처리를 뺐다. 측정 중 agy 의 `read_file` 인자는 `Path` 만 나왔다. 세 파일을 한 디렉터리에 두고 `python3 -I` 로 돌린다. 토큰은 운영자 자신의 agy 로그인을 쓴다. 측정 2 의 HOME 은 `setup` 으로 만들고, `mcp_config.json` 의 `tools` 에 206개 이름을 `{"eager": true}` 로 넣는다.

`server.py` (`<port> <specs.json> <log> [always_load|big=<tool>]`):

```python
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, SPECS, LOG = int(sys.argv[1]), json.load(open(sys.argv[2])), sys.argv[3]
MODE = sys.argv[4] if len(sys.argv) > 4 else ""
if MODE == "always_load":
    SPECS = [dict(s, _meta={"antigravity/alwaysLoad": True}) for s in SPECS]
BIG = MODE.removeprefix("big=") if MODE.startswith("big=") else ""
BIG_TEXT = "".join(f"line {i:05d} of a large result\n" for i in range(700)) + "END-OF-BIG-RESULT"

def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

def answer(msg):
    if msg.get("id") is None:
        return None
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "masc", "version": "0"}}
    elif method == "tools/list":
        log({"method": "tools/list"})
        result = {"tools": SPECS}
    elif method == "tools/call":
        name = msg["params"]["name"]
        log({"method": "tools/call", "name": name})
        result = {"content": [{"type": "text", "text": BIG_TEXT if name == BIG else f"ok:{name}"}]}
    else:
        return {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown"}}
    return {"jsonrpc": "2.0", "id": msg["id"], "result": result}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return
    def do_GET(self):
        self.send_response(405); self.end_headers()
    def do_POST(self):
        reply = answer(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        if reply is None:
            self.send_response(202); self.end_headers(); return
        body = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
```

`setup` (HOME 구성, masc 의 `Native_none` settings 와 같다):

```text
<HOME>/.gemini/antigravity-cli/settings.json
  {"permissions": {"allow": ["mcp(masc/*)"],
                   "deny": ["read_file(*)", "write_file(*)", "command(*)", "read_url(*)", "execute_url(*)"]}}
<HOME>/.gemini/config/mcp_config.json
  {"mcpServers": {"masc": {"url": "http://127.0.0.1:<port>/mcp", "headers": {}, "tools": {...}}}}
<HOME>/.gemini/config/hooks.json            (측정 5 만)
  {"probe": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command",
     "command": "python3 -I <dir>/hook.py <log> <HOME>/.gemini/antigravity-cli/mcp/masc"}]}]}}
```

`hook.py` (측정용. 경로 인자가 없는 도구는 통과시킨다):

```python
import json, os, sys
LOG, ALLOWED = sys.argv[1], [os.path.realpath(r) for r in sys.argv[2:]]
call = json.load(sys.stdin).get("toolCall", {})
path = call.get("args", {}).get("Path", "")
real = os.path.realpath(path) if path else ""
inside = any(real == r or real.startswith(r + os.sep) for r in ALLOWED)
decision = ("allow" if inside else "deny") if path else "allow"
with open(LOG, "a") as f:
    f.write(json.dumps({"name": call.get("name"), "decision": decision}) + "\n")
print(json.dumps({"decision": decision, "reason": "probe hook"}))
```

실행 예:

```sh
cd <HOME>/ws && HOME=<HOME> agy -p '<질문>' --model claude-sonnet-5-5-low \
  --output-format stream-json --print-timeout 240s
```
