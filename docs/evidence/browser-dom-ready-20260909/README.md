# Read visible DOM before remaining resources finish

Actual Firefox extension experiment using Gecko WebDriver, with a synthetic page
whose image response is held by the local fixture server. The page text is already
visible. `tabs.executeScript` with `runAt: "document_end"` returns that text while
the image is still held; the default call returns only after the fixture releases
it. Both exact responses are in `proof.json`.

Reproduce with existing binaries (no local build):

```sh
python3 test/test_browser_injection_timing.py --driver /path/to/geckodriver --browser /path/to/firefox --out /path/to/evidence
```

The extension now uses document_end for observation and interaction injection.
It waits for the DOM to exist, without requiring remaining images to finish.
This fixture establishes the loading dependency; it does not establish that the
current Slack timeout has this cause. Live Slack verification remains pending.

Mozilla documents document_idle as the default:
https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/executeScript
