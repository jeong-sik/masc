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

The sidecar itself — what gets installed, the container environment, and why
the pool is stood up by bootstrap rather than by the model — lives in
`masc_sidecar.py`, shared with the opencode variant of this same arm.
"""
from __future__ import annotations

import json
import shlex
import sys
from pathlib import Path

from harbor.agents.installed.claude_code import ClaudeCode
from harbor.environments.base import BaseEnvironment

sys.path.insert(0, str(Path(__file__).resolve().parent))

from masc_sidecar import (  # noqa: E402
    MASC_MCP_URL,
    MCP_SERVER_NAME,
    MascSidecar,
    pool_names,
    pool_prompt,
    read_token_guard,
    runtime_id_from_model,
)

class KeeperToolsAgent(MascSidecar, ClaudeCode):
    def __init__(
        self,
        *args,
        arm: str = "k",
        keeper_runtime_id: str | None = None,
        keeper_effort: str = "high",
        announce_pool: bool = True,
        **kwargs,
    ):
        names = pool_names(arm)
        # CLI_FLAGS kwargs are consumed by BaseInstalledAgent.__init__, so the
        # default has to be in place before the chain runs. An explicit
        # --ak append_system_prompt=... still wins.
        if announce_pool:
            kwargs.setdefault("append_system_prompt", pool_prompt(names))
        super().__init__(*args, **kwargs)
        self.arm = arm
        self.pool_names = names
        self.keeper_effort = keeper_effort
        self.announce_pool = announce_pool
        self.keeper_runtime_id = keeper_runtime_id or runtime_id_from_model(
            self.model_name
        )

    @staticmethod
    def name() -> str:
        return "masc-keeper-tools"

    async def install(self, environment: BaseEnvironment) -> None:
        # Claude Code first: it is the agent, MASC is the thing it can reach.
        await super().install(environment)
        await self.install_masc(environment)

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
            f"{read_token_guard()}; "
            f"([ -f {config} ] || echo '{{}}' > {config}) && "
            f'jq --arg t "$masc_token" --arg url {shlex.quote(MASC_MCP_URL)} '
            f"{shlex.quote(program)} "
            f"{config} > {config}.tmp && mv {config}.tmp {config}"
        )
        base = super()._build_register_mcp_servers_command()
        return f"{base} && {masc}" if base else masc
