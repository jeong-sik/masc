# Item HTTP acceptance

Run the **Manual probe artifacts** workflow on the desired Item branch with
`target=linux-x64` or `target=macos-arm64`, and `capture_item_http=true`. It builds the release binaries
and production dashboard from that checkout, then starts its own loopback
server in a fresh temporary workspace. No installed MASC process is contacted.

The `item-http-<target>-<sha>-attempt-<run_attempt>` artifact contains HTTP and browser receipts, desktop/mobile
screenshots, the Item account JSON,
a portrait PNG and the isolated server log. It also retains the matching TUI’s synthetic-HTTP PTY manifest, captured frames and scenario log. The receipt records source SHA,
binary hash, dashboard index hash, fixture hashes and HTTP response hashes.
The harness requires the native `build-commit` and dashboard build identity to
match the workflow SHA. It verifies readiness, refusal of anonymous account
reads, a Worker-authenticated 100-milli wallet with empty ownership and its catalog, PNG delivery, and delivery
of the exact production dashboard index. It then authenticates as the synthetic
Keeper over MCP, buys a free face item, rejects repeat/insufficient purchases
and unowned equipment, equips the item, and verifies ledger-backed account
ownership and changed PNG bytes. Restoring the default must restore the
original PNG; the other slots must stay unchanged. Before restoration, Chromium
opens the production bundle served by that same native process, follows the
Keeper route, opens 대화 도구 → 상세, selects the Item tab, and checks 0.100 Candle, one owned item and its
equipped marker through real authenticated API requests. At 360px it also
reloads the document, opens the visible keeper command menu and enters Item
from fresh application state. Desktop and fresh mobile entry must each make a real account read;
the menu lower edge, runtime alert width and mobile overflow are checked.
A second fresh mobile reload enters through the composer `/detail` command list
and independently checks its account request, ownership, equipment and portrait.
All four screenshots and entry paths are recorded.
External browser
requests are blocked; API responses are never replaced by fixtures. Finally
the harness stops its server, starts a new process against the same isolated
workspace with the purchased accessory equipped. It verifies identical account
and equipped portrait responses, persisted ownership through a new MCP
session, repeat-purchase rejection, an unchanged repeated equipment selection,
and restoration of the original default PNG after restart. The HTTP
PASS receipt is written only after this restart check.

Inputs are two synthetic paused Keepers in the current metadata schema, two
canonical synthetic Paid rows granting 100 milli to the free-test Keeper and
700 milli to the paid-test Keeper, and explicit test prices/payout policy.
Buying the zero-price face item preserves the free-test Keeper’s 100 milli.
The paid Keeper buys crown for 200 milli and must retain 500 milli. Duplicate
and insufficient purchases must leave the ledger byte-identical. After a
process restart, paid ownership, balance and equipped PNG must remain; only
one 200-milli purchase event may exist. Both original synthetic Paid rows must
remain unchanged. Seed and before/after ledger hashes are retained. This proves real HTTP routing
with those inputs. It does not prove Keeper lifecycle creation, model-driven
purchase/equipment decisions, a real earned payout, or production rollout.
The same explicit Item capture first runs the existing eight portrait/Item TUI scenarios against the compiled TUI, checking its embedded source SHA. These exercise preview, short panes, roster revisions, account failure and workspace authority with synthetic HTTP fixtures; they do not prove a live TUI account or earned payout. Additional browser fixture evidence comes from the separate Dashboard workflow.

The macOS target runs natively on `macos-14`, using the Release workflow's
OCaml dependencies and build flags. Its runtime artifact also records the
server's dynamic-library dependencies. These raw probe binaries rely on the
runner's native libraries; they are not the relocatable Release package.
This target provides isolated Mac execution evidence before a separate
release, installation and live-runtime check.

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

Once Chromium has started, a browser validation failure retains a receipt
with `passed: false`, the last validation stage, API paths/statuses and
screenshot hashes. Launch failures occur before this receipt handling. It attempts to capture the
actual failed page as `item-server-failure.png`; a closed or unresponsive page
may prevent that capture. Storage, tokens, headers, request bodies, DOM dumps
and raw error text are excluded from this receipt. The original error still
fails the process. A failed run is not a passing receipt. Inspect the workflow
step and server log before interpreting the artifact.

The transaction stage also rejects an owned face item in the head slot and checks that duplicate, insufficient and wrong-slot refusals leave the ledger unchanged. Both the original and equipped PNG must have valid dimensions, chunks and decoded image data.

Browser validation failures retain a separate failed receipt with the current stage, request paths/statuses and available screenshot hashes. Credentials, storage, headers, request bodies, DOM dumps and raw error text are excluded. A successful receipt is written only after browser cleanup succeeds.

Authenticated probe HTTP requests reject redirects before following another URL. The route receipt cannot substitute a redirected endpoint for the isolated server.
The standalone `python3 -I test/test_item_http_redirects.py scripts/item-http-acceptance.py --mcp` regression exercises real loopback GET and MCP redirects without a native binary. Its scope is the actual extracted helper and redirect refusal, rather than a complete native acceptance run.

The harness and all source fixtures, including the paid credit and browser script when used, must match the binary source SHA before the isolated server starts. Browser access uses the synthetic admin bearer required by its surrounding dashboard reads; purchases use each synthetic Keeper’s own Worker bearer.
