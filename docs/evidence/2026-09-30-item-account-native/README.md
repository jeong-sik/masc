# Item account native and terminal evidence

Source: `1b3723f8f99ffd83f8c402929b6a17f8773f1857`.
Targeted Test run: https://github.com/jeong-sik/masc/actions/runs/36649111830

The retained suite runner log reports all six requested suites OK:

- `test_dashboard_http_core`: 136 cases, including a free purchase, price-only edit and changed disabled reason changing the account revision without inventing a balance or outfit.
- `test_candle_purchase_flow`: 8 cases.
- `test_keeper_portrait_http`: 15 cases through the real authenticated HTTP router.
- `test_candle_ledger`: 10 cases, including a held cross-process lock and a lock taken between read and append.
- `test_tui_keeper_portrait_pty`: five real PTY scenarios, including Item browsing and ready → HTTP 503 → recovered account refresh.
- `test_tui_candle_currency_pty`: four real PTY scenarios with synthetic currency responses.

The Item PTY account and roster HTTP responses are synthetic. The TUI executable is real and its SHA-256 is in `tui-manifest.json`. The four text files contain the completed captured screen, and `terminal-streams.tar.gz` preserves the actual terminal bytes. The failed account refresh withdraws the previous balance while retaining the portrait preview; recovery shows 13.000 Candle.

These are suite-level results, not a claim that every workflow step or required PR check has finished. They do not prove a deployed server, operator configuration, a real Keeper payout, or an integrated browser connected to that server. Later source-selection metadata and operator documentation do not change the production source or executable scenarios.
