# Live Firefox: recovered browsing, unsuccessful composition

A separate headless Firefox profile loaded the actual Browser Lane extension
and native messaging host. The operator TUI copied a live scene context, and a
natural Keeper turn used it to summarize three synthetic team channels.

The Keeper answered the request and the live TUI followed all three pages.
**The new composition did not complete.** This is a recorded failure and
recovery experiment, not proof that the composition made live browsing faster.

| Result | Observed |
| --- | --- |
| Outer calls / errors | 13 / 4 |
| Composition attempts / successful compositions | 1 / 0 |
| Subsequent direct link follows | 3 |
| Successful retained scene reads | 4, exact delivered bytes verified |
| Raw outer result bytes | 25,153 UTF-8 bytes, including failure suffixes |
| Observed turn duration | 55.264 seconds |
| Completed TUI frames | 67; Alpha, Beta and Gamma each visible |
| Operator input after Keeper start | None |
| Owned server, driver and TUI exits | 0 |

## What failed and what recovered

The original [TUI context](tui-context.json), native client list and copied user
message agree on `a93a5385-6faa-44ea-8bfc-e576f2cfadf4`. The model instead supplied
`a93a5385-6faa-44ea-8bfc-e5761f2cfadf4` twice to BrowserRead and once to the new
composition. The extra digit makes it an invalid UUID. The composition stopped
at `click` with a recorded `proven_pre_effect` result; it did not follow a link
or run the dependent content read.

The model then omitted clientId in the ordinary tools. The server could resolve
the only connected browser, and three direct follows plus scene reads retrieved
the requested channels. A separate text-mode read failed because it carried a
navigation guard that requires scene or regions mode. All four errors and the
raw failure-class suffixes remain in [composition-audit.json](composition-audit.json).
The audit also preserves byte-count discrepancies where a raw failure suffix
was added after the producer's byte count.

The answer correctly distinguishes the superseded Friday plan from Tuesday's
Alpha decision, leaves Alpha's unspecified owner unassigned, identifies Joon
and Sora's explicit responsibilities, and cites visible-message links. The
sidebar's cached snippet was excluded. This validates the recovered answer's
visible coverage, not a complete history crawl.

The input failures were reported as `workflow_rejection`, with guidance about
waiting for changed state. Here the caller needed to correct its arguments.
That distinction is an identified recovery-feedback gap; it is not fixed or
proved fixed by this evidence. The failed composition is not counted among the
three successful direct follows.

## Identity and visible evidence

- Server/TUI candidate: `cc757326f8ebb1d4d3d4ac08486bb507352be35f`, as in
  [report.json](report.json). The experimental Skill is the reviewed source from
  `07c2479c49452ef8fcda6e64b01b2d81e84d40b4`, copied into this isolated runtime.
  It was **not exported by that older binary**.
- [extension/](extension/) contains the actual loaded extension files. The only
  background-script modification changes `HOST_NAME` to a unique private test
  host. Its page scripts and extension manifest were unchanged. The temporary
  native host registration was removed after the experiment; the operator's
  ordinary host registration and Firefox profiles were not replaced.
- [Live Gamma TUI](tui-gamma.png) and [actual Firefox screenshot](firefox-final.png)
  show the fixture. The TUI images replay complete frames from the original
  native PTY; source recordings, clipboard bytes and per-frame offsets are
  included. They do not imply aligned browser screenshots for every observation.
- [native-history-d441/](native-history-d441/) records a **separate** final
  history-key regression on downloaded macOS TUI `d4414681eb`. Its native CI
  run is 34711268006; its Linux suite run is 34711266435. This passed the `B`
  reopen repair and does not change which candidate produced the live experiment.

## Verify the recorded experiment

```sh
python3 docs/evidence/browser-live-content-20260913/audit.py
```

The standard-library audit uses only this bundle. It checks hashes, raw result
and receipt joins, the failed composition's settled node, wrong UUID arguments,
the direct follow receipts, exact retained scene bytes, completed TUI frame
prefixes and process cleanup. It performs no network calls or browser actions.
The original collection scripts in `scripts/` depend on the original local
paths and private runtime setup and are archived procedures, not portable
reproduction commands. No credential value is included. Slack was not accessed.
