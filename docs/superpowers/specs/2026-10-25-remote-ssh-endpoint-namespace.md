# Remote SSH endpoint namespace proposal

Status: Implemented in the endpoint-namespace source change; candidate runtime
verification remains separate. This records the reproduced defect and the
implementation boundary.
Related: #38593; [readiness plan](../plans/2026-10-24-remote-ssh-keeper-ready.md).

## Observed failure

An actual a317 Keeper first executed Python and received its cwd in stdout.
The SSH runner changed the endpoint cwd into a host bookkeeping pathname.
The next Execute copied exactly that reported cwd into a literal Python script
and tried to read the file just created. The read returned ENOENT, while a
relative read of the same file returned the correct fresh marker. Base64 of
`os.getcwd()` bypassed the output substitution and identified the actual
endpoint directory. The canonical ledger records both real SSH executions.

[Retained evidence](../../evidence/2026-10-24-remote-ssh-keeper/README.md#reported-cwd-reuse-inside-a-script)
binds this observation to binary/source a317, not the unexecuted current main.
The experiment uses a scripted model; it is not autonomous model discovery.

This is specifically reuse of a reported path inside opaque program text.
It does not establish failure of the public Execute `cwd` field or every
absolute-path tool argument: those use their own translation boundaries.

## Existing contract and proposed change

RFC-0395 and `Keeper_remote_path.rewrite_output` deliberately expose host-shaped
logical paths. `Keeper_sandbox.keeper_visible_root_abs_of_meta` and
`Keeper_sandbox_repo_path.execution_location_json` use that same host namespace
for endpoint-owned trees. The current behavior therefore follows its own
contract; the defect is that the reported absolute name is not an OS pathname
the remote process can use. Rewriting arbitrary script contents cannot repair
that contract without changing program semantics.

Decision: remote SSH Keeper-facing absolute paths identify the resolved
endpoint namespace. Relative paths resolve from the actual endpoint cwd. Host
bookkeeping paths remain internal facts with explicit ownership; they are not
presented as remote OS paths. The prompt root is resolved from the admitted
profile snapshot and retained for prompt/turn telemetry. Each Execute response
uses its actual dispatch target, so later endpoint reconfiguration is not
misreported as an atomic whole-turn configuration snapshot.

## Implementation boundary

1. Resolve the named SSH endpoint and Keeper workspace at the existing runtime
   edge. Pass the resolved namespace as data into pure prompt and execution-
   location projections. Do not repeatedly load configuration inside path
   formatting or silently substitute a host pathname if resolution fails.
2. Keep logical input, host bookkeeping and endpoint paths distinct in the
   interface. Internal host-to-endpoint projection remains explicit. User-facing
   relative or endpoint-absolute input must not be guessed as a host path from
   its spelling. Return a named resolution error when the endpoint is unknown.
3. Make prompt roots and every path in `execution_location` use the same
   resolved endpoint root/cwd, including repository and declared-root cases.
   Endpoint normalization is lexical; do not run host realpath on endpoint paths.
4. Preserve stdout/stderr bytes from SSH commands, including streamed chunks
   and JSON strings. Remove host-root substitution for this transport rather
   than scanning strings to infer which bytes are paths. Original capture files
   and returned output must describe the same byte stream.
5. Audit Read/Grep/Write/Edit, git helpers and callers of the visible-root getter
   before changing its contract. Docker and microVM share some current code but
   have different namespace owners; handle each profile explicitly and do not
   change another lane through a combined pattern arm.

This is not the declared-root kernel-enforcement change (#38895), remote
background jobs (#36941), repository materialization (#31460), or internal typed
IR file attachments (#31442). Their evidence remains separate.

## Acceptance evidence

- Replay the exact previous-output-to-Python-literal scenario on a matching
  candidate: reported absolute and relative reads must return the same fresh
  file bytes, and base64 of the process cwd must agree with the reported cwd.
- Verify nested cwd, repository paths and endpoint-absolute structured file
  calls using the same resolved namespace. Preserve current refusal at sibling
  or undeclared roots without claiming filesystem isolation from string checks.
- Compare unmodified payload stdout/stderr and captures, including JSON containing
  root strings, root-like sibling strings and streamed splits across boundaries.
- Verify missing/ambiguous endpoints report unavailability before effects;
  preserve endpoint selection, per-call authentication and restart behavior.
- Obtain independent source review and focused consumer checks; keep matching
  candidate execution distinct from merge, package installation and real-model
  sustained use.
