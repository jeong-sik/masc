# Native Firefox Browser Lane

MASC owns automation sessions in OCaml/Eio and speaks the W3C WebDriver
protocol directly to Mozilla geckodriver. Firefox is the stock browser.
The `live` lane remains the operator's read-only WebExtension connection.

Set the existing workspace `runtime.toml`:

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
```

Run `geckodriver --host 127.0.0.1 --port 4444`, then restart MASC. Session
open/close, navigation, tab listing and page reading use the native executor.
The configured endpoint must be a loopback HTTP origin. Without this setting,
the existing automation command queue remains available.

The OCaml client serializes commands for its owned session, retains stable
integer tab IDs, reports WebDriver failures, and forgets invalid sessions so
an explicit open can recover after Firefox exits. A session opens an isolated
Firefox profile; it does not borrow the operator's authenticated profile.
Browser text is capped by Unicode code points. Remote requests have a 60-second
I/O deadline. Server shutdown attempts to close its session before releasing
the HTTP pool. geckodriver is a vendor browser driver, not application logic.

Sources checked 2026-09-07:

- https://firefox-source-docs.mozilla.org/testing/geckodriver/Usage.html
- https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/Capabilities/firefoxOptions
- https://www.w3.org/TR/webdriver/
- https://github.com/ocaml-multicore/eio

Validation: lifecycle/crash-recovery scenarios are registered in
`test_browser_webdriver`. Local builds are excluded by the execution protocol;
compilation and execution evidence must come from CI, followed by a deployed
binary run. Source changes alone do not prove native runtime behavior.
