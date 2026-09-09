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

[models.{model_alias}]
reasoning-effort = "{effort}"

[{runtime_id}]
max-concurrent = {max_concurrent}

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
[[models]]
id_prefix = "{model_alias}"
supports_parallel_tool_calls = {parallel}
"""

# provider 프로토콜 매핑. 새 provider 추가 시 여기만 고친다.
PROVIDERS = {
    "anthropic": dict(protocol="messages-http",
                      endpoint="https://api.anthropic.com",
                      api_key_env="ANTHROPIC_API_KEY"),
    "openai": dict(protocol="openai-compatible-http",
                   endpoint="https://api.openai.com/v1",
                   api_key_env="OPENAI_API_KEY"),
    "kimi_coding": dict(protocol="openai-compatible-http",
                        endpoint="https://api.kimi.com/coding/v1",
                        api_key_env="KIMI_API_KEY"),
}


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
        **pcfg)
    if spec["skills"]:
        # skills=True arm만 seed의 [skills]/[[skills.sources]] 블록을 보존한다.
        # skills=False이면 이 블록을 빼서 skill source가 없어 어떤 skill도
        # 로드되지 않는다 (keeper TOML의 skills.names = []와 같은 방향).
        runtime_toml += "\n" + seed_skills_block()
    (root / "runtime.toml").write_text(runtime_toml)
    (root / "agent-core-models-overlay.toml").write_text(OVERLAY_TOML.format(
        model_alias=model_alias, parallel=str(spec["parallel"]).lower()))

    # skills=True arm은 skill source tree를 함께 싣는다. bootstrap.sh가 이를
    # $MASC_BASE_PATH/.masc/skills/로 옮겨 [[skills.sources]]가 resolve한다.
    # keeper 측 skills.names가 arm별 제한을 담당하므로 tree는 전부 싣는다.
    # skills=False이면 디렉터리 자체를 만들지 않는다.
    if spec["skills"]:
        shutil.copytree(REPO_ROOT / "skills", root / "skills")

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
