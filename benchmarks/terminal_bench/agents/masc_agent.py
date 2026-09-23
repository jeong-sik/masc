"""MASC harness as a Harbor installed agent (spec §5, approach A).

install(): prebuilt masc 바이너리 + bash 드라이버 + 렌더된 arm config를
태스크 컨테이너 /opt/masc-bench에 업로드하고 bootstrap.sh를 root로 실행한다.
run(): instruction을 업로드하고 run_episode.sh를 실행한 뒤 collect_result.sh 가 쓴 result.json을
읽어 AgentContext에 싣는다.
"""
from __future__ import annotations

import asyncio
import json
import shutil
import sys
import tempfile
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from render_configs import (  # noqa: E402
    ARMS,
    PROVIDERS,
    candidate_runtime_ids,
    keeper_route,
    render_arm,
)
from masc_dist import (  # noqa: E402
    DistIdentity,
    container_distribution,
    identity_metadata,
    require_fetched_release,
)
from masc_task_skills import (  # noqa: E402
    preflight_task_skill_catalog,
    task_skills_snapshot,
)

REMOTE = "/opt/masc-bench"

# Bounds the report written after harbor's agent timeout has already fired.
# Harbor waits for run() to return once it cancels it, with no limit of its
# own, so an exec into a wedged container would hold the trial open forever.
# This is not time given to the agent: the keepers are stopped first, and what
# remains is counting the tool-call store and the trace dumps.
RESULT_RECOVERY_TIMEOUT_SEC = 600


def _runtime_id_of_model(model: str) -> str:
    """`provider/model` as harbor names it -> `provider.model`."""
    provider, sep, name = model.strip().partition("/")
    if not sep or not provider or not name:
        raise ValueError(f"fallback model must be 'provider/model', got {model!r}")
    return f"{provider}.{name}"


class MascAgent(BaseInstalledAgent):
    def __init__(self, logs_dir, model_name=None, arm="b",
                 runtime_id=None, effort="high", fallback_models="", **kwargs):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)
        if arm not in ARMS:
            raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
        self.arm = arm
        self.effort = effort
        if runtime_id:
            self.runtime_id = runtime_id
        elif model_name and "/" in model_name:
            provider, model = model_name.split("/", 1)
            self.runtime_id = f"{provider}.{model}"
        else:
            raise ValueError("model_name 'provider/model' 또는 runtime_id kwarg 필요")
        # `--ak fallback_models=p/m1,p/m2` (run_matrix.sh BENCH_FALLBACK_MODELS):
        # the models after --model in the failover arm's candidate order. Checked
        # here so a bad list fails at agent construction, not after install.
        self.fallback_runtime_ids = tuple(
            _runtime_id_of_model(m) for m in fallback_models.split(",") if m.strip())
        candidate_runtime_ids(self.arm, self.runtime_id, self.fallback_runtime_ids)
        self._dist_identity: DistIdentity | None = None

    @staticmethod
    def name() -> str:
        return "masc"

    def version(self) -> str:
        try:
            return require_fetched_release(BENCH_ROOT)["release_version"]
        except (OSError, RuntimeError):
            return "unknown"

    def _container_env(self) -> dict[str, str]:
        provider = self.runtime_id.split(".", 1)[0]
        if provider not in PROVIDERS:
            raise ValueError(
                f"unknown provider {provider!r}; expected one of {sorted(PROVIDERS)}")
        key_env = PROVIDERS[provider]["api_key_env"]
        key = self._get_env(key_env)
        if not key:
            raise RuntimeError(f"{key_env} not set in Harbor agent environment")
        env = {
            key_env: key,
            # masc resolves `<provider>.<binding id>`, and the binding id is a
            # slug when the wire model carries a slash (OpenRouter). Rendering
            # takes the wire form; keeper_up takes this one.
            # On a failover arm this is the lane (keeper_route): keeper_up
            # writes it as the keeper's assignment.
            "BENCH_RUNTIME_ID": keeper_route(
                self.arm, self.runtime_id, self.fallback_runtime_ids),
            "KEEPER_COUNT": str(ARMS[self.arm]["keepers"]),
        }
        # Optional. A keeper gets a GitHub login only when this is set:
        # gh_seed.sh writes hosts.yml from it, and the remote_ssh preflight
        # runs `gh auth status` only for an endpoint that has one (#35412).
        # Terminal-Bench tasks do not need GitHub, and a token passed here
        # lands in every task container of the run.
        # _get_env also sees what `harbor run --ae` gives the agent, which harbor
        # applies to every exec as well; os.environ alone would disagree with
        # the container about whether a login was given.
        gh_token = self._get_env("GH_TOKEN")
        if gh_token:
            env["GH_TOKEN"] = gh_token
        return env

    async def install(self, environment: BaseEnvironment) -> None:
        container_env = self._container_env()
        async with task_skills_snapshot(self, environment) as (task_skills_dir, task_skills):
            with tempfile.TemporaryDirectory(prefix="masc-bench-dist-") as snapshot:
                distribution = await container_distribution(
                    self, environment, BENCH_ROOT, Path(snapshot),
                    with_gh="GH_TOKEN" in container_env)
                self._dist_identity = distribution.identity
                # A lane may read provider limits over the network while rendering;
                # harbor installs every trial in one event loop.
                config_dir = await asyncio.to_thread(
                    render_arm, self.arm, self.runtime_id, self.effort,
                    task_skills_dir=task_skills_dir,
                    fallback_runtime_ids=self.fallback_runtime_ids)
                await self.exec_as_root(environment, f"mkdir -p {REMOTE}/bin")
                for binary in distribution.binaries:
                    await environment.upload_file(binary, f"{REMOTE}/bin/{binary.name}")
            await environment.upload_dir(BENCH_ROOT / "driver", f"{REMOTE}/driver")
            try:
                await environment.upload_dir(config_dir, f"{REMOTE}/config")
            finally:
                # render_arm hands back a directory of its own so that
                # concurrent trials of one arm cannot delete each other's
                # config mid-upload. Whoever asked for it removes it.
                shutil.rmtree(config_dir, ignore_errors=True)
        await self.exec_as_root(
            environment,
            f"chmod +x {REMOTE}/bin/masc {REMOTE}/driver/*.sh && "
            f"bash {REMOTE}/driver/bootstrap.sh",
            env=container_env,
        )
        await preflight_task_skill_catalog(self, environment, task_skills)

    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        instr_local = Path(self.logs_dir) / "instruction.txt"
        instr_local.parent.mkdir(parents=True, exist_ok=True)
        instr_local.write_text(instruction)
        await environment.upload_file(instr_local, f"{REMOTE}/instruction.txt")
        interrupted = False
        try:
            await self.exec_as_root(
                environment,
                f"bash {REMOTE}/driver/run_episode.sh "
                f"{REMOTE}/instruction.txt {REMOTE}/result.json",
                env=self._container_env(),
                timeout_sec=None,  # harbor's agent timeout is the only bound
            )
        except asyncio.CancelledError:
            # Harbor enforces its agent timeout by cancelling run(), and never
            # tells the agent what the timeout is. The episode in the container
            # is still running and has written no result yet.
            interrupted = True
            raise
        finally:
            # run_episode.sh exits non-zero unless the episode Succeeded, so
            # the exec above raises. Harbor must still record that as the run
            # error; before it does, the result is recovered into the context.
            # Nothing in here may raise. It runs in `finally`, so an
            # exception raised while recovering the result would replace the
            # episode failure this block exists to preserve — a truncated
            # result.json would surface as a JSONDecodeError from the
            # recovery path instead of as the run error.
            if interrupted:
                # Its own try: a report that fails to finish must not stop the
                # read below, which may still find one written by the episode.
                try:
                    await self.exec_as_root(
                        environment,
                        f"bash {REMOTE}/driver/collect_result.sh "
                        f"{REMOTE}/result.json --interrupted",
                        env=self._container_env(),
                        timeout_sec=RESULT_RECOVERY_TIMEOUT_SEC,
                    )
                except Exception:  # noqa: BLE001 - see above
                    self.logger.exception("reporting the interrupted episode failed")
            try:
                result = await self.exec_as_root(
                    environment, f"cat {REMOTE}/result.json 2>/dev/null || true",
                    timeout_sec=RESULT_RECOVERY_TIMEOUT_SEC)
                if result.stdout and result.stdout.strip():
                    (Path(self.logs_dir) / "result.json").write_text(result.stdout)
                self.populate_context_post_run(context)
            except Exception:  # noqa: BLE001 - see above
                self.logger.exception("recovering the episode result failed")

    def _cost_usd(self, usage) -> float | None:
        """What this episode cost, from the four token counts and litellm.

        Every other arm's cost arrives from harbor, and the judging rule this
        benchmark exists to answer is a cost-per-task one. Leaving it None for
        the MASC arms does not make the comparison cautious — it removes the
        arms from it.

        Cache creation and cache read are priced separately and can differ by
        an order of magnitude, so they are read apart rather than from the
        summed cache_tokens. A model litellm cannot price returns None: a
        guessed rate would feed a rule that decides which arm is cheaper.
        """
        try:
            import litellm
        except ImportError:  # pragma: no cover - harbor ships it
            self.logger.debug("litellm not available; no cost for this episode")
            return None
        rates = litellm.model_cost.get(self.model_name)
        if not rates:
            self.logger.debug(
                "litellm prices no model named %s; cost left unmeasured",
                self.model_name)
            return None
        priced = {
            "input_tokens": rates.get("input_cost_per_token") or 0.0,
            "output_tokens": rates.get("output_cost_per_token") or 0.0,
            "cache_creation_tokens":
                rates.get("cache_creation_input_token_cost") or 0.0,
            "cache_read_tokens": rates.get("cache_read_input_token_cost") or 0.0,
        }
        if priced["input_tokens"] <= 0 and priced["output_tokens"] <= 0:
            # An entry with no usable input or output rate is not a free model.
            return None
        total = 0.0
        counted = False
        for key, rate in priced.items():
            tokens = usage(key)
            if tokens is None:
                continue
            counted = True
            total += tokens * rate
        return total if counted else None

    def populate_context_post_run(self, context: AgentContext) -> None:
        result_path = Path(self.logs_dir) / "result.json"
        if not result_path.exists():
            context.metadata = {
                **(context.metadata or {}), **identity_metadata(self._dist_identity)}
            return
        try:
            data = json.loads(result_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            # A truncated result.json is a fact about the run, not a reason to
            # lose it.
            context.metadata = {**(context.metadata or {}),
                                "masc_state": f"result_unreadable: {exc}",
                                "arm": self.arm, "runtime_id": self.runtime_id,
                                **identity_metadata(self._dist_identity)}
            return
        final = data.get("final") or {}
        fallback = final.get("usage") or {}

        def usage(key: str):
            # collect_result.sh emits episode-summed usage at the top level, read
            # from the agent-core trace dumps under .masc/traces. It always
            # writes the keys, using null when there was nothing to sum, so
            # `data.get(key, fallback)` never reaches the fallback — the key is
            # present and the value is None. final.usage.* is the older shape.
            value = data.get(key)
            return fallback.get(key) if value is None else value

        context.n_input_tokens = usage("input_tokens")
        context.n_cache_tokens = usage("cache_tokens")
        context.n_output_tokens = usage("output_tokens")
        context.cost_usd = self._cost_usd(usage)
        context.metadata = {
            **(context.metadata or {}),
            "masc_state": data.get("state"),
            "interrupted": data.get("interrupted"),
            "keepers_stopped": data.get("keepers_stopped"),
            "duration_ms": data.get("duration_ms"),
            "tool_calls": data.get("tool_calls"),
            "duplicate_tool_calls": data.get("duplicate_tool_calls"),
            # The image variables its keepers ran without (driver/endpoint_env.sh).
            "endpoint_env_left_out": data.get("endpoint_env_left_out"),
            "arm": self.arm,
            "runtime_id": self.runtime_id,
            "fallback_runtime_ids": list(self.fallback_runtime_ids),
            **identity_metadata(self._dist_identity),
        }
