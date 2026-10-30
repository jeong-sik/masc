# MicroVM first-handoff recovery evidence

The source candidate extends PR #46924 from `187a5f25269b1faa1ed7640ab0a61955c1badc4c`.
This bundle describes source and local extraction evidence, not an installed
binary or live Apple guest recovery.

## Observed incident

On 2026-10-30, the affected Keeper's read-only `gh api .../pulls/46958/files`
request returned a missing-container error and no trustworthy result trailer.
The retained execution observation was `transport_unavailable` with acceptance
`not_asked`; it did not prove that the remote command was unsent.

The host's unified log records the affected Virtualization process handling
SIGTERM at 18:46:11.997 KST and launchd removing that process at 18:46:12.331.
The sender and reason for the termination remain unproven. This patch does not
claim to repair that host-side termination; #44333 and #46602 track the broader
Apple runtime stalls.

## Source correction

Cleanup and unresolved symlink applications follow the shared backend/Keeper
work resource across workspace and network aliases. Cleanup availability is
consumed before dispatch, including known-not-sent results. Trusted terminal
failure, timeout and explicit pre-spawn refusal permit best-effort handoff;
unknown destructive cleanup prevents new mutation handoffs. A fresh scan can
recreate disposable targets without replaying persistent work-tree effects.

The unrestricted running-endpoint API consumes any unused cleanup opportunity
under lifecycle ownership. Maintenance checks cleanup admission and retains
that owner through its command. Attached diagnostic reads remain separate.

## Checks performed

- `ocamlc -stop-after parsing -impl lib/keeper/keeper_turn_sandbox_runtime.ml`
- `ocamlc -stop-after parsing -intf lib/keeper/keeper_turn_sandbox_runtime.mli`
- `ocamlc -stop-after parsing -impl test/keeper_guest_survival_runtime/test_keeper_guest_survival_runtime.ml`
- `git diff --check`
- `python3 scripts/changelog-fragments.py check-files changelog.d/46924.md`
- OCaml 5.5.1 interpreter execution of the actual extracted receipt/state core,
  with dependency-interface stubs and warning 4 fatal: 20 checks passed. The
  scenarios include terminal versus unresolved results, not-sent consumption,
  resource-alias preservation, stale-generation rejection and target readiness.
  This extraction does not execute the full first-handoff provider path.

The extraction and output were captured under
`artifacts/microvm-handoff-resource-effects-20261030/` in the working checkout.
The extracted core SHA-256 was `7d0faaf619e3443a098917bad8b439770e41b3438da7d16059844d08d39cacb0`.
The harness SHA-256 was `f2757a193f3c121d36cd1b32f3303332cb62c38223ac7317206a077e9da118a5`.

The provider suite now executes the production cleanup/scan scripts over mapped
fixture-owned directories and models the build-volume lifecycle, target mkdir
and non-overwriting symlink applications. Its new scenarios cover alias output
preservation, reboot target restoration, unknown cleanup/link effects, terminal
nonzero/timeout and explicit refusal. Parse checks are not test execution.
Focused CI is requested separately for the exact published head.

## Remaining limits

No local Dune build, full regression, deployment or live Apple recovery probe
was performed in this coding session. Actual first-handoff `Request_not_sent`
integration has no reliable provider injection: lifecycle cancellation is
protected and a failed wire probe falls back to the current protocol. The
callback and extracted-state checks cover that edge at source/core scope only.
The effect records remain process-local and nominal-resource-scoped. They do
not provide durable reconciliation, physical mount identity, external instance
fencing or automatic recovery of an unknown destructive effect.
