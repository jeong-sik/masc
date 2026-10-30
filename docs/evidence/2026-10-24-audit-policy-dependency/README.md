# Audit policy dependency repair

Repair PR #45702 is the sixth layer of Native Stack #45554, above #45608.

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
  cells from `Runtime_settings` to gate-owned `Connector_trigger_params`.
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
compared to the prior source after identifier-only renaming. Twenty-three changed
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

Source review caught a name collision between the first extraction name and
the existing root `Connector_trigger_policy` TOML loader. The extracted typed
handles are therefore named `Connector_trigger_params`; the loader module and
its `Make`/`load_error` API remain unchanged. Run 40063030116 targeted the
pre-correction head and is not validation of this corrected source.

Independent source review also found that both actual gateway starts checked
transport tokens before publishing their configured default. Startup now
resolves the strict policy and publishes it before those checks. This changes
observable behavior: a disconnected or disabled connector with configured
`all` reports `all`, and a live override still wins. Invalid policy does not
install a fallback; Slack retains the typed loader's startup diagnostic.
New cases in the existing two policy suites call the real `start` functions
with transport tokens absent, verify status and descriptor policy, verify
clear returns to the newly configured value, and cover Slack disabled state
and invalid-policy diagnostics without opening a transport. These cases are
prepared source until the new exact-source execution completes.

## Actual six-suite execution and narrow fixture correction

[Run 40063396106](https://github.com/jeong-sik/masc/actions/runs/40063396106)
completed on `b0f9f1c2bf1d6051a49377e6d9fb7cd3127a46fa`. All six executables
compiled and ran: **219 cases, 218 passed, one failed, zero skipped**. Five
suites fully passed (39 overlay, 16 connector-state, 20 Discord-policy,
34 Slack-policy and 7 Dashboard cases). All new actual-start cases passed.
Workspace ran 103 cases: 102 passed and one stale rendered-message assertion
failed. [Structured accounting](behavior-40063396106.json) comes from the full
runner artifact; its downloaded archive digest and extracted log were verified.
This remains a failed run, not a passing six-suite receipt.

The failed Workspace fixture required the removed text `current_assignee=claude`,
while the current error is typed `TransitionRejected` / `Current_owner_required`
and the renderer states the owner in prose. The attempted public completion
mutation is preserved. The correction checks the exact typed task, requested
actor, completion-submission action and assignee; then re-reads the authoritative
backlog to verify the task remains Claimed by the original owner. Other errors
and success both fail the test. No production source or other suite input
changes follow the six-suite execution. Only the corrected Workspace suite
requires a new execution; the other five results keep their original source
identity above. The follow-up PR receipt records its exact source and result.
