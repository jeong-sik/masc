import sys
import tomllib
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "configs"))

from render_configs import (  # noqa: E402
    ARMS,
    COMPOSITION_FENCE,
    REPO_ROOT,
    effective_runtime_id,
    composition_skill_names,
    instruction_skill_names,
    keeper_toml,
    render_arm,
)


def test_skill_classification_agrees_with_the_files():
    # This used to pin the exact skill names as of 2026-09-10. That made it a
    # change detector: two skills landing on main (sangokushi-2 and
    # sangokushi-2-end-command, one of them a composition skill) broke it
    # without saying anything about whether the classifier is right. What arm
    # c actually depends on is the invariant — a skill is a composition skill
    # exactly when its SKILL.md carries the fenced composition block — so
    # assert that against an independent read of the files.
    composition = composition_skill_names()
    instruction = instruction_skill_names()
    all_skills = sorted(p.parent.name for p in (REPO_ROOT / "skills").glob("*/SKILL.md"))

    assert all_skills, "no skills found; the renderer would silently restrict nothing"
    # A partition: nothing lost, nothing counted twice.
    assert sorted(composition + instruction) == all_skills
    assert not (set(composition) & set(instruction))
    # Both sides non-empty, or arm c's restriction is a no-op in one direction.
    assert composition and instruction

    expected_composition = sorted(
        name
        for name in all_skills
        if any(
            line.startswith(COMPOSITION_FENCE)
            for line in (REPO_ROOT / "skills" / name / "SKILL.md")
            .read_text()
            .splitlines()
        )
    )
    assert composition == expected_composition


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
    keeper = keeper_toml("c")
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


@pytest.mark.parametrize("arm", list(ARMS))
def test_parallel_arm_sets_request_policy_without_changing_model_facts(arm):
    root = render_arm(arm, runtime_id="anthropic.claude-fable-5", effort="high")
    config = tomllib.loads((root / "runtime.toml").read_text())
    binding = config["anthropic"]["claude-fable-5"]
    assert binding["disable-parallel-tool-use"] is (not ARMS[arm]["parallel"])
    capabilities = config["models"]["claude-fable-5"]["capabilities"]
    assert "supports-parallel-tool-calls" not in capabilities


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
        keeper = keeper_toml(arm)
        assert "tools.deny = [" in keeper
        for name in SPAWN + DELEGATE:
            assert f'"{name}"' in keeper, f"arm {arm} must deny {name}"
    keeper_e = keeper_toml("e")
    assert "tools.deny = [" in keeper_e
    for name in SPAWN:
        assert f'"{name}"' not in keeper_e, f"arm e keeps {name}"
    for name in DELEGATE:
        assert f'"{name}"' in keeper_e, f"arm e denies {name}"
    for arm in ("f", "g", "h"):
        assert "tools.deny" not in keeper_toml(arm), f"arm {arm} denies nothing"


def test_claude_code_lane_renders_official_client_provider():
    # masc protocol "claude-code" (runtime_adapter.claude_code_execution): the
    # provider is a CLI command with is-non-interactive = true, no endpoint
    # and no credentials table — the CLI owns the login. Effort lands on the
    # model row (CLI --effort), and the lane declares no capabilities of its
    # own: the embedded catalog answers for these models by api-name.
    out = render_arm("e", runtime_id="claude_code.claude-sonnet-5", effort="high")
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
    assert "turn-timeout-s = 0.0" in rt
    assert "wall-clock-ceiling-s = 28800.0" in rt
    assert '[claude_code."claude-sonnet-5"]' in rt
    assert "max-concurrent = 4" in rt
    assert "[exec.ssh.endpoints.local]" in rt
    assert '[models."claude-sonnet-5".capabilities]' not in rt
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


@pytest.mark.parametrize("arm", ["b", "c", "d"])
def test_claude_code_refuses_parallel_off_before_writing_configs(arm, tmp_path):
    with pytest.raises(ValueError, match="requires disabling parallel tool calls"):
        render_arm(arm, "claude_code.claude-sonnet-5", "high", out_root=tmp_path)
    assert list(tmp_path.iterdir()) == []


@pytest.fixture
def openrouter_lists(monkeypatch):
    import render_configs

    asked = []

    def limits(wire_model):
        asked.append(wire_model)
        return render_configs.OpenRouterLimits(max_context=111616, max_output=16384)

    monkeypatch.setattr(render_configs, "openrouter_limits", limits)
    return asked


def test_a_slashed_wire_model_binds_by_slug_and_keeps_the_wire_name(openrouter_lists):
    # runtime_toml.ml refuses a model id outside [A-Za-z0-9._-]+, and the
    # OpenRouter wire id carries a vendor slash. Rendering it verbatim made
    # the whole config fail to load ("model id must match"), which surfaced
    # as masc_keeper_up answering "no valid initialized runtime" — measured
    # 2026-09-12 against release 0.35.8.
    out = render_arm("b", runtime_id="openrouter.z-ai/glm-4.7-flash", effort="high")
    rt = (out / "runtime.toml").read_text()
    assert 'default = "openrouter.z-ai-glm-4.7-flash"' in rt
    assert '[models."z-ai-glm-4.7-flash"]' in rt
    assert '[openrouter."z-ai-glm-4.7-flash"]' in rt
    # The wire name survives, because that is what reaches the provider.
    assert 'api-name = "z-ai/glm-4.7-flash"' in rt
    assert '[models."z-ai/glm-4.7-flash"]' not in rt


def test_the_router_lane_inherits_its_ladder_instead_of_declaring_one(
        openrouter_lists):
    # An accepted_reasoning_efforts list written here is a capability claim the
    # benchmark makes up about someone else's API. The router publishes one
    # contract for everything it serves, so the catalog carries it
    # (Capabilities.openrouter_capabilities) and this lane inherits it.
    out = render_arm("b", runtime_id="openrouter.z-ai/glm-4.7-flash", effort="high")
    rt = (out / "runtime.toml").read_text()
    # Pin the capability block present first: a render that dropped it would
    # satisfy the absences below without inheriting anything.
    assert '[models."z-ai-glm-4.7-flash".capabilities]' in rt
    for spelling in ("accepted_reasoning_efforts", "accepted-reasoning-efforts"):
        assert spelling not in rt
    # The dialect is inherited too, so it is not declared either — unlike the
    # openai lane, which has to declare it (see PROVIDERS).
    assert "thinking-control-format" not in rt
    # The effort still reaches the runtime; inheriting is not disabling.
    assert 'reasoning-effort = "high"' in rt


def test_no_lane_writes_a_ladder_of_its_own():
    # Which efforts a model takes is a fact the vendors publish per model:
    # gpt-6-astra answers HTTP 400 to none while gpt-5.6-sol, -terra and -luna
    # accept it, so one list written here is wrong for one side or the other.
    # The catalog is where that fact lives; a lane whose model has no row is
    # refused by name (Undeclared_reasoning_effort_capability), which is the
    # outcome to keep.
    # An absence on its own is the weak kind of assertion this file is being
    # cleaned of: an empty render, or one that dropped the row entirely, would
    # satisfy it. So the row is pinned present first, and the ladder absent
    # from that row.
    for runtime_id, model_alias in (
            ("anthropic.claude-fable-5", "claude-fable-5"),
            ("openai.gpt-6-astra", "gpt-6-astra")):
        provider = runtime_id.split(".", 1)[0]
        out = render_arm("b", runtime_id=runtime_id, effort="high")
        rt = (out / "runtime.toml").read_text()
        assert f'[{provider}."{model_alias}"]' in rt, runtime_id
        assert f'api-name = "{model_alias}"' in rt, runtime_id
        assert "thinking-support = true" in rt, runtime_id
        for spelling in ("accepted_reasoning_efforts", "accepted-reasoning-efforts"):
            assert spelling not in rt, runtime_id


def test_effective_runtime_id_is_what_masc_resolves():
    assert effective_runtime_id("openrouter.z-ai/glm-4.7-flash") == (
        "openrouter.z-ai-glm-4.7-flash"
    )
    # A model with no slash is untouched, so the existing lanes keep their ids.
    assert effective_runtime_id("anthropic.claude-sonnet-5") == (
        "anthropic.claude-sonnet-5"
    )
    for bad in ("no-dot", ".leading", "trailing."):
        try:
            effective_runtime_id(bad)
        except ValueError:
            continue
        raise AssertionError(f"{bad!r} should be rejected, not guessed at")


def test_http_lanes_declare_tool_calling():
    # `masc runtime-verify` refuses a binding without tools-support, so the
    # offline readiness check answered tools_not_declared for lanes that do
    # deliver tools (the Agent_core arm reads the catalog capability instead).
    for runtime_id in ("anthropic.claude-sonnet-5", "openrouter.z-ai/glm-4.7-flash"):
        rt = (render_arm("b", runtime_id=runtime_id, effort="high") / "runtime.toml")
        assert "tools-support = true" in rt.read_text(), runtime_id


def test_two_renders_of_one_arm_do_not_share_a_directory():
    # harbor runs several trials of the same arm at once and each calls
    # render_arm through install(). A shared configs/out/<arm> meant one
    # trial's rmtree ran while another was mid-upload.
    a = render_arm("b", runtime_id="anthropic.claude-sonnet-5", effort="high")
    b = render_arm("b", runtime_id="anthropic.claude-sonnet-5", effort="high")
    assert a != b
    assert a.exists() and b.exists()
    assert (a / "runtime.toml").read_text() == (b / "runtime.toml").read_text()


def test_an_openrouter_lane_declares_the_window_and_output_budget(openrouter_lists, tmp_path):
    # 0.35.19 refuses a runtime with no catalog max-context and no override
    # ("no silent default — RFC-0206 §2.1"), and OpenRouter models are not in
    # the catalog: masc_keeper_up answered "Model setup required" (2026-09-17).
    import tomllib

    out = render_arm("b", runtime_id="openrouter.z-ai/glm-4.7-flash", effort="high",
                     out_root=tmp_path)
    runtime = tomllib.loads((out / "runtime.toml").read_text())
    model = runtime["models"]["z-ai-glm-4.7-flash"]
    assert model["max-context"] == 111616
    assert "max-context" not in runtime["providers"]["openrouter"]
    assert model["capabilities"]["max-output-tokens"] == 16384
    assert openrouter_lists == ["z-ai/glm-4.7-flash"]


def test_a_catalog_lane_declares_no_window_override(tmp_path):
    import tomllib

    out = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high",
                     out_root=tmp_path)
    runtime = tomllib.loads((out / "runtime.toml").read_text())
    assert "max-context" not in runtime["models"]["claude-fable-5"]


def endpoints_listing(monkeypatch, endpoints):
    import io
    import json

    import render_configs

    fetched = []

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def urlopen(url, **_):
        fetched.append(url)
        return Response(json.dumps({"data": {"endpoints": endpoints}}).encode())

    render_configs.openrouter_limits.cache_clear()
    monkeypatch.setattr(render_configs.urllib.request, "urlopen", urlopen)
    return render_configs, fetched


def test_every_endpoint_can_serve_the_declared_input_and_output(monkeypatch):
    # The real z-ai/glm-4.7-flash endpoint list, 2026-09-17.
    render_configs, fetched = endpoints_listing(monkeypatch, [
        {"provider_name": "Venice", "context_length": 128000, "max_completion_tokens": 16384},
        {"provider_name": "Cloudflare", "context_length": 131072, "max_completion_tokens": 117964},
        {"provider_name": "Novita", "context_length": 200000, "max_completion_tokens": 128000},
    ])
    limits = render_configs.openrouter_limits("z-ai/glm-4.7-flash")
    assert limits == render_configs.OpenRouterLimits(max_context=111616, max_output=16384)
    render_configs.openrouter_limits("z-ai/glm-4.7-flash")
    assert len(fetched) == 1, "read once per process"
    render_configs.openrouter_limits.cache_clear()


def test_an_endpoint_without_a_completion_limit_does_not_set_the_budget(monkeypatch):
    render_configs, _ = endpoints_listing(monkeypatch, [
        {"context_length": 64000, "max_completion_tokens": None},
        {"context_length": 128000, "max_completion_tokens": 8192},
    ])
    assert render_configs.openrouter_limits("vendor/model") == (
        render_configs.OpenRouterLimits(max_context=64000 - 8192, max_output=8192))
    render_configs.openrouter_limits.cache_clear()


@pytest.mark.parametrize("endpoints, reason", [
    ([], "no endpoints"),
    ([{"context_length": None, "max_completion_tokens": 4096}], "no context_length"),
    ([{"context_length": 8192, "max_completion_tokens": None}], "declares max_completion_tokens"),
    ([{"context_length": 8192, "max_completion_tokens": 8192}], "leaves no input"),
])
def test_limits_openrouter_cannot_state_are_refused(monkeypatch, endpoints, reason):
    render_configs, _ = endpoints_listing(monkeypatch, endpoints)
    with pytest.raises(ValueError, match=reason):
        render_configs.openrouter_limits("vendor/model")
    render_configs.openrouter_limits.cache_clear()
