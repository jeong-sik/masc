import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.masc_agent import MascAgent  # noqa: E402


class FakeResult:
    def __init__(self, stdout="", return_code=0):
        self.stdout = stdout
        self.returncode = return_code
        self.return_code = return_code
        self.stderr = ""


class FakeEnv:
    def __init__(self):
        self.commands = []
        self.uploads = []
        self.default_user = None

    async def upload_file(self, src, dst):
        self.uploads.append(("file", str(src), dst))

    async def upload_dir(self, src, dst):
        self.uploads.append(("dir", str(src), dst))

    async def exec(self, command, **kw):
        self.commands.append(command)
        if "cat /opt/masc-bench/result.json" in command:
            return FakeResult('{"state":"Succeeded","duration_ms":1234,'
                              '"tool_calls":17,"duplicate_tool_calls":2,"final":{}}')
        return FakeResult("")


@pytest.fixture(autouse=True)
def _provider_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")


def make_agent(tmp_path, **kw):
    return MascAgent(logs_dir=tmp_path, model_name="anthropic/claude-fable-5", **kw)


def test_runtime_id_from_model(tmp_path):
    a = make_agent(tmp_path)
    assert a.runtime_id == "anthropic.claude-fable-5"


def test_runtime_id_kwarg_wins(tmp_path):
    a = make_agent(tmp_path, runtime_id="kimi_coding.kimi-k2.7")
    assert a.runtime_id == "kimi_coding.kimi-k2.7"


def test_install_uploads_binary_driver_config(tmp_path):
    async def go():
        a = make_agent(tmp_path, arm="b")
        env = FakeEnv()
        await a.install(env)
        return env

    env = asyncio.run(go())
    kinds = [(k, d) for k, _, d in env.uploads]
    assert ("file", "/opt/masc-bench/bin/masc") in kinds
    assert ("file", "/opt/masc-bench/bin/masc-exec-shim") in kinds
    assert ("dir", "/opt/masc-bench/driver") in kinds
    assert ("dir", "/opt/masc-bench/config") in kinds
    assert any("bootstrap.sh" in c for c in env.commands)


def test_run_populates_context(tmp_path):
    from harbor.models.agent.context import AgentContext

    async def go():
        a = make_agent(tmp_path, arm="b")
        env = FakeEnv()
        ctx = AgentContext()
        await a.run("do the task", env, ctx)
        return env, ctx

    env, ctx = asyncio.run(go())
    assert any("run_episode.sh" in c for c in env.commands)
    assert ctx.metadata["masc_state"] == "Succeeded"
    assert ctx.metadata["tool_calls"] == 17
    assert ctx.metadata["duplicate_tool_calls"] == 2


def test_claude_code_lane_env_uses_oauth_token(tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-test")
    a = MascAgent(logs_dir=tmp_path, model_name="claude_code/claude-sonnet-5", arm="b")
    assert a.runtime_id == "claude_code.claude-sonnet-5"
    env = a._container_env()
    assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-test"
    assert env["BENCH_RUNTIME_ID"] == "claude_code.claude-sonnet-5"
    assert "ANTHROPIC_API_KEY" not in env


def test_claude_code_lane_requires_oauth_token(tmp_path, monkeypatch):
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    a = MascAgent(logs_dir=tmp_path, model_name="claude_code/claude-sonnet-5", arm="b")
    with pytest.raises(RuntimeError, match="CLAUDE_CODE_OAUTH_TOKEN"):
        a._container_env()
