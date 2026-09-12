import asyncio
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.keeper_tools_agent import KeeperToolsAgent  # noqa: E402


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
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    # keeper_up's remote_ssh preflight refuses without a gh identity, and
    # bootstrap writes the keeper's hosts.yml from this token.
    monkeypatch.setenv("GH_TOKEN", "test-gh-token")


def make_agent(tmp_path, **kw):
    kw.setdefault("model_name", "anthropic/claude-sonnet-5")
    return KeeperToolsAgent(logs_dir=tmp_path, **kw)


def test_pool_size_comes_from_the_arm(tmp_path):
    a = make_agent(tmp_path)
    assert a.arm == "k"
    assert a.pool_names == ["bench-1", "bench-2", "bench-3", "bench-4"]
    assert a.keeper_runtime_id == "anthropic.claude-sonnet-5"


def test_keeper_runtime_id_kwarg_wins(tmp_path):
    a = make_agent(tmp_path, keeper_runtime_id="claude_code.claude-sonnet-5")
    assert a.keeper_runtime_id == "claude_code.claude-sonnet-5"


def test_bare_model_name_is_an_error_not_a_guess(tmp_path):
    with pytest.raises(ValueError, match="keeper_runtime_id"):
        KeeperToolsAgent(logs_dir=tmp_path, model_name="claude-sonnet-5")


def test_pool_is_announced_in_the_appended_system_prompt(tmp_path):
    a = make_agent(tmp_path)
    flags = a.build_cli_flags()
    assert "--append-system-prompt" in flags
    assert "masc_keeper_msg" in flags
    assert "bench-4" in flags
    # A keeper the model starts itself has no approval stance and would stall,
    # so the prompt has to say so rather than leave it to be discovered.
    assert "masc_keeper_up" in flags and "approval" in flags
    # The baseline arm is this agent's parent with none of this, so the
    # announcement must stay opt-out rather than baked in.
    quiet = make_agent(tmp_path, announce_pool=False)
    assert "--append-system-prompt" not in quiet.build_cli_flags()


def test_explicit_append_system_prompt_wins(tmp_path):
    a = make_agent(tmp_path, append_system_prompt="mine")
    assert "mine" in a.build_cli_flags()
    assert "masc_keeper_msg" not in a.build_cli_flags()


def test_mcp_registration_carries_the_bearer_header(tmp_path):
    # Harbor's own writer emits no headers and the MASC /mcp endpoint requires
    # strict bearer auth, so the entry has to be built here. The token is
    # minted in the container, so it is read at setup time, not interpolated.
    cmd = make_agent(tmp_path)._build_register_mcp_servers_command()
    assert "$CLAUDE_CONFIG_DIR/.claude.json" in cmd
    assert "/opt/masc-bench/token" in cmd
    assert "Bearer " in cmd
    assert "http://127.0.0.1:8935/mcp" in cmd
    # Merged into whatever is already there rather than clobbering a task's own
    # declared servers.
    assert '.mcpServers["masc"]' in cmd


def test_mcp_registration_command_actually_runs(tmp_path, monkeypatch):
    # The jq program is the part that is easy to get subtly wrong (a bare
    # object index is an identifier to jq, not a string), so run it.
    import json as _json
    import shutil
    import subprocess

    if shutil.which("jq") is None:
        pytest.skip("jq not installed")
    token_dir = tmp_path / "opt" / "masc-bench"
    token_dir.mkdir(parents=True)
    (token_dir / "token").write_text("tok-123\n")
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / ".claude.json").write_text('{"mcpServers":{"task-owned":{"type":"stdio"}}}')
    cmd = make_agent(tmp_path)._build_register_mcp_servers_command()
    cmd = cmd.replace("/opt/masc-bench", str(token_dir))
    subprocess.run(
        ["bash", "-c", cmd],
        env={"CLAUDE_CONFIG_DIR": str(cfg), "PATH": os.environ["PATH"]},
        check=True,
    )
    written = _json.loads((cfg / ".claude.json").read_text())
    assert written["mcpServers"]["task-owned"] == {"type": "stdio"}
    masc = written["mcpServers"]["masc"]
    assert masc["type"] == "http"
    assert masc["url"] == "http://127.0.0.1:8935/mcp"
    assert masc["headers"]["Authorization"] == "Bearer tok-123"


def test_container_env_names_the_pool_and_starts_no_keeper(tmp_path):
    env = make_agent(tmp_path).masc_container_env()
    assert env["BENCH_KEEPER_POOL"] == "bench-1,bench-2,bench-3,bench-4"
    assert env["BENCH_RUNTIME_ID"] == "anthropic.claude-sonnet-5"
    assert env["ANTHROPIC_API_KEY"] == "test-key"
    assert "KEEPER_COUNT" not in env


def test_install_adds_masc_on_top_of_claude_code(tmp_path, monkeypatch):
    installed = []

    async def fake_super_install(self, environment):
        installed.append("claude-code")

    monkeypatch.setattr(
        "harbor.agents.installed.claude_code.ClaudeCode.install", fake_super_install
    )
    # The binaries are fetched, not committed, so point the sidecar at a tree
    # that has them. Without this the test passes only on a machine that has
    # run image/fetch_masc.sh, and fails everywhere else for a reason that has
    # nothing to do with what it checks.
    import masc_sidecar

    fake_root = tmp_path / "bench-root"
    (fake_root / "dist").mkdir(parents=True)
    (fake_root / "driver").mkdir()
    for name in ("masc", "masc-exec-shim"):
        (fake_root / "dist" / name).write_bytes(b"")
    (fake_root / "driver" / "bootstrap.sh").write_text("")
    monkeypatch.setattr(masc_sidecar, "BENCH_ROOT", fake_root)

    async def go():
        a = make_agent(tmp_path)
        env = FakeEnv()
        await a.install(env)
        return env

    env = asyncio.run(go())
    assert installed == ["claude-code"]
    kinds = [(k, d) for k, _, d in env.uploads]
    assert ("file", "/opt/masc-bench/bin/masc") in kinds
    assert ("dir", "/opt/masc-bench/config") in kinds
    assert any("bootstrap.sh" in c for c in env.commands)
    # run_episode.sh drives keepers for the other arms; here the model does.
    assert not any("run_episode.sh" in c for c in env.commands)


def test_registration_refuses_an_empty_token(tmp_path):
    # An unreadable token used to yield `Authorization: Bearer ` and exit 0.
    # Claude Code would then start with an MCP server that 401s, the model
    # would find no keeper tools, and arm K would silently produce a baseline
    # run — the exact comparison the arm exists to make.
    import shutil
    import subprocess

    if shutil.which("jq") is None:
        pytest.skip("jq not installed")
    token_dir = tmp_path / "opt" / "masc-bench"
    token_dir.mkdir(parents=True)
    (token_dir / "token").write_text("")
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    cmd = make_agent(tmp_path)._build_register_mcp_servers_command()
    cmd = cmd.replace("/opt/masc-bench", str(token_dir))
    r = subprocess.run(
        ["bash", "-c", cmd],
        env={"CLAUDE_CONFIG_DIR": str(cfg), "PATH": os.environ["PATH"]},
        capture_output=True,
        text=True,
    )
    assert r.returncode != 0
    assert "empty" in r.stderr
    assert not (cfg / ".claude.json").exists()


def test_registration_refuses_an_unset_config_dir(tmp_path):
    import shutil
    import subprocess

    if shutil.which("jq") is None:
        pytest.skip("jq not installed")
    token_dir = tmp_path / "opt" / "masc-bench"
    token_dir.mkdir(parents=True)
    (token_dir / "token").write_text("tok-123\n")
    cmd = make_agent(tmp_path)._build_register_mcp_servers_command()
    cmd = cmd.replace("/opt/masc-bench", str(token_dir))
    r = subprocess.run(
        ["bash", "-c", cmd],
        env={"PATH": os.environ["PATH"]},
        capture_output=True,
        text=True,
    )
    assert r.returncode != 0
    assert "CLAUDE_CONFIG_DIR" in r.stderr
