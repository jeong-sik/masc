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
from harbor.models.agent.context import AgentContext  # noqa: E402


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
    # bootstrap writes the keeper's gh hosts.yml from this, and keeper_up's
    # remote_ssh preflight refuses without it.
    monkeypatch.setenv("GH_TOKEN", "test-gh-token")


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
    asyncio.run(make_agent(tmp_path).run("solve the task", FakeEnv(), AgentContext()))
    assert captured["instruction"].endswith("solve the task")
    assert "`bench-1`" in captured["instruction"]
    assert "masc_keeper_msg" in captured["instruction"]


def test_announce_pool_false_leaves_the_task_prompt_alone(tmp_path, monkeypatch):
    captured = _capture_instruction(monkeypatch)
    agent = make_agent(tmp_path, announce_pool=False)
    asyncio.run(agent.run("solve the task", FakeEnv(), AgentContext()))
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
    bootstrapped_first = []

    async def fake_super_install(self, environment):
        installed.append("opencode")
        # The ordering is the point, and a stub cannot fail on a missing token
        # the way the real install does: the config patch it appends reads the
        # bearer token at /opt/masc-bench/token, which bootstrap.sh mints. So
        # record whether bootstrap had already run by the time the parent
        # install started. With the old order this is False and every fresh
        # container failed setup.
        bootstrapped_first.append(
            any("bootstrap.sh" in command for command in environment.commands)
        )

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
    assert bootstrapped_first == [True]
    assert ("file", "/opt/masc-bench/bin/masc") in [(k, d) for k, _, d in env.uploads]
    assert any("bootstrap.sh" in c for c in env.commands)
    # The other arms drive keepers from a script; here the model does.
    assert not any("run_episode.sh" in c for c in env.commands)


def test_the_run_adds_keeper_spend_to_the_episode(tmp_path, monkeypatch):
    """What the keepers spent is the number the arm is compared on."""
    rows = [
        '{"usage_projection": "resolved_delta", "input_tokens": 100,'
        ' "output_tokens": 10, "cost_usd": 0.25,'
        ' "cache_read_tokens": 7, "cache_creation_tokens": 3}',
        '{"usage_projection": "resolved_delta", "input_tokens": 50,'
        ' "output_tokens": 5, "cost_usd": 0.75, "usage_missing": true}',
        # The same request MASC also writes as a raw observation. Counting it
        # beside the settlement doubles a single-request turn.
        '{"usage_projection": "raw_observation", "input_tokens": 100,'
        ' "output_tokens": 10, "cost_usd": 0.25}',
        # A row with no projection at all is not a valid ledger row; it is
        # counted rather than folded into the total on a guess.
        '{"input_tokens": 900, "output_tokens": 90, "cost_usd": 9.0}',
        "not json",
        "",
    ]

    class LedgerEnv(FakeEnv):
        async def exec(self, command, **kw):
            self.commands.append(command)

            class R:
                stdout = "\n".join(rows) if "costs" in command else ""
                stderr = ""
                returncode = 0
                return_code = 0

            return R()

    async def fake_super_run(self, instruction, environment, context):
        # The agent's own usage is already recorded by the time the merge runs.
        context.n_input_tokens = 1_000
        context.cost_usd = 1.0

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.run", fake_super_run
    )
    context = AgentContext()
    env = LedgerEnv()
    asyncio.run(make_agent(tmp_path).run("solve the task", env, context))
    # The read has to be able to fail. `2>/dev/null || true` made every
    # outcome exit 0, which put the read_failed branch below out of reach and
    # reported an unreadable ledger as a run with no keeper spend.
    ledger_command = next(c for c in env.commands if "costs" in c)
    assert "2>/dev/null" not in ledger_command
    assert "|| true" not in ledger_command
    # Added to what the agent reported, not replacing it.
    assert context.n_input_tokens == 1_150
    assert context.n_output_tokens == 15
    assert context.n_cache_tokens == 10
    assert context.cost_usd == pytest.approx(2.0)
    keeper = context.metadata["keeper_usage"]
    assert keeper["rows"] == 2
    # A turn the provider never reported usage for is counted, not folded in as
    # zero: a total that quietly omits turns is worse than one that says so.
    assert keeper["rows_without_reported_usage"] == 1
    assert keeper["unparseable_rows"] == 1
    # Neither the raw observation nor the projectionless row reached the total.
    assert keeper["raw_observation_rows"] == 1
    assert keeper["rows_without_projection"] == 1
    # Harbor reported both token fields this run, so the total is whole.
    assert keeper["parent_fields_unreported"] == [
        "n_cache_tokens",
        "n_output_tokens",
    ]


def test_an_unpriced_ledger_row_is_counted_not_free(tmp_path, monkeypatch):
    """A row the ledger could not price must not read as a free turn.

    cost_ledger serializes cost_usd as null for a turn whose usage it never
    resolved. Adding that as zero published a number the aggregate reads as
    measured, and cost is the axis this arm is compared on: unknown keeper
    spend looked like free keeper spend.
    """
    rows = [
        '{"usage_projection": "resolved_delta", "input_tokens": 10,'
        ' "output_tokens": 1, "cost_usd": 0.5}',
        '{"usage_projection": "resolved_delta", "input_tokens": 20,'
        ' "output_tokens": 2, "cost_usd": null, "usage_missing": true}',
    ]

    class LedgerEnv(FakeEnv):
        async def exec(self, command, **kw):
            self.commands.append(command)

            class R:
                stdout = "\n".join(rows) if "costs" in command else ""
                stderr = ""
                returncode = 0
                return_code = 0

            return R()

    async def fake_super_run(self, instruction, environment, context):
        context.cost_usd = 0.0

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.run", fake_super_run
    )
    context = AgentContext()
    asyncio.run(make_agent(tmp_path).run("solve the task", LedgerEnv(), context))
    keeper = context.metadata["keeper_usage"]
    assert keeper["rows"] == 2
    # Only the priced row reaches the total.
    assert keeper["cost_usd"] == pytest.approx(0.5)
    assert context.cost_usd == pytest.approx(0.5)
    # And the unpriced one is named, which is what aggregate.py puts in its own
    # column next to the total.
    assert keeper["cost_rows_unreported"] == 1
    # The tokens that row did report are still counted: it is the price that is
    # unknown, not the traffic.
    assert keeper["input_tokens"] == 30


def test_an_unreadable_ledger_is_a_failure_not_a_zero(tmp_path, monkeypatch):
    """A collection failure must not read as a run with no keeper spend."""

    class BrokenEnv(FakeEnv):
        async def exec(self, command, **kw):
            self.commands.append(command)

            class R:
                stdout = ""
                stderr = "find: /root/.masc/costs: Permission denied"
                returncode = 1
                return_code = 1

            return R()

    async def fake_super_run(self, instruction, environment, context):
        context.n_input_tokens = 7

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.run", fake_super_run
    )
    context = AgentContext()
    asyncio.run(make_agent(tmp_path).run("solve the task", BrokenEnv(), context))
    keeper = context.metadata["keeper_usage"]
    assert "Permission denied" in keeper["read_failed"]
    assert "rows" not in keeper
    # The agent's own figure is left exactly as harbor reported it.
    assert context.n_input_tokens == 7


def test_the_env_refuses_without_a_github_credential(tmp_path, monkeypatch):
    """keeper_up refuses a remote_ssh keeper with no gh identity, and
    bootstrap runs under set -e: the missing credential is named here."""
    monkeypatch.delenv("GH_TOKEN", raising=False)
    with pytest.raises(RuntimeError, match="GH_TOKEN"):
        make_agent(tmp_path).masc_container_env()


def test_a_run_without_a_ledger_leaves_the_totals_alone(tmp_path, monkeypatch):
    async def fake_super_run(self, instruction, environment, context):
        context.n_input_tokens = 42

    monkeypatch.setattr(
        "harbor.agents.installed.opencode.OpenCode.run", fake_super_run
    )
    context = AgentContext()
    asyncio.run(make_agent(tmp_path).run("solve the task", FakeEnv(), context))
    assert context.n_input_tokens == 42
    assert context.metadata["keeper_usage"]["rows"] == 0


def test_the_container_env_names_the_pool(tmp_path):
    env = make_agent(tmp_path).masc_container_env()
    assert env["BENCH_KEEPER_POOL"] == "bench-1,bench-2,bench-3,bench-4"
    # The wire id carries a slash; MASC binds the slug and keeps the wire name
    # in api-name, so keeper_up has to be given the slug.
    assert env["BENCH_RUNTIME_ID"] == "openrouter.z-ai-glm-4.7-flash"
    assert env["OPENROUTER_API_KEY"] == "test-key"
