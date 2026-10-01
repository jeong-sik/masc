# Item HTTP acceptance

Run the **Manual probe artifacts** workflow on the desired Item branch with
`target=linux-x64` and `capture_item_http=true`. It builds the release binaries
and production dashboard from that checkout, then starts its own loopback
server in a fresh temporary workspace. No installed MASC process is contacted.

The `item-http-<sha>` artifact contains HTTP and browser receipts, desktop/mobile
screenshots, the Item account JSON,
a portrait PNG and the isolated server log. The receipt records source SHA,
binary hash, dashboard index hash, fixture hashes and HTTP response hashes.
The harness requires the native `build-commit` and dashboard build identity to
match the workflow SHA. It verifies readiness, refusal of anonymous account
reads, an authenticated empty wallet and catalog, PNG delivery, and delivery
of the exact production dashboard index. It then authenticates as the synthetic
Keeper over MCP, buys a free face item, rejects repeat/insufficient purchases
and unowned equipment, equips the item, and verifies ledger-backed account
ownership and changed PNG bytes. Restoring the default must restore the
original PNG; the other slots must stay unchanged. Before restoration, Chromium
opens the production bundle served by that same native process, follows the
Keeper route and Item tab, and checks zero balance, one owned item and its
equipped marker through real authenticated API requests. External browser
requests are blocked; API responses are never replaced by fixtures.

Inputs are a synthetic paused Keeper in the current metadata schema, an empty
ledger, and explicit test prices/payout policy. This proves real HTTP routing
with those inputs. It does not prove Keeper lifecycle creation, model-driven
purchase/equipment decisions, a paid purchase or real payout, or production
rollout.
Additional browser fixture and TUI transition evidence comes from the separate dashboard and
Test workflows.

The script accepts only a new output directory. Provider credentials and
operator runtime settings are excluded from the child environment. Login
credentials remain in the temporary workspace auth directory until cleanup;
that directory is removed on exit and never included in the artifact paths.

For a previously built CI binary and dashboard:

```sh
python3 scripts/item-http-acceptance.py \
  --binary /path/to/main_eio.exe --dashboard /path/to/assets/dashboard \
  --source-sha FULL_SOURCE_SHA --output /new/temp/evidence --capture-browser
```

A failed run is not a passing receipt. Inspect the workflow step and server
log before interpreting the artifact.

The transaction stage also rejects an owned face item in the head slot and checks that duplicate, insufficient and wrong-slot refusals leave the ledger unchanged. Both the original and equipped PNG must have valid dimensions, chunks and decoded image data.
