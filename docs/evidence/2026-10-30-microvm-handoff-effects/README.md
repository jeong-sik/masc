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

## Follow-up execution admission

An extraction of the complete handoff and owned endpoint admission at parent
`899a6dbafcef29f9e84a4c38f97003f3397f3955` reproduced successful handoff after
a failed link scan, failed target mkdir, or retained unresolved link application.
The follow-up requires current-generation build preparation and retains the
shared unresolved-effect refusal through final endpoint admission. A separate
extraction reproduced a cached Running runtime skipping a failed scan's retry;
its outer endpoint path now re-enters incomplete Apple build preparation.

The follow-up extraction executes actual state/classifier, pure build plan,
handoff, owned endpoint admission and outer endpoint source with dependency
stubs: 20 scenarios and 111 assertions passed with warning 4 fatal. The real
cleanup shell runs only in temporary host directories. Native transport,
identity/owner observations, target effects and the already-Running state are
modeled; this does not execute the registered provider suite or a real guest.
Before/after source hashes and results are under
`artifacts/pr-4c-response-20261030T0900Z/46924-resource-effects-review/`.

## Remaining limits

No local Dune build, full regression, deployment or live Apple recovery probe
was performed in this coding session. Actual first-handoff `Request_not_sent`
integration has no reliable provider injection: lifecycle cancellation is
protected and a failed wire probe falls back to the current protocol. The
callback and extracted-state checks cover that edge at source/core scope only.
The effect records remain process-local and nominal-resource-scoped. They do
not provide durable reconciliation, physical mount identity, external instance
fencing or automatic recovery of an unknown destructive effect.

## Follow-up to maintenance and late-link review

Review CR 5711111653 and comment 6519716416 identified two boundaries missed
by the original source PASS for `899a6dbafcef29f9e84a4c38f97003f3397f3955`.
That PASS was withdrawn. Attached maintenance now reserves a shared work-resource
attempt before sending `--apply`. Unknown outcomes retain the operation ID and
actual observation after lifecycle release. Terminal or request-not-sent evidence
releases only the matching attempt. The existing workspace audit store records
intent before send and the full redacted receipt/result afterward. An intent
write failure sends no maintenance; result-write failure cannot erase unknown
state or create an avoidable latch after trusted termination. This audit uses
flush-only append, not fsync-backed crash durability or restart admission.

Target planning now retains safe `Link_create` targets while suppressing unknown
symlink redispatch. The provider fixture delays an original unresolved symlink
until after a later scan emitted `Build_absent`, during target mkdir on the new
empty build volume. The expected target is still prepared for that late link.
Execution remains withheld while the persistent application is unresolved.
Refused and differently targeted rows retain their existing treatment.

Additional provider scenarios cover maintenance missing receipt, transport loss,
terminal success/nonzero/timeout/refusal, failed endpoint construction and failed
intent-audit writes. They read the real audit store to verify operation-ID pairs,
full redacted receipt fields and exclusion of command output/credentials. The
maintenance payload's selected filesystem effect is modeled; its actual embedded
bytes are validated, but the fixture does not execute the embedded Python script
or an Apple VM. Known-not-sent integration remains unproven as above.

Local follow-up checks passed: parser checks for all three source/interface/test
files, whitespace/changelog checks, 28 checks on the actual extracted state/core,
and type checking of the actual audit/maintenance helper blocks with interface
stubs and warnings 4/32/69 fatal. These extraction checks are not a project build
or provider-suite execution. New follow-up output stays under the working checkout's
`artifacts/microvm-handoff-followup-20261030/`. The original 20-check capture
and its digests remain in their original run directory. The follow-up core
harness SHA-256 is `b6ff4698c0ef0b1e2c24f4ac95ee0f686d7336a127d7d7e9ce7021185d709a17`.


The candidate was integrated onto concurrent public head
`fcdfa13e9ba9fe808ae3f60c7ca5d0d3af4c1e52` (base
`a97919872890eb9b4e730f65b745ab094ed8ce12`), preserving its stricter execution
admission. A further temporary-target-failure gap was found: local target
uncertainty could refuse every later handoff even after the fault disappeared.
A shared-resource check now permits a current-generation scan/idempotent mkdir
retry when no persistent symlink application is unresolved. It never clears
shared link uncertainty. Provider cases distinguish same-runtime and next-turn
recovery without stop, replacement, readiness invalidation or cleanup replay.
