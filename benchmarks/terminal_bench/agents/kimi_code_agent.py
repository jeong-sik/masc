"""Same-model baseline using the maintained native Kimi Code CLI.

The PyPI kimi-cli package exits successfully with a retirement notice. Use
the official, checksum-verifying installer and its non-interactive JSONL
protocol instead. A process exit alone is insufficient execution evidence.
"""
from __future__ import annotations

import json
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

KIMI_CODE_VERSION = "2.2.0"
KIMI_CODE_HOME = "/logs/agent/kimi-code"
STREAM_NAME = "kimi-code.jsonl"


class KimiCodeProtocolError(RuntimeError):
    """A successful process produced no completed assistant response."""


def inspect_stream(path: Path) -> dict:
    messages = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not messages or any(not isinstance(m, dict) for m in messages):
        raise KimiCodeProtocolError("Kimi Code emitted no message objects")
    conversation = []
    for message in messages:
        match message.get("role"):
            case "meta":
                if message.get("type") not in {"system.version", "session.resume_hint"}:
                    raise KimiCodeProtocolError("Kimi Code emitted an unknown metadata event")
            case "assistant" | "tool":
                conversation.append(message)
            case _:
                raise KimiCodeProtocolError("Kimi Code emitted an unknown message role")
    if not conversation:
        raise KimiCodeProtocolError("Kimi Code emitted no conversation")
    final = conversation[-1]
    if final.get("role") != "assistant" or final.get("tool_calls") or not final.get("content"):
        raise KimiCodeProtocolError("Kimi Code emitted no final assistant response")
    return {
        "messages": len(messages),
        "assistant_messages": sum(m.get("role") == "assistant" for m in messages),
        "tool_calls": sum(len(m.get("tool_calls") or []) for m in messages),
        "tool_results": sum(m.get("role") == "tool" for m in messages),
    }


class KimiCodeAgent(BaseInstalledAgent):
    def __init__(self, *args, version=KIMI_CODE_VERSION, **kwargs):
        super().__init__(*args, version=version, **kwargs)
        if not self.model_name or not self.model_name.startswith("kimi/"):
            raise ValueError("Kimi Code baseline requires --model kimi/<model>")

    @staticmethod
    def name() -> str:
        return "kimi-code"

    def get_version_command(self) -> str:
        return '"$HOME/.kimi-code/bin/kimi" --version'

    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(environment, ("curl", "python3"))
        await self.exec_as_agent(
            environment,
            "curl -fsSL https://code.kimi.com/kimi-code/install.sh "
            "-o /tmp/install-kimi-code.sh && "
            "KIMI_NO_MODIFY_PATH=1 bash /tmp/install-kimi-code.sh --version "
            + shlex.quote(self._version),
        )
        installed = await self.exec_as_agent(environment, self.get_version_command())
        if installed.stdout.strip().split()[-1:] != [self._version]:
            raise KimiCodeProtocolError("Kimi Code version did not match the pinned installation")

    @with_prompt_template
    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        key = self._get_env("KIMI_API_KEY")
        if not key:
            raise ValueError("KIMI_API_KEY is missing from the Harbor agent environment")
        # All configuration is isolated in the trial's own agent log directory.
        # Credentials are resolved from the environment on each request; none
        # are interpolated into shell commands or written into the config.
        config = '\n'.join([
            'default_model = "bench"',
            'telemetry = false',
            'auto_session_title = false',
            '[providers.bench]',
            'type = "kimi"',
            'base_url = "https://api.kimi.com/coding/v1"',
            'api_key_env = "KIMI_API_KEY"',
            '[models.bench]',
            'provider = "bench"',
            'model = ' + json.dumps(self.model_name.split('/', 1)[1]),
            'max_context_size = 262144',
            'capabilities = ["thinking", "always_thinking", "image_in", "video_in", "tool_use"]',
            '',
        ])
        writer = (
            "from pathlib import Path; "
            f"p=Path({KIMI_CODE_HOME!r}); p.mkdir(parents=True,exist_ok=True); "
            f"(p/'config.toml').write_text({config!r})"
        )
        env = {"KIMI_API_KEY": key, "KIMI_CODE_HOME": KIMI_CODE_HOME,
               "KIMI_CODE_NO_AUTO_UPDATE": "true"}
        await self.exec_as_agent(environment, "python3 -c " + shlex.quote(writer), env=env)
        skills = " --skills-dir " + shlex.quote(str(self.skills_dir)) if self.skills_dir else ""
        try:
            await self.exec_as_agent(
                environment,
                '"$HOME/.kimi-code/bin/kimi" -m bench -p ' + shlex.quote(instruction)
                + " --output-format stream-json" + skills
                + f" > /logs/agent/{STREAM_NAME} 2> /logs/agent/kimi-code.stderr.log",
                env=env,
                timeout_sec=None,
            )
        finally:
            context.metadata = {
                **(context.metadata or {}), "cli_version": self._version,
                "model": self.model_name, "output_protocol": "stream-json",
            }
        # Non-mounted environments publish logs only after run() returns.
        # Download before inspecting; local Docker's mount is not the contract.
        if not environment.capabilities.mounted:
            await environment.download_file(
                source_path=f"/logs/agent/{STREAM_NAME}",
                target_path=self.logs_dir / STREAM_NAME,
            )
        evidence = inspect_stream(self.logs_dir / STREAM_NAME)
        context.metadata.update(execution_evidence=evidence, tool_calls=evidence["tool_calls"])
