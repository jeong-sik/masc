# Plan usage report boundaries

Three current-head review findings were reproduced by the actual provider/Plan tests: positive infinity became a full meter and counted as at-limit, out-of-range finite historical reports lost their markers in Plan, and Plan omitted meanings for empty-window and uncapped-USD history symbols. Before the fix, three of 20 cases failed. The same final tests pass after the repair.

Nonfinite meter shares now use neutral unfilled cells and do not count as reported at-limit. Finite historical values below zero or above full use the same arrows as Trend. The Plan legend explains empty reports, uncapped USD and both range arrows. Reported amounts, finite full/overfull meters and missing/zero distinctions remain unchanged.

The focused OCaml5.5.1/DUNE_JOBS=2 wrapper built the provider test and actual TUI. All 20 native tests passed with NO_COLOR removed for the color-dependent suite. The actual existing Usage studio journey passed in color and NO_COLOR, covering wide, compact and short scrolling Plan, Trend and restoration. Those two journeys use synthetic HTTP; no live provider, full suite, hosted CI or release result is claimed. Root and independent response source review found no P0–P2 issue in this bounded change.

Raw logs, exact tested source and executable hashes are pinned in checks.json. Regression commands: scripts/dune-local.sh build test/test_tui_overview_providers.exe bin/masc_tui.exe under opam5.5.1; then the actual test executable and test_tui_usage_studio_pty.journey(binary) / journey(binary, True). No fixture expectations were weakened.
