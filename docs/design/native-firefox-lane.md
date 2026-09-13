# Native Firefox Browser Lane

MASC owns automation sessions in OCaml/Eio and speaks the W3C WebDriver
protocol directly to Mozilla geckodriver. Firefox is the stock browser.
The `live` lane is the operator's WebExtension connection; it supports semantic
reads, capture and explicit-tab interactions, including observed-link follows
and screenshot point click/scroll. Trusted drag, BrowserAct and session lifecycle
operations belong to automation. The current action contracts are in
[Browser Lane](browser-lane.md#browser-controls).

Set the existing workspace `runtime.toml`:

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
```

Run `geckodriver --host 127.0.0.1 --port 4444 --websocket-port 0`, then restart MASC. Session
open/close, navigation, tab listing and page reading use the native executor.
The configured endpoint must be a loopback HTTP origin. This setting is
required for automation: without an installed native executor, automation
commands return `Lane_absent`. The external poll/result endpoints accept
only `live`; they cannot register or answer for automation.

The HTTP port and BiDi WebSocket port are separate. `--websocket-port 0`
lets the OS allocate a free BiDi port instead of sharing the default 9222
with another browser or driver. A collision there can make session setup
fail at the WebSocket handshake even while the HTTP driver reports ready.
See Mozilla's [geckodriver flags](https://firefox-source-docs.mozilla.org/testing/geckodriver/Flags.html).

The OCaml client serializes commands for its owned session, retains stable
integer tab IDs, reports WebDriver failures, and forgets invalid sessions so
an explicit open can recover after Firefox exits. A session opens an isolated
Firefox profile; it does not borrow the operator's authenticated profile.
Browser text is capped by Unicode code points. Remote requests have a 60-second
I/O deadline, while the lane's overall deadline includes lock acquisition and
every request in a tab scan. Cancellation releases the session lock so the
next command can run. A closed current tab does not prevent discovering the
remaining windows. Server shutdown deletes its owned session through a fresh
transport scope after the normal server connections have been released.
geckodriver is a vendor browser driver, not application logic.

Sources checked 2026-09-07:

- https://firefox-source-docs.mozilla.org/testing/geckodriver/Usage.html
- https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/Capabilities/firefoxOptions
- https://www.w3.org/TR/webdriver/
- https://github.com/ocaml-multicore/eio

Validation: lifecycle/crash-recovery scenarios are registered in
`test_browser_webdriver`. Local builds are excluded by the execution protocol;
compilation and execution evidence must come from CI, followed by a deployed
binary run. Source changes alone do not prove native runtime behavior.

Interaction, explicit tab targeting, and screenshot/Vision contracts are described in
[Firefox interaction support](firefox-controls.md). See [usage examples](browser-lane-examples.md)
for the supported live and automation capabilities.
