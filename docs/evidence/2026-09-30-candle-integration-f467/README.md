# Integrated Candle result at f467:29/30 suites

[Run36597801658](https://github.com/jeong-sik/masc/actions/runs/36597801658)
executed source `f4673b23d7686a62ace921be5ecb588e7e072f88`.
Its targeted Test step failed:29 requested suites reported OK and
`test_tui_remote_equipped_portrait` failed. The workflow was still running its
separate no-build step at inspection. This is not a full integration PASS.

The raw targeted log is preserved losslessly in `ci-run-tests.log.gz`.
[result.json](result.json) retains every successful/failed suite identity.

## Confirmed new coverage

- Dashboard HTTP passed135cases, including actual isolated Paid1000 →
  purchase200 → equip → warm HTTP/briefing/production SSE preparation. The
  assertions verify supply1000/200/800, wallet800 and current equipment, then
  Disabled/null and unchanged corrupt ledger bytes. This is the production
  payload preparation function, not a live SSE socket ordering proof.
- The currency PTY scenario passed against the integrated main Dashboard:
  Ready large amounts → Disabled/malformed supply/malformed balance/Off.
  The three errors retain client pause control and recover balances. Wire
  input is synthetic loopback JSON; it does not pause a live Keeper.
- Goal, appraisal, purchase, ledger, decoder, Auth/Play, Lane Add-on and Quiz
  suites listed in result.json completed. Injected appraisal decisions are
  not semantic model acceptance; the positive whole Goal→Paid gap remains
  separately under investigation in the accompanying audit.

## Remaining failure

The remote portrait scenario passes the real workspace mismatch boundary but
cannot select the expected Keeper. Remote HTTP refresh populates runtime
roster data while the visible list relies on local metadata cleared by the
mismatch. The frame wait fails with an empty Keeper list; no PNG parity result
is inferred. The native portrait router case invoked before the failed PTY is
not evidence that the remote TUI rendered the resulting PNG.

The earlier649 prepared-byte failures are absent: this source contains the
canonical portrait fields in the smoke fixture. No assertions were weakened.
A replacement run after the remote list correction must retain its own source
identity and results. No deployment or live workspace change was performed.

## Original artifacts

`currency-artifacts.tar.gz` retains all original current-head terminal frames,
PTY streams, request receipts and binary manifest. The Ready captures identify
the actual MASC Dashboard title and all three exact large supply amounts.
`remote-artifacts.tar.gz` retains the failed remote scenario's raw PTY, health
fixtures, native router log, original before/equipped PNGs and roster JSON.
Both archives preserve every source file byte; they do not turn the failed
remote render into a successful image comparison.
