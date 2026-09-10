"""Render per-arm MASC configs for the harness benchmark.

Arm 체인 (spec §6.2): b(1 keeper, 전부 off) -> c(+skills) -> d(+composition)
-> e(+parallel) -> f(4 keepers) -> g(8 keepers) -> h(fusion on).
Arm A는 Harbor 빌트인 terminus-2라 여기서 렌더하지 않는다.

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

import shutil
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

[models."{model_alias}"]
{effort_lines}

[{provider}."{model_alias}"]
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
{thinking_control}{sampling_lines}supports_parallel_tool_calls = {parallel}
"""

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
    "kimi_coding": dict(protocol="openai-compatible-http",
                        endpoint="https://api.kimi.com/coding/v1",
                        api_key_env="KIMI_API_KEY",
                        kind="openai_compat",
                        request_path="/chat/completions",
                        capabilities_base="kimi"),
}

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


def keeper_toml(arm: str, index: int) -> str:
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

    root = (out_root or OUT_ROOT) / arm
    if root.exists():
        shutil.rmtree(root)
    shutil.copytree(REPO_ROOT / "config", root, ignore=shutil.ignore_patterns(
        "keepers", "keepers-default", "runtime.toml", "*.env",
        "agent-core-models-overlay.toml"))

    runtime_toml = RUNTIME_TOML.format(
        runtime_id=runtime_id, provider=provider, model_alias=model_alias,
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
    elif pcfg["capabilities_base"] == "openai":
        thinking_control = 'thinking_control_format = "reasoning_effort"\n'
    else:
        thinking_control = ""
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
        (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm, i))
    return root


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=sorted(ARMS))
    ap.add_argument("--runtime-id", default="anthropic.claude-fable-5")
    ap.add_argument("--effort", default="high")
    ns = ap.parse_args()
    print(render_arm(ns.arm, ns.runtime_id, ns.effort))
