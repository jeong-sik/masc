"""Arm K on opencode: the wiring that decides whether the arm is its own baseline.

The failure this file guards against is silent. If the MCP entry carries no
bearer header, or the token is empty, opencode still starts and still solves
the task — with no keeper tools. The trial then records as a slightly worse
baseline run rather than as a broken arm, and the comparison the arm exists
to make is quietly answered with the wrong number.
"""
import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.keeper_tools_opencode import KeeperToolsOpenCode  # noqa: E402


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

        class R:
            stdout = ""
            stderr = ""
            returncode = 0
            return_code = 0

        return R()


@pytest.fixture(autouse=True)
def _provider_key(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key")


def make_agent(tmp_path, **kw):
    kw.setdefault("model_name", "openrouter/z-ai/glm-4.7-flash")
    return KeeperToolsOpenCode(logs_dir=tmp_path, **kw)


def test_the_keeper_runtime_follows_the_agents_own_model(tmp_path):
    assert make_agent(tmp_path).keeper_runtime_id == "openrouter.z-ai/glm-4.7-flash"


def test_a_bare_model_name_is_an_error_not_a_guess(tmp_path):
    with pytest.raises(ValueError, match="keeper_runtime_id"):
        make_agent(tmp_path, model_name="glm-4.7-flash")


def _capture_instruction(monkeypatch) -> dict:
    """Replace opencode's own run so only what this class prepends is seen."""
    captured: dict[str, str] = {}

    async def fake_super_run(self, instruction, environment, context):
        captured["instruction"] = instruction

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.run", fake_super_run
    )
    return captured


def test_the_pool_prompt_precedes_the_task(tmp_path, monkeypatch):
    captured = _capture_instruction(monkeypatch)
    asyncio.run(make_agent(tmp_path).run("solve the task", FakeEnv(), object()))
    assert captured["instruction"].endswith("solve the task")
    assert "`bench-1`" in captured["instruction"]
    assert "masc_keeper_msg" in captured["instruction"]


def test_announce_pool_false_leaves_the_task_prompt_alone(tmp_path, monkeypatch):
    captured = _capture_instruction(monkeypatch)
    agent = make_agent(tmp_path, announce_pool=False)
    asyncio.run(agent.run("solve the task", FakeEnv(), object()))
    assert captured["instruction"] == "solve the task"


def test_mcp_registration_carries_the_bearer_header(tmp_path):
    command = make_agent(tmp_path)._build_register_config_command()
    assert "opencode.json" in command
    # opencode's own schema for a remote server; without headers the endpoint
    # answers 401 and the model sees no keeper tools.
    assert 'type:"remote"' in command
    assert 'Authorization:("Bearer "+$t)' in command
    assert "/opt/masc-bench/token" in command


def test_the_entry_is_patched_in_not_written_over(tmp_path):
    # Harbor writes the whole config with `echo > file`, including the
    # provider registration opencode needs to recognise the model. Replacing
    # that file would leave the agent unable to resolve its own model.
    command = make_agent(tmp_path)._build_register_config_command()
    assert "jq " in command
    assert ".mcp[" in command
    assert command.count("opencode.json") >= 2


def test_registration_refuses_an_empty_token(tmp_path):
    command = make_agent(tmp_path)._build_register_config_command()
    assert 'masc_token="$(cat /opt/masc-bench/token)"' in command
    assert '[ -n "$masc_token" ]' in command
    assert "exit 1" in command


def test_install_adds_masc_on_top_of_opencode(tmp_path, monkeypatch):
    installed = []

    async def fake_super_install(self, environment):
        installed.append("opencode")

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.install", fake_super_install
    )
    import masc_sidecar

    fake_root = tmp_path / "bench-root"
    (fake_root / "dist").mkdir(parents=True)
    (fake_root / "driver").mkdir()
    for name in ("masc", "masc-exec-shim"):
        (fake_root / "dist" / name).write_bytes(b"")
    (fake_root / "driver" / "bootstrap.sh").write_text("")
    monkeypatch.setattr(masc_sidecar, "BENCH_ROOT", fake_root)

    async def go():
        agent = make_agent(tmp_path)
        env = FakeEnv()
        await agent.install(env)
        return env

    env = asyncio.run(go())
    assert installed == ["opencode"]
    assert ("file", "/opt/masc-bench/bin/masc") in [(k, d) for k, _, d in env.uploads]
    assert any("bootstrap.sh" in c for c in env.commands)
    # The other arms drive keepers from a script; here the model does.
    assert not any("run_episode.sh" in c for c in env.commands)


def test_the_container_env_names_the_pool(tmp_path):
    env = make_agent(tmp_path).masc_container_env()
    assert env["BENCH_KEEPER_POOL"] == "bench-1,bench-2,bench-3,bench-4"
    # The wire id carries a slash; MASC binds the slug and keeps the wire name
    # in api-name, so keeper_up has to be given the slug.
    assert env["BENCH_RUNTIME_ID"] == "openrouter.z-ai-glm-4.7-flash"
    assert env["OPENROUTER_API_KEY"] == "test-key"
