"""Arm K — Claude Code with a MASC keeper fleet available as MCP tools.

The task is solved by harbor's own `claude-code` agent, unmodified. This
subclass adds one thing: a MASC server running in the same container,
registered as an HTTP MCP server, so the model can call `masc_keeper_up`,
`masc_keeper_msg`, `masc_keeper_status` and the shared board / task ledger
tools. Keepers dispatch their shell through the `remote_ssh` lane back into
this same container, so their work lands where the verifier looks.

The baseline is `--agent claude-code` with the same model and no MCP server,
which is a published leaderboard configuration. The only variable between the
two is whether a keeper fleet is reachable as tools, so a difference is
attributable to the multi-agent layer rather than to the harness.

Two facts decide the wiring:

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
  says out loud. Issue filed upstream.
"""
from __future__ import annotations

import json
import os
import shutil
import shlex
import sys
from pathlib import Path

from harbor.agents.installed.claude_code import ClaudeCode
from harbor.environments.base import BaseEnvironment

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))

from render_configs import (  # noqa: E402
    ARMS,
    PROVIDERS,
    effective_runtime_id,
    render_arm,
)

REMOTE = "/opt/masc-bench"
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

class KeeperToolsAgent(ClaudeCode):
    def __init__(
        self,
        *args,
        arm: str = "k",
        keeper_runtime_id: str | None = None,
        keeper_effort: str = "high",
        announce_pool: bool = True,
        **kwargs,
    ):
        if arm not in ARMS:
            raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
        pool_names = [f"bench-{i}" for i in range(1, ARMS[arm]["keepers"] + 1)]
        # CLI_FLAGS kwargs are consumed by BaseInstalledAgent.__init__, so the
        # default has to be in place before the chain runs. An explicit
        # --ak append_system_prompt=... still wins.
        if announce_pool:
            kwargs.setdefault(
                "append_system_prompt",
                POOL_PROMPT.format(
                    server=MCP_SERVER_NAME,
                    names=", ".join(f"`{n}`" for n in pool_names),
                ),
            )
        super().__init__(*args, **kwargs)
        self.arm = arm
        self.pool_names = pool_names
        self.keeper_effort = keeper_effort
        self.announce_pool = announce_pool
        self.keeper_runtime_id = keeper_runtime_id or self._derive_runtime_id()

    @staticmethod
    def name() -> str:
        return "masc-keeper-tools"

    def _derive_runtime_id(self) -> str:
        """Keepers run the same model the top agent does, unless overridden.

        harbor names models `provider/model`; a MASC runtime id is
        `provider.model`. A bare model name has no MASC provider to bind, so
        it is an error rather than a guess.
        """
        model = self.model_name or ""
        if "/" not in model:
            raise ValueError(
                "keeper_runtime_id kwarg required when --model is not "
                f"'provider/model' (got {model!r})"
            )
        provider, name = model.split("/", 1)
        return f"{provider}.{name}"

    def _container_env(self) -> dict[str, str]:
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
            # masc resolves `<provider>.<binding id>`, and the binding id is a
            # slug when the wire model carries a slash (OpenRouter). Rendering
            # takes the wire form; keeper_up takes this one.
            "BENCH_RUNTIME_ID": effective_runtime_id(self.keeper_runtime_id),
            # Names the pool bootstrap brings up and sets the approval stance
            # for, before any of them is addressed. See the module docstring.
            "BENCH_KEEPER_POOL": ",".join(self.pool_names),
        }
        if os.environ.get("GH_TOKEN"):
            env["GH_TOKEN"] = os.environ["GH_TOKEN"]
        return env

    async def install(self, environment: BaseEnvironment) -> None:
        # Claude Code first: it is the agent, MASC is the thing it can reach.
        await super().install(environment)
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
            # render_arm hands back a directory of its own so that
            # concurrent trials of one arm cannot delete each other's
            # config mid-upload. Whoever asked for it removes it.
            shutil.rmtree(config_dir, ignore_errors=True)
        await self.exec_as_root(
            environment,
            f"chmod +x {REMOTE}/bin/masc {REMOTE}/driver/*.sh && "
            f"bash {REMOTE}/driver/bootstrap.sh",
            env=self._container_env(),
            timeout_sec=900,
        )

    def _build_register_mcp_servers_command(self) -> str:
        """Add the MASC server to `.claude.json`, keeping any the task declared.

        Harbor's own writer emits no `headers`, and the MASC `/mcp` endpoint
        requires strict bearer auth, so the entry is built here instead. The
        token is minted inside the container by bootstrap.sh, so it is read at
        setup time rather than interpolated from the host.
        """
        entry = '{type:"http",url:$url,headers:{Authorization:("Bearer "+$t)}}'
        # The server name indexes a jq object, so it needs JSON quoting inside
        # the program; shlex.quote would leave a bare token that jq reads as an
        # identifier and rejects.
        program = f".mcpServers[{json.dumps(MCP_SERVER_NAME)}] = {entry}"
        config = '"$CLAUDE_CONFIG_DIR/.claude.json"'
        # Both guards are the difference between arm K and its own baseline.
        # An unreadable token yielded `Authorization: Bearer ` and exit 0, and
        # an unset CLAUDE_CONFIG_DIR wrote /.claude.json and exit 0 — either
        # way Claude Code starts with an MCP server that 401s or that it never
        # reads, the model finds no keeper tools, and the run looks like a
        # baseline run rather than a broken one.
        masc = (
            ': "${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR is unset}" && '
            f'masc_token="$(cat {REMOTE}/token)" && '
            '[ -n "$masc_token" ] || '
            f'{{ echo "masc MCP token at {REMOTE}/token is empty" >&2; exit 1; }}; '
            f"([ -f {config} ] || echo '{{}}' > {config}) && "
            f'jq --arg t "$masc_token" --arg url {shlex.quote(MASC_MCP_URL)} '
            f"{shlex.quote(program)} "
            f"{config} > {config}.tmp && mv {config}.tmp {config}"
        )
        base = super()._build_register_mcp_servers_command()
        return f"{base} && {masc}" if base else masc
