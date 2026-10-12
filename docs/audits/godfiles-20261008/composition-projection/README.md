# Composition result projection boundary

PR #42113. Base: 442ae53049e040710a845424f14251907c5b2749.

The composition surface mixed execution, observation, audit and settlement effects with JSON result and typed failure projections. Private keeper_tool_composition_projection now owns the pure projections (349 lines). The root retains execution, receipt creation, timed result constructors, observation, activation and async settlement (1921 lines, previously 2266). The public surface MLI is unchanged.

The extracted functions retain their existing behavior. A comment was corrected because a cause containing full node input/output can itself exceed the log window. Another comment now cites execute_keeper_with_authority by function name rather than a stale line range. Neither correction changes failure policy or truncation behavior.

Focused build: opam exec -- dune build test/test_keeper_tool_composition_catalog.exe test/test_browser_observation_composition.exe completed exit 0.

Catalog execution: 20 PASS, run HNPDICP5, exit 0. Observer composition execution: 4 PASS, run ZR61855N, exit 0. The retained outputs record all 24 distinct cases. Observer fixtures use an in-process fake automation executor and isolated temporary files; no browser, provider or live Keeper was contacted.

These results prove focused compilation and those selected executions. Full CI, installation, deployment, live runtime, GitHub approval and merge remain unverified. Runtime effects and the remaining composition policies still require semantic audit. Falling below 2000 lines does not complete the original candidate or the full campaign.
