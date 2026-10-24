Run [40095356149](https://github.com/jeong-sik/masc/actions/runs/40095356149), workflow run_attempt1, actually checked out `44b6daee827adb9ef700c29f8d221220c2024df9` (checkout-step.log147–148) and passed all five selected suites: **105 OK, 0 FAIL, 0 SKIP, 0 TODO**. Raw jobs head and artifact head independently agree. Parent supplied terminal SUCCESS; this audit did not re-query run status.

| Suite | OK | FAIL | SKIP | TODO | Raw summary |
| --- | ---: | ---: | ---: | ---: | --- |
| goal_verifier_worker | 16 | 0 | 0 | 0 | Test Successful in 1.252s. 16 tests run. |
| goal_verification_agent | 39 | 0 | 0 | 0 | Test Successful in 72.562s. 39 tests run. |
| verifier_review_worker | 18 | 0 | 0 | 0 | Test Successful in 0.869s. 18 tests run. |
| completion_trust_harness | 9 | 0 | 0 | 0 | Test Successful in 0.707s. 9 tests run. |
| verification_run_registry | 23 | 0 | 0 | 0 | Test Successful in 0.080s. 23 tests run. |

`ci-run-tests.log:2` records the actual Dune build of all five .exe targets and original fixture dependencies. All five suite starts, summaries and targeted OK terminals follow. The exact OCaml5.5.1 opam dependency cache was reused; this does not skip the targeted build or tests. MINIMAL_CHECK skipped nonselected infrastructure preparation, which is separate from zero skipped cases. This is focused execution, not full regression, operator four-product build or installed-runtime proof.

Task execution17 is one passing case (`ci-run-tests.log:1247`). Its compiled source loops over Judged, Committing and Commit_unknown, running one missing-observer negative and one actually observed positive in each phase. The raw excerpt1154–1247 contains all six complete assertion blocks, including actual host observe0/apply0 in each direct negative commit, observe2/apply1 in each positive, preserved raw Task/Owner/optional registry for each negative, and total fixture reviewer calls1 before/after recovery (added calls0). Each negative also calls the production process entry and checks the exact missing-observations refusal. Those production-entry calls have state/error assertions; their callbacks are not separately instrumented. Positive Task Done, Owner ACK and disk-replayed Completed Approved checks are source pattern guards, and do not print standalone success labels. They are bound to the exact test source and enclosing case PASS. See `critical-assertions.json` for every raw line, numeric-source binding and limits. Fixture reviewer and private temp workspaces are distinct from external provider or production runtime proof.

Artifact12560518815 `suite-runner-log.zip` is23905bytes with verified advertised SHA256 `8937746dd34dae50a5d4fc4bf218ec9bc970c63821eb022bc31d3bada348dcd3`. Its sole member exactly equals the saved runner log (172665bytes, SHA256 `656f84ac3f1346832135c63fc7d809a40a229e8dcfcb8811b901b41a2abdc9c7`). The raw workflow archive SHA256 is `5062c8d2fce014a21bf683846a0482ae60cb78dbb8e3d8fdb268585164d9b381`; raw job log SHA256 is `2fe05dc8b4568cc6d0a051f4179470f25f8e18d6ada6907840c7806c2d1c26a7`. These identify evidence archives/logs, not built binaries.

Canonical machine-readable receipt: `receipt.json`. The earlier6c9 run40078689529 compile failure/zero-suite execution and cd155 historical55PASS remain separate; neither is carried into105. No code, CI, remote state, installed runtime or branch was changed by this audit.
