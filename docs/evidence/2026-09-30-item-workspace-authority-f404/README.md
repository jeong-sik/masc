# Item workspace authority: native verification

[Run36654016413](https://github.com/jeong-sik/masc/actions/runs/36654016413), implementation head `f4041a99a7d86886336e4838588dc2f4e47f3b74`: **9/9 selected suites passed**, Test step success. This is a reproducible composition of Item account and remote-authority source, not a main-based release or deployed server.

| Observation | Balance | Owned accessory | Price | Evidence |
|---|---:|---|---:|---|
| A current |12.500|glasses|1.000|a-ready.txt|
| B with A read held |withdrawn|withdrawn|withdrawn|b-with-a-read-held.txt|
| B current |7.500|crown|2.000|b-ready.txt|
| B current read failed |unavailable|withdrawn|withdrawn|b-unread.txt|
| B Off |Off|withdrawn|withdrawn|b-off.txt|
| B recovered |7.500|crown|2.000|b-recovered.txt|
| A current after return |3.250|quill|1.750|a-current-after-return.txt|

The synthetic account values make wrong authority visible. A held response carries99.999; that value is absent from every PTY byte after B authority. The fixture release event alone is not a client-completion receipt. Frames and the subsequent real navigation/reads establish the UI behavior. Source admission independently rejects the invalidated request token. No Keeper POST was sent. The test inspects actual prices and owned markers; A-returned quill comes from the accepted account, while its currently selected glasses row correctly lacks owned.

## Other selected proofs

- Existing local portrait/Item PTY:5scenarios.
- Existing remote equipped portrait: actual native HTTP receipts and decoded real TUI pixels.
- Held chat history: old-response withdrawal and unsent draft restoration.
- Actual authenticated Item HTTP/purchase fixtures: portrait HTTP15cases and purchase8cases.
- HTTP AST44cases, keys126cases, and current tab strip PTY.

Complete raw log is compressed without modification. item-pty-artifacts.tar.gz retains all Item scenario files, including full PTY bytes and request events. manifest.json identifies the TUI binary and scenario by SHA256. audit.json records all nine original outcomes. SHA256SUMS covers every file.

No failing native baseline reproduction was measured; the original defect was found by tracing and independently reviewing the production cache, request admission and rendering. These passes do not establish actual-model grading quality, live Keeper continuity, rollout, a fresh57-suite result, or current documentation-head merge checks. Draft PR checks were skipped.
