# Installed Add-on role and original-target PTY capture

These are actual keyboard interactions with the existing installed `masc-tui` executable, running against a private synthetic HTTP fixture in separate temporary workspaces. The PNG files render verbatim tmux screen captures; they are not source projections or desktop/browser screenshots. The raw PTY stream, plain frames, synthetic input snapshots, fixture source and captured HTTP requests are retained beside them.

The installed binary is version `0.63.0`, embedded commit `107c58401723313611f7c599bbe15225de5910da`, SHA-256 `2dceec3ebb2af38a11287ba33f2e288e9f6e27aa741fb30c0fdfa09b5522a713`. The emulator was tmux at 140 columns by 46 rows. `provenance.json` records the exact paths, source comparison and executed keys. `landed-main-source-equality.json` additionally compares the role/selection implementation and category domain with landed main `c2dfa238ebd318a9152e70d874ac2cbf68ae2ad8`.

## Captures

- [Role grouping and exact-declaration classification](01-summary.png).
- [Original Browser target after Summary to Flow](03-flow-browser-selected.png).
- [Actual action menu opened from Flow](04-action-menu-from-flow.png).
- [Fixture receipt and original target after action](05-action-receipt-summary.png).
- [Summary after another Flow round trip](07-summary-roundtrip.png).
- [Replacement leaves no selected action target](replacement/03-action-refused-without-reselection.png).
- [Replacement action after explicit reselection](replacement/05-explicit-replacement-receipt.png).

The follow-up [observations](OBSERVATIONS.md) explains the scenario, target identity, current host incarnation contract and practical limits. [Artifact hashes](artifact-sha256.json) bind the captured inputs and outputs. They are a provenance inventory, not a screenshot/layout test.

The fixture's `/health` identity is synthetic and does not certify an actual MASC server. A rendered `confirmed` receipt is produced by the fixture, whose executor is unknown; it does not prove real worker execution, model activity, production installation or deployment. No production API mutation, local Dune build or new binary installation/deployment was performed. Both private listeners and own tmux sessions were shut down; the two `cleanup.json` files record closed ports and sessions.

To repeat, copy a fixture directory into a fresh temporary directory, create `workspace/.masc/config`, and run its `fixture.py`. Use the emitted private port with the installed TUI's `--port`, `--base-path <temporary-directory>/workspace` and `--workspace` flags in a private tmux PTY. The first fixture serves its original snapshot; the replacement fixture rereads its owned `fixture-snapshot.json` on each inventory read. Use the recorded key sequence and retain actual requests and terminal frames. Do not execute this fixture in a production workspace.
