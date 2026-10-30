# Lane inventory parent integration

Parent: `10e6a16cd13c394cfd5474115f73d16087e69a22`.
Original child: `5f46c9582f0e0f545d4e1e9148edd26e17032cac` (#41130).

The only merge conflict was adjacent additions in `test/dune`: both the inventory
test stanza and the parent runtime-status PTY include are retained. The backend
route merged cleanly, preserving mandatory runtime-config source-revision CAS.
Original inventory implementation and regression-test source bytes are unchanged.
The fragment now has its required section and PR citation.

Local OCaml 5.5.1 focused build passed for `test/test_server_lane_inventory.exe`,
`test/test_browser_lane.exe`, and `test/test_lane_addon_reconcile.exe` through
`scripts/dune-local.sh`. Executing those targets with the declared test environment
passed 4/4 (0.011s), 8/8 (0.034s), and 15/15 (0.155s) respectively: 27 native tests.
Coverage includes operator HTTP authorization, file-byte preservation, retained
metadata with a corrupt sibling, and inventory reads without Browser-request or
worker side effects. These are controlled native fixtures, not live browser,
worker/container, production deployment, full-suite or CI evidence.

`parser.json` and `source-review.json` retain their historical source-only scope.
The current execution results above supplement those records rather than changing
their original provenance.
