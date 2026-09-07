# Firefox selected-tab image capture

Firefox 155.0.1 ran in a disposable headless profile using Mozilla geckodriver 0.37.1. The production extension source at the recorded commit was loaded with a proof-only native host name, so it did not connect to the operator's MASC browser queue. A local generated HTML page supplied the fixture. The extension captured an explicitly identified background tab without substituting the active tab.

`firefox-selected-tab.png` is the actual returned viewport PNG. Tab creation, loading and capture together took 191 ms; this is not isolated screenshot latency. The PNG is 37,237 bytes. See `measurement.json` for the source identity and hash.

The first harness attempted a WebDriver navigation to an extension URL, which Firefox refused. The revised harness initially raced the fixture's about:blank load; the production capture code correctly rejected the changed URL. Waiting for the requested fixture URL and completed load produced the recorded successful capture. No production browser tabs or profiles were modified.

This proves the extension capture API and returned image in real Firefox. The newly changed OCaml host, server endpoint, Keeper vision call and TUI preview have not yet been measured together. Their source checks and fixture regressions must not be presented as that end-to-end measurement.

Contracts: [Mozilla captureTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/captureTab), [W3C viewport screenshot](https://www.w3.org/TR/webdriver2/#take-screenshot).
