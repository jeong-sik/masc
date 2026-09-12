"""Render per-arm MASC configs for the harness benchmark.

Arm 체인 (spec §6.2): b(1 keeper, 전부 off) -> c(+skills) -> d(+composition)
-> e(+parallel) -> f(4 keepers) -> g(8 keepers) -> h(fusion on).
Arm A는 Harbor 빌트인 kimi-cli라 여기서 렌더하지 않는다.

스키마 근거 (main checkout에서 확인):
- keeper TOML: lib/keeper/keeper_types_profile_toml_parser.ml — 허용 키는
  [keeper] 테이블 아래 dotted key로 선언된다 (skills.names,
  tools.attached_allow). 최상위 [skills]/[tools] 테이블은 unknown key로
  로드가 실패한다. 생성 형식은 keeper_turn_up_config_persistence.ml의
  writer가 쓰는 형태와 같다.
- overlay: config/agent-core-models-overlay.toml의 [[models]] row는
  id_prefix (underscore) 철자를 쓴다.
- runtime.toml [fusion] enabled: lib/fusion_core/fusion_config.ml
  (Otoml ["fusion"; "enabled"]).
"""
from __future__ import annotations

import re
import shutil
import tempfile
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BENCH_ROOT.parents[1]
OUT_ROOT = BENCH_ROOT / "configs" / "out"

# keepers, skills, composition, parallel
ARMS: dict[str, dict] = {
    "b": dict(keepers=1, skills=False, composition=False, parallel=False, fusion=False),
    "c": dict(keepers=1, skills=True,  composition=False, parallel=False, fusion=False),
    "d": dict(keepers=1, skills=True,  composition=True,  parallel=False, fusion=False),
    "e": dict(keepers=1, skills=True,  composition=True,  parallel=True,  fusion=False),
    "f": dict(keepers=4, skills=True,  composition=True,  parallel=True,  fusion=False),
    "g": dict(keepers=8, skills=True,  composition=True,  parallel=True,  fusion=False),
    "h": dict(keepers=8, skills=True,  composition=True,  parallel=True,  fusion=True),
    # Arm K renders a keeper pool for agents/keeper_tools_agent.py: the task is
    # solved by harbor's own claude-code agent and these keepers are reachable
    # to it as MCP tools. bootstrap.sh brings the pool up and sets each
    # keeper's approval stance before handing the fleet over, because that
    # stance is REST-only and 404s for a keeper that is not registered yet
    # (masc#35319), so `keepers` is how many are running when the model starts.
    "k": dict(keepers=4, skills=True,  composition=True,  parallel=True,  fusion=False),
}

# composition skill 판정 마커: SKILL.md 안에 ```toml composition fenced block이
# 있으면 그 skill은 keeper_compose_<name> 도구를 만든다. arm c(composition OFF)는
# skills.names를 이 마커가 없는 skill로만 제한해 composition 도구가 아예
# 존재하지 않게 한다 — tools.attached_allow는 OAuth attached-service 도구만
# filter하고 built-in/composition 도구는 gate하지 못하는 no-op이라 쓰지 않는다
# (keeper_run_tools_setup.ml: Keeper_identity_tool_allow.apply 대상 확인).
COMPOSITION_FENCE = "```toml composition"

# spawn/delegate 게이트 (masc v0.35.6+, #35169): keeper TOML tools.deny는
# model-visible 이름의 built-in tool을 capability surface에서 완전 제거한다
# (dispatch bundle에도 없고 frozen-surface admission이 호출을 거부).
# spawn = parallel 실행 기구라 parallel=False arm(b, c, d)에서 deny.
# delegate = 다른 keeper에게 위임이라 keeper가 1개인 arm(b-e)에서 deny.
SPAWN_TOOLS = ["keeper_spawn", "keeper_spawn_read", "keeper_spawn_wait", "keeper_spawn_stop"]
DELEGATE_TOOLS = ["masc_keeper_delegate", "masc_keeper_delegate_status", "masc_keeper_delegate_cancel"]


def denied_tools(spec: dict) -> list[str]:
    denied = []
    if not spec["parallel"]:
        denied += SPAWN_TOOLS
    if spec["keepers"] == 1:
        denied += DELEGATE_TOOLS
    return denied

# Canonical bench keeper instructions. Rendered into every keeper profile TOML
# (keeper_up requires non-empty keeper.instructions); run_episode.sh passes
# the same text on the keeper_up call.
KEEPER_INSTRUCTIONS = (
    "You are an autonomous engineering agent inside a Linux container. "
    "Complete the task by running shell commands (your tool calls execute in "
    "this container as root). Work directly; do not ask questions. "
    "When the task is verifiably done, finish."
)


def _skill_names() -> list[str]:
    return sorted(
        p.parent.name
        for p in (REPO_ROOT / "skills").glob("*/SKILL.md")
    )


def composition_skill_names() -> list[str]:
    return sorted(
        name
        for name in _skill_names()
        if any(
            line.startswith(COMPOSITION_FENCE)
            for line in (REPO_ROOT / "skills" / name / "SKILL.md").read_text().splitlines()
        )
    )


def instruction_skill_names() -> list[str]:
    composition = set(composition_skill_names())
    return [name for name in _skill_names() if name not in composition]


RUNTIME_TOML = """\
[runtime]
default = "{runtime_id}"

[providers.{provider}]
display-name = "Bench provider"
protocol = "{protocol}"
endpoint = "{endpoint}"

[providers.{provider}.credentials]
type = "env"
key = "{api_key_env}"

[models."{binding_id}"]
api-name = "{model_alias}"
# HTTP lanes deliver tools off the catalog capability, not this key
# (keeper_effective_tool_surface: the Agent_core arm reads
# capabilities.supports_tools; only the Claude_code arm reads
# runtime.model.tools_support). It is declared anyway because it is true, and
# because `masc runtime-verify` refuses a binding without it — without this
# line the offline readiness check answers tools_not_declared for a lane that
# does deliver tools.
tools-support = true
{effort_lines}

[{provider}."{binding_id}"]
max-concurrent = {max_concurrent}

# Boot gate (server_runtime_bootstrap.require_explicit_mandatory_exact_output_
# lanes): hitl_auto_judge and board_attention_exact must be declared with
# non-empty slots or cli_slots. slots would need AGENT_CORE exact-output
# catalog target refs the bench overlay does not carry; cli_slots are admitted
# verbatim and are only walked by the HITL-summary / board-attention lanes,
# which a bench episode never triggers (autonomous orchestration is off).
[runtime.exact_output_lanes.hitl_auto_judge]
slots = []
cli_slots = ["{runtime_id}"]

[runtime.exact_output_lanes.board_attention_exact]
slots = []
cli_slots = ["{runtime_id}"]

[exec.ssh.endpoints.local]
host = "127.0.0.1"
user = "root"
remote_root = "/root"
port = 22
identity_file = "/opt/masc-bench/ssh/id_ed25519"

[fusion]
enabled = {fusion}
"""

# Official Claude Code client as the keeper's model runtime (masc protocol
# "claude-code", lib/runtime/runtime_adapter.ml claude_code_execution). The CLI
# owns the wire, the session (--session-id / --resume per turn) and the login,
# so the provider carries no endpoint and must not declare credentials; the
# subscription token reaches the CLI through CLAUDE_CODE_OAUTH_TOKEN, which
# runtime_claude_code.client_environment forwards. Effort is a model-level
# reasoning-effort (the CLI's --effort); Claude Code rejects "minimal".
OFFICIAL_CLIENT_RUNTIME_TOML = """\
[runtime]
default = "{runtime_id}"

[providers.{provider}]
display-name = "Bench official client"
protocol = "{protocol}"
command = "{command}"
is-non-interactive = true

[models."{binding_id}"]
api-name = "{model_alias}"
max-context = 1000000
max-prompt-bytes = 524288
tools-support = true
streaming = true
reasoning-effort = "{effort}"
turn-timeout-s = {turn_timeout_s}

[{provider}."{binding_id}"]
max-concurrent = {max_concurrent}

[runtime.exact_output_lanes.hitl_auto_judge]
slots = []
cli_slots = ["{runtime_id}"]

[runtime.exact_output_lanes.board_attention_exact]
slots = []
cli_slots = ["{runtime_id}"]

[exec.ssh.endpoints.local]
host = "127.0.0.1"
user = "root"
remote_root = "/root"
port = 22
identity_file = "/opt/masc-bench/ssh/id_ed25519"

[fusion]
enabled = {fusion}
"""

# The catalog gate (runtime.ml decide_capability_gate) resolves official-client
# models by api-name against the embedded catalog, which already carries bare
# claude-sonnet-5 / claude-opus-5 rows and the claude_code prefix row. No
# deployment row is needed; production runs the same shape with none.
OFFICIAL_CLIENT_OVERLAY_TOML = """\
# No deployment rows: the claude-code lane resolves capabilities from the
# embedded AGENT_CORE catalog by api-name (see render_configs.py).
"""

# Per-turn bound for the official client. Production binds opus-5 at max
# effort with 900s; the bench episode cap (EPISODE_TIMEOUT_SEC=2400) stays the
# outer bound.
OFFICIAL_CLIENT_TURN_TIMEOUT_S = 900.0
CLAUDE_CODE_EFFORTS = ("low", "medium", "high", "xhigh", "max")

OVERLAY_TOML = """\
# messages-http bindings are materialized only when the provider id has an
# AGENT_CORE provider registry entry (runtime_adapter.ml: "messages-http
# requires registry kind SSOT"). The registry is built from the catalog's
# [[providers]] rows, and the embedded catalog carries no anthropic row, so
# the bench provider must be declared here.
[[providers]]
id = "{provider}"
kind = "{kind}"
base_url = "{endpoint}"
request_path = "{request_path}"
api_key_env = "{api_key_env}"
capabilities_base = "{capabilities_base}"

[[models]]
# provider_name is required: a runtime with a declared provider_id resolves
# capabilities only through a provider-scoped row (allow_bare_fallback=false,
# provider_config.ml capabilities_for_config_model), and lookup_for_provider
# matches id_prefix by exact (normalized) equality, not prefix. The
# provider-wide capabilities_base is unreachable here anyway — "anthropic" is
# a wire-kind label, which provider_entry_for_label refuses to resolve
# (model_catalog.ml wire_kind_labels).
provider_name = "{provider}"
id_prefix = "{model_alias}"
base = "{capabilities_base}"
supports_reasoning = true
supports_tools = true
supports_native_streaming = true
# Without an accepted_reasoning_efforts contract the request validator rejects
# any reasoning-effort (provider_config.ml Undeclared_reasoning_effort_capability).
accepted_reasoning_efforts = ["low", "medium", "high", "xhigh", "max"]
{thinking_control}{sampling_lines}{max_output_lines}supports_parallel_tool_calls = {parallel}
"""

def model_binding_id(wire_model: str) -> str:
    """runtime.toml 의 model id 로 쓸 수 있는 이름.

    파서가 `[A-Za-z0-9._-]+` 만 받는다 (runtime_toml.ml: "model id must match").
    OpenRouter 의 와이어 id 는 `z-ai/glm-4.7-flash` 처럼 vendor 슬래시를 달고
    오므로 그대로 쓰면 설정 로드가 실패한다. 바인딩 id 는 슬러그로 두고 와이어
    이름은 `api-name` 이 나른다. capability 조회도 api-name 을 읽으므로
    (runtime_adapter: `~model_id:spec.api_name`) overlay 의 id_prefix 는 와이어
    이름 그대로 둔다.
    """
    return re.sub(r"[^A-Za-z0-9._-]", "-", wire_model)


def effective_runtime_id(runtime_id: str) -> str:
    """masc 가 실제로 해소하는 runtime id (`<provider>.<binding id>`)."""
    provider, _, wire_model = runtime_id.partition(".")
    if not provider or not wire_model:
        raise ValueError(f"runtime_id must be '<provider>.<model>', got {runtime_id!r}")
    return f"{provider}.{model_binding_id(wire_model)}"


# provider 프로토콜 매핑. 새 provider 추가 시 여기만 고친다.
PROVIDERS = {
    "anthropic": dict(protocol="messages-http",
                      endpoint="https://api.anthropic.com",
                      api_key_env="ANTHROPIC_API_KEY",
                      kind="anthropic",
                      request_path="/v1/messages",
                      capabilities_base="anthropic"),
    "openai": dict(protocol="openai-compatible-http",
                   endpoint="https://api.openai.com/v1",
                   api_key_env="OPENAI_API_KEY",
                   kind="openai_compat",
                   request_path="/chat/completions",
                   capabilities_base="openai"),
    # 한 계정 크레딧으로 여러 vendor 모델을 태우는 스윕 레인. 모델 id 에
    # 슬래시가 들어가므로 --model openrouter/z-ai/glm-5.3 처럼 주면
    # runtime_id 는 openrouter.z-ai/glm-5.3 이 된다. glm/deepseek 계열은
    # fable 대비 입력 단가 1~2자릿수 아래라 넓은 매트릭스에 맞다.
    "openrouter": dict(protocol="openai-compatible-http",
                       endpoint="https://openrouter.ai/api/v1",
                       api_key_env="OPENROUTER_API_KEY",
                       kind="openai_compat",
                       request_path="/chat/completions",
                       capabilities_base="openai"),
    "kimi_coding": dict(protocol="openai-compatible-http",
                        endpoint="https://api.kimi.com/coding/v1",
                        api_key_env="KIMI_API_KEY",
                        kind="openai_compat",
                        request_path="/chat/completions",
                        capabilities_base="kimi"),
    # Claude Code subscription lane: `--model claude_code/claude-sonnet-5`
    # gives runtime_id claude_code.claude-sonnet-5; the alias doubles as the
    # CLI api-name. bootstrap.sh installs the unmodified CLI (native
    # installer, no node) when BENCH_RUNTIME_ID starts with "claude_code." and
    # refuses to start the server unless `claude auth status --json` reports
    # the token. Token: `claude setup-token` on the host.
    "claude_code": dict(protocol="claude-code",
                        command="claude",
                        api_key_env="CLAUDE_CODE_OAUTH_TOKEN",
                        official_client=True),
}


def is_official_client(provider: str) -> bool:
    return bool(PROVIDERS[provider].get("official_client"))

# reasoning-effort / thinking-support in [models.X] seed the keeper turn's
# reasoning controls (Runtime_inference.thinking_support_of_runtime_id ->
# keeper_turn_driver.attempt_inference_policy). Emit them only where the
# provider wire can carry effort:
# - anthropic: thinking-support=true + adaptive policy (without it the keeper
#   default enable_thinking=false reaches
#   backend_anthropic.validate_thinking_controls, which rejects
#   reasoning_effort + enable_thinking=false outright).
# - openai: chat-completions carries reasoning_effort only under the
#   reasoning_effort thinking-control dialect (see the overlay emitter).
# - kimi: capabilities_base"kimi" declares thinking_control_format =
#   No_thinking_control, so any reasoning_effort is rejected by
#   reasoning_dialect.validate_request_control_inputs. K2.7-code thinks
#   always-on anyway (supports_thinking_type="only").
EFFORT_CAPABLE_BASES = {"anthropic", "openai"}


def seed_skills_block() -> str:
    """레포 seed config/runtime.toml에서 [skills] 블록을 발췌한다.

    [skills] 헤더 라인부터 다음 최상위 섹션([runtime]) 직전까지, 즉
    [[skills.sources]] entries를 포함한 블록 전체를 verbatim으로 가져온다.
    """
    lines = (REPO_ROOT / "config" / "runtime.toml").read_text().splitlines()
    start = lines.index("[skills]")
    end = next(
        i for i in range(start + 1, len(lines))
        if lines[i].startswith("[") and not lines[i].startswith(("[skills.", "[[skills"))
    )
    return "\n".join(lines[start:end]).rstrip() + "\n"


def keeper_toml(arm: str) -> str:
    """Every keeper in an arm gets the same profile; only the filename differs."""
    spec = ARMS[arm]
    lines = [
        "[keeper]",
        "always_allow = true",
        'sandbox_profile = "remote_ssh"',
        'remote_endpoint = "local"',
        # keeper_up rejects a profile without non-empty keeper.instructions,
        # even when the call itself carries instructions.
        'instructions = """',
        KEEPER_INSTRUCTIONS,
        '"""',
    ]
    if not spec["skills"]:
        # 명시적 빈 배열 = skills 없음 (키 생략은 "전부"라 반대 의미).
        lines += ["", "skills.names = []"]
    elif not spec["composition"]:
        # composition OFF: skills.names를 비-composition skill로 명시 제한한다.
        # composition skill이 scope 밖이면 keeper_compose_<name> 도구 자체가
        # 만들어지지 않는다. 키 생략(arms d-h)은 전 skill 허용.
        names = ", ".join(f'"{n}"' for n in instruction_skill_names())
        lines += ["", f"skills.names = [{names}]"]
    denied = denied_tools(spec)
    if denied:
        names = ", ".join(f'"{n}"' for n in denied)
        lines += ["", f"tools.deny = [{names}]"]
    return "\n".join(lines) + "\n"


def render_arm(arm: str, runtime_id: str, effort: str, out_root: Path | None = None) -> Path:
    """arm config를 (out_root/<arm>/)에 렌더하고 디렉터리를 반환한다.

    레포 config/ 시드(도구 정의·프롬프트 등)를 복사한 뒤 runtime.toml,
    keepers/, overlay를 arm 사양으로 덮어쓴다.
    """
    if arm not in ARMS:
        raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
    spec = ARMS[arm]
    provider, _, model_alias = runtime_id.partition(".")
    if not provider or not model_alias:
        raise ValueError(f"runtime_id must be '<provider>.<model>', got {runtime_id!r}")
    pcfg = PROVIDERS[provider]
    # The binding is named by a slug; the wire name stays in api-name and in
    # the overlay's id_prefix. See model_binding_id.
    binding_id = model_binding_id(model_alias)
    runtime_id = f"{provider}.{binding_id}"
    if is_official_client(provider) and effort not in CLAUDE_CODE_EFFORTS:
        raise ValueError(
            f"effort {effort!r} is not admitted by Claude Code; "
            f"expected one of {CLAUDE_CODE_EFFORTS}")

    if out_root is not None:
        root = out_root / arm
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True, exist_ok=True)
        root.rmdir()
    else:
        # Never a shared path. harbor runs several trials of the same arm at
        # once (run_matrix.sh passes -n ${CONCURRENCY:-2}) and each calls
        # install() -> render_arm(); rendering into configs/out/<arm> meant one
        # trial's rmtree ran while another was mid-upload, so a half-copied
        # config could be uploaded as though it were complete. The caller owns
        # the returned directory and removes it when the upload is done.
        OUT_ROOT.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix=f"{arm}-", dir=OUT_ROOT))
        root.rmdir()
    shutil.copytree(REPO_ROOT / "config", root, ignore=shutil.ignore_patterns(
        "keepers", "keepers-default", "runtime.toml", "*.env",
        "agent-core-models-overlay.toml"))

    if is_official_client(provider):
        runtime_toml = OFFICIAL_CLIENT_RUNTIME_TOML.format(
            runtime_id=runtime_id, provider=provider, model_alias=model_alias,
            binding_id=binding_id,
            protocol=pcfg["protocol"], command=pcfg["command"], effort=effort,
            turn_timeout_s=OFFICIAL_CLIENT_TURN_TIMEOUT_S,
            fusion=str(spec["fusion"]).lower(),
            max_concurrent=4 if spec["parallel"] else 1)
        if spec["skills"]:
            runtime_toml += "\n" + seed_skills_block()
        (root / "runtime.toml").write_text(runtime_toml)
        (root / "agent-core-models-overlay.toml").write_text(
            OFFICIAL_CLIENT_OVERLAY_TOML)
        if spec["skills"]:
            shutil.copytree(REPO_ROOT / "skills", root / "skills")
        keepers = root / "keepers"
        keepers.mkdir(exist_ok=True)
        for i in range(1, spec["keepers"] + 1):
            (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm))
        return root

    runtime_toml = RUNTIME_TOML.format(
        runtime_id=runtime_id, provider=provider, model_alias=model_alias,
        binding_id=binding_id,
        effort=effort, fusion=str(spec["fusion"]).lower(),
        max_concurrent=4 if spec["parallel"] else 1,
        effort_lines=(
            f'reasoning-effort = "{effort}"\nthinking-support = true\n'
            if pcfg["capabilities_base"] in EFFORT_CAPABLE_BASES else ""),
        **pcfg)
    if spec["skills"]:
        # skills=True arm만 seed의 [skills]/[[skills.sources]] 블록을 보존한다.
        # skills=False이면 이 블록을 빼서 skill source가 없어 어떤 skill도
        # 로드되지 않는다 (keeper TOML의 skills.names = []와 같은 방향).
        runtime_toml += "\n" + seed_skills_block()
    (root / "runtime.toml").write_text(runtime_toml)
    # Anthropic-kind backends refuse an explicit enable_thinking without a
    # catalog-declared thinking policy
    # (backend_anthropic.validate_nonexact_thinking_controls).
    # adaptive_only = the wire gets {"type":"adaptive"} when thinking is on
    # and NO thinking field when off; the model decides depth. fable-5 rejects
    # {"type":"disabled"} outright (observed v0.35.8 smoke, anthropic4:
    # '"thinking.type.disabled" is not supported for this model'), which the
    # no-thinking truncation retry would otherwise emit under
    # adaptive_default. adaptive_only matches the model's contract.
    # OpenAI chat-completions carries effort only when the model row declares
    # the reasoning_effort thinking-control dialect
    # (reasoning_dialect.validate_request_control_inputs:
    # Chat_completions + Reasoning_effort is the admitted pair).
    if pcfg["capabilities_base"] == "anthropic":
        thinking_control = 'anthropic_thinking_control = "adaptive_only"\n'
        # The anthropic base preset caps output at 8192 ("higher for newer
        # models" — capabilities.ml anthropic_capabilities). With adaptive
        # thinking on, a turn burns 8k before finishing: observed v0.35.8
        # smoke anthropic5, "Provider output reached its maximum token
        # boundary before completion" at 775s after the truncation recovery
        # exhausted the same ceiling. fable-5 takes 64k.
        max_output_lines = "max_output_tokens = 64000\n"
    elif pcfg["capabilities_base"] == "openai":
        thinking_control = 'thinking_control_format = "reasoning_effort"\n'
        max_output_lines = ""
    else:
        thinking_control = ""
        max_output_lines = ""
    # kimi-for-coding accepts only temperature=1 ("invalid temperature: only
    # 1 is allowed for this model"), and Anthropic under adaptive thinking
    # answers "temperature may only be set to 1 when thinking is enabled or
    # in adaptive mode" (observed v0.35.6 smoke, turn_failed at 12s — after
    # the oneOf projection fix let the request through). Both are handled the
    # repo's own way: drop the sampling fields from the wire entirely.
    sampling_lines = (
        'ignored_sampling_parameters = ["temperature", "top_p"]\n'
        if pcfg["capabilities_base"] in ("kimi", "anthropic") else "")
    (root / "agent-core-models-overlay.toml").write_text(OVERLAY_TOML.format(
        provider=provider, model_alias=model_alias,
        thinking_control=thinking_control,
        sampling_lines=sampling_lines,
        max_output_lines=max_output_lines,
        parallel=str(spec["parallel"]).lower(), **pcfg))

    # skills=True arm은 skill source tree를 함께 싣는다. bootstrap.sh가 이를
    # $MASC_BASE_PATH/.masc/skills/로 옮겨 [[skills.sources]]가 resolve한다.
    # keeper 측 skills.names가 arm별 제한을 담당하므로 tree는 전부 싣는다.
    # skills=False이면 디렉터리 자체를 만들지 않는다.
    if spec["skills"]:
        shutil.copytree(REPO_ROOT / "skills", root / "skills")

    # NOTE: 예전에는 anthropic arm의 tool_execute.toml에서 [[one_of]]를 벤치 측
    # strip 했다 (Anthropic API의 top-level combinator 400 때문). masc v0.35.6
    # (#35168)부터 backend_anthropic.ml이 wire serialization 시점에 Anthropic
    # kind만 projection하므로 워크어라운드 제거 — seed 스키마 fidelity와
    # dispatcher의 [[one_of]] 런타임 검증을 두 레인 모두 회복한다.

    keepers = root / "keepers"
    keepers.mkdir(exist_ok=True)
    for i in range(1, spec["keepers"] + 1):
        (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm))
    return root


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=sorted(ARMS))
    ap.add_argument("--runtime-id", default="anthropic.claude-fable-5")
    ap.add_argument("--effort", default="high")
    ns = ap.parse_args()
    print(render_arm(ns.arm, ns.runtime_id, ns.effort))
