# Native Slice scope refusal and the separately found global-query defect

Frozen source `d9b62724e72e7a3f231a4a7f2f3ca4cd7d8a5e1f`,
[native run 39614788834](https://github.com/jeong-sik/masc/actions/runs/39614788834).
The original receipt, executable hash/build-commit checks and actual logs identify
24 TUI and 5 application checks. Those 29 checks passed; they did not cover the
global HTTP path defect found below. This is not execution of a rebased candidate.

The actual matching server and TUI used an isolated workspace whose declaration
was Off, with two retained workers from the previous synthetic observer session.
No new worker was started. A raw forwarding proxy closed only selected Slice
connections; it fabricated no response and logged no headers or credentials.
The operator server, browser, provider and installed binaries were not changed.

## Direct observations

1. Captures03–04 open the original retained worker and select its original row.
2. Capture05 shows a real Slice connection failure while the original row and
   selection remain. Inventory reads continue through the real backend.
3. Captures06–07 choose Preserve only and receive a real Evidence POST receipt.
   It coexists with the read failure. Its content-addressed digest matches the
   earlier identical saved content; a new POST is not a newly unique artifact.
4. Captures08–11 submit other-run, omitted, blank and duplicate run_id from the
   actual A composer. Each leaves the original row, read failure, receipt and
   draft visible. The separately recorded request windows show no query from
   those rejected commands. Automatic correct-run refreshes are distinguishable.
5. Capture13 restores a real successful matching refresh. Capture16 permits the
   same run with an unmatched lane filter: the successful empty result clears
   current rows and the old read failure while retaining the receipt. Capture17
   restores the original row with a full matching refresh.
6. Capture18 finds an additional defect: Overview slice {} dispatches `/slice?`
   and receives HTTP400 `unknown slice parameter:`. Actual manual reads recorded
   in actual-api-reads.json distinguish `/slice` HTTP200 from `/slice?` HTTP400.
   Captures19–20 show a nonempty other-run query is still dispatched from Overview.
   Source admission alone did not prove global HTTP success. Follow-up source
   repair removes the empty query marker; this artifact does not execute it.

The two mistaken manual palette attempts 12/15 are retained with their exact
commands and are explicitly not scope-admission proof. The compiled A composer
path was actually exercised. No screen-text/layout/PTY assertions were added.

## Reading the evidence and limits

The .txt and compressed cell JSON files come from the actual 160×56 PTY buffer.
The compressed raw terminal stream and command log are preserved. Diagnostic PNGs
render selected captured cells; they are not physical desktop screenshots.
Request traces include later explicit API comparisons; absence claims are bounded
to observation.json's original command windows, not the whole trace.

shutdown-observed.json separately confirms all three owned processes and both
ports absent, and both exact historical containers absent. The final inventory
was read before shutdown. Private login files, credentials and server logs are
excluded and exact private token bytes were checked internally before publication.
This is a bounded G06 observation, not full 54 completion, same-source Dashboard,
actual LLM/Browser/audio use, operator installation or release verification.
