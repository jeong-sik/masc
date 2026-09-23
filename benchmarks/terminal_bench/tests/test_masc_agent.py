import asyncio
import hashlib
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.masc_agent import MascAgent  # noqa: E402
from masc_task_skills import (  # noqa: E402
    SKILL_CATALOG_SCHEMA,
    validate_task_skill_catalog,
)
from render_configs import (  # noqa: E402
    TASK_SKILL_SOURCE_ID,
    TASK_SKILLS_RUNTIME_PATH,
)
import masc_dist  # noqa: E402


class FakeResult:
    def __init__(self, stdout="", return_code=0):
        self.stdout = stdout
        self.returncode = return_code
        self.return_code = return_code
        self.stderr = ""


class FakeEnv:
    def __init__(self, remote_dirs=None, skill_catalog=None):
        self.commands = []
        self.exec_kwargs = []
        self.uploads = []
        self.uploaded_bytes = {}
        self.downloads = []
        self.remote_dirs = remote_dirs or {}
        self.skill_catalog = skill_catalog
        self.default_user = None
        self.machine = "x86_64"

    async def upload_file(self, src, dst):
        self.uploads.append(("file", str(src), dst))
        self.uploaded_bytes[dst] = Path(src).read_bytes()

    async def upload_dir(self, src, dst):
        self.uploads.append(("dir", str(src), dst))

    async def download_dir(self, src, dst):
        self.downloads.append((src, str(dst)))
        shutil.copytree(self.remote_dirs[src], dst)

    async def is_dir(self, path, user=None):
        return path in self.remote_dirs

    async def exec(self, command, **kw):
        self.commands.append(command)
        self.exec_kwargs.append(kw)
        if "uname -m" in command:
            # harbor's docker exec folds stderr into stdout.
            return FakeResult("bash: warning: setlocale: LC_ALL: cannot change locale\n"
                              f"MASC_UNAME_M={self.machine}\n")
        if "cat /opt/masc-bench/result.json" in command:
            return FakeResult('{"state":"Succeeded","duration_ms":1234,'
                              '"tool_calls":17,"duplicate_tool_calls":2,"final":{}}')
        if "/api/v1/skills" in command and self.skill_catalog is not None:
            return FakeResult(json.dumps(self.skill_catalog))
        return FakeResult("")


@pytest.fixture(autouse=True)
def _provider_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.delenv("GH_TOKEN", raising=False)


SOURCE_COMMIT = "a" * 40


def write_dist_manifest(root, version):
    architectures = {}
    machines = {"linux-x64": ("x86_64", "linux/amd64"),
                "linux-arm64": ("aarch64", "linux/arm64")}
    for directory, (machine, platform) in machines.items():
        dist_dir = root / "dist" / directory
        if not dist_dir.exists():
            continue
        binaries = {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in dist_dir.iterdir()
            if path.name in masc_dist.KNOWN_BINARIES
        }
        architectures[directory] = {
            "machine": machine, "platform": platform, "binaries": binaries}
    (root / "dist" / masc_dist.MANIFEST_FILE).write_text(json.dumps({
        "schema": masc_dist.MANIFEST_SCHEMA,
        "release_version": version.strip(),
        "source_commit": SOURCE_COMMIT,
        "architectures": architectures,
    }))


def fake_bench(tmp_path, dist_dir="linux-x64",
               names=("masc", "masc-exec-shim", "gh"),
               version=None):
    root = tmp_path / "bench"
    (root / "dist" / dist_dir).mkdir(parents=True)
    for name in names:
        (root / "dist" / dist_dir / name).write_text("")
    # image/fetch_masc.sh commits the release it fetched; the floor by default.
    fetched = masc_dist.MIN_VERSION_FILE.read_text() if version is None else version
    write_dist_manifest(root, fetched)
    (root / "driver").mkdir()
    return root


def make_agent(tmp_path, **kw):
    return MascAgent(logs_dir=tmp_path, model_name="anthropic/claude-fable-5", **kw)


def write_task_skill(root, name="task-guide"):
    package = root / name
    (package / "references").mkdir(parents=True)
    (package / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: Task guide.\n---\n\nRead the reference.\n")
    (package / "references" / "guide.md").write_text("nested resource\n")
    return root


def task_catalog(name="task-guide"):
    identity = {"source_id": TASK_SKILL_SOURCE_ID, "package_id": name, "name": name}
    return {
        "schema": SKILL_CATALOG_SCHEMA,
        "state": "ready",
        "snapshot": {
            "config": {"kind": "configured", "revision": "fixture"},
            "sources": [{
                "id": TASK_SKILL_SOURCE_ID,
                "anchor": "base-path",
                "path": TASK_SKILLS_RUNTIME_PATH,
                "access": "read-only",
                "observation": {"kind": "ready"},
            }],
            "skills": [{"identity": identity}],
            "effective_skills": [identity],
            "shadows": [],
            "rejections": [],
        },
    }


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

    root = fake_bench(tmp_path)

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


def test_install_snapshots_remote_task_skills_and_checks_catalog(tmp_path, monkeypatch):
    import agents.masc_agent as m

    root = fake_bench(tmp_path)
    remote = write_task_skill(tmp_path / "remote-skills")

    class CapturingEnv(FakeEnv):
        def __init__(self):
            super().__init__(remote_dirs={"/task/skills": remote},
                             skill_catalog=task_catalog())
            self.config_copy = tmp_path / "uploaded-config"

        async def upload_dir(self, src, dst):
            await super().upload_dir(src, dst)
            if dst == "/opt/masc-bench/config":
                shutil.copytree(src, self.config_copy)

    async def go():
        monkeypatch.setattr(m, "BENCH_ROOT", root)
        agent = make_agent(tmp_path / "logs", arm="b", skills_dir="/task/skills")
        env = CapturingEnv()
        await agent.install(env)
        return env

    env = asyncio.run(go())
    assert env.downloads and env.downloads[0][0] == "/task/skills"
    resource = env.config_copy / "task-skills/task-guide/references/guide.md"
    assert resource.read_text() == "nested resource\n"
    assert any("/api/v1/skills" in command for command in env.commands)


def test_install_refuses_a_missing_task_skills_directory(tmp_path, monkeypatch):
    import agents.masc_agent as m

    root = fake_bench(tmp_path)

    async def go():
        monkeypatch.setattr(m, "BENCH_ROOT", root)
        agent = make_agent(tmp_path / "logs", arm="b", skills_dir="/missing")
        env = FakeEnv()
        with pytest.raises(RuntimeError, match="not a directory"):
            await agent.install(env)
        return env

    env = asyncio.run(go())
    assert not any("bootstrap.sh" in command for command in env.commands)


@pytest.mark.parametrize("failure", ["rejection", "shadow", "missing_effective"])
def test_task_skill_catalog_failures_are_not_silent(failure):
    catalog = task_catalog()
    snapshot = catalog["snapshot"]
    identity = snapshot["effective_skills"][0]
    if failure == "rejection":
        snapshot["rejections"] = [
            {"source_id": TASK_SKILL_SOURCE_ID,
             "reason": {"kind": "document_rejected"}}]
    elif failure == "shadow":
        snapshot["shadows"] = [{
            "winner": identity,
            "shadowed": {"source_id": "project-masc", "package_id": "task-guide",
                         "name": "task-guide"},
        }]
    else:
        snapshot["effective_skills"] = []
    with pytest.raises(RuntimeError):
        validate_task_skill_catalog(catalog, ["task-guide"])


@pytest.mark.parametrize("field", ["rejections", "shadows"])
def test_task_skill_catalog_requires_diagnostic_lists(field):
    catalog = task_catalog()
    del catalog["snapshot"][field]
    with pytest.raises(RuntimeError, match=field):
        validate_task_skill_catalog(catalog, ["task-guide"])


@pytest.mark.parametrize("field", ["rejections", "shadows"])
@pytest.mark.parametrize("value", [None, {}, "not-a-list"])
def test_task_skill_catalog_refuses_non_list_diagnostics(field, value):
    catalog = task_catalog()
    catalog["snapshot"][field] = value
    with pytest.raises(RuntimeError, match=field):
        validate_task_skill_catalog(catalog, ["task-guide"])


@pytest.mark.parametrize("failure", ["missing_schema", "wrong_schema", "wrong_anchor", "wrong_path"])
def test_task_skill_catalog_refuses_a_different_public_contract(failure):
    catalog = task_catalog()
    source = catalog["snapshot"]["sources"][0]
    if failure == "missing_schema":
        del catalog["schema"]
    elif failure == "wrong_schema":
        catalog["schema"] = "masc.skill-snapshot/v2"
    elif failure == "wrong_anchor":
        source["anchor"] = "user-home"
    else:
        source["path"] = ".masc/other-skills"
    with pytest.raises(RuntimeError):
        validate_task_skill_catalog(catalog, ["task-guide"])


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


def test_the_failover_arm_hands_keeper_up_the_lane(tmp_path, monkeypatch):
    # keeper_up writes its runtime_id as the keeper's assignment, so the head
    # runtime here would pin the keeper to one model (#37952).
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key")
    a = MascAgent(logs_dir=tmp_path, model_name="openrouter/z-ai/glm-5.3", arm="l",
                  fallback_models="openrouter/deepseek/deepseek-v4-pro")
    assert a.fallback_runtime_ids == ("openrouter.deepseek/deepseek-v4-pro",)
    assert a._container_env()["BENCH_RUNTIME_ID"] == "bench"


def test_fallback_models_are_refused_at_construction(tmp_path):
    with pytest.raises(ValueError, match="renders one model"):
        make_agent(tmp_path, arm="e", fallback_models="anthropic/claude-sonnet-5")
    with pytest.raises(ValueError, match="at least one fallback"):
        make_agent(tmp_path, arm="l")
    with pytest.raises(ValueError, match="provider/model"):
        make_agent(tmp_path, arm="l", fallback_models="claude-sonnet-5")


def test_claude_code_lane_requires_oauth_token(tmp_path, monkeypatch):
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    a = MascAgent(logs_dir=tmp_path, model_name="claude_code/claude-sonnet-5", arm="b")
    with pytest.raises(RuntimeError, match="CLAUDE_CODE_OAUTH_TOKEN"):
        a._container_env()


def install_into(tmp_path, monkeypatch, root, env):
    """{remote path: bytes uploaded there last}."""
    import agents.masc_agent as m

    monkeypatch.setattr(m, "BENCH_ROOT", root)
    asyncio.run(make_agent(tmp_path, arm="b").install(env))
    return env.uploaded_bytes


def test_gh_is_uploaded_only_for_a_run_that_gives_a_github_login(tmp_path, monkeypatch):
    root = fake_bench(tmp_path, names=("masc", "masc-exec-shim", "gh"))
    assert "/opt/masc-bench/bin/gh" not in install_into(tmp_path, monkeypatch, root, FakeEnv())
    monkeypatch.setenv("GH_TOKEN", "test-gh-token")
    uploads = install_into(tmp_path, monkeypatch, root, FakeEnv())
    assert uploads["/opt/masc-bench/bin/gh"] == (
        root / "dist" / "linux-x64" / "gh").read_bytes()


# --- the binaries follow the task container's architecture -----------------
#
# Harbor builds a 4.0 task image for the Docker daemon's architecture, so on
# Apple Silicon the task container is arm64 and an amd64 masc cannot start in
# it. A single-architecture base image still runs amd64, emulated. Both
# architectures are fetched, as image/fetch_masc.sh leaves them.


def both_architectures(tmp_path):
    root = fake_bench(tmp_path, dist_dir="linux-arm64")
    for name in ("masc", "masc-exec-shim", "gh"):
        (root / "dist" / "linux-arm64" / name).write_text("arm64:" + name)
    (root / "dist" / "linux-x64").mkdir()
    for name in ("masc", "masc-exec-shim", "gh"):
        (root / "dist" / "linux-x64" / name).write_text("x64:" + name)
    write_dist_manifest(root, masc_dist.MIN_VERSION_FILE.read_text())
    return root


def expected(root, dist_dir):
    return {f"/opt/masc-bench/bin/{name}": (root / "dist" / dist_dir / name).read_bytes()
            for name in ("masc", "masc-exec-shim")}


def test_an_arm64_container_gets_the_arm64_binaries(tmp_path, monkeypatch):
    root = both_architectures(tmp_path)
    env = FakeEnv()
    env.machine = "aarch64"
    assert install_into(tmp_path, monkeypatch, root, env) == expected(root, "linux-arm64")


def test_an_amd64_container_gets_the_x64_binaries(tmp_path, monkeypatch):
    root = both_architectures(tmp_path)
    assert install_into(tmp_path, monkeypatch, root, FakeEnv()) == expected(root, "linux-x64")


def test_a_container_architecture_without_a_release_is_refused_by_name(tmp_path, monkeypatch):
    env = FakeEnv()
    env.machine = "ppc64le"
    with pytest.raises(RuntimeError, match="ppc64le"):
        install_into(tmp_path, monkeypatch, fake_bench(tmp_path), env)
    assert env.uploads == []


def test_a_missing_architecture_names_the_fetch_step(tmp_path, monkeypatch):
    env = FakeEnv()
    env.machine = "aarch64"
    with pytest.raises(RuntimeError, match="fetch_masc.sh"):
        install_into(tmp_path, monkeypatch, fake_bench(tmp_path, dist_dir="linux-x64"), env)


# --- the fetched release must be one the bootstrap works with --------------
#
# An older shim refuses the bootstrap's env_file= per command, after install
# and keeper_up have passed, so the task would score zero instead of the run
# being refused. The committed manifest is checked before anything reaches
# the container.


@pytest.mark.parametrize("version, reason", [
    ("0.35.19", "older than"),
    ("0.35.20-rc1", "not an X.Y.Z release"),
    ("v0.35.20", "not an X.Y.Z release"),
])
def test_a_release_the_bootstrap_cannot_use_is_refused_before_upload(
        tmp_path, monkeypatch, version, reason):
    env = FakeEnv()
    with pytest.raises(RuntimeError, match=reason):
        install_into(tmp_path, monkeypatch, fake_bench(tmp_path, version=version), env)
    assert env.uploads == []


def test_a_task_that_names_its_agent_user_is_refused_before_upload(tmp_path, monkeypatch):
    # harbor would run its own agents as that account; the keepers run as the
    # image's user, so the two would differ.
    env = FakeEnv()
    env.default_user = "agent"
    with pytest.raises(RuntimeError, match="'agent'"):
        install_into(tmp_path, monkeypatch, fake_bench(tmp_path), env)
    assert env.uploads == []


def test_a_dist_without_a_committed_manifest_names_the_fetch_step(tmp_path, monkeypatch):
    root = fake_bench(tmp_path)
    (root / "dist" / masc_dist.MANIFEST_FILE).unlink()
    env = FakeEnv()
    with pytest.raises(RuntimeError, match="fetch_masc.sh"):
        install_into(tmp_path, monkeypatch, root, env)
    assert env.uploads == []


def test_a_matching_version_file_cannot_hide_changed_binary_bytes(tmp_path, monkeypatch):
    root = fake_bench(tmp_path)
    (root / "dist" / "linux-x64" / "masc").write_text("changed after commit")
    env = FakeEnv()
    with pytest.raises(RuntimeError, match="sha256 does not match"):
        install_into(tmp_path, monkeypatch, root, env)
    assert env.uploads == []


def test_releases_compare_as_numbers():
    assert masc_dist.release_version("0.35.100") > masc_dist.release_version("0.35.20")
    assert masc_dist.release_version(" 0.35.20\n") == (0, 35, 20)


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


def test_the_image_variables_the_keepers_lacked_reach_harbor_metadata(tmp_path):
    left_out = [{"name": "GH_TOKEN", "reason": "refused_by_shim"}]
    write_result(tmp_path, endpoint_env_left_out=left_out)
    context = SimpleNamespace(metadata=None)
    make_agent(tmp_path).populate_context_post_run(context)
    assert context.metadata["endpoint_env_left_out"] == left_out


def test_validated_dist_identity_reaches_harbor_metadata(tmp_path, monkeypatch):
    import agents.masc_agent as m

    root = fake_bench(tmp_path)
    monkeypatch.setattr(m, "BENCH_ROOT", root)
    logs = tmp_path / "logs"
    logs.mkdir()
    agent = make_agent(logs)
    asyncio.run(agent.install(FakeEnv()))
    write_result(logs)
    context = SimpleNamespace(metadata=None)
    agent.populate_context_post_run(context)
    identity = context.metadata["masc_dist"]
    assert identity["source_commit"] == SOURCE_COMMIT
    assert identity["binary_sha256"] == hashlib.sha256(
        (root / "dist" / "linux-x64" / "masc").read_bytes()).hexdigest()


def test_concurrent_dist_replacement_cannot_mix_one_upload_snapshot(
        tmp_path, monkeypatch):
    root = fake_bench(tmp_path)
    active = root / "dist" / "linux-x64"
    replacement = root / "dist" / "replacement"
    replacement.mkdir()
    for name in ("masc", "masc-exec-shim", "gh"):
        (replacement / name).write_text("new:" + name)
    original_copy = masc_dist.shutil.copy2
    replaced = False

    def replace_between_copies(source, destination):
        nonlocal replaced
        result = original_copy(source, destination)
        if not replaced:
            replaced = True
            active.rename(root / "dist" / "old-linux-x64")
            replacement.rename(active)
        return result

    monkeypatch.setattr(masc_dist.shutil, "copy2", replace_between_copies)
    with pytest.raises(RuntimeError, match="snapshot sha256 does not match"):
        asyncio.run(masc_dist.container_distribution(
            make_agent(tmp_path), FakeEnv(), root, tmp_path / "snapshot",
            with_gh=False))


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
    # gap is why collect_result.sh reports the two apart.
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


def test_an_episode_runs_without_a_github_credential(tmp_path, monkeypatch):
    """The remote_ssh preflight checks a GitHub login only for an endpoint that
    has one (#35412), and a token given here reaches every task container."""
    assert "GH_TOKEN" not in make_agent(tmp_path)._container_env()
    monkeypatch.setenv("GH_TOKEN", "test-gh-token")
    assert make_agent(tmp_path)._container_env()["GH_TOKEN"] == "test-gh-token"


# --- harbor's agent timeout is the only bound on an episode ----------------
#
# Terminal-Bench 4.0 gives every task 28800s. The adapter used to stop the
# episode at 2400s on its own and cap bootstrap at 900s, so a full run measured
# 40 minutes of an 8-hour task. Harbor never tells an installed agent its
# timeout; it cancels run() when the time is up.


class EpisodeRunsUntilCancelled(FakeEnv):
    """run_episode.sh never returns; the interrupted report is what exists."""

    async def exec(self, command, **kw):
        if "run_episode.sh" in command:
            self.commands.append(command)
            self.exec_kwargs.append(kw)
            await asyncio.Event().wait()
        self.commands.append(command)
        self.exec_kwargs.append(kw)
        if "cat /opt/masc-bench/result.json" in command:
            return FakeResult('{"state":"Running","interrupted":true,'
                              '"duration_ms":28800000,"tool_calls":412,'
                              '"duplicate_tool_calls":9,"final":{}}')
        return FakeResult("")


def test_the_container_env_names_no_episode_deadline(tmp_path):
    assert "EPISODE_TIMEOUT_SEC" not in make_agent(tmp_path)._container_env()


def test_bootstrap_is_bounded_by_harbor_setup_timeout_alone(tmp_path, monkeypatch):
    import agents.masc_agent as m

    root = fake_bench(tmp_path)
    monkeypatch.setattr(m, "BENCH_ROOT", root)
    env = FakeEnv()
    asyncio.run(make_agent(tmp_path, arm="b").install(env))
    bootstrap = [kw for c, kw in zip(env.commands, env.exec_kwargs)
                 if "bootstrap.sh" in c]
    assert bootstrap and bootstrap[0].get("timeout_sec") is None


def test_a_harbor_timeout_stops_the_keepers_and_reports_the_episode(tmp_path):
    from harbor.models.agent.context import AgentContext

    env = EpisodeRunsUntilCancelled()
    ctx = AgentContext()

    async def go():
        # The same call harbor makes (trial.py: asyncio.wait_for(run(...))).
        await asyncio.wait_for(make_agent(tmp_path, arm="b").run("task", env, ctx),
                               timeout=0.05)

    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(go())
    collect = [i for i, c in enumerate(env.commands)
               if "collect_result.sh /opt/masc-bench/result.json --interrupted" in c]
    read = [i for i, c in enumerate(env.commands)
            if "cat /opt/masc-bench/result.json" in c]
    assert collect and read and collect[0] < read[0]
    assert ctx.metadata["interrupted"] is True
    assert ctx.metadata["masc_state"] == "Running"
    assert ctx.metadata["tool_calls"] == 412


def test_an_episode_that_ends_on_its_own_is_not_collected_twice(tmp_path):
    from harbor.models.agent.context import AgentContext

    env = FakeEnv()
    asyncio.run(make_agent(tmp_path, arm="b").run("task", env, AgentContext()))
    assert not any("--interrupted" in c for c in env.commands)


class EpisodeEndsInFailure(FakeEnv):
    """run_episode.sh reported a Failed episode and exited 1 on its own."""

    async def exec(self, command, **kw):
        self.commands.append(command)
        self.exec_kwargs.append(kw)
        if "run_episode.sh" in command:
            return FakeResult("", return_code=1)
        if "cat /opt/masc-bench/result.json" in command:
            return FakeResult('{"state":"Failed","interrupted":false,"final":{}}')
        return FakeResult("")


def test_an_episode_that_fails_on_its_own_is_not_reported_as_interrupted(tmp_path):
    from harbor.models.agent.context import AgentContext

    env = EpisodeEndsInFailure()
    ctx = AgentContext()
    with pytest.raises(Exception):  # harbor's NonZeroAgentExitCodeError
        asyncio.run(make_agent(tmp_path, arm="b").run("task", env, ctx))
    assert not any("--interrupted" in c for c in env.commands)
    assert ctx.metadata["masc_state"] == "Failed"
    assert ctx.metadata["interrupted"] is False


def test_the_interrupted_report_is_bounded_after_the_time_is_up(tmp_path):
    import agents.masc_agent as m
    from harbor.models.agent.context import AgentContext

    env = EpisodeRunsUntilCancelled()

    async def go():
        await asyncio.wait_for(
            make_agent(tmp_path, arm="b").run("task", env, AgentContext()), timeout=0.05)

    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(go())
    recovery = [kw for c, kw in zip(env.commands, env.exec_kwargs)
                if "--interrupted" in c or "cat /opt/masc-bench/result.json" in c]
    assert recovery and all(
        kw.get("timeout_sec") == m.RESULT_RECOVERY_TIMEOUT_SEC for kw in recovery)
