import asyncio
import json
import sys
from pathlib import Path
from types import SimpleNamespace

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


def test_install_uploads_binary_driver_config(tmp_path, monkeypatch):
    # dist/ is gitignored, so calling the real install() made this fail rather
    # than skip on a clean checkout, and it rendered into the repo tree as a
    # side effect. Same fixture shape as the vendored-gh test below.
    import agents.masc_agent as m

    root = tmp_path / "bench"
    (root / "dist").mkdir(parents=True)
    for name in ("masc", "masc-exec-shim"):
        (root / "dist" / name).write_text("")
    (root / "driver").mkdir()

    async def go():
        monkeypatch.setattr(m, "BENCH_ROOT", root)
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


def test_vendored_gh_is_uploaded_when_present(tmp_path, monkeypatch):
    # deps.sh installs $BENCH/bin/gh system-wide when it is there; the
    # keeper_up preflight runs `gh auth status` and debian stable has no gh
    # package, so the vendored copy is what makes those base images work.
    import agents.masc_agent as m

    async def go(root):
        monkeypatch.setattr(m, "BENCH_ROOT", root)
        a = make_agent(tmp_path, arm="b")
        env = FakeEnv()
        await a.install(env)
        return env

    root = tmp_path / "bench"
    (root / "dist").mkdir(parents=True)
    for name in ("masc", "masc-exec-shim", "gh"):
        (root / "dist" / name).write_text("")
    (root / "driver").mkdir()
    env = asyncio.run(go(root))
    assert ("file", "/opt/masc-bench/bin/gh") in [(k, d) for k, _, d in env.uploads]


# --- episode cost ----------------------------------------------------------
#
# The judging rule this benchmark answers is cost per task. Until now the MASC
# arms reported no cost at all, which did not make the comparison careful — it
# left those arms out of it.

RATES = {
    "input_cost_per_token": 2e-06,
    "output_cost_per_token": 1e-05,
    "cache_creation_input_token_cost": 2.5e-06,
    "cache_read_input_token_cost": 2e-07,
}


def write_result(tmp_path, **usage):
    body = {"state": "Succeeded", "duration_ms": 1, "tool_calls": 0,
            "duplicate_tool_calls": 0, "final": {}}
    body.update(usage)
    (Path(tmp_path) / "result.json").write_text(json.dumps(body))


def price(monkeypatch, table):
    import litellm
    monkeypatch.setattr(litellm, "model_cost", table)


def context_for(tmp_path, monkeypatch, table, **usage):
    price(monkeypatch, table)
    write_result(tmp_path, **usage)
    agent = make_agent(tmp_path)
    context = SimpleNamespace(metadata=None)
    agent.populate_context_post_run(context)
    return context


def test_cost_prices_each_token_class_at_its_own_rate(tmp_path, monkeypatch):
    context = context_for(
        tmp_path, monkeypatch, {"anthropic/claude-fable-5": RATES},
        input_tokens=1000, output_tokens=100, cache_tokens=600,
        cache_creation_tokens=400, cache_read_tokens=200)
    expected = 1000 * 2e-06 + 100 * 1e-05 + 400 * 2.5e-06 + 200 * 2e-07
    assert context.cost_usd == pytest.approx(expected)


def test_the_cache_split_is_not_the_cache_sum(tmp_path, monkeypatch):
    # 600 cache tokens priced as one class would be either 1.5e-03 (all
    # creation) or 1.2e-04 (all read). The real answer is neither, and the
    # gap is why run_episode.sh reports the two apart.
    context = context_for(
        tmp_path, monkeypatch, {"anthropic/claude-fable-5": RATES},
        input_tokens=0, output_tokens=0, cache_tokens=600,
        cache_creation_tokens=400, cache_read_tokens=200)
    assert context.cost_usd == pytest.approx(400 * 2.5e-06 + 200 * 2e-07)
    assert context.cost_usd != pytest.approx(600 * 2.5e-06)
    assert context.cost_usd != pytest.approx(600 * 2e-07)


def test_an_unpriced_model_reports_no_cost_rather_than_a_guess(tmp_path, monkeypatch):
    context = context_for(
        tmp_path, monkeypatch, {"some/other-model": RATES},
        input_tokens=1000, output_tokens=100)
    assert context.cost_usd is None


def test_an_entry_without_usable_rates_is_not_a_free_model(tmp_path, monkeypatch):
    zeroed = {**RATES, "input_cost_per_token": 0.0, "output_cost_per_token": 0.0}
    context = context_for(
        tmp_path, monkeypatch, {"anthropic/claude-fable-5": zeroed},
        input_tokens=1000, output_tokens=100)
    assert context.cost_usd is None


def test_an_episode_with_no_usage_has_no_cost(tmp_path, monkeypatch):
    context = context_for(tmp_path, monkeypatch, {"anthropic/claude-fable-5": RATES})
    assert context.cost_usd is None


def test_a_missing_cache_class_does_not_zero_the_rest(tmp_path, monkeypatch):
    # Older result.json files carry no cache split at all. Their input and
    # output are still real and still cost money.
    context = context_for(
        tmp_path, monkeypatch, {"anthropic/claude-fable-5": RATES},
        input_tokens=1000, output_tokens=100)
    assert context.cost_usd == pytest.approx(1000 * 2e-06 + 100 * 1e-05)
