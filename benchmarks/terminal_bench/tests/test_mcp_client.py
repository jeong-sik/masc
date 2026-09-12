"""driver/mcp.sh, exercised without a server.

This file exists because the shell driver had no automated coverage at all,
and that is where the failures live that cost a whole matrix run rather than
one trial. Each test below pins a bug that was live in the branch:

- `catch .result` was reached for every tool whose content[0].text is prose
  rather than JSON, and jq binds the error *message string* to `.` inside
  catch, so it raised "Cannot index string with string" and exited 5 — after
  the response had already been judged healthy.
- The response frame was taken as the last SSE `data:` line, and the guard
  asked only "no error", so a progress notification arriving after the result
  was accepted as the result.

`mcp_call` is driven by replacing `_mcp_post` with a stub, so these run
offline and in milliseconds.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

DRIVER = Path(__file__).resolve().parents[1] / "driver" / "mcp.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("jq") is None, reason="the MCP client is curl + jq"
)


def run_sh(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f'set -uo pipefail\nMCP_TOKEN=t\nsource "{DRIVER}"\n{script}'],
        capture_output=True,
        text=True,
    )


def stub_post(body: str) -> str:
    """Replace the transport with a fixture. Single-quoted heredoc: no expansion."""
    return f"_mcp_post() {{ cat <<'FIXTURE'\n{body}\nFIXTURE\n}}\n"


TEXT_RESULT = (
    '{{"jsonrpc":"2.0","id":7,"result":{{"content":[{{"type":"text","text":{text}}}]}}}}'
)


def test_a_prose_tool_result_comes_back_instead_of_erroring():
    # The bug: jq exited 5 here and mcp_call produced no stdout, so a caller
    # that polls a tool returning prose saw every poll fail.
    payload = TEXT_RESULT.format(text='"keeper bench-1 is up"')
    r = run_sh(stub_post(payload) + 'mcp_call 7 some_tool "{}" 5')
    assert r.returncode == 0, r.stderr
    assert "keeper bench-1 is up" in r.stdout


def test_a_json_tool_result_is_unwrapped_and_parsed():
    payload = TEXT_RESULT.format(text='"{\\"state\\":\\"Succeeded\\"}"')
    r = run_sh(stub_post(payload) + 'mcp_call 7 some_tool "{}" 5')
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == '{"state":"Succeeded"}'


def test_a_notification_is_not_mistaken_for_the_response():
    # Well-formed, no error field, arrives last. The old guard passed it.
    sse = (
        "data: " + TEXT_RESULT.format(text='"done"') + "\n"
        'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"x":1}}'
    )
    r = run_sh(stub_post(sse) + 'mcp_call 7 some_tool "{}" 5')
    assert r.returncode == 0, r.stderr
    assert "done" in r.stdout


def test_a_frame_for_a_different_request_is_refused():
    payload = '{"jsonrpc":"2.0","id":999,"result":{"content":[]}}'
    r = run_sh(stub_post(payload) + 'mcp_call 7 some_tool "{}" 5')
    assert r.returncode == 1
    assert "no response frame with id 7" in r.stderr


def test_an_error_result_is_refused_and_named():
    payload = (
        '{"jsonrpc":"2.0","id":7,"result":{"isError":true,'
        '"content":[{"type":"text","text":"nope"}]}}'
    )
    r = run_sh(stub_post(payload) + 'mcp_call 7 some_tool "{}" 5')
    assert r.returncode == 1
    assert "mcp_call some_tool failed" in r.stderr
    assert "nope" in r.stderr


def test_a_transport_failure_is_diagnosed_even_when_the_caller_ignores_stdout():
    # bootstrap.sh calls `mcp_call ... >/dev/null` bare. An unguarded
    # assignment aborted the caller with curl's exit code and printed nothing.
    r = run_sh("_mcp_post() { return 28; }\nmcp_call 7 some_tool '{}' 5 >/dev/null")
    assert r.returncode == 1
    assert "transport error" in r.stderr


def test_an_empty_body_is_diagnosed():
    r = run_sh(stub_post("") + "mcp_call 7 some_tool '{}' 5 >/dev/null")
    assert r.returncode == 1
    assert "no response frame" in r.stderr
