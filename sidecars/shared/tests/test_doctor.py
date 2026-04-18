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
    await d.run_auto_fixes(initial)
    assert calls == ["bad-fix"]
