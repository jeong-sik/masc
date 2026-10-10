# Keeper state-diagram evidence boundary

PR #42124. Base: d576c545ee70441f3f79b36abb8bd02c087ef095.

The keeper API state-diagram function combined runtime lookup with redacted display calculation. Private server_dashboard_keeper_state_projection owns canonical display data, closed missing/present evidence, pure redaction/JSON/Mermaid projection (74 lines). Root retains metadata inspection, runtime-model lookup, unavailable diagnostics and cancellation propagation (2189 lines, previously 2230).

The public root MLI is unchanged. A manifest type re-export preserves the existing record identity; existing JSON/Mermaid API values bind directly to their owner. The pure calculation takes acquired evidence rather than performing runtime lookup. A valid last attempt always makes runtime_model_evidence true and the displayed model list nonempty, so the original last-attempt/empty-model branch was unreachable and is removed. Provider names and metadata records do not enter the pure owner.

Final-source focused build `opam exec -- dune build test/test_dashboard_http_core.exe` completed exit 0. Selected command `_build/default/test/test_dashboard_http_core.exe test 'dashboard behavior contracts' 22 --color=never`: one PASS, GFKA84CP, exit 0. Selected `test executor_pool 68 --color=never`: one PASS, 2XCNLOJ7, exit 0. Other groups were skipped. The two existing cases cover missing metadata, synthetic last-attempt evidence, provenance strings, redacted JSON and redacted Mermaid without exposing the synthetic provider name. No live Keeper, provider request or browser screen was exercised.

Six source hashes, one executable hash and actual outputs are retained. Full CI, installation, visible dashboard, formal GitHub approval and merge remain unverified. Cache/storage/read handlers, chat enrichment and other API responsibilities still require semantic audit; the original candidate and full campaign remain open.
