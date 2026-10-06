# #40950 reported-total qualification

The partial coverage label now says **reported totals are lower bounds**. Unreported token/cost values remain unreported; no value, denominator, scale or bar policy changed. Both existing affected fixtures require the precise qualifier.

The updated actual Keeper-comparison assertion failed on the retained Native40952 combined binary (handle 17489, exit 1): the old unqualified text did not satisfy the reported-total statement. This baseline is a combined candidate binary, not an exact #40950 member build; its affected Usage renderer matches the member. A fresh focused TUI build on isolated #40950 plus this one-line repair passed (handle 28388).

The matching repaired binary passed three actual Keeper comparison PTYs (handle 36291): reported values plus gamma-missing with both metrics absent, the same flow without color, and all costs unreported. Existing missing-bar, zero-value, coverage, compact scrolling and end-row assertions remain intact. Ruff and Pyright passed for both affected Python fixtures. Raw logs/captures are retained unchanged and checks.json records source and executed binary hashes.

Commands: `DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe`; from repository root with `PYTHONPATH=test`, import `test_tui_usage_studio_pty` and execute `keeper_comparison(binary)`, `keeper_comparison(binary, no_color=True)` and `keeper_comparison(binary, unreported_cost=True)`. No full suite, browser, hosted CI, release or production proof is claimed.

Native Stack40952 order and branch bases are preserved. Subsequent parent propagation carries this same Usage wording and fixture expectation without reclassifying these member-specific local executions as independently rerun descendants.
