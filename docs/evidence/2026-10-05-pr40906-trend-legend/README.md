# Trend range-arrow legend — #40906

The Trend view rendered below-zero and above-limit history arrows without explaining them locally. Add a separate short legend line so both meanings remain visible in compact width; the Plan view and measurements are unchanged.

The actual existing Usage PTY journey, with wide/compact legend assertions, failed on the published binary at `f72e5902dacd359a008b3cf0d5272e5911193815`. After the focused `opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build bin/masc_tui.exe`, both full Usage journeys passed with color and NO_COLOR. They also retain their Plan, Trend, scrolling, account-card and navigation checks. Ruff and Pyright passed.

Run from the worktree with `test` on Python's import path: `test_tui_usage_studio_pty.journey('_build/default/bin/masc_tui.exe')`, then the same call with `True` as the second argument. This is synthetic HTTP fixture PTY evidence for this bottom PR only; no live provider, whole Native Stack execution, full CI or release is claimed. Exact raw logs, source and binary hashes are recorded in checks.json.
