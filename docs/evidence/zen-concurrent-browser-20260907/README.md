# Firefox + Zen routing and TUI measurement

The actual MASC server, OCaml native host, and TUI were downloaded from [CI run 34126133709](https://github.com/jeong-sik/masc/actions/runs/34126133709), source `3f80b0bef240373abdcbef8e0a668e8130b5fbbe`. The allowlisted binary hashes are in [binary-artifact.json](binary-artifact.json). The server's embedded commit and executable hash were checked through `/health?full=1` on an isolated temporary runtime before the test.

## Observed behavior

[measurement.json](measurement.json) records a passing run with actual Firefox 155.0.1 and Zen 1.22b / Gecko 155.0.1, each in a disposable headless profile. Both fixture tabs had ID **1**.

- The live inventory preserved distinct client UUIDs and actual browser versions. Zen's `getBrowserInfo()` reports `name: Firefox` plus `zen.version`; the explicit Zen metadata supplied its brand.
- `BrowserTabs` without a selected client returned both available identities and `ambiguous_browser_clients`. Completed reads on both serial native queues confirmed that the ambiguous request dispatched no browser command.
- Explicit client + tab selection filled, clicked, scrolled, and captured only the chosen browser. A fresh read verified each result and the other browser's retained state.
- Closing Firefox left Zen connected. Requests using the retired Firefox UUID were refused and dispatched no native command.
- A fresh Firefox process reused tab ID 1 but received a new client UUID. The old UUID remained refused, the new fixture started unchanged, and Zen retained its prior state. Completed read barriers checked both queues again.

The extension's native command handler included an awaited metadata-only observer for queue evidence. The 15 measured HTTP/MCP operations include that observer and transport overhead. Two fill calls took 17.9/8.7 ms, click calls 20.3/8.0 ms, and scroll calls 9.1/12.0 ms. These local samples are not a comparative performance benchmark.

## Actual TUI path

The same CI-built TUI connected to the real scratch MASC server while both browsers were open. The probe opened Browser, chose Zen from the UUID inventory, verified `Owned zen`, `Clicked zen`, and `Scroll 640`, and pressed Ctrl-O. The TUI emitted the complete [Zen PNG](zen-through-tui.png) through its Kitty graphics protocol. It then returned to Overview and exited normally through the two-key quit confirmation. No VDISCARD override was applied by this probe.

[browser-text.ansi](browser-text.ansi) contains the terminal output before image preview. The PNG is the image payload actually emitted by the TUI; this measurement observes the terminal protocol rather than a desktop terminal compositor.

The separate repository PTY scenario passed screenshot ownership, URL draft retention, cancellation, client selection/reconnection, error recovery, and terminal restoration using this same compiled TUI. Its two corrected differential-frame waits and fresh picker-output wait are recorded by the test fixture source; [tui-fixture-tests.log](tui-fixture-tests.log) is the result. The native host's real HTTP/stdio fixture suite also passed all 12 tests in 25.634 seconds ([log](native-host-tests.log)).

## Configured automation browser

A separate [automation measurement](automation-configuration.json) exercised the same server's `runtime.toml` browser configuration. A temporary loopback observer captured the actual WebDriver session request: `moz:firefoxOptions.binary` was the configured Zen executable, and geckodriver had no CLI binary override. The returned process ID was independently matched to that executable and its `application.ini` Name=Zen. The WebDriver browser version was 1.22b.

MASC opened the session in 3157.1 ms, navigated to a generated local page in 93.4 ms, read it in 45.8 ms, and returned the [PNG](configured-zen-automation.png) in 85.7 ms. The created session was closed, the configuration bytes stayed unchanged, and the plain idle driver was restored and independently checked. Paths in the published receipt use an explicitly documented user-directory redaction.

## Scope

The proof revision combines the product implementations from capture #34009, interaction #34019, Zen configuration #34043, client routing #34051, TUI selection #34034, and VDISCARD #34052. Later test dependency, comment, and schema-description corrections have separate PR heads. This receipt names the exact executable revision that was measured.

All local fixture servers, native manifests, and disposable browser sessions belonged to the proof. Their cleanup is recorded in the receipt. The operator's production server and profiles were untouched. A Keeper model turn is not included in these measurements.
