# Candle economic observation: browser fixture evidence

PASS on clean source `ec4a71f4e77fcd135b4b275f00b3dea63645e525`.

This runs the actual production `Overview` and complete `KeeperDetailPage` in
Chromium through the repository's Vite dev configuration. The script opens
the detail page's real command menu and its real operating detail view.
Production components, CSS, execution fetch, normalization and store decoding
are unchanged. The fixture toolbar switches surfaces only.

**Amounts are synthetic HTTP JSON. They are not native ledger output, a live
deployment, a real payment, or server-side authorization evidence.** Auxiliary
providers, metrics, schedules and diagnostic APIs deliberately answer 503 with
an explicit fixture-scope reason. Those unavailable panels and console entries
are retained in the evidence. No product mutation is requested.

## Measured transitions

1. Ready: Overview displays issued `18014398509481.987`, burned
   `9007199254740.994`, circulating `9007199254740.993` Candle. Every raw
   milli-Candle amount exceeds JavaScript's maximum safe integer. The single
   Keeper wallet is exactly `9007199254740.993` Candle.
2. Disabled: the next real execution HTTP response clears displayed amounts
   and shows `Controlled fixture: ledger unreadable`. The same Keeper, running
   phase and enabled lifecycle button remain.
3. Malformed: a numeric wallet instead of a canonical decimal string is
   rejected. Both production surfaces show an unavailable observation and no
   former amount. The Keeper and enabled lifecycle control remain.
4. Off: both currency displays disappear. Keeper identity and control remain.

The script asserts DOM values and enabled lifecycle buttons, records all HTTP
requests/responses with hashes, and captures eight browser screenshots. It
does not click a lifecycle mutation. The complete detail body is loaded before
capturing its ready state. Chromium reported no uncaught page errors; no
external requests escaped the loopback fixture.

## Files

- `evidence.json`: scope, source hashes, browser version, requests and response
  bodies, observed decoder results, assertions and image hashes.
- `scenario.mjs`: exact retained harness, with its hash in `evidence.json`.
- `run.log`: runner output.
- `01-ready-overview.png`, `02-ready-keeper.png`.
- `03-disabled-keeper.png`, `04-disabled-overview.png`.
- `05-malformed-overview.png`, `06-malformed-keeper.png`.
- `07-off-keeper.png`, `08-off-overview.png`.
- `SHA256SUMS`: artifact integrity listing.

Reproduce with existing dashboard Node dependencies and Playwright Chromium:

```sh
node scenario.mjs /path/to/masc /path/to/new-output-directory
```

Native ledger-to-wire CI, native HTTP PNG replay and literal remote-TUI PNG
evidence remain separate work. No local Dune/native build was used here.
