# Codex child environment projection

PR #42121.

The app-server runtime combined environment/config/path acquisition with child credential filtering. Private runtime_codex_environment_projection now owns environment-key parsing, allowed keys, explicit-account override filtering and the final CODEX_HOME projection (51 lines). The root retains current environment/cwd reads, TOML acquisition, account-home resolution, spawn and protocol execution (2730 lines, previously 2778). Public runtime MLI is unchanged.

The pure owner takes the actual resolved home, declared credential names and environment snapshot. explicit_account captures the only fact about the original account_home option that filtering used: whether selection was explicit. The original selected path stays at the resolution/acquisition boundary; its unused contents are not copied into the pure filter. The boolean reformulation preserves the previous match semantics. No credential key policy or error behavior was changed.

Focused build `opam exec -- dune build test/test_runtime_codex_app_server.exe` completed exit 0. Selected execution used temporary HOME and CODEX_HOME directories and `_build/default/test/test_runtime_codex_app_server.exe test 'subscription boundary' 17-21 --color=never`: five PASS, XG1QBQ3I, exit 0. Fixtures run local fake CLI shell processes and temporary TOML files; they verify isolation overrides, selected account configuration, declared provider keys, allowlisted environment and relative/absolute declared credential paths. Other groups were skipped. No actual Codex CLI, provider, account login or live Keeper was contacted.

Six source hashes, one executable hash and actual output are retained. Full CI, installation, deployment, formal approval and merge remain unverified. Protocol decoding, turn orchestration, subprocess cleanup and remaining configuration semantics still require audit. The original candidate and 171-file campaign remain open.
