# Native Keeper build maintenance validation

Checked 2026-10-02 UTC. Scope: source integration and shared guest algorithm;
not an installed-server or linked OCaml integration claim.

Safe admission is `Keeper_owner.run_maintenance_if_idle ~defer_to_chat:true`.
The actor rejects an occupied turn slot, shutdown, queued/running user operations,
and unavailable operation storage. A root-switch background loop attaches only
to an existing recorded Apple guest, using the normal Keeper UID/GID. It never
pauses a Keeper, boots a guest, stops a VM, or mounts its live volume elsewhere.

Runtime enablement, interval, and retention use the existing Runtime_params
store and surface. The shared Python payload is embedded with ocaml-crunch from
config; the operator CLI imports and sends that same source.

Validation:

- Ruff and Pyright: three Python files, zero errors.
- Changed OCaml sources/interfaces and Owner regression: parser checks passed.
- Host service lifecycle test passed; Linux-only cases skipped on macOS.
- Isolated Apple fixture used the cached OCaml image, UID 502:GID 20,
  `--cap-drop ALL`, network none, one CPU and 512M memory. Guest PID 1 cwd
  was readable by UID 502. Six tests passed in 2.316 seconds: script service
  lifecycle, native/wrapper locks, retention/generated-target-only deletion,
  symlink/operator marker protection, and unreadable-process fail-closed.
  Fixtures used temporary guest directories; no production work tree was swept.
- Added live-checkout process protection test: Ruff/Pyright passed; subsequent
  fixture exec timed out before test output, so this added guest case remains
  unexecuted. No cleanup was authorized by that timeout.
- Independent source review found no remaining P0-P2 after extraction and
  packaging fixes. Exact-head review is recorded separately in PR evidence.

The new Owner regression covers background maintenance yielding to queued chat
while preserving explicit maintenance transactions. It was parser-checked, not
linked or executed in this external session. Full build/CI and actual deployed
maintenance-loop proof remain outstanding. A request submitted after cleanup
admission can wait until the bounded attempt finishes; zero additional latency
is not claimed. Existing standalone service remains until a native binary is
installed and verified.

## Self-review fixes and subsequent verification

The original head b489952fcc used raw `read_meta`, whose decoder deliberately
returns Docker/None for TOML-owned sandbox fields. Therefore the earlier claim
of working native automatic cleanup was unsupported. It also lacked a binding
between the Owner name and the re-read payload name. These findings invalidate
the original source PASS; the six original guest tests exercised only the shared
guest algorithm, not its native metadata producer.

The corrected consumer reads effective TOML metadata, checks both names against
the admitted Owner, and refuses overlay errors. Three native regressions use
real temporary TOML/runtime JSON fixtures and are wired in test/dune. They are
parser-checked; linked OCaml execution remains outstanding.

Raw container exec was replaced with the existing framed remote runner. The
same guest shim owns payload deadlines, stdin EOF cancellation, process-group
cleanup, and exit receipts. Success requires both exit zero and this call's
execution receipt; transport failures and missing receipts are errors.

Subsequent isolated Apple fixture: UID502:GID20, all capabilities dropped,
network none, cached OCaml image, one CPU, 512M memory. Seven shared cleanup
checks passed in 2.365s, including the previously unexecuted live-checkout case.
Three real Linux exec-shim tests passed in 2.722s: payload cleanup/exit receipt,
guest timeout, and EOF cancellation. The latter two used a slow Dune fixture
with a child process ignoring SIGTERM and checked that neither PID remained
live at the result trailer. No production checkout was swept.

The tested installed Linux shim SHA256 was
018254c8ce38a191c70a4c97aa0f530780faec8c7467ff47ef5d995d9c2fdb6b.
These tests directly drive the shim inside the VM; they do not prove the full
OCaml Owner/Apple CLI cancellation path or the newly installed native loop.
Ruff/Pyright, OCaml parser checks, and diff whitespace checks passed.
