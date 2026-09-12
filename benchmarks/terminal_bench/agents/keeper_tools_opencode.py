"""Arm K on opencode — the same ablation without an Anthropic credential.

`keeper_tools_agent.py` runs this experiment on harbor's `claude-code` agent.
That agent needs an Anthropic credential, and the subscription path is not the
right one for an unattended benchmark: Anthropic documents OAuth as being for
"ordinary use" of Claude Code, and points developers building products at API
keys instead. With no API credit on the account, arm K had no lane at all.

opencode gives it one. It speaks MCP for real (harbor's `terminus-2` only
lists the servers in the prompt), and it passes the model through to its own
provider registry, so an OpenRouter model needs no Anthropic anything.

The baseline is `--agent opencode` with the same model and no MCP server. It
and this class run the same binary, the same model, and the same task prompt
apart from the paragraph that names the keepers — so a difference between
them is attributable to the keeper layer.

One gap has to be filled, the same one as on claude-code: harbor's config
writer emits a remote MCP server as `{type, url}` with no `headers`, and the
MASC `/mcp` endpoint requires strict bearer auth. opencode's own schema does
support `headers` on a remote server, so the entry is patched in afterwards,
in the container, where the token exists.
"""
from __future__ import annotations

import json
import shlex
import sys
from pathlib import Path

from harbor.agents.installed.opencode import OpenCode
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

sys.path.insert(0, str(Path(__file__).resolve().parent))

from masc_sidecar import (  # noqa: E402
    MASC_MCP_URL,
    MCP_SERVER_NAME,
    MascSidecar,
    merge_keeper_usage,
    pool_names,
    pool_prompt,
    read_token_guard,
    runtime_id_from_model,
)

OPENCODE_CONFIG = "~/.config/opencode/opencode.json"


class KeeperToolsOpenCode(MascSidecar, OpenCode):
    def __init__(
        self,
        *args,
        arm: str = "k",
        keeper_runtime_id: str | None = None,
        keeper_effort: str = "high",
        announce_pool: bool = True,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self.arm = arm
        self.pool_names = pool_names(arm)
        self.keeper_effort = keeper_effort
        self.announce_pool = announce_pool
        self.keeper_runtime_id = keeper_runtime_id or runtime_id_from_model(
            self.model_name
        )

    @staticmethod
    def name() -> str:
        return "masc-keeper-tools-opencode"

    async def install(self, environment: BaseEnvironment) -> None:
        # MASC first, even though opencode is the agent and MASC is only the
        # thing it can reach. The config patch appended by
        # _build_register_config_command runs inside the parent install and
        # reads the bearer token at /opt/masc-bench/token; bootstrap.sh mints
        # that token, and it runs in install_masc. With opencode first, every
        # fresh container failed setup on a token that did not exist yet.
        # install_masc uploads binaries and runs bootstrap, none of which needs
        # opencode present, so the order is free to be this way round.
        await self.install_masc(environment)
        await super().install(environment)

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        """Name the keepers in the task prompt.

        claude-code takes `--append-system-prompt`; opencode has no equivalent
        flag, so the paragraph goes at the top of the instruction instead. It
        is the only textual difference from the baseline, which is the point
        of the arm: without it the tools are present but unannounced, which is
        a different experiment (`--ak announce_pool=false` runs that one).
        """
        if self.announce_pool:
            instruction = f"{pool_prompt(self.pool_names)}\n\n{instruction}"
        await super().run(instruction, environment, context)
        # What the keepers spent is not in what opencode reports, and the arm is
        # compared on cost.
        await merge_keeper_usage(self, environment, context)

    def _build_register_config_command(self) -> str | None:
        """Add the MASC server to opencode.json with its bearer header.

        Harbor writes the config wholesale with `echo > file`, so this runs
        after it and patches the result rather than replacing it: whatever the
        job configured — provider registration, a task's own MCP servers — is
        kept.
        """
        entry = (
            '{type:"remote",url:$url,enabled:true,'
            'headers:{Authorization:("Bearer "+$t)}}'
        )
        # The server name indexes a jq object, so it needs JSON quoting inside
        # the program; shlex.quote would leave a bare token that jq reads as an
        # identifier and rejects.
        program = f".mcp[{json.dumps(MCP_SERVER_NAME)}] = {entry}"
        masc = (
            f"mkdir -p $(dirname {OPENCODE_CONFIG}) && "
            f"{read_token_guard()}; "
            f"([ -s {OPENCODE_CONFIG} ] || echo '{{}}' > {OPENCODE_CONFIG}) && "
            f'jq --arg t "$masc_token" --arg url {shlex.quote(MASC_MCP_URL)} '
            f"{shlex.quote(program)} "
            f"{OPENCODE_CONFIG} > {OPENCODE_CONFIG}.tmp && "
            f"mv {OPENCODE_CONFIG}.tmp {OPENCODE_CONFIG}"
        )
        base = super()._build_register_config_command()
        return f"{base} && {masc}" if base else masc
