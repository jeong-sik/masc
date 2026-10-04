"""Usage account cards and separate views in the current-head fixture PTY."""
import base64
import hashlib
import json
import os
import sys
import time

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime






def fixtures():
    now = time.time()
    result = _keyboard_harness.keeper_runtime_http_fixtures()
    _, runtime = _keyboard_runtime.runtime_resolved_response()
    assert isinstance(runtime, dict)
    scopes = []
    for index, (name, share) in enumerate([
        ("Claude Code Max Subscription", 0.0),
        ("Codex ChatGPT Subscription", 0.25),
        ("Codex ChatGPT Subscription", 0.33),
        ("Antigravity Google Subscription", 1.0),
        ("Kimi For Coding Subscription", 0.5),
        ("팀 계정 · 긴 이름도 숫자를 밀어내지 않음", 0.67),
    ]):
        scope = f"provider:studio-{index}"
        scopes.append({
            "scope": scope, "scope_id": hashlib.md5(scope.encode()).hexdigest(),
            "providers": [{"id": f"studio-{index}", "display_name": name}],
            "state": "reported", "windows": [
                {"limit_id": None, "window": {"kind": "five_hour"},
                 "role": "gates_model_calls",
                 "utilization": {"unit": "fraction", "value": share},
                 "resets_at": now + 3600, "observed_at": now - 30, "source": "fixture"},
                {"limit_id": None, "window": {"kind": "seven_day"},
                 "role": "gates_model_calls",
                 "utilization": {"unit": "fraction", "value": 0.89},
                 "resets_at": now + 5 * 86400, "observed_at": now - 30, "source": "fixture"},
            ]})
    scopes[0]["windows"][0]["resets_at"] = now - 300
    scopes[0]["windows"].extend([
        {"limit_id": "TOOL_LIMIT", "window": {"kind": "provider_label", "label": "tool calls"},
         "role": "counts_other_use", "utilization": {"unit": "percent", "value": 100},
         "resets_at": None, "observed_at": now - 30, "source": "fixture"},
        {"limit_id": "UNKNOWN_LIMIT", "window": {"kind": "provider_label", "label": "unknown"},
         "role": "unclassified_limit", "utilization": {"unit": "percent", "value": 80},
         "resets_at": None, "observed_at": now - 30, "source": "fixture"},
    ])
    runtime["provider_usage_windows"] = scopes
    runtime["runtimes"][0].update({"quota_scope": scopes[0]["scope"],
                                  "quota_exhausted": True,
                                  "quota_resets_at": now + 5 * 86400})
    result[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (200, runtime)
    result[_keyboard_harness.ACCOUNT_EMAILS_PATH] = (200, {"account_emails": [
        {"integration_id": "studio-0", "state": "read", "email": "claude@example.com"},
        {"integration_id": "studio-5", "state": "read", "email": "long-account-identity-that-wraps@example.com"}]})
    for days in (1, 7, 14):
        result[f"/api/v1/dashboard/provider-usage-history?days={days}"] = (200, {
            "days": days, "generated_at": now,
            "sampling": "latest_provider_report_per_utc_day", "unreadable_reports": 0, "reported_no_windows": [],
            "points": [{"scope_id": scope["scope_id"], "kind": "five_hour",
                        "limit_id": None, "unit": "fraction", "value": value,
                        "observed_at": now - (6 - offset) * 86400,
                        "source": "fixture", "resets_at": None}
                       for scope in scopes
                       for offset, value in enumerate((0.0, 0.15, None, 0.35, 0.6, 0.9, 0.4))
                       if value is not None and 6 - offset < days]})
    result["/api/v1/dashboard/keeper-costs?window=1440"] = (200, {
        "keepers": [], "window_minutes": 1440, "generated_at": now,
        "cache": {"state": "fresh", "generated_at": now}})
    return result, scopes


def capture(process, fd, output, name, rows, columns, needle):
    _keyboard_harness.resize_and_wait(process, fd, output, rows=rows, columns=columns + 1,
                      needle=needle, controls=(_keyboard_harness.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
    frame = _keyboard_harness.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                             needle=needle, controls=(_keyboard_harness.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
    screen = _keyboard_harness.screen_text(frame)
    print("STUDIO_CAPTURE=" + json.dumps({"suite": "test_tui_usage_studio_pty",
        "name": name, "rows": rows, "columns": columns,
        "provenance": "CI fixture PTY", "frame_b64": base64.b64encode(frame).decode(),
        "screen": b"\n".join(_keyboard_harness.screen_rows(frame).get(row, b"") for row in range(1, rows + 1)).decode(errors="replace")}), flush=True)
    return screen


def journey(executable, no_color=False):
    responses, scopes = fixtures()
    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        _keyboard_harness.tab_until(process, fd, output, b"MASC Usage")
        _keyboard_harness.wait_for_output(process, fd, output, b"catalogue reopens", start=0, timeout=10)
        wide = capture(process, fd, output, "plan-wide-no-color" if no_color else "plan-wide",
                       80, 220, b"claude@example.com")
        for value in (b"Plan usage", b"Used   0%", b"Used  25%", b"Used  33%", b"Reset",
                      b"Last report", b"Model call limit", b"Other use", b"does not block model calls",
                      b"Unclassified limit", b"Catalogue", b"reported", b"claude@example.com",
                      b"Remaining", b"At limit (reported)", b"Blocked (observed)", b"Trend 14 UTC days"):
            if value not in wide:
                raise AssertionError(f"Plan omitted {value!r}: {wide!r}")
        if b"Quota scope trend" in wide or b"Keeper usage" in wide:
            raise AssertionError("Plan mixed unrelated views into its account cards")
        for scope in scopes:
            if scope["scope_id"][:8].encode() not in wide:
                raise AssertionError("Plan merged or hid independently reported scopes")
        compact = capture(process, fd, output, "plan-compact", 30, 80, b"catalogue reopens")
        if b"0%" not in compact or b"exhausted (observed)" not in compact:
            raise AssertionError("compact Plan conflated observed blocking and provider usage")
        capture(process, fd, output, "terminal-too-small", 14, 80, b"terminal too small")
        short = capture(process, fd, output, "plan-short", 16, 80, b"Plan usage")
        later_account = scopes[-1]["scope_id"][:8].encode()
        if later_account in short:
            raise AssertionError("scroll fixture's later account is already visible")
        while later_account not in short:
            notice = next((line for line in short.splitlines() if b"[rows " in line), None)
            if notice is None:
                raise AssertionError("short Usage has no reachable overflow window")
            span = notice.split(b"[rows ", 1)[1].split(b" ", 1)[0]
            window, total = span.split(b"/")
            first, last = map(int, window.split(b"-"))
            if last >= int(total):
                raise AssertionError("later account remained hidden at the end of Usage")
            # Move one visible window in individual row steps so no account
            # heading can be skipped between consecutive inspected windows.
            _keyboard_harness.press_and_settle(process, fd, output, b"j" * (last - first + 1), cap=4.0)
            short = capture(process, fd, output, "plan-short-scrolled", 16, 80, b"MASC Usage")
            updated = next((line for line in short.splitlines() if b"[rows " in line), None)
            if updated is None or int(updated.split(b"[rows ", 1)[1].split(b"-", 1)[0]) <= first:
                raise AssertionError("Usage scroll input did not advance its visible window")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[H", b"Claude")
        capture(process, fd, output, "plan-restored", 30, 120, b"Claude")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"UTC days reported")
        trend = capture(process, fd, output, "trend", 60, 220, b"UTC days reported")
        for value in (b"100%", b"75%", b"50%", b"25%", b"UTC", b"Latest report", b"6/14 UTC days reported"):
            if value not in trend:
                raise AssertionError(f"Trend omitted chart evidence {value!r}: {trend!r}")
        if not any(b"Antigravity" in line and "팀 계정".encode() in line for line in trend.splitlines()):
            raise AssertionError("wide Trend did not place account charts side by side")
        compact_trend = capture(process, fd, output, "trend-compact", 30, 80, b"UTC days reported")
        if b"100%" not in compact_trend or b"Latest report" not in compact_trend:
            raise AssertionError("compact Trend hid the measurement or its scale")
        for reading in (trend, compact_trend):
            for meaning in ("↓ below zero", "↑ above limit"):
                if meaning.encode() not in reading:
                    raise AssertionError(f"Trend omitted range meaning {meaning!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"w", b"1 UTC days")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Keeper usage")
        capture(process, fd, output, "keepers", 30, 120, b"Keeper usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC Usage / Telemetry")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"Keeper usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Plan usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")
    _keyboard_harness.run_terminal_scenario(executable, description="Usage studio" + (" NO_COLOR" if no_color else ""),
                            interact=interact, http_fixtures=responses,
                            terminal_cols=220, terminal_rows=48,
                            extra_env={"NO_COLOR": "1"} if no_color else {})


def failure(executable):
    responses, _ = fixtures()
    responses[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (503, {"error": "usage-studio-unavailable"})
    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        _keyboard_harness.tab_until(process, fd, output, b"MASC Usage")
        _keyboard_harness.wait_for_output(process, fd, output, b"usage data unavailable", start=0, timeout=10)
        screen = capture(process, fd, output, "plan-source-failed", 30, 80, b"usage data unavailable")
        if b"0%" in screen:
            raise AssertionError("unavailable source became zero usage")
        os.write(fd, b"q")
    _keyboard_harness.run_terminal_scenario(executable, description="Usage failed source", interact=interact,
                            http_fixtures=responses, terminal_cols=80, terminal_rows=30)


def keeper_comparison(executable, no_color=False, unreported_cost=False):
    responses, _ = fixtures()
    def row(name, tokens, cost, missing=0, failed=False, malformed=0, unread=0):
        return {"keeper_name": name, "sample_count": 10,
                "total_tokens": tokens, "total_cost_usd": cost,
                "tokens_reported_samples": 0 if tokens is None else 10 - missing,
                "tokens_unreported_samples": missing, "tokens_unread_samples": 0,
                "cost_reported_samples": 0 if cost is None else 10 - missing,
                "cost_unreported_samples": missing, "cost_unread_samples": 0,
                "metrics_read": {"state": "failed", "reason": "fixture read failure"} if failed
                                else {"state": "read", "malformed_rows": malformed, "unread_turn_rows": unread}}
    keeper_rows = [row("alpha", 1000, 1.0), row("beta-partial", 500, 0.25, missing=3, malformed=2, unread=3),
                   row("gamma-missing", None, None, missing=10, unread=4),
                   row("delta-failed", 900000, 900.0, failed=True), row("epsilon-zero", 0, 0.0)]
    responses["/api/v1/dashboard/keeper-costs?window=1440"] = (200, {
        "keepers": keeper_rows,
        "window_minutes": 1440, "generated_at": 1790985600.0,
        "cache": {"state": "stale_refreshing", "generated_at": 1790985600.0, "age_s": 120.0,
                  "last_error": "fixture refresh failure"}})
    if unreported_cost:
        for keeper in keeper_rows:
            keeper["total_cost_usd"] = None
            keeper["cost_reported_samples"] = 0
            keeper["cost_unreported_samples"] = 10
    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        _keyboard_harness.tab_until(process, fd, output, b"MASC Usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Quota scope trend")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Keeper usage")
        suffix = "-unreported-cost" if unreported_cost else "-no-color" if no_color else ""
        wide = capture(process, fd, output, "keeper-comparison-wide" + suffix,
                       70, 120, b"epsilon-zero")
        for text in ("Scale: tokens 1000", "cost unreported" if unreported_cost else "cost $1.0000", "As of 2026-10-03 00:00 UTC",
                     "120s old", "refresh failed: fixture refresh failure",
                     "partial (2 malformed rows, 3 unread turn rows)",
                     "partial (0 malformed rows, 4 unread turn rows)", "reported totals are lower bounds", "7 reported, 3 missing",
                     "unreported", "fixture read failure", "bars are not quota",
                     "[unavailable", "[" + "░" * 32 + "] 0"):
            assert text.encode() in wide, f"Keeper comparison evidence missing: {text}"
        assert wide.count(b"[unavailable") == (8 if unreported_cost else 6), "missing/failed metrics drew a bar"
        compact = capture(process, fd, output, "keeper-comparison-compact" + suffix,
                          20, 80, b"Keeper usage")
        assert b"Scale: tokens 1000" in compact
        for _ in range(70):
            current = _keyboard_harness.press_and_settle(process, fd, output, b"j")
            if b"epsilon-zero" in current:
                break
        else:
            raise AssertionError("last Keeper was unreachable on compact screen")
        capture(process, fd, output, "keeper-comparison-bottom" + suffix,
                20, 80, b"epsilon-zero")
        os.write(fd, b"q")
    _keyboard_harness.run_terminal_scenario(executable, description="Keeper reported usage comparison" + (" no color" if no_color else ""),
                            interact=interact, http_fixtures=responses,
                            terminal_cols=120, terminal_rows=70,
                            extra_env={"NO_COLOR": "1"} if no_color else {})


def keeper_partial_scale(executable, *, unreported_cost=False, unreported_tokens=False):
    responses, _ = fixtures()
    now = time.time()
    responses["/api/v1/dashboard/keeper-costs?window=1440"] = (200, {
        "keepers": [{
            "keeper_name": "partial-only", "sample_count": 1,
            "total_tokens": None if unreported_tokens else 1000,
            "total_cost_usd": None if unreported_cost else 1.0,
            "tokens_reported_samples": 0 if unreported_tokens else 1,
            "tokens_unreported_samples": 1 if unreported_tokens else 0,
            "tokens_unread_samples": 0,
            "cost_reported_samples": 0 if unreported_cost else 1,
            "cost_unreported_samples": 1 if unreported_cost else 0,
            "cost_unread_samples": 0,
            "metrics_read": {"state": "read", "malformed_rows": 0, "unread_turn_rows": 2}}],
        "window_minutes": 1440, "generated_at": now,
        "cache": {"state": "fresh", "generated_at": now}})

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        _keyboard_harness.tab_until(process, fd, output, b"MASC Usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Quota scope trend")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"Keeper usage")
        screen = capture(process, fd, output, "keeper-partial-scale", 40, 160, b"partial-only")
        tokens = "unreported" if unreported_tokens else "unavailable (no complete window)"
        cost = "unreported" if unreported_cost else "unavailable (no complete window)"
        assert f"Scale: tokens {tokens} · cost {cost}".encode() in screen
        if not unreported_tokens:
            assert b"Tokens  1000" in screen
        if not unreported_cost:
            assert b"Cost    $1.0000" in screen
        assert screen.count(b"[unavailable") == 2
        assert "█".encode() not in screen and "░".encode() not in screen
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Keeper partial-only metric scales",
                            interact=interact, http_fixtures=responses,
                            terminal_cols=160, terminal_rows=40)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(open(executable, "rb").read()).hexdigest())
    journey(executable)
    journey(executable, no_color=True)
    failure(executable)
    keeper_comparison(executable)
    keeper_comparison(executable, no_color=True)
    keeper_comparison(executable, unreported_cost=True)
    keeper_partial_scale(executable)
    keeper_partial_scale(executable, unreported_cost=True)
    keeper_partial_scale(executable, unreported_cost=True, unreported_tokens=True)
    print("tui usage studio PTY: PASS")
