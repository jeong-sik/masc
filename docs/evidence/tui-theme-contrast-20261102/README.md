# Theme contrast labels: isolated TUI capture

- 날짜(ISO8601): 2026-11-02T12:54:00+09:00
- 작성자: Codex
- 결정 ID: tui-theme-contrast-label-47483
- 적용 대상: Draft PR #47483, source delta on `f236caf37f1dd4719a8cf2a7dbf05958da48b871`
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: 80×24 before/after and 140×24 after PTY captures with synthetic fixture data
- 출처: retained raw terminal prefixes, input logs, binary identities and replay images in this directory
- 확인일시: 2026-11-02T12:49:00+09:00–2026-11-02T12:54:00+09:00
- 신뢰도: High for these identified local binaries and inspected synthetic frames
- 제한조건: the server is an older build, the workspace and responses are synthetic, and the images replay terminal bytes. This is not the user's live TUI, an installed rollout, or a measurement of an actual terminal's indexed palette.

## 검증 (Verification)

- The [80-column baseline](before-80.png) labels an under-floor scheme as `보정 1/7` with no explanation. The [80-column candidate](after-80.png) shows the heading `원래 대비` and the value `부족 1/7`. Both use `NO_COLOR=1`. The [140-column candidate](after-140.png) also displays the explanation that the numbers are based on theme values. These observations concern the captured frames; narrower widths can clip the existing table.
- The baseline binary SHA-256 is `fa93f2304fe28682d409fd5516a04f335465c9c625a8ec504dee73608a94760f`: it was built from the Keeper source represented by `aa77119f2fe011090999495d829f9a5be89a0092` with parent `2079903f1636615afc1a783c69b329b1eb60f771` checked out. The later `f236caf` delta is evidence/comment only.
- The candidate binary SHA-256 is `f36c09535e5e56167d359350f0f21518225ed0224b6f6f3125fb4bcf2698edef`. It was built with `f236caf37f1dd4719a8cf2a7dbf05958da48b871` checked out and the source delta uncommitted; the captured binary reports that parent. Two subsequent source edits changed comments only. It is not an exact-head or installed binary.
- The sandboxed fixture server is the older `e65093e585d61091eb72e7dd5cfa3942dc9209ad` build and the proxy supplies synthetic responses. The [startup summary](health-summary.json) records its temporary base and zero read account-email rows. Sandbox profiles deny operator-home access, selected Keychain IPC services, non-fixture networking and unapproved process execution; these settings and the startup observation are not a comprehensive isolation audit. The three captured TUI processes exited 0; the owned server exited 0 and the proxy exited on SIGTERM. These exit results were transcribed from tool output in [shutdown transcript](shutdown-transcript.txt), not collected as an independent process log.
- Each `.ansi.gz` decompresses to the unmodified PTY prefix through its named snapshot; the input logs include later exit keys. PNGs are xterm.js 6.0.0 replays with dark background `#0c0e12`; the replay removes an unsupported Kitty graphics query. The two `NO_COLOR` prefixes used SGR 0, 7 and 49 (reset/reverse/default-background), with no colour-setting SGR. The [SHA-256 manifest](SHA256SUMS) records the retained files. A limited scan for email-like strings, operator-home paths, bearer strings and credential assignments found no matches; this is not a full privacy audit.

## 불확실성 (Uncertainty)

- 미확인 항목: real terminal colour configuration, installed TUI and final-head runtime
- 영향: the captures establish labels and layout for this fixture, not actual indexed-colour contrast
- 추가 확인 필요: #47482, #47503 and #47507 track remaining palette and surface limitations

## 적용범위 (Scope)

- 영향 받는 영역: theme picker measurement labels
- 제약/배제: no live server or installed TUI was restarted or replaced
- 롤백 조건: restore if the labels misstate the original scheme values or displace essential content
