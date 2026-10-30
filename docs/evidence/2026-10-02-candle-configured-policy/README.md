# Configured Candle policy validation

Scope: production payout worker and ledger under isolated fixture workspaces. Provider answers and transport edges are controlled fixtures, not live provider or production runtime proof. Paths in captured logs are normalized to `<worktree>`; assertions and results are otherwise unchanged.

Focused compilation used `opam exec --switch=5.5.1 -- scripts/dune-local.sh build` with the changed Candle libraries and 16 directly affected test executables, including the Dashboard/portrait HTTP consumers and Goal verification consumer. No full suite or automatic CI was started.

Passing suites: 12; passing cases in those suites: 155.

The configured-policy worker scenario covers a single operator-defined `release` grade, its criteria and exact schema enum, rejection of an unconfigured grade, configured amounts, ascending/descending remainder ties, floor/ceil deduction, unissued remainder under down rounding, and immutable receipt replay after changing the current config.

`test_candle_appraiser_transport` remains 18/22 passed, with four HTTP refusal/fallback classification assertion failures. They are recorded in [#40847](https://github.com/jeong-sik/masc/issues/40847); no passing transport-suite claim is made. The unchanged base suite had compilation omissions, so a clean base runtime comparison is not established.

Independent source review found no unresolved P0/P1/P2 in the policy diff. This is not GitHub approval, live runtime proof, or release evidence. Existing Paid rows without the new required distribution fields are unsupported; the repository disallows compatibility migrations for unreleased data. Check any target workspace ledger before deployment.
