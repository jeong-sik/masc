"""MASC harness as a Harbor installed agent (spec §5, approach A).

install(): prebuilt masc 바이너리 + bash 드라이버 + 렌더된 arm config를
태스크 컨테이너 /opt/masc-bench에 업로드하고 bootstrap.sh를 root로 실행한다.
run(): instruction을 업로드하고 run_episode.sh를 실행한 뒤 result.json을
읽어 AgentContext에 싣는다.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))

from render_configs import ARMS, PROVIDERS, render_arm  # noqa: E402

REMOTE = "/opt/masc-bench"


class MascAgent(BaseInstalledAgent):
    def __init__(self, logs_dir, model_name=None, arm="b",
                 runtime_id=None, effort="high", **kwargs):
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

    @staticmethod
    def name() -> str:
        return "masc"

    def version(self) -> str:
        version_file = BENCH_ROOT / "dist" / ".version"
        return version_file.read_text().strip() if version_file.exists() else "unknown"

    def _container_env(self) -> dict[str, str]:
        provider = self.runtime_id.split(".", 1)[0]
        key_env = PROVIDERS[provider]["api_key_env"]
        key = os.environ.get(key_env)
        if not key:
            raise RuntimeError(f"{key_env} not set in harbor process env")
        return {
            key_env: key,
            "BENCH_RUNTIME_ID": self.runtime_id,
            "KEEPER_COUNT": str(ARMS[self.arm]["keepers"]),
        }

    async def install(self, environment: BaseEnvironment) -> None:
        binary = BENCH_ROOT / "dist" / "masc"
        if not binary.exists():
            raise RuntimeError("run image/fetch_masc.sh first")
        config_dir = render_arm(self.arm, self.runtime_id, self.effort)
        await self.exec_as_root(environment, f"mkdir -p {REMOTE}/bin")
        await environment.upload_file(binary, f"{REMOTE}/bin/masc")
        await environment.upload_dir(BENCH_ROOT / "driver", f"{REMOTE}/driver")
        await environment.upload_dir(config_dir, f"{REMOTE}/config")
        await self.exec_as_root(
            environment,
            f"chmod +x {REMOTE}/bin/masc {REMOTE}/driver/*.sh && "
            f"bash {REMOTE}/driver/bootstrap.sh",
            env=self._container_env(),
            timeout_sec=900,
        )

    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        instr_local = Path(self.logs_dir) / "instruction.txt"
        instr_local.parent.mkdir(parents=True, exist_ok=True)
        instr_local.write_text(instruction)
        await environment.upload_file(instr_local, f"{REMOTE}/instruction.txt")
        try:
            await self.exec_as_root(
                environment,
                f"bash {REMOTE}/driver/run_episode.sh "
                f"{REMOTE}/instruction.txt {REMOTE}/result.json",
                env=self._container_env(),
                timeout_sec=None,  # Harbor의 agent timeout이 상한
            )
        finally:
            # run_episode.sh는 Succeeded가 아니면 non-zero로 끝나 위에서 raise된다.
            # Harbor가 agent error로 기록하도록 예외는 삼키지 않되, 그 전에
            # result.json을 회수해 context에 싣는다. 에피소드 실패 시 파일이
            # 없을 수 있어 || true로 회수 자체는 실패하지 않게 한다.
            result = await self.exec_as_root(
                environment, f"cat {REMOTE}/result.json 2>/dev/null || true")
            if result.stdout and result.stdout.strip():
                (Path(self.logs_dir) / "result.json").write_text(result.stdout)
            self.populate_context_post_run(context)

    def populate_context_post_run(self, context: AgentContext) -> None:
        result_path = Path(self.logs_dir) / "result.json"
        if not result_path.exists():
            return
        data = json.loads(result_path.read_text())
        final = data.get("final") or {}
        usage = final.get("usage") or {}
        context.n_input_tokens = usage.get("input_tokens")
        context.n_cache_tokens = usage.get("cache_tokens")
        context.n_output_tokens = usage.get("output_tokens")
        context.metadata = {
            **(context.metadata or {}),
            "masc_state": data.get("state"),
            "duration_ms": data.get("duration_ms"),
            "tool_calls": data.get("tool_calls"),
            "duplicate_tool_calls": data.get("duplicate_tool_calls"),
            "arm": self.arm,
            "runtime_id": self.runtime_id,
        }
