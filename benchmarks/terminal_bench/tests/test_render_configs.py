import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "configs"))

from render_configs import ARMS, keeper_toml, render_arm  # noqa: E402


def test_arms_cover_spec():
    assert set(ARMS) == {"b", "c", "d", "e", "f", "g", "h"}
    assert ARMS["b"]["keepers"] == 1
    assert ARMS["f"]["keepers"] == 4
    assert ARMS["g"]["keepers"] == 8


def test_arm_b_skills_off():
    out = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    keeper = (out / "keepers" / "bench-1.toml").read_text()
    assert "always_allow = true" in keeper
    assert 'sandbox_profile = "remote_ssh"' in keeper
    # keeper TOML schema: [keeper] 테이블 안 dotted key (skills.names).
    # 빈 배열 = skills 없음. 최상위 [skills] 테이블은 parser가 unknown key로
    # 로드를 실패시키므로 이 형태여야 한다.
    assert "[keeper]" in keeper and "skills.names = []" in keeper
    rt = (out / "runtime.toml").read_text()
    assert '[fusion]' in rt and "enabled = false" in rt
    assert 'default = "anthropic.claude-fable-5"' in rt
    assert "[exec.ssh.endpoints.local]" in rt
    assert 'reasoning-effort = "high"' in rt


def test_arm_c_skills_on_no_composition():
    keeper = keeper_toml("c", 1)
    assert "skills.names" not in keeper  # 생략 = profile skills 전부
    assert "attached_allow" in keeper  # spawn/composition 도구 차단
    # allowlist는 실재하는 비-composition 도구만 담는다.
    assert "keeper_spawn" not in keeper
    assert "keeper_composition" not in keeper
    assert "masc_keeper_delegate" not in keeper


def test_arm_e_parallel_on():
    rt_e = render_arm("e", runtime_id="anthropic.claude-fable-5", effort="high")
    overlay = (rt_e / "agent-core-models-overlay.toml").read_text()
    assert "supports_parallel_tool_calls = true" in overlay
    rt_b = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    overlay_b = (rt_b / "agent-core-models-overlay.toml").read_text()
    assert "supports_parallel_tool_calls = false" in overlay_b
    assert "max-concurrent = 1" in (rt_b / "runtime.toml").read_text()


def test_arm_c_runtime_keeps_skills_sources():
    # skills=True arm은 seed runtime.toml의 [skills]/[[skills.sources]] 블록을
    # 보존해야 skill이 실제로 로드된다. skills=False arm은 생략한다.
    rt_c = render_arm("c", runtime_id="anthropic.claude-fable-5", effort="high")
    assert "[[skills.sources]]" in (rt_c / "runtime.toml").read_text()
    rt_b = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    assert "[[skills.sources]]" not in (rt_b / "runtime.toml").read_text()


def test_arm_f_renders_four_keepers():
    out = render_arm("f", runtime_id="anthropic.claude-fable-5", effort="high")
    keepers = sorted((out / "keepers").glob("bench-*.toml"))
    assert len(keepers) == 4
