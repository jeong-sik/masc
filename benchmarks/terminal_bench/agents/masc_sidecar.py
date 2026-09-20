"""The MASC server that arm K puts beside a coding agent, and its wiring.

Arm K's claim is that the difference between it and its baseline is one
thing: whether a keeper fleet is reachable as MCP tools. That claim only
holds if the two arms are otherwise the same binary, the same model and the
same prompt — so the sidecar is kept apart from the agent that talks to it,
and each agent variant adds only the two lines its own config format needs.

Two facts decide the wiring, and they are properties of MASC rather than of
any agent:

- `Tool_catalog_surfaces.public_mcp_surface_tools` already exposes
  masc_keeper_up / down / msg / status / list / delegate_status plus the
  board, task and goal tools to an external MCP client. Nothing in MASC has
  to change for a client to drive keepers.
- The chat approval stance (`Keeper_tool_approval_mode`) is in-memory, has no
  config default by design, and is set only over REST — which an MCP client
  cannot reach. The setter also answers 404 for a keeper that is not
  registered yet (measured on 0.35.8, 2026-09-12), so the stance cannot be
  pre-declared either. bootstrap.sh therefore stands the pool up and sets the
  stance, and the model addresses keepers that already exist. A keeper the
  model starts itself is `Auto` and would stall, which the appended prompt
  says out loud. Issue #35319 filed upstream.

The bearer token is minted by `masc login` inside the container, against the
running server, so the host cannot know it in advance and cannot write it
into a config it renders locally. Every agent variant therefore patches its
own config file *in the container*, after bootstrap, reading the token from
disk there.
"""
from __future__ import annotations

import asyncio
import json
import shutil
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Any

from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from render_configs import (  # noqa: E402
    ARMS,
    PROVIDERS,
    effective_runtime_id,
    render_arm,
)
from masc_dist import container_binaries  # noqa: E402
from masc_task_skills import (  # noqa: E402
    preflight_task_skill_catalog,
    task_skills_snapshot,
)

REMOTE = "/opt/masc-bench"
TOKEN_PATH = f"{REMOTE}/token"
# bootstrap.sh sets MASC_BASE_PATH to this, and MASC writes one cost row per
# provider turn under it.
KEEPER_COSTS = f"{REMOTE}/base/.masc/costs"
MASC_MCP_URL = "http://127.0.0.1:8935/mcp"
MCP_SERVER_NAME = "masc"

POOL_PROMPT = """\
A MASC server runs in this container and is registered as the MCP server \
`{server}`. A fleet of keeper agents is already running on it: {names}. Each \
one executes its shell commands in this same container.

- `masc_keeper_msg` gives a keeper work. `masc_keeper_status` and \
`masc_keeper_list` report on what they are doing.
- They share a board and a task ledger with you: `masc_board_post`, \
`masc_add_task`, `masc_tasks`, `masc_broadcast`.
- Address the keepers listed above. One you start yourself with \
`masc_keeper_up` will wait for an approval nobody is there to give.

Using them is optional. You remain responsible for the task either way.\
"""


def pool_names(arm: str) -> list[str]:
    if arm not in ARMS:
        raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
    return [f"bench-{i}" for i in range(1, ARMS[arm]["keepers"] + 1)]


def pool_prompt(names: list[str]) -> str:
    return POOL_PROMPT.format(
        server=MCP_SERVER_NAME, names=", ".join(f"`{n}`" for n in names)
    )


def runtime_id_from_model(model_name: str | None) -> str:
    """`provider/model` as harbor names it → `provider.model` as MASC binds it.

    A bare model name has no MASC provider to bind, so it is an error rather
    than a guess: guessing produces a config that loads and a keeper that
    never answers.
    """
    model = model_name or ""
    if "/" not in model:
        raise ValueError(
            "keeper_runtime_id kwarg required when --model is not "
            f"'provider/model' (got {model!r})"
        )
    provider, name = model.split("/", 1)
    return f"{provider}.{name}"


class MascSidecar:
    """Installs the MASC server into the task container beside the agent.

    Mixed into a harbor installed agent. The agent class owns `arm`,
    `pool_names`, `keeper_runtime_id` and `keeper_effort`; this contributes
    the container environment and the install step, both of which are the
    same whichever agent is being measured.
    """

    arm: str
    pool_names: list[str]
    keeper_runtime_id: str
    keeper_effort: str
    skills_dir: str | None

    if TYPE_CHECKING:
        # Supplied by the harbor agent this is mixed into. Declared so the
        # mixin's requirement on its host is visible and type-checked rather
        # than discovered at run time.
        exec_as_root: Callable[..., Awaitable[Any]]
        _get_env: Callable[..., str | None]

    def masc_container_env(self) -> dict[str, str]:
        provider = self.keeper_runtime_id.split(".", 1)[0]
        if provider not in PROVIDERS:
            raise ValueError(
                f"unknown provider {provider!r}; expected one of {sorted(PROVIDERS)}")
        key_env = PROVIDERS[provider]["api_key_env"]
        key = self._get_env(key_env)
        if not key:
            raise RuntimeError(f"{key_env} not set in Harbor agent environment")
        env = {
            key_env: key,
            # MASC resolves `<provider>.<binding id>`, and the binding id is a
            # slug when the wire model carries a slash (OpenRouter). Rendering
            # takes the wire form; keeper_up takes this one.
            "BENCH_RUNTIME_ID": effective_runtime_id(self.keeper_runtime_id),
            # Names the pool bootstrap brings up and sets the approval stance
            # for, before any of them is addressed. See the module docstring.
            "BENCH_KEEPER_POOL": ",".join(self.pool_names),
        }
        # Optional. A keeper gets a GitHub login only when this is set:
        # bootstrap writes hosts.yml from it, and the remote_ssh preflight
        # runs `gh auth status` only for an endpoint that has one (#35412).
        # _get_env also sees what `harbor run --ae` gives the agent, which harbor
        # applies to every exec as well; os.environ alone would disagree with
        # the container about whether a login was given.
        gh_token = self._get_env("GH_TOKEN")
        if gh_token:
            env["GH_TOKEN"] = gh_token
        return env

    async def install_masc(self, environment: BaseEnvironment) -> None:
        container_env = self.masc_container_env()
        async with task_skills_snapshot(self, environment) as (task_skills_dir, task_skills):
            binaries = await container_binaries(
                self, environment, BENCH_ROOT, with_gh="GH_TOKEN" in container_env)
            # A lane may read provider limits over the network while rendering;
            # harbor installs every trial in one event loop.
            config_dir = await asyncio.to_thread(
                render_arm, self.arm, self.keeper_runtime_id, self.keeper_effort,
                task_skills_dir=task_skills_dir)
            await self.exec_as_root(environment, f"mkdir -p {REMOTE}/bin")
            for binary in binaries:
                await environment.upload_file(binary, f"{REMOTE}/bin/{binary.name}")
            await environment.upload_dir(BENCH_ROOT / "driver", f"{REMOTE}/driver")
            try:
                await environment.upload_dir(config_dir, f"{REMOTE}/config")
            finally:
                # render_arm hands back a directory of its own so that concurrent
                # trials of one arm cannot delete each other's config mid-upload.
                # Whoever asked for it removes it.
                shutil.rmtree(config_dir, ignore_errors=True)
        await self.exec_as_root(
            environment,
            f"chmod +x {REMOTE}/bin/masc {REMOTE}/driver/*.sh && "
            f"bash {REMOTE}/driver/bootstrap.sh",
            env=container_env,
        )
        await preflight_task_skill_catalog(self, environment, task_skills)


async def merge_keeper_usage(
    agent, environment: BaseEnvironment, context: AgentContext
) -> None:
    """Add what the keepers spent to the episode totals.

    The harness records the agent process's own usage. Keepers reach providers
    themselves, and that spend lands in MASC's cost ledger inside the container
    rather than in anything harbor sees -- so without this an arm that delegates
    reads as cheaper than the baseline it exists to be compared with, which is
    the one number the comparison turns on.

    Rows whose usage the provider never reported are counted and carried in
    metadata rather than folded in as zero: a total that quietly omits turns is
    worse than one that says how many it could not see.
    """
    # AgentContext starts with no metadata at all rather than an empty mapping.
    if context.metadata is None:
        context.metadata = {}
    # `2>/dev/null || true` made every outcome exit 0, so the read_failed
    # branch below was unreachable and an unreadable ledger reported as a run
    # with no keeper spend. An absent directory is the one real zero -- no
    # keeper has written yet -- so it exits 0 on its own; anything else keeps
    # its status and its stderr.
    ledger = await environment.exec(
        f"test -d {KEEPER_COSTS} || exit 0; "
        f"find {KEEPER_COSTS} -name '*.jsonl' -type f -exec cat {{}} +"
    )
    if ledger.return_code != 0:
        context.metadata["keeper_usage"] = {"read_failed": ledger.stderr[-400:]}
        return
    totals = {"input": 0, "output": 0, "cache": 0}
    cost = 0.0
    rows = 0
    unreported = 0
    cost_unreported = 0
    unparseable = 0
    raw_observations = 0
    without_projection = 0
    for line in ledger.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            unparseable += 1
            continue
        # MASC writes two rows for one request: a raw_observation per provider
        # response (keeper_hooks_agent_core_cost_events.ml) and the turn's
        # accounted figure as resolved_delta
        # (keeper_unified_turn_success.ml). Summing both counts a
        # single-request turn twice, which is why the inference-metrics reader
        # drops the raw rows too (model_inference_metrics_reader.ml). The field
        # is required of a valid row, so a row without one is not a projection
        # this can classify and is counted rather than assumed.
        projection = row.get("usage_projection")
        if projection == "raw_observation":
            raw_observations += 1
            continue
        if projection != "resolved_delta":
            without_projection += 1
            continue
        rows += 1
        if row.get("usage_missing"):
            unreported += 1
        totals["input"] += int(row.get("input_tokens") or 0)
        totals["output"] += int(row.get("output_tokens") or 0)
        totals["cache"] += int(row.get("cache_read_tokens") or 0) + int(
            row.get("cache_creation_tokens") or 0
        )
        # A row the ledger could not price serializes cost_usd as null
        # (cost_ledger.ml). Adding it as zero publishes a number that reads as
        # measured, and cost is the one axis this arm is compared on, so the
        # count of unpriced rows travels with the total instead.
        row_cost = row.get("cost_usd")
        if row_cost is None:
            cost_unreported += 1
        else:
            cost += float(row_cost)
    parent_unreported = sorted(
        name
        for name, value in (
            ("n_input_tokens", context.n_input_tokens),
            ("n_output_tokens", context.n_output_tokens),
            ("n_cache_tokens", context.n_cache_tokens),
            ("cost_usd", context.cost_usd),
        )
        if value is None
    )
    # The agent's own usage is already here; these are additional requests, so
    # they add rather than replace.
    context.n_input_tokens = (context.n_input_tokens or 0) + totals["input"]
    context.n_output_tokens = (context.n_output_tokens or 0) + totals["output"]
    context.n_cache_tokens = (context.n_cache_tokens or 0) + totals["cache"]
    context.cost_usd = (context.cost_usd or 0.0) + cost
    context.metadata["keeper_usage"] = {
        "rows": rows,
        "input_tokens": totals["input"],
        "output_tokens": totals["output"],
        "cache_tokens": totals["cache"],
        "cost_usd": cost,
        "rows_without_reported_usage": unreported,
        # Read by aggregate.py into its own CSV column. Named here only, the
        # diagnostic never reached the table the arms are compared in, so an
        # unpriced keeper turn read as free.
        "cost_rows_unreported": cost_unreported,
        "unparseable_rows": unparseable,
        "raw_observation_rows": raw_observations,
        "rows_without_projection": without_projection,
        # aggregate.py reads None as unmeasured and 0 as measured, so a parent
        # field harbor never reported cannot be told apart from a measured
        # zero once the keeper spend is added to it. The sum is kept -- losing
        # the keeper figure is worse on the one axis the arm is compared on --
        # and the fields it rests on are named here, so a total that is only
        # the keeper's half says so.
        "parent_fields_unreported": parent_unreported,
    }


ENDPOINT_ENV_LEFT_OUT = f"{REMOTE}/endpoint-env-left-out.tsv"
# Harbor's docker environment returns stderr inside stdout (masc_dist.UNAME_MARK),
# so the JSON is printed on a marked line of its own.
LEFT_OUT_MARK = "MASC_ENDPOINT_ENV_LEFT_OUT="


async def merge_endpoint_env_left_out(
    environment: BaseEnvironment, context: AgentContext
) -> None:
    """Carry the image variables the keepers ran without into the result.

    The bootstrap records each one it could not hand to the shim
    (driver/endpoint_env.sh). masc_agent reads it from collect_result.sh; arm K
    never runs that script, so the record is read here.
    """
    if context.metadata is None:
        context.metadata = {}
    result = await environment.exec(
        f"bash -c 'source {REMOTE}/driver/endpoint_env.sh && "
        f"printf \"{LEFT_OUT_MARK}%s\\n\" \"$(bench_env_left_out_json {ENDPOINT_ENV_LEFT_OUT})\"'",
        user="root",
    )
    output = result.stdout or ""
    marked = [line[len(LEFT_OUT_MARK):] for line in output.splitlines()
              if line.startswith(LEFT_OUT_MARK)]
    if result.return_code != 0 or len(marked) != 1:
        context.metadata["endpoint_env_left_out"] = {
            "read_failed": (result.stderr or output)[-400:]}
        return
    try:
        context.metadata["endpoint_env_left_out"] = json.loads(marked[0])
    except json.JSONDecodeError as exc:
        context.metadata["endpoint_env_left_out"] = {"read_failed": str(exc)}


def read_token_guard() -> str:
    """Shell that puts a non-empty bearer token in `$masc_token`, or exits 1.

    This guard is the difference between arm K and its own baseline. An
    unreadable token yields `Authorization: Bearer ` and exit 0: the agent
    starts, its MCP server 401s, the model finds no keeper tools, and the
    trial records as a baseline run rather than as a broken one.
    """
    return (
        f'masc_token="$(cat {TOKEN_PATH})" && '
        '[ -n "$masc_token" ] || '
        f'{{ echo "masc MCP token at {TOKEN_PATH} is empty" >&2; exit 1; }}'
    )
