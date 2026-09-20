"""Harbor's per-agent credentials must reach the MASC bootstrap."""

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.keeper_tools_agent import KeeperToolsAgent  # noqa: E402
from agents.keeper_tools_opencode import KeeperToolsOpenCode  # noqa: E402
from agents.masc_agent import MascAgent  # noqa: E402
from tests.test_masc_agent import FakeEnv, fake_bench  # noqa: E402


@pytest.mark.parametrize(
    "agent_class", [MascAgent, KeeperToolsAgent, KeeperToolsOpenCode]
)
@pytest.mark.parametrize("host_key", [None, "host-key"])
def test_install_uses_harbor_agent_credentials(
    tmp_path, monkeypatch, agent_class, host_key
):
    if host_key is None:
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    else:
        monkeypatch.setenv("ANTHROPIC_API_KEY", host_key)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    root = fake_bench(tmp_path)
    monkeypatch.setattr("agents.masc_agent.BENCH_ROOT", root)
    monkeypatch.setattr("masc_sidecar.BENCH_ROOT", root)
    agent = agent_class(
        logs_dir=tmp_path,
        model_name="anthropic/claude-sonnet-5",
        extra_env={"ANTHROPIC_API_KEY": "agent-key"},
    )
    environment = FakeEnv()
    install = agent.install if agent_class is MascAgent else agent.install_masc
    asyncio.run(install(environment))
    bootstrap_envs = [
        kwargs["env"]
        for command, kwargs in zip(environment.commands, environment.exec_kwargs)
        if "bootstrap.sh" in command
    ]
    assert len(bootstrap_envs) == 1
    assert bootstrap_envs[0]["ANTHROPIC_API_KEY"] == "agent-key"
