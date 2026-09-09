# Firefox browser interaction proof

A disposable headless Firefox 155.0.1 profile loaded the extension implementation recorded by SHA-256 in measurement.json. Its proof-only native host name never connected to production MASC. The exact bytes were subsequently verified against committed source 47e99c445aafc175e0242fe8f07251b74a46dbad.

On a locally generated page, BrowserInteract's actual extension function filled #note, clicked #count, and scrolled to y=640. A fresh DOM read confirmed the text and button change; firefox-after-fill-click.png is the actual selected-tab viewport PNG. The complete tab creation/loading/actions/capture sequence took 173 ms, not the latency of a single operation.

Changed URL, ambiguous selector, disabled field and invalid numeric input returned distinct errors. The invalid numeric input retained its prior value 42. No external service or user browser profile participated.

This measures Firefox extension code. It does not claim a newly built MASC OCaml host/server/TUI, an autonomous Keeper turn, Zen compatibility, or automatic selector discovery has been exercised. The tool currently requires known explicit selectors.
