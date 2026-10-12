# Claude child environment policy boundary

PR #42126.

Private runtime_claude_environment_projection owns allowed variable names for inherited/selected accounts and mandatory CLI environment assembly (64 lines). The runtime retains actual environment reads, inherited config-path normalization, account/config-file acquisition, authentication probes and process execution (2236 lines, previously 2292). Public MLI is unchanged.

explicit_account captures the only fact needed to choose inherited variable names. The original selected account path remains necessary when assembling CLAUDE_CONFIG_DIR. Policy lists, ordering, entrypoint, SDK identity, auto-memory disabling and tool-search settings are retained. HOME/XDG remain available for OS facilities; this change does not claim complete settings isolation beyond the selected CLI credential store.

Focused build `opam exec -- dune build test/test_runtime_claude_code.exe` completed exit 0. Selected commands used temporary HOME/CLAUDE_CONFIG_DIR and `_build/default/test/test_runtime_claude_code.exe test admission <range> --color=never`. Cases2–4: three PASS, DPFJ6IBS, exit 0. Case8: one PASS, BOYWJ56J, exit 0. Four distinct cases cover subscription/env scrub, selected account home, relative inherited home and routed credentials/tool-search configuration. Other groups were skipped. Local fake CLI shell fixtures exercise the real child environment boundary; no actual Claude login/provider/live Keeper was contacted.

The actual outputs are retained. Full CI, installation, deployment, formal GitHub approval and merge remain unverified. Protocol/event parsing, subprocess lifecycle, configuration and other runtime responsibilities remain pending audit. The original candidate and full campaign remain open.
