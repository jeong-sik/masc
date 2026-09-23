"""Render per-arm MASC configs for the harness benchmark.

Arm 체인 (spec §6.2): b(1 keeper, 전부 off) -> c(+skills) -> d(+composition)
-> e(+parallel) -> f(4 keepers) -> g(8 keepers) -> h(fusion on).
Arm A는 run_matrix.sh 가 모델 제공자의 harbor 기본 에이전트로 돌리므로 여기서 렌더하지 않는다.

스키마 근거 (main checkout에서 확인):
- keeper TOML: lib/keeper/keeper_types_profile_toml_parser.ml — 허용 키는
  [keeper] 테이블 아래 dotted key로 선언된다 (skills.names,
  tools.attached_allow). 최상위 [skills]/[tools] 테이블은 unknown key로
  로드가 실패한다. 생성 형식은 keeper_turn_up_config_persistence.ml의
  writer가 쓰는 형태와 같다.
- runtime.toml [models.X.capabilities]: lib/runtime/runtime_toml.ml
  parse_model_capabilities (dash 철자).
- runtime.toml [fusion] enabled: lib/fusion_core/fusion_config.ml
  (Otoml ["fusion"; "enabled"]).
"""
from __future__ import annotations

import functools
import json
import re
import shutil
import tempfile
import tomllib
import urllib.request
from dataclasses import dataclass
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BENCH_ROOT.parents[1]
OUT_ROOT = BENCH_ROOT / "configs" / "out"
PROVIDER_CATALOG = REPO_ROOT / "packages" / "agent_core" / "models.toml"

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
TASK_SKILL_SOURCE_ID = "terminal-bench-task"
TASK_SKILLS_CONFIG_DIR = "task-skills"
TASK_SKILLS_RUNTIME_PATH = ".masc/task-skills"

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

# The endpoint's remote_root: a directory per keeper, owned by the task image's
# user whose commands run there (driver/endpoint_account.sh BENCH_REMOTE_ROOT,
# compared in tests/test_endpoint_account.py).
REMOTE_ROOT = "/opt/masc-bench/remote"

# Canonical bench keeper instructions. Rendered into every keeper profile TOML
# (keeper_up requires non-empty keeper.instructions); run_episode.sh passes
# the same text on the keeper_up call.
KEEPER_INSTRUCTIONS = (
    "You are an autonomous engineering agent inside a Linux container. "
    "Complete the task by running shell commands (your tool calls execute in "
    "this container). Work directly; do not ask questions. "
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
{max_context_line}# HTTP lanes deliver tools off the catalog capability, not this key
# (keeper_effective_tool_surface: the Agent_core arm reads
# capabilities.supports_tools; only the Claude_code arm reads
# runtime.model.tools_support). It is declared anyway because it is true, and
# because `masc runtime-verify` refuses a binding without it — without this
# line the offline readiness check answers tools_not_declared for a lane that
# does deliver tools.
tools-support = true
{effort_lines}
# The capability row for this binding. A model the embedded AGENT_CORE catalog
# has no row for is described here and nowhere else
# (runtime_adapter.model_capabilities_override_of_model_spec); without it the
# startup capability gate refuses the binding by name. A catalogued model keeps
# its catalog row and takes only the output ceiling and the thinking-control
# dialect from here.
[models."{binding_id}".capabilities]
{max_output_lines}{thinking_control}

[{provider}."{binding_id}"]
max-concurrent = {max_concurrent}
disable-parallel-tool-use = {disable_parallel}

# Boot gate (server_runtime_bootstrap.require_explicit_mandatory_exact_output_
# lanes): hitl_auto_judge and board_attention_exact must be declared with
# non-empty slots or cli_slots. cli_slots are admitted verbatim and are only
# walked by the HITL-summary / board-attention lanes, which a bench episode
# never triggers (autonomous orchestration is off).
[runtime.exact_output_lanes.hitl_auto_judge]
slots = []
cli_slots = ["{runtime_id}"]

[runtime.exact_output_lanes.board_attention_exact]
slots = []
cli_slots = ["{runtime_id}"]

[exec.ssh.endpoints.local]
host = "127.0.0.1"
user = "root"
remote_root = "{remote_root}"
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
#
# The lane declares no capabilities of its own: the catalog gate
# (runtime.ml decide_capability_gate) resolves official-client models by
# api-name against the embedded catalog, which already carries bare
# claude-sonnet-5 / claude-opus-5 rows and the claude_code prefix row.
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
wall-clock-ceiling-s = {wall_clock_ceiling_s}

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
remote_root = "{remote_root}"
port = 22
identity_file = "/opt/masc-bench/ssh/id_ed25519"

[fusion]
enabled = {fusion}
"""

# The official client's turn-timeout-s is an idle window: the turn ends when
# the CLI stream stays silent that long. A keeper waiting on one long tool call
# (a build, a test suite) is silent for its whole duration, so any value here
# would cut real work short. 0 removes it (keeper_claude_code_runtime.ml).
OFFICIAL_CLIENT_TURN_TIMEOUT_S = 0.0
# The whole-turn ceiling cannot be removed (runtime_toml.ml
# wall_clock_ceiling_opt_field) and defaults to 14400s
# (Runtime_wall_clock.default_ceiling_s), half of the 28800s agent timeout
# every Terminal-Bench 4.0.0 task declares. Set to that timeout, a single turn
# is bounded by the task's own time and nothing shorter.
OFFICIAL_CLIENT_WALL_CLOCK_CEILING_S = 28800.0
CLAUDE_CODE_EFFORTS = ("low", "medium", "high", "xhigh", "max")

OPENROUTER_ENDPOINTS_URL = "https://openrouter.ai/api/v1/models/{model}/endpoints"
OPENROUTER_TIMEOUT_S = 30


@dataclass(frozen=True, slots=True)
class OpenRouterLimits:
    max_context: int  # runtime.toml max-context: the input window masc plans against
    max_output: int   # runtime.toml max-output-tokens: the max_tokens masc requests


@functools.lru_cache(maxsize=None)
def openrouter_limits(wire_model: str) -> OpenRouterLimits:
    """Input window and output budget that every OpenRouter endpoint of
    `wire_model` can serve.

    OpenRouter routes a request to any of the model's endpoints, and each
    endpoint's context_length counts input and output together, while masc's
    max-context is the input window alone (runtime.ml "Effective input context
    window"). Left to the catalog, glm-4.7-flash asked for max_tokens 128000
    against endpoints of 128000 and 131072 (2026-09-17). So the output budget
    is the smallest max_completion_tokens any endpoint declares, and the input
    window is the smallest context_length minus that budget.

    Read once per process: harbor installs every trial in one event loop, and
    a run must not have trials planning against different windows.
    """
    url = OPENROUTER_ENDPOINTS_URL.format(model=wire_model)
    with urllib.request.urlopen(url, timeout=OPENROUTER_TIMEOUT_S) as response:
        endpoints = (json.load(response).get("data") or {}).get("endpoints") or []
    if not endpoints:
        raise ValueError(f"OpenRouter lists no endpoints for {wire_model!r}")
    windows = [e.get("context_length") for e in endpoints]
    if not all(isinstance(w, int) and w > 0 for w in windows):
        raise ValueError(f"an OpenRouter endpoint of {wire_model!r} has no context_length")
    outputs = [e.get("max_completion_tokens") for e in endpoints
               if isinstance(e.get("max_completion_tokens"), int)
               and e["max_completion_tokens"] > 0]
    if not outputs:
        raise ValueError(
            f"no OpenRouter endpoint of {wire_model!r} declares max_completion_tokens")
    max_output = min(outputs)
    max_context = min(windows) - max_output
    if max_context <= 0:
        raise ValueError(
            f"{wire_model!r}: smallest window {min(windows)} leaves no input "
            f"beside an output budget of {max_output}")
    return OpenRouterLimits(max_context=max_context, max_output=max_output)


def model_binding_id(wire_model: str) -> str:
    """runtime.toml 의 model id 로 쓸 수 있는 이름.

    파서가 `[A-Za-z0-9._-]+` 만 받는다 (runtime_toml.ml: "model id must match").
    OpenRouter 의 와이어 id 는 `z-ai/glm-4.7-flash` 처럼 vendor 슬래시를 달고
    오므로 그대로 쓰면 설정 로드가 실패한다. 바인딩 id 는 슬러그로 두고 와이어
    이름은 `api-name` 이 나른다. capability 조회도 api-name 을 읽으므로
    (runtime_adapter: `~model_id:spec.api_name`) 와이어 이름은 슬러그로 바꾸지
    않는다.
    """
    return re.sub(r"[^A-Za-z0-9._-]", "-", wire_model)


def effective_runtime_id(runtime_id: str) -> str:
    """masc 가 실제로 해소하는 runtime id (`<provider>.<binding id>`)."""
    provider, _, wire_model = runtime_id.partition(".")
    if not provider or not wire_model:
        raise ValueError(f"runtime_id must be '<provider>.<model>', got {runtime_id!r}")
    runtime_provider = PROVIDERS[provider].get("runtime_provider", provider)
    return f"{runtime_provider}.{model_binding_id(wire_model)}"


# provider 프로토콜 매핑. 새 provider 추가 시 여기만 고친다.
PROVIDERS = {
    "anthropic": dict(runtime_provider="claude",
                      protocol="messages-http",
                      endpoint="https://api.anthropic.com",
                      api_key_env="ANTHROPIC_API_KEY",
                      carries_effort=True,
                      # The anthropic base preset caps output at 8192 ("higher
                      # for newer models" — capabilities.ml
                      # anthropic_capabilities). With adaptive thinking on, a
                      # turn burns 8k before finishing: observed v0.35.8 smoke
                      # anthropic5, "Provider output reached its maximum token
                      # boundary before completion" at 775s after the truncation
                      # recovery exhausted the same ceiling. fable-5 takes 64k.
                      max_output_tokens=64000),
    "openai": dict(runtime_provider="openai-responses",
                   protocol="openai-compatible-http",
                   endpoint="https://api.openai.com",
                   api_key_env="OPENAI_API_KEY",
                   # The canonical catalog provider selects Responses and its
                   # scoped model rows own the reasoning-effort dialect.
                   carries_effort=True),
    # 한 계정 크레딧으로 여러 vendor 모델을 태우는 스윕 레인. 모델 id 에
    # 슬래시가 들어가므로 --model openrouter/z-ai/glm-5.3 처럼 주면
    # runtime_id 는 openrouter.z-ai/glm-5.3 이 된다. glm/deepseek 계열은
    # fable 대비 입력 단가 1~2자릿수 아래라 넓은 매트릭스에 맞다.
    # OpenRouter serves models the AGENT_CORE catalog has no row for, and masc
    # refuses a runtime with neither a catalog max-context nor an override
    # (RFC-0206 §2.1, measured on 0.35.19). Both the window and the output
    # budget are read from OpenRouter's endpoint list: openrouter_limits.
    "openrouter": dict(context_from_openrouter=True,
                       protocol="openai-compatible-http",
                       endpoint="https://openrouter.ai/api/v1",
                       api_key_env="OPENROUTER_API_KEY",
                       # The router's catalog provider row declares both the
                       # dialect and the accepted ladder, so nothing about
                       # either is repeated into the rendered row.
                       carries_effort=True),
    "kimi_coding": dict(protocol="openai-compatible-http",
                        endpoint="https://api.kimi.com/coding/v1",
                        api_key_env="KIMI_API_KEY"),
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


@functools.lru_cache(maxsize=None)
def provider_parallel_suppression_contract(provider: str) -> bool:
    """Whether the checked-in Agent Core provider declaration permits it.

    An absent row and an omitted field both mean false. That is the same
    fail-closed contract the runtime enforces; the HTTP protocol alone does
    not prove that a service accepts this request policy.
    """
    rows = tomllib.loads(PROVIDER_CATALOG.read_text()).get("providers") or []
    matches = [row for row in rows
               if provider == row.get("id") or provider in (row.get("aliases") or [])]
    if len(matches) > 1:
        raise ValueError(f"provider catalog declares {provider!r} more than once")
    if not matches:
        return False
    value = matches[0].get("supports_parallel_tool_suppression", False)
    if not isinstance(value, bool):
        raise ValueError(
            f"provider catalog {provider!r} parallel suppression contract is not boolean")
    return value

# reasoning-effort / thinking-support in [models.X] seed the keeper turn's
# reasoning controls (Runtime_inference.thinking_support_of_runtime_id ->
# keeper_turn_driver.attempt_inference_policy). Emit them only where the
# provider wire can carry effort:
# - anthropic: thinking-support=true (without it the keeper default
#   enable_thinking=false reaches
#   backend_anthropic.validate_thinking_controls, which rejects
#   reasoning_effort + enable_thinking=false outright).
# - openai: the canonical openai-responses provider and its scoped model row
#   declare the reasoning_effort dialect.
# - kimi: capabilities_base"kimi" declares thinking_control_format =
#   No_thinking_control, so any reasoning_effort is rejected by
#   reasoning_dialect.validate_request_control_inputs. K2.7-code thinks
#   always-on anyway (supports_thinking_type="only").
# - openrouter: the router's own base, which declares the reasoning_effort
#   dialect and the accepted ladder (Capabilities.openrouter_capabilities).
#
# Which of them that is reads as carries_effort on the provider entry, so this
# note stays an explanation and does not become a second list to keep in step.

# No accepted_reasoning_efforts table lives here, and none should.
#
# For the two bases this file used to write one for, the accepted set is a
# model fact, not a provider one, and the vendors publish it that way
# (2026-09-18):
#
# - gpt-6-astra takes low..max and does not take `none`, answering HTTP 400 to
#   it; gpt-5.6-sol, -terra and -luna take `none` as well, and document
#   `medium (default)` where astra's page documents no default at all. The
#   other five values are the same across all four, so the split is one value
#   wide -- and one value is enough: a list under "openai" either carries
#   `none` and is wrong for the flagship, where wrong means a 400 mid-run
#   rather than a refusal before dispatch, or omits it and is wrong for the
#   other three.
# - Anthropic's enum is low..max with no `none` (thinking is turned off by
#   `thinking.type`, not by an effort), and "Not every model that supports
#   `max` supports `xhigh`". The catalog already declares exactly that set for
#   claude-fable-5-1, which is the model this benchmark names, so a copy here
#   would be a second place to keep one fact right.
#
# A model whose ladder nobody has declared is refused by
# Undeclared_reasoning_effort_capability, which names the model and says what
# is missing. That refusal is the correct outcome, and the fix for it is a
# catalog row, not a value maintained beside the benchmark.


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


def task_skill_names(skills_dir: Path) -> list[str]:
    """Package names from one Harbor task-provided Agent Skills directory."""
    if not skills_dir.is_dir():
        raise ValueError(f"task skills directory is missing: {skills_dir}")
    names = sorted(
        child.name
        for child in skills_dir.iterdir()
        if child.is_dir() and (child / "SKILL.md").is_file()
    )
    if not names:
        raise ValueError(f"task skills directory has no */SKILL.md packages: {skills_dir}")
    collisions = sorted(set(names) & set(_skill_names()))
    if collisions:
        raise ValueError(
            "task Skill package names collide with MASC seed Skills: "
            + ", ".join(collisions))
    return names


def _toml_string(value: str) -> str:
    # A JSON string is also a TOML basic string. json.dumps owns escaping so a
    # task package name never becomes TOML syntax.
    return json.dumps(value, ensure_ascii=False)


def skills_block_with_task_source(*, include_seed_sources: bool) -> str:
    """Render a complete section; never edit already-rendered TOML."""
    seed = tomllib.loads((REPO_ROOT / "config" / "runtime.toml").read_text())["skills"]
    sources = [dict(id=TASK_SKILL_SOURCE_ID, anchor="base-path",
                    path=TASK_SKILLS_RUNTIME_PATH, access="read-only")]
    if include_seed_sources:
        sources.extend(seed["sources"])
    lines = ["[skills]", f'resource-read-max-bytes = {seed["resource-read-max-bytes"]}']
    for source in sources:
        lines += [
            "", "[[skills.sources]]",
            f'id = {_toml_string(source["id"])}',
            f'anchor = {_toml_string(source["anchor"])}',
            f'path = {_toml_string(source["path"])}',
            f'access = {_toml_string(source["access"])}',
        ]
    return "\n".join(lines) + "\n"


def keeper_toml(arm: str, task_skills: list[str] | None = None) -> str:
    """Every keeper in an arm gets the same profile; only the filename differs."""
    spec = ARMS[arm]
    task_skills = task_skills or []
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
        # Task Skills are common benchmark input. With none, this is byte-for-
        # byte the old explicit empty selection.
        names = ", ".join(_toml_string(n) for n in task_skills)
        lines += ["", f"skills.names = [{names}]"]
    elif not spec["composition"]:
        # composition OFF: skills.names를 비-composition skill로 명시 제한한다.
        # composition skill이 scope 밖이면 keeper_compose_<name> 도구 자체가
        # 만들어지지 않는다. 키 생략(arms d-h)은 전 skill 허용.
        names = ", ".join(
            _toml_string(n) for n in task_skills + instruction_skill_names())
        lines += ["", f"skills.names = [{names}]"]
    denied = denied_tools(spec)
    if denied:
        names = ", ".join(f'"{n}"' for n in denied)
        lines += ["", f"tools.deny = [{names}]"]
    return "\n".join(lines) + "\n"


def render_arm(arm: str, runtime_id: str, effort: str, out_root: Path | None = None,
               task_skills_dir: Path | None = None) -> Path:
    """arm config를 (out_root/<arm>/)에 렌더하고 디렉터리를 반환한다.

    레포 config/ 시드(도구 정의·프롬프트 등)를 복사한 뒤 runtime.toml 과
    keepers/ 를 arm 사양으로 덮어쓴다.
    """
    if arm not in ARMS:
        raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
    spec = ARMS[arm]
    task_skills = task_skill_names(task_skills_dir) if task_skills_dir else []
    provider, _, model_alias = runtime_id.partition(".")
    if not provider or not model_alias:
        raise ValueError(f"runtime_id must be '<provider>.<model>', got {runtime_id!r}")
    pcfg = PROVIDERS[provider]
    runtime_provider = pcfg.get("runtime_provider", provider)
    # The binding is named by a slug; the wire name stays in api-name.
    # See model_binding_id.
    binding_id = model_binding_id(model_alias)
    runtime_id = f"{runtime_provider}.{binding_id}"
    if is_official_client(provider) and effort not in CLAUDE_CODE_EFFORTS:
        raise ValueError(
            f"effort {effort!r} is not admitted by Claude Code; "
            f"expected one of {CLAUDE_CODE_EFFORTS}")
    if is_official_client(provider) and not spec["parallel"]:
        raise ValueError(
            f"arm {arm} requires disabling parallel tool calls, but the "
            f"{provider} runtime cannot carry that request policy; "
            "use an HTTP runtime for arms b, c, d")
    suppression = provider_parallel_suppression_contract(runtime_provider)
    if not spec["parallel"] and not suppression:
        raise ValueError(
            f"arm {arm} requires disabling parallel tool calls, but provider "
            f"{runtime_provider!r} has no catalog-declared suppression contract; "
            "use arm e or later with this provider")

    # Before anything is written: a lookup that fails must not leave a
    # half-rendered config directory behind.
    openrouter = (openrouter_limits(model_alias)
                  if pcfg.get("context_from_openrouter") else None)

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
        "keepers", "keepers-default", "runtime.toml", "*.env"))

    if is_official_client(provider):
        runtime_toml = OFFICIAL_CLIENT_RUNTIME_TOML.format(
            runtime_id=runtime_id, provider=provider, model_alias=model_alias,
            binding_id=binding_id,
            protocol=pcfg["protocol"], command=pcfg["command"], effort=effort,
            turn_timeout_s=OFFICIAL_CLIENT_TURN_TIMEOUT_S,
            wall_clock_ceiling_s=OFFICIAL_CLIENT_WALL_CLOCK_CEILING_S,
            fusion=str(spec["fusion"]).lower(),
            max_concurrent=4 if spec["parallel"] else 1,
            remote_root=REMOTE_ROOT)
        if task_skills:
            runtime_toml += "\n" + skills_block_with_task_source(
                include_seed_sources=spec["skills"])
        elif spec["skills"]:
            runtime_toml += "\n" + seed_skills_block()
        (root / "runtime.toml").write_text(runtime_toml)
        if spec["skills"]:
            shutil.copytree(REPO_ROOT / "skills", root / "skills")
        if task_skills:
            assert task_skills_dir is not None
            shutil.copytree(task_skills_dir, root / TASK_SKILLS_CONFIG_DIR)
        keepers = root / "keepers"
        keepers.mkdir(exist_ok=True)
        for i in range(1, spec["keepers"] + 1):
            (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm, task_skills))
        return root

    # Provider-specific overrides live on the provider entry above. Read them
    # here rather than deriving capabilities from the HTTP protocol.
    thinking_control = pcfg.get("thinking_control_line", "")
    max_output = pcfg.get("max_output_tokens")
    if max_output is None and openrouter is not None:
        max_output = openrouter.max_output
    max_output_lines = (
        f"max-output-tokens = {max_output}\n" if max_output is not None else "")
    runtime_toml = RUNTIME_TOML.format(
        runtime_id=runtime_id, provider=runtime_provider, model_alias=model_alias,
        binding_id=binding_id,
        effort=effort, fusion=str(spec["fusion"]).lower(),
        max_concurrent=4 if spec["parallel"] else 1,
        remote_root=REMOTE_ROOT,
        effort_lines=(
            f'reasoning-effort = "{effort}"\nthinking-support = true\n'
            if pcfg.get("carries_effort") else ""),
        max_context_line=(
            f"max-context = {openrouter.max_context}\n" if openrouter else ""),
        max_output_lines=max_output_lines,
        thinking_control=thinking_control,
        disable_parallel=str(not spec["parallel"]).lower(),
        **pcfg)
    if task_skills:
        runtime_toml += "\n" + skills_block_with_task_source(
            include_seed_sources=spec["skills"])
    elif spec["skills"]:
        # skills=True arm만 seed의 [skills]/[[skills.sources]] 블록을 보존한다.
        # skills=False이면 이 블록을 빼서 skill source가 없어 어떤 skill도
        # 로드되지 않는다 (keeper TOML의 skills.names = []와 같은 방향).
        runtime_toml += "\n" + seed_skills_block()
    (root / "runtime.toml").write_text(runtime_toml)

    # skills=True arm은 skill source tree를 함께 싣는다. bootstrap.sh가 이를
    # $MASC_BASE_PATH/.masc/skills/로 옮겨 [[skills.sources]]가 resolve한다.
    # keeper 측 skills.names가 arm별 제한을 담당하므로 tree는 전부 싣는다.
    # skills=False이면 디렉터리 자체를 만들지 않는다.
    if spec["skills"]:
        shutil.copytree(REPO_ROOT / "skills", root / "skills")
    if task_skills:
        assert task_skills_dir is not None
        shutil.copytree(task_skills_dir, root / TASK_SKILLS_CONFIG_DIR)

    # NOTE: 예전에는 anthropic arm의 tool_execute.toml에서 [[one_of]]를 벤치 측
    # strip 했다 (Anthropic API의 top-level combinator 400 때문). masc v0.35.6
    # (#35168)부터 backend_anthropic.ml이 wire serialization 시점에 Anthropic
    # kind만 projection하므로 워크어라운드 제거 — seed 스키마 fidelity와
    # dispatcher의 [[one_of]] 런타임 검증을 두 레인 모두 회복한다.

    keepers = root / "keepers"
    keepers.mkdir(exist_ok=True)
    for i in range(1, spec["keepers"] + 1):
        (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm, task_skills))
    return root


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=sorted(ARMS))
    ap.add_argument("--runtime-id", default="anthropic.claude-fable-5-1")
    ap.add_argument("--effort", default="high")
    ns = ap.parse_args()
    print(render_arm(ns.arm, ns.runtime_id, ns.effort))
