# Item account during a partial-roster transition

A Keeper already displayed in a complete roster can disappear from the next capped response without losing authority over its private Item account. The old refresh path treated the missing public revision as an authority change: it replaced a pending read and blanked the account. This repair retains the account and pending request for the same Keeper and workspace during a partial observation; existing absence, invalidity, workspace and failed-read withdrawal remain.

## Evidence and limits

The production function and the added two-mode PTY scenario are byte-identical to local repair `251c9c561387b2bbeb1a6ab37189160f8ebe6ddb`, independently reviewed by masc-pro-builder. That repair was built as `be37f5af998adb7b9825bbf2549910eb12f3cfcd` plus the exact two-file patch, in an isolated OCaml 5.5.1 switch with all candidate dependency pins checked.

- Focused TUI build: exit 0, 151.135 seconds.
- Partial roster from startup, Present-to-partial transition, private account changes, and complete-roster authority withdrawal: four separate fixture PTY runs, all exit 0.
- Captures show 12.500 Candle and owned prices retained while the reply is held, 13.000 after the original response, and monetary/ownership facts withdrawn after a roster failure.
- Recorded executable SHA-256: `2f503fb1f82001bbbc3dcbc9087d37e771094563c0c3b37b9c80dd2400969b8e`.

[Original verifier packet](verification.tar.gz) is 374826 bytes, SHA-256 `457b8c927b85f263f7c6a23f605a738721fa0994aed309d18c0439438ff9f760`. It includes REPORT.md, command/exit/time receipts, source and executable identities, raw PTY/text/request records and a file manifest. All 62 listed files were reopened and checked; the manifest itself is the 63rd archive file. The executable is not included.

This PR transplants only the production function and regression scenario onto canonical `e4afdce8f0c4ba4cf02e4326ba423c4fe2207339`. Every other pre-existing byte in the two changed source files is preserved, apart from registering the two scenarios and updating their reported count. OCaml parsing, Python AST and diff checks passed for the transplant. The prior execution is scoped evidence for the same functions on the earlier candidate context; this e4-based PR has not been rebuilt or run. It requires its own current-diff review and final integrated-head Full RC. No production installation or release success is claimed.

[근거] verifier packet and source transplant comparison, checked 2026-10-03 19:25–19:46 UTC; High for the recorded fixture execution and unchanged functions, new candidate execution unrun.

— e-masc-the-leader
