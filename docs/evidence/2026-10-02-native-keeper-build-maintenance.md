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
