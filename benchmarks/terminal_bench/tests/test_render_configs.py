import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "configs"))

from render_configs import (  # noqa: E402
    ARMS,
    composition_skill_names,
    instruction_skill_names,
    keeper_toml,
    render_arm,
)


def test_skill_classification_matches_repo():
    # skills/ 아래 10개 중 composition skill은 ```toml composition 블록을
    # 가진 2개뿐이다 (2026-09-10 repo 사실 확인).
    assert composition_skill_names() == ["browser-live-click-regions", "msx-observe"]
    assert instruction_skill_names() == [
        "browser-design", "browser-lanes", "evidence-review",
        "frontend-implement", "frontend-verify", "msx-play",
        "observe-act-verify", "slack-web",
    ]


def test_arms_cover_spec():
    # b-h are the spec's ablation chain; k is the keeper-pool arm that
    # agents/keeper_tools_agent.py renders (no keeper is pre-started).
    assert set(ARMS) == {"b", "c", "d", "e", "f", "g", "h", "k"}
    assert ARMS["b"]["keepers"] == 1
    assert ARMS["f"]["keepers"] == 4
    assert ARMS["g"]["keepers"] == 8
    assert ARMS["k"]["keepers"] == 4


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
    # composition OFF = skills.names를 비-composition skill로 명시 제한한다.
    # (tools.attached_allow는 built-in을 gate하지 못하는 no-op이라 폐기.)
    assert "skills.names = [" in keeper
    for name in instruction_skill_names():
        assert f'"{name}"' in keeper
    for name in composition_skill_names():
        assert f'"{name}"' not in keeper
    assert "attached_allow" not in keeper


def test_skills_tree_copied_only_for_skills_arms():
    out_c = render_arm("c", runtime_id="anthropic.claude-fable-5", effort="high")
    skill_dirs = sorted(p.name for p in (out_c / "skills").iterdir() if p.is_dir())
    # keeper 측 names 리스트가 제한을 담당하고, source tree는 10개 전부 실어
    # 두 메커니즘이 서로를 honest하게 유지한다.
    assert skill_dirs == sorted(instruction_skill_names() + composition_skill_names())
    out_b = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    assert not (out_b / "skills").exists()


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


SPAWN = ["keeper_spawn", "keeper_spawn_read", "keeper_spawn_wait", "keeper_spawn_stop"]
DELEGATE = ["masc_keeper_delegate", "masc_keeper_delegate_status", "masc_keeper_delegate_cancel"]


def test_tools_deny_maps_spawn_to_parallel_and_delegate_to_keepers():
    # v0.35.6 (#35169): tools.deny로 built-in을 surface에서 제거한다.
    # spawn = parallel 기구 → parallel=False arm(b, c, d)에서 deny.
    # delegate = 다 keeper 위임 → keepers=1 arm(b-e)에서 deny.
    for arm in ("b", "c", "d"):
        keeper = keeper_toml(arm, 1)
        assert "tools.deny = [" in keeper
        for name in SPAWN + DELEGATE:
            assert f'"{name}"' in keeper, f"arm {arm} must deny {name}"
    keeper_e = keeper_toml("e", 1)
    assert "tools.deny = [" in keeper_e
    for name in SPAWN:
        assert f'"{name}"' not in keeper_e, f"arm e keeps {name}"
    for name in DELEGATE:
        assert f'"{name}"' in keeper_e, f"arm e denies {name}"
    for arm in ("f", "g", "h"):
        assert "tools.deny" not in keeper_toml(arm, 1), f"arm {arm} denies nothing"


def test_claude_code_lane_renders_official_client_provider():
    # masc protocol "claude-code" (runtime_adapter.claude_code_execution): the
    # provider is a CLI command with is-non-interactive = true, no endpoint
    # and no credentials table — the CLI owns the login. Effort lands on the
    # model row (CLI --effort), and no overlay deployment row is written.
    out = render_arm("b", runtime_id="claude_code.claude-sonnet-5", effort="high")
    rt = (out / "runtime.toml").read_text()
    assert 'default = "claude_code.claude-sonnet-5"' in rt
    assert 'protocol = "claude-code"' in rt
    assert 'command = "claude"' in rt
    assert "is-non-interactive = true" in rt
    # [exec.ssh.endpoints.local] stays, so match the provider keys themselves.
    assert 'endpoint = "' not in rt
    assert "[providers.claude_code.credentials]" not in rt
    assert 'api-name = "claude-sonnet-5"' in rt
    assert 'reasoning-effort = "high"' in rt
    assert "turn-timeout-s = 900.0" in rt
    assert '[claude_code."claude-sonnet-5"]' in rt
    assert "max-concurrent = 1" in rt
    assert "[exec.ssh.endpoints.local]" in rt
    overlay = (out / "agent-core-models-overlay.toml").read_text()
    assert "[[providers]]" not in overlay and "[[models]]" not in overlay
    keeper = (out / "keepers" / "bench-1.toml").read_text()
    assert 'sandbox_profile = "remote_ssh"' in keeper


def test_claude_code_lane_keeps_arm_knobs():
    out_e = render_arm("e", runtime_id="claude_code.claude-opus-5", effort="max")
    rt_e = (out_e / "runtime.toml").read_text()
    assert "max-concurrent = 4" in rt_e
    assert "[[skills.sources]]" in rt_e
    assert (out_e / "skills").is_dir()
    out_h = render_arm("h", runtime_id="claude_code.claude-opus-5", effort="max")
    assert "enabled = true" in (out_h / "runtime.toml").read_text()
    assert len(sorted((out_h / "keepers").glob("bench-*.toml"))) == 8


def test_claude_code_lane_rejects_minimal_effort():
    import pytest
    with pytest.raises(ValueError, match="minimal"):
        render_arm("b", runtime_id="claude_code.claude-sonnet-5", effort="minimal")
