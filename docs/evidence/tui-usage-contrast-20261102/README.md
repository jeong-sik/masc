# Usage contrast: isolated TUI capture

- 날짜(ISO8601): 2026-11-02T11:40:00+09:00
- 작성자: Codex
- 결정 ID: tui-usage-contrast-47483
- 적용 대상: draft PR #47483, source commit `df981f02db0c6ced24ff5e7bc02083f0c1fcbbf2`
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: focused source build, tests, synthetic terminal captures and review
- 출처: `scripts/dune-local.sh`; test executables; retained ANSI, identity, input and screenshot files in this directory; `gh pr checks 47483 --watch`
- 확인일시: 2026-11-02T11:26:00+09:00–2026-11-02T11:44:10+09:00
- 신뢰도: High for the identified builds, tests, fixture and captured frames
- 제한조건: the fixture uses artificial provider usage and a server from a different commit; xterm.js screenshots replay captured bytes and are not the user's live terminal. No performance claim follows from these frames.

## 검증 (Verification)

- The final source TUI and provider test target built with `MASC_SKIP_DEPS_CHECK=1 DUNE_JOBS=1 scripts/dune-local.sh build bin/masc_tui.exe test/test_tui_overview_providers.exe`; the regular dependency guard passed in the immediately preceding focused build. Those build outcomes were observed in tool output; no separate build log is retained here. The TUI reports build commit `df981f02db0c6ced24ff5e7bc02083f0c1fcbbf2` and SHA-256 `b1baf55fb16175dc2fe7ee1776fffbe4add9aa8299a27aaf666226ff2702ab66`.
- The final provider suite passed 44 tests with [forced colour](test-providers-color.txt) and another 44 under [`NO_COLOR=1`](test-providers-no-color.txt). The separate [theme contrast suite](test-theme-color.txt) passed 22 tests; each log omits the local test-results path, and the commands, environment and executable hashes are transcribed in [observations](observations.txt). Its cache-toggle test passed with both `NO_COLOR=1` and `MASC_TUI_FORCE_COLOR=1` in tool output; no separate log for that combined setting is retained here. `git diff --check` passed. The independent final-head source reviewer reported no unresolved P0–P3 in the reviewed diff; this is not GitHub approval. The PR's changelog-format check passed for source commit `df981f02db0c6ced24ff5e7bc02083f0c1fcbbf2`; full CI was not observed.
- The fixture's server reports `e65093e585d61091eb72e7dd5cfa3942dc9209ad`, SHA-256 `627ef0d86f7c08e15b8012cdbf4747a9f36a981094f26ec47d97ca27847dbad0`; it is not the candidate's matching server. `/health?full=1` reported only the temporary base and instance `01a19a1d-8624-7000-933a-b09a35d5482a`. Its account-email endpoint returned zero rows read both before and after; [startup health](health-start-summary.json) was written by the fixture orchestrator, while the post-read, preflight and exit lines are [transcribed from tool output](observations.txt), not an independent audit log. The sandbox denied operator-home access, selected Keychain IPC services, unapproved process execution and non-fixture network connections; preflight observed EPERM for home read, direct server connection from the TUI profile, and unapproved execution. This is not a comprehensive syscall or Keychain audit.
- In a 170×45 PTY with no reported OSC palette, [the light-background replay](plan170shown-light.png) shows Usage names, connection text and at-limit `!` marks. In a 35×24 PTY with `NO_COLOR=1`, [the first view](plan35top.png) and [a scrolled view](plan35more.png) together show the long synthetic name, percentage and repeated marks; the latter raw prefix has zero colour SGR codes. Its reset and inverse codes remain. Screenshot colours are xterm.js 6.0.0 defaults with background `#f9f9f7` / foreground `#1c1c1c` for light and `#0c0e12` / `#e6e3da` for dark; no OSC palette answers were supplied. Replay strips an unsupported Kitty graphics query; each retained `.ansi.gz` input decompresses to the unmodified raw prefix through its snapshot, not the entire terminal session; the input logs also include subsequent quit keys.
- The two retained capture processes exited 0 after returning to Dashboard and quitting. A preliminary 170-column preview was force-stopped after a single `q` only returned to Dashboard; it is not one of the retained captures. The owned fixture server exited 0 and the owned proxy exited on SIGTERM. A limited scan of retained text/ANSI inputs found no email-like strings, absolute or tilde-prefixed operator-home paths, bearer strings or credential assignments; that scan is not a full privacy audit.

## 불확실성 (Uncertainty)

- 미확인 항목: the user's already-running TUI, all terminal themes/colour depths, live History latency and native Stack #47217 membership for #47483
- 영향: these captures prove the displayed synthetic fixture for one identified binary and emulator, not rollout or production behavior
- 추가 확인 필요: current-head review/checks, real terminal appearance if requested, and `gh stack link` after its authentication issue is resolved without copying credentials

## 적용범위 (Scope)

- 영향 받는 영역: Usage Plan, self-describing connection/status text, explicit colour-lift setting
- 제약/배제: the live server and user's running TUI were not restarted or replaced; other colour-only status paths remain tracked separately in #47482
- 롤백 조건: stop rollout if at-limit and other-use readings become indistinguishable or the selected workspace changes unexpectedly
