# Remove obsolete tests from the full suite

Baseline: `1c5635d5586f2eb7a689dff8131df5e167cc4eeb`.

The full behavior workflow runs the root `@runtest` alias through
`scripts/ci-run-test-suite.sh`. This change removes obsolete executable tests
from `test/dune`; it does not narrow the root alias or change the known-failure
ledger, test assertions for current product behavior, or release requirements.

The repository test filename inventory includes OCaml, Python, shell, Node and
dashboard tests. Semantic deletion review focused on historical migration guards
and constants-only tests; this is not a claim that every remaining test has been
individually audited.

## Deleted suites and reason

| Suites | Reason |
| --- | --- |
| `test_dispatch_telemetry_gap`, `test_mcp_telemetry`, `test_tag_dispatch_typed` | Compare locally defined counters and label lists with literal expectations; never observe production dispatch or telemetry. |
| `test_pr_b_shell_paths_migration`, `test_pr_c_coreutils_migration` | Pin historical source literals and exact Host_config call counts. Bash/zsh/coreutils defaults remain covered by `test_host_config_resolution`. The zsh source scope was empty. |
| `test_pr_d_agent_runtime_migration` | Ratchets retired scratch-file strings and source call counts. Its real temporary-root assertion is moved to `test_host_config_resolution`. |
| `test_pr_f_test_mode_migration` | Pins a helper signature and migration AST shape. Typed Test/Production behavior remains covered by `test_host_config_resolution`. |
| `test_rfc_0085_pr3_server_runtime_paths` | Checks old strings and Host_config call presence without executing server takeover/bootstrap. Keep `test_server_startup_takeover` and bootstrap behavior suites. |
| `test_rfc_0085_pr4_tool_library_proof_store` | Checks absence of environment/host calls and literals. Actual conflicting-environment workspace isolation remains in `test_tool_library` and its coverage suite. |
| `test_rfc_0085_pr8_config_dir_resolver_host_config`, `test_rfc_0085_pr9_base_path_opt_purge`, `test_rfc_0085_pr10_home_assets_purge`, `test_rfc_0085_pr11_deprecation_purge` | Repeatedly walk and parse lib/bin to count calls to removed APIs or pin migration call counts; one case only touches record fields. Keep config-dir resolution and Host_config environment behavior suites. |
| `test_rfc_0085_pr13_underscore_rename`, `test_rfc_0085_pr16_dashboard_http_core_rename`, `test_rfc_0085_pr17_dead_purge_and_rename`, `test_rfc_0085_pr18_execution_surfaces_rename` | Pin local binding names and historical dead-code deletion. No product behavior is exercised. |
| `test_rfc_0085_pr14_dispatch_inline` | Pins private dispatch bindings and call presence. Keep actual guarded-dispatch, observer, MCP and Keeper dispatch behavior suites. |
| `test_provider_prefix_boundary` | Scans for helpers on the removed Provider_adapter module; does not exercise provider routing. |
| `test_runtime_provider_projection_boundary` | Asserts three source-file locations only. |

Remove the `hardcode-site-inventory-pin` case in the retained Host_config suite:
it compares local historical constants with the same numbers. Keep its runtime
assertions and add the temporary-root assertion recovered above.

## Verification and limits

- Expanded executable test registrations in `test/dune`: 1,609 → 1,589.
  Exactly the 20 deleted suites disappear; no other executable registrations change.
- Deleted suites contain 67 case registrations; the retained Host_config suite
  loses one additional constants-only case. Real Host_config behavior assertions
  in the deleted migration suites are preserved or already covered.
- All remaining literal Dune includes resolve and parenthesis balance is checked.
- `python3 scripts/ci/test_dune_suite_scope.py`: PASS.
- `python3 scripts/ci/stanza_env.py --self-test`: PASS.
- `bash -n scripts/ci/run-edited-tests.sh`: PASS.
- `git diff --check`: PASS.
- Independent source review found no P0–P2 issue in the implementation diff.

No local Dune compilation or full runtime suite was run. Removing 20 executables
and repeated whole-tree AST scans reduces scheduled work, but CI duration savings
are unmeasured. No test deadline or known-failure exemption was changed.
