# Declared runtime configuration projection

PR #42122. Base: c7f12d726d89729a02ac2d38c68fb467db214263.

The dashboard runtime-info surface mixed declared configuration JSON with live admission snapshots, effective capability lookup, runtime inventory acquisition and cached network/git probes. Private server_dashboard_runtime_declaration_projection owns canonical wire labels and pure request/provider/model/binding declaration projection (299 lines). The root retains all acquisition, admission snapshot and effective capability lookup responsibilities (2406 lines, previously 2703).

Extracted declarations are exact parent blocks except final newline normalization. The public root MLI is unchanged. No public wrapper or copied policy was introduced; root consumers use the private owner directly. Declared capability absence, verification markers and secret omission retain their existing semantics. This is not proof that declared capabilities have been measured on a real provider.

The first focused build failed because the private module was registered in lib/dune although lib/server owns a separate library. Registration was moved to lib/server/dune. The subsequent `opam exec -- dune build test/test_runtime_per_keeper_routing.exe` completed exit 0. Selected command `_build/default/test/test_runtime_per_keeper_routing.exe test 'per-model thinking gate' 4-8 --color=never` completed exit 0: five PASS, KWEABQ46. They cover parameter policy, effective capabilities, request settings including secret omission, declared spec and declared model capability JSON through the existing runtime inventory consumer. Other groups were skipped. Fixtures use temporary TOML/catalog files and restore process-local runtime snapshots. No provider request, live Keeper or browser screen was exercised.

The actual test output is retained. Full CI, installation, visible dashboard, formal GitHub approval and merge remain unverified. Network/git probes, cache concurrency, runtime resolution and other policies remain pending audit; the original Godfile candidate and full campaign remain open.
