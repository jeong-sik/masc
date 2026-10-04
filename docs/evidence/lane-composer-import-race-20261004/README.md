# Composition import ordering — local browser evidence

The standalone Lane composer now keeps the latest selected file or subsequent
edit when an older `File.text()` completes. This is browser behavior in a design
editor. No MASC server, installation, native worker, live provider, Broadcast or
Keeper use was executed.

The same committed browser scenario ran against the HTML/exporter from base
`a3461f1fb69fc85041ab62ae0d27a60902c1c90d` and the candidate files. Each summary
records source SHA-256 values, including the scenario itself. Chromium was
`147.0.7727.15`; neither run reported a page error.

| Run | Observed result | Evidence |
| --- | --- | --- |
| Base HTML, candidate scenario | Expected failure: select A then B, complete B then A; final downloaded graph is A / `run-a` | [summary](baseline-summary.json), [download](baseline-late-a.json), [screenshot](baseline-late-a.png) |
| Candidate HTML and scenario | Pass: the same final download remains B / `run-b`; all 17 browser check groups pass | [summary](candidate-summary.json), [download](candidate-late-a.json), [screenshot](candidate-late-a.png) |

The fixture defers the real browser `File.text()` promises while using actual
file-input changes, editor fields, template selection and Undo. Both A/B completion
orders are checked, together with typing before blur, a committed setting edit,
template replacement, Undo, stale validation/read errors and a failed latest
import. A node inspection without editing still permits the current import.
Negative cases compare the live editor graph and rendered title/run setting;
the main stale-overwrite case checks a real downloaded JSON and all four rendered
TOMLs. Stale reads add no Undo entry.

The full runner also passed its existing declaration download, saved-settings
roundtrip, report display, sharing-receipt and mobile layout checks. Report data
comes from local Python MCP package subprocesses with synthetic host evidence;
sharing metadata is synthetic. Its fixture now supplies custom response text to
`computation_output(text=...)` before that helper retains the response, preserving
the existing producer/receipt contract. No package or sampling contract changed.

Run the candidate checks from the repository root:

```sh
python3 test/test_lane_composition_browser.py --output-dir /tmp/lane-composer-browser
node test/test_lane_composition_export.mjs
```

The Node exporter check passed as well. To reproduce the baseline, copy the
candidate scenario into a temporary tree with the three other source files named
by `baseline-summary.json` taken from the base commit, then run the same Python
command there. It fails in the first import scenario before package execution.

Native Lane sampling, retention recovery, runtime reconciliation and downstream
Keeper use remain outside this change and this evidence.
