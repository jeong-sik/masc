"""Doctor framework 단위 테스트.

실제 네트워크/파일시스템 의존 없이 Check 조립 / 렌더링 / exit code / auto-fix
콜백 동작만 검증한다.
"""

from __future__ import annotations

import json

import pytest

from gate_shared.doctor import (
    AutoFix,
    Check,
    Doctor,
    Severity,
    check_dependencies_installed,
    exit_code_for,
    render_json,
    render_pretty,
)


def test_severity_symbols_render_prefix() -> None:
    checks = [
        Check(name="alpha", severity=Severity.ok, message=""),
        Check(name="beta", severity=Severity.warn, message="missing"),
        Check(name="gamma", severity=Severity.error, message="broken"),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "[✓] alpha" in text
    assert "[!] beta" in text
    assert "[✗] gamma" in text
    # ok 는 상세 줄이 없어야 한다
    assert "↳ " in text  # warn/error 는 ↳ 로 설명
    assert "missing" in text and "broken" in text


def test_banner_all_ok() -> None:
    checks = [
        Check(name="a", severity=Severity.ok, message=""),
        Check(name="b", severity=Severity.ok, message=""),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "모든 검사가 통과" in text
    # all-ok 에서는 조치 항목 블록이 나오면 안 된다
    assert "조치 항목:" not in text


def test_banner_has_error_takes_priority_over_warn() -> None:
    checks = [
        Check(name="a", severity=Severity.ok, message=""),
        Check(name="b", severity=Severity.warn, message="m"),
        Check(name="c", severity=Severity.error, message="boom"),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "심각한 문제 1개" in text
    assert "실행 전 점검" in text
    # warn 배너 문구는 error 가 있을 때 배너 줄에 노출되지 않아야 한다
    banner_section = text.split("조치 항목:")[0]
    assert "주의 항목" not in banner_section.splitlines()[2]


def test_banner_warn_only() -> None:
    checks = [Check(name="a", severity=Severity.warn, message="m")]
    text = render_pretty("T", checks, use_color=False)
    assert "주의 항목 1개" in text
    assert "실행은 가능" in text


def test_banner_all_skipped_not_ok() -> None:
    """전제 부족으로 전부 skip 될 때는 '통과' 로 오해되지 않도록."""

    checks = [
        Check(name="a", severity=Severity.skip, message=""),
        Check(name="b", severity=Severity.skip, message=""),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "건너뛰었습니다" in text
    assert "모든 검사가 통과" not in text


def test_action_items_lists_hints_and_auto_fix() -> None:
    checks = [
        Check(
            name="needs-cfg",
            severity=Severity.warn,
            message="m",
            hint="SLACK_BOT_TOKEN 을 환경에 설정",
        ),
        Check(
            name="needs-fix",
            severity=Severity.error,
            message="x",
            auto_fix=AutoFix(description="권한 재설정", command="chmod 0755 /var/gate"),
        ),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "조치 항목:" in text
    assert "[설정] needs-cfg — SLACK_BOT_TOKEN 을 환경에 설정" in text
    assert "[수동 실행] 권한 재설정" in text
    assert "$ chmod 0755 /var/gate" in text


def test_action_item_marks_auto_fix_callback_available() -> None:
    async def _noop() -> None:
        return None

    checks = [
        Check(
            name="auto",
            severity=Severity.error,
            message="x",
            auto_fix=AutoFix(description="재시작", callback=_noop),
        )
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "[자동 치유] 재시작" in text
    assert "# doctor --fix 로 실행" in text


def test_summary_line_in_korean() -> None:
    checks = [
        Check(name="a", severity=Severity.ok, message=""),
        Check(name="b", severity=Severity.warn, message="m"),
        Check(name="c", severity=Severity.error, message="x"),
    ]
    text = render_pretty("T", checks, use_color=False)
    assert "합계: 정상 1 · 경고 1 · 오류 1" in text


def test_render_json_shape() -> None:
    checks = [Check(name="x", severity=Severity.ok, message="", detail="v1")]
    payload = json.loads(render_json("T", checks))
    assert payload["title"] == "T"
    assert payload["checks"][0]["severity"] == "ok"
    assert payload["summary"]["ok"] == 1
    assert payload["summary"]["error"] == 0


def test_exit_code_priority() -> None:
    ok = [Check(name="a", severity=Severity.ok, message="")]
    warn = [Check(name="a", severity=Severity.warn, message="m")]
    err = [
        Check(name="a", severity=Severity.warn, message="m"),
        Check(name="b", severity=Severity.error, message="boom"),
    ]
    assert exit_code_for(ok) == 0
    assert exit_code_for(warn) == 1
    assert exit_code_for(err) == 2


@pytest.mark.asyncio
async def test_check_dependencies_installed_reports_missing() -> None:
    fn = check_dependencies_installed(["httpx", "nonexistent_pkg_xyz_xyz"])
    result = await fn()
    assert result.severity == Severity.error
    assert "nonexistent_pkg_xyz_xyz" in result.detail
    assert result.hint is not None


@pytest.mark.asyncio
async def test_check_dependencies_installed_all_present() -> None:
    fn = check_dependencies_installed(["httpx"])
    result = await fn()
    assert result.severity == Severity.ok


def test_severity_needs_action() -> None:
    assert Severity.warn.needs_action()
    assert Severity.error.needs_action()
    assert not Severity.ok.needs_action()
    assert not Severity.info.needs_action()
    assert not Severity.skip.needs_action()


@pytest.mark.asyncio
async def test_doctor_runs_all_checks_even_when_one_raises() -> None:
    async def good() -> Check:
        return Check(name="good", severity=Severity.ok, message="")

    async def bad() -> Check:
        raise RuntimeError("boom")

    async def other() -> Check:
        return Check(name="other", severity=Severity.warn, message="skip-me")

    d = Doctor("unit")
    d.register_many([good, bad, other])
    results = await d.run()
    names = [c.name for c in results]
    assert names == ["good", "bad", "other"]
    bad_check = results[1]
    assert bad_check.severity == Severity.error
    assert "RuntimeError" in bad_check.message


@pytest.mark.asyncio
async def test_auto_fix_callback_invoked_only_for_warn_or_error() -> None:
    calls: list[str] = []

    async def fix_ok() -> None:
        calls.append("ok-fix")

    async def fix_bad() -> None:
        calls.append("bad-fix")

    ok_check = Check(
        name="ok",
        severity=Severity.ok,
        message="",
        auto_fix=AutoFix(description="noop", callback=fix_ok),
    )
    bad_check = Check(
        name="bad",
        severity=Severity.error,
        message="x",
        auto_fix=AutoFix(description="retry", callback=fix_bad),
    )

    async def emit_ok() -> Check:
        return ok_check

    async def emit_bad() -> Check:
        return bad_check

    d = Doctor("unit")
    d.register_many([emit_ok, emit_bad])
    initial = await d.run()
    rerun, outcomes = await d.run_auto_fixes(initial)
    assert calls == ["bad-fix"]
    assert len(rerun) == 2
    # outcome 은 실제로 실행된 fix 에 대해서만 기록된다 — ok 는 skip
    assert [o.check_name for o in outcomes] == ["bad"]
    assert outcomes[0].success is True


@pytest.mark.asyncio
async def test_run_auto_fixes_captures_failure_and_continues() -> None:
    """한 fix 가 예외를 던져도 나머지 fix 가 계속 실행돼야 한다."""

    calls: list[str] = []

    async def fix_raises() -> None:
        calls.append("first")
        raise OSError("boom")

    async def fix_succeeds() -> None:
        calls.append("second")

    c1 = Check(
        name="first",
        severity=Severity.error,
        message="x",
        auto_fix=AutoFix(description="do first", callback=fix_raises),
    )
    c2 = Check(
        name="second",
        severity=Severity.error,
        message="y",
        auto_fix=AutoFix(description="do second", callback=fix_succeeds),
    )

    async def emit_c1() -> Check:
        return c1

    async def emit_c2() -> Check:
        return c2

    d = Doctor("unit")
    d.register_many([emit_c1, emit_c2])
    initial = await d.run()
    _, outcomes = await d.run_auto_fixes(initial)
    # 첫 실패가 두 번째 실행을 막지 않아야 한다
    assert calls == ["first", "second"]
    assert [o.success for o in outcomes] == [False, True]
    assert "OSError: boom" in outcomes[0].message


def test_render_fix_outcomes_empty_returns_empty_string() -> None:
    from gate_shared.doctor import render_fix_outcomes  # noqa: PLC0415

    assert render_fix_outcomes([], use_color=False) == ""


def test_render_fix_outcomes_shows_success_and_failure() -> None:
    from gate_shared.doctor import FixOutcome, render_fix_outcomes  # noqa: PLC0415

    outcomes = [
        FixOutcome(
            check_name="binding paths writable",
            description="0755 적용",
            success=True,
        ),
        FixOutcome(
            check_name="stale lock",
            description="lock 파일 삭제",
            success=False,
            message="PermissionError: read-only",
        ),
    ]
    text = render_fix_outcomes(outcomes, use_color=False)
    assert "자가 치유 실행:" in text
    assert "[✓] binding paths writable — 0755 적용" in text
    assert "[✗] stale lock — lock 파일 삭제" in text
    # 실패한 fix 의 에러 메시지는 하위 들여쓰기로 노출
    assert "↳ PermissionError: read-only" in text
