# G01 exact-source native artifact and focused consumer execution

Product source: `7b16a9175711aefe744c5c704e038a42fd5b6b7b` (the unchanged
source/evidence parent of this documentation layer). Workflow source:
`97468f95df78f35a35bb3fe14a9670240cced930`.

[Native run 39595834943](https://github.com/jeong-sik/masc/actions/runs/39595834943)
completed successfully with scenario `addon-lifecycle`.
[Artifact 12343798542](https://github.com/jeong-sik/masc/actions/runs/39595834943/artifacts/12343798542)
contains the matching server/TUI, key reference, dependency lists and test logs.
The retained receipt names all five targets and both executed suites. Actual
logs report `test_tui_lane_addons` 20 cases and `test_lane_addon_application`
5 cases; each suite and log exit is0. The TUI suite is mixed: its existing
presentation assertions are not classified as request/state-only checks.

Downloaded binaries and key-reference file were hashed against receipt.json.
Both binaries were executed with their build-identity commands; each returned
the exact product SHA above. download-verification.json retains those observed
results. The artifact is available from the run; executable binaries are not
copied into Git.

[Focused run 39594048964](https://github.com/jeong-sik/masc/actions/runs/39594048964)
checked out the same product and used `minimal=true`, `EIO_BACKEND=posix`,
with exactly `test_lane_addon_reconcile` (52), `test_server_lane_inventory` (13),
`test_tui_lane_inventory` (13): 78 passing cases. direct-consumer.log is a bounded
excerpt of the original completed log, preserving source, target selection,
environment and all three suite conclusions. This is not a full regression run.

The earlier product5840bab native/direct-consumer failures remain in the prior
compiler follow-up and public correction; their clean source verdict was
withdrawn. These new results establish the repaired source, not a retroactive
success of that candidate.

A01 is satisfied for this frozen G01 candidate. No operator server replacement,
installed-runtime change, visible TUI On/Off/reconnect, browser interaction or
real provider was performed. A02, G04/G03 later changes, actual Candle lifecycle,
complete same-candidate integration and the other 54-item requirements are not
certified by these results. This evidence-only child changes no product/test
blob and does not rename the executed product SHA.
