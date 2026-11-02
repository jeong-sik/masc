# Keeper suggested action: isolated TUI capture

- 날짜(ISO8601): 2026-11-02T12:13:59+09:00
- 작성자: Codex
- 결정 ID: tui-keeper-action-text-47483
- 적용 대상: draft PR #47483 업데이트 후보, source commit `aa77119f2fe011090999495d829f9a5be89a0092`
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: focused TUI build, Keeper-control tests, synthetic PTY captures and source review
- 출처: `scripts/dune-local.sh`; [test log](keeper-control-no-color.txt); retained raw terminal prefixes, input logs, binary identities and replay screenshots in this directory
- 확인일시: 2026-11-02T11:52:00+09:00–2026-11-02T12:13:59+09:00
- 신뢰도: High for the identified local build, fixture and inspected frames
- 제한조건: the fixture server is an older build, the Keeper rows are synthetic, and the screenshots replay PTY bytes in xterm.js. They do not establish the appearance or behavior of the user's running TUI.

## 검증 (Verification)

- `MASC_SKIP_DEPS_CHECK=1 DUNE_JOBS=1 scripts/dune-local.sh build bin/masc_tui.exe` passed with the source represented by `aa77119f2fe011090999495d829f9a5be89a0092`. The build ran with parent `2079903f1636615afc1a783c69b329b1eb60f771` checked out and the final source change uncommitted, so the binary reports that parent, not the final source commit. Its SHA-256 is `fa93f2304fe28682d409fd5516a04f335465c9c625a8ec504dee73608a94760f`. The ordinary dependency guard had passed in the preceding focused Usage build.
- The existing `test_tui_keeper_control.exe` passed [66 tests under `NO_COLOR=1`](keeper-control-no-color.txt). These cover control and reading decisions; they are not assertions about UI wording or layout. The full test-results path was omitted from the retained log. `git diff --check` passed.
- The fixture supplied three named synthetic Keeper rows, with `recover`, `probe` and `direct_message` suggestions, through a read-only loopback proxy. The sandboxed server was the older `e65093e585d61091eb72e7dd5cfa3942dc9209ad` build; its effective temporary base and zero account-email rows at startup appear in [startup health](health-start-summary.json). Sandbox profiles denied operator-home access, selected Keychain IPC services, unapproved process execution and non-fixture networking. These are profile settings and startup observations, not a comprehensive isolation audit.
- A [20×24 capture](narrow.png) shows the selected Keeper, its health and runtime, and the complete `direct message` suggestion wrapped in the navigator. A [140×24 capture](wide.png) shows the same suggestion in the Info pane and selected-Keeper summary below the roster. Both used `NO_COLOR=1` and contained zero colour SGR sequences in the retained prefixes; reset and inverse sequences remain. The PNGs are xterm.js 6.0.0 replays with background `#0c0e12` and foreground `#e6e3da`. Replay removes an unsupported Kitty graphics query; each `.ansi.gz` decompresses to the unmodified raw prefix through its snapshot, not a full session. Input logs also include the later exit keys.
- Earlier exploratory captures built from the uncommitted source now in `ea2d808b8267c3542cb838cb15830464e0fd090d` showed all three suggestions in Info. That binary reports its then-checked-out parent `d6f3956d573daeca6df61bc9e873697c713f751e`. One earlier preview was force-stopped after a single quit key did not exit; it is not a retained capture. Both retained capture processes exited 0 after returning and quitting. The owned server exited 0 and the owned proxy exited on SIGTERM. A limited scan of retained ANSI and input logs found no email-like strings, operator-home paths, bearer strings or credential assignments; this is not a full privacy audit.
- An independent source reviewer inspected the complete Keeper delta from `d6f3956d573daeca6df61bc9e873697c713f751e` through source head `aa77119f2fe011090999495d829f9a5be89a0092`. Findings concerning unobserved action, narrow wrapping and the detail-row budget were corrected. The reviewer reported no remaining P0–P3 in that delta; full diff SHA-256 `8ded53b5394becb0c6fbaa73b34be5a2e4d3d12ad6011b811f9c6eea6bb738a0`. This is a static source review, not a GitHub approval.

## 불확실성 (Uncertainty)

- 미확인 항목: the already-running TUI, current-head GitHub approval and a real user's terminal
- 영향: these captures demonstrate a synthetic fixture, not an installed rollout or a Keeper operation
- 추가 확인 필요: native Stack #47217 membership and current-head review/checks

## 적용범위 (Scope)

- 영향 받는 영역: Keeper navigator, Info pane and chat identity header
- 제약/배제: no live server or installed TUI was restarted or replaced; the existing Keeper health label is tracked separately in #47494
- 롤백 조건: stop rollout if suggested actions are attributed to the wrong selected Keeper or obscure its observed state
