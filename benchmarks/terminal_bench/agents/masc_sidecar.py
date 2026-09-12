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

import os
import shutil
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Any

from harbor.environments.base import BaseEnvironment

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))

from render_configs import (  # noqa: E402
    ARMS,
    PROVIDERS,
    effective_runtime_id,
    render_arm,
)

REMOTE = "/opt/masc-bench"
TOKEN_PATH = f"{REMOTE}/token"
MASC_MCP_URL = "http://127.0.0.1:8935/mcp"
MCP_SERVER_NAME = "masc"

POOL_PROMPT = """\
A MASC server runs in this container and is registered as the MCP server \
`{server}`. A fleet of keeper agents is already running on it: {names}. Each \
one executes its shell commands in this same container, as root.

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

    if TYPE_CHECKING:
        # Supplied by the harbor agent this is mixed into. Declared so the
        # mixin's requirement on its host is visible and type-checked rather
        # than discovered at run time.
        exec_as_root: Callable[..., Awaitable[Any]]

    def masc_container_env(self) -> dict[str, str]:
        provider = self.keeper_runtime_id.split(".", 1)[0]
        if provider not in PROVIDERS:
            raise ValueError(
                f"unknown provider {provider!r}; expected one of {sorted(PROVIDERS)}")
        key_env = PROVIDERS[provider]["api_key_env"]
        key = os.environ.get(key_env)
        if not key:
            raise RuntimeError(f"{key_env} not set in harbor process env")
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
        # keeper_up's remote_ssh preflight runs `gh auth status` and refuses
        # without a GitHub identity.
        if os.environ.get("GH_TOKEN"):
            env["GH_TOKEN"] = os.environ["GH_TOKEN"]
        return env

    async def install_masc(self, environment: BaseEnvironment) -> None:
        binaries = [BENCH_ROOT / "dist" / "masc", BENCH_ROOT / "dist" / "masc-exec-shim"]
        for binary in binaries:
            if not binary.exists():
                raise RuntimeError("run image/fetch_masc.sh first")
        # gh is required by the keeper_up preflight and is absent from debian
        # stable, which most task base images use, so it ships in dist/ when
        # fetched. deps.sh falls back to the package manager without it.
        vendored_gh = BENCH_ROOT / "dist" / "gh"
        if vendored_gh.exists():
            binaries.append(vendored_gh)
        config_dir = render_arm(self.arm, self.keeper_runtime_id, self.keeper_effort)
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
            env=self.masc_container_env(),
            timeout_sec=900,
        )


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
