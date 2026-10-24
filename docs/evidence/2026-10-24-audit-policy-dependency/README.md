# Audit policy dependency repair

Native Stack #45554 previously failed actual focused execution
[40059615886](https://github.com/jeong-sik/masc/actions/runs/40059615886)
at combined head `121f51ef10cb1ea48ce9499582cb9925d11ef9c7`, before its six
suites ran. Gate status readers referenced the root `masc` library's runtime
parameters, while `masc` already depends on `masc.gate`. An added direct
dependency would create a library cycle. One connector regression had the same
upward reference, and `Dashboard_http_helpers` had become an unused open.

The repair keeps one generic registry and one typed trigger-policy authority:

- Move `Runtime_params.ml/.mli` byte for byte into existing `masc_core`, whose
  declared dependencies already own all modules the implementation uses.
- Move the sole enum helper and two trigger parameter declarations/default
  cells from `Runtime_settings` to gate-owned `Connector_trigger_policy`.
  Existing persisted keys, parsers, validators, metadata, configured defaults
  and override behavior are preserved. The old declarations are removed.
- Make ingress, disconnected status, and runtime API regressions read the same
  typed handles directly. No callback registry, mirrored policy or compatibility
  alias is introduced. Existing namespace-qualified generic-store callers use
  `Runtime_params` directly.
- Remove the actual unused Dashboard open.

`test/deps/dune` already re-exports `masc_core` and `masc.gate`; every migrated
isolated test stanza uses that dependency. The checkpoint binary directly links
`masc_core`. [Source checks](source-checks.json) record exact relocation hashes
and the owning dependency declarations. The helper and full policy block were
compared to the prior source after identifier-only renaming. Twenty-one changed
or new OCaml files passed parser-only checks with OCaml 5.5.1; `git diff --check`
passed. These are source/syntax checks, not typing or execution evidence.

The focused actual behavior request retains all original six suites:
`test_workspace`, `test_keeper_effective_meta_overlay`,
`test_channel_gate_discord_state`, `test_server_discord_trigger_policy`,
`test_server_slack_trigger_policy`, and `test_dashboard_keeper_metrics_10286`.
The dispatch identity and eventual result belong in the repair PR. No test is
excluded, and a dispatch alone is not a successful execution. No local Dune
build, broad CI, installed binary replacement, restart or live transport repair
is claimed. The original five native layer identities are preserved; this is
an upper repair layer and the whole stack integrates through its new top only.
