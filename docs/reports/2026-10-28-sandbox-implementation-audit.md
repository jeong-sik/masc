# Sandbox implementation and safety audit — 2026-10-28

## Scope and verdict

Audit baseline: `197f56852c59eb5e7c3c2305974b58c73c9c23f9` (`origin/main`).
The review followed configuration, execution, image admission, network,
filesystem, lifecycle, and observation contracts through their current source
interfaces and tests, then compared operator documentation and open issues.

MASC's Sandbox is a substantial multi-backend implementation, not a stub. It
has typed profiles and failure outcomes, catalog-based image admission,
persistent guest support, framed remote execution, and explicit refusal for
unmeasured network modes. It is **not complete or uniformly safe across every
feature**. Backend maturity differs, and open defects remain at filesystem,
identity, error-reporting, credential-retention, and cleanup boundaries.

This report does not claim a current-head full regression, a live Apple
network operation, or a live fleet check. The exact verification performed for
this stack is recorded at the end.

## Implementation matrix

| Surface | Current source-backed implementation | Boundary or incomplete part |
|---|---|---|
| Profiles and configuration | `Docker`, `Micro_vm`, and `Remote_ssh`; there is no Keeper host profile (`lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.mli:1-7`). Docker and microVM require an admitted catalog image; remote SSH starts no container (`lib/keeper/keeper_sandbox_image_admission.mli:1-27`). | Selecting a backend is not proof that a guest booted or its tools work. `Sandbox_readiness.guest_verification` currently has only `Not_run` (`lib/sandbox_readiness.mli:1-9`). |
| Execution | `Sandbox_target` carries Docker, microVM, SSH, and delegated targets and distinguishes `Ran` from `Transport_failed` (`lib/exec/sandbox_target.mli:30-59,108-141`). | `Lane_unavailable` can still collapse to `WEXITED 1` through `status_tuple`; the remaining wire-loss scope is #38890. |
| Docker | Hardened container defaults, persistent containers adopted across turns, explicit image resolution, and `none`/`inherit` network modes. | `policy` is refused because its egress boundary is unmeasured. Docker startup errors lose typed classes at string boundaries (#33622), and deleted workspaces can leave running containers (#35543). |
| Apple microVM | Per-Keeper VM, endpoint-owned work volume, guest adoption, framed exec shim, trim/repair helpers, and a per-Keeper policy network and proxy. | Policy network names violate Apple's length/edge rules and can collide after case folding (#36467); the policy-name layer of this stack repairs that bounded defect. The current fleet-wide exec incident #46602 is not claimed as repaired. |
| Microsandbox | Backend type, argv builders, parsers, and image-store adapters exist. | `container_listing_for` is `Listing_not_established`: list output lacks the labels needed to scope guests, and the operator runbook says msb does not boot under MASC. `policy` is refused. This is not a completed backend. |
| Nerdctl/Kata | Kata runtime selection, labelled inventory decoding, work volumes, and typed constraint handling exist. | `policy` is refused as unmeasured. Managed work-directory size is not enforced. Some lifecycle constraints are explicitly recorded as dropped rather than silently claimed. |
| Remote SSH | Registered endpoints, pinned SSH identity and known-hosts files, framed shim execution, endpoint-owned filesystem access, preflight, and lane reports. | Transport-only: only `inherit` is accepted; MASC does not reproduce container or network isolation on the endpoint. Typed transport and path/confinement gaps remain open. |
| Network policy | `none`, `inherit`, and `policy` are typed and checked at create/load. Apple uses an internal host-only network and a MASC-owned CONNECT proxy with parsed per-request allowlist rules. | Available only on Apple microVM; other profiles/backends explicitly refuse. The current `.ml` inventory contains no production network-delete argv, so teardown/retention must not be assumed. |
| Filesystem | Docker is `Shared_mount`; microVM and remote SSH are `Endpoint_owned`. Endpoint-owned reads and writes use the remote lane. | `check_read_target` promises symlink-resolved containment, but #35934 records a reproduced lenient-realpath/open-view gap. Complete Read confinement is not established. |
| Lifecycle and volumes | Persistent guest adoption, typed unknown-versus-absent probes, work/build volumes, trim, and filesystem repair paths exist. | Credential snapshots can outlive their owner process (#44678); work-volume artifact retention needs an explicit policy (#40708); policy-network teardown is not established by the current call graph. |
| Observability | Readiness distinguishes service prerequisites from guest verification. Lane reports distinguish payload receipts, dispatch failures, and probe history. Execute output streams from backend callbacks through a per-Keeper event log to SSE and the Dashboard terminal. | Readiness is not a boot or tool-success guarantee. Keeper-facing diagnosis can still omit execution-condition context (#32799). The native TUI has no consumer for the execute-output SSE endpoint; the web Dashboard is the verified terminal view. |

## Documentation parity

The egress runbook's availability table matches the current backend boundary:
Apple microVM alone offers `policy`; Docker, microsandbox, Nerdctl/Kata, and
remote SSH refuse it rather than silently falling back to `inherit`.

Its `--network masc-egress-policy` example was stale. Current code creates one
network per Keeper. This stack updates the example and explains the shared
`policy_network_name` identity used by create, list, and inspect.

RFC documents also contain proposals, rejected alternatives, and historical
measurements. They are useful design history, not proof that every proposed
feature landed. In particular, RFC-0405 records both the microsandbox argv work
and the later observation that its unlabelled listing prevents a complete boot
lifecycle. The implementation interface retains that limitation explicitly.

## Real-time terminal output

Execute output is not confined to the final tool response. `Sandbox_target.runner`
passes stdout and stderr callbacks through `Exec_dispatch`; the remote shim
releases stdout and non-trailer stderr while the process is still running
(`lib/keeper/keeper_sandbox_remote.ml:450-489,755-865`). The Execute runtime
redacts those chunks and calls `Keeper_keepalive_signal.record_execute_stream_chunk`
(`lib/keeper/keeper_tool_execute_runtime.ml:716-765`). `Dashboard_execute_output`
retains ordered line events, wakes subscribers, and exposes gaps instead of
silently losing slow-reader output (`lib/dashboard/dashboard_execute_output.ml:265-308,471-557`).
`GET /api/dashboard/execute-output/<keeper>` and its `/api/v1` alias carry those
events as SSE. The Dashboard terminal subscribes and appends them while the task
is open (`dashboard/src/api/execute-output.ts:66-116`,
`dashboard/src/components/ide/execute-output-drawer.ts:289-350`). In the
Dashboard IDE, opening **Terminal** for a Keeper enables this subscription
(`dashboard/src/components/ide/ide-shell.ts:935-968,1208-1215`). The endpoint
requires control-plane authentication: an unauthenticated read-only local probe
returned `missing_token`, and the actual Dashboard also presented `Login
required`. No authenticated live event or paint was observed.

This is a real-time **web Dashboard terminal**, not a separate interactive PTY
or a native-TUI stream viewer. The native TUI has no consumer for this endpoint
in the audited source. Streaming also has explicit boundaries: secret redaction
can hold partial text, output has retention limits, large overshoot produces a
visible gap, and the last complete process output is persisted separately. No
live browser paint, live fleet timing, or interactive terminal-input claim is
made here.

## Bounded repair in this stack

The policy-name layer changes only Apple policy-network naming. It preserves an
existing name when the original Keeper name is already lowercase, bounded,
alphanumeric-ended, and outside the reserved digest shape. Otherwise it uses a
trimmed Keeper segment and a 128-bit SHA-256 digest of the original, untrimmed
name. This covers case folding, excessive length, punctuation at the end, and
names that could otherwise impersonate a hashed owner. Network create, list,
and inspect retain their existing interfaces.

The regression test calls the real `policy_network_name` function and checks
its result against an independent implementation of Apple's `nameValid` rule.
It also covers owner separation and preservation of an already-valid name.
This is deliberately narrower than choosing a global Keeper naming policy.

A separate validation layer handles the failures already present in the focused
Sandbox suites. It supplies the identity, shim, probe and mounted-volume facts
that the existing fixtures omitted; it does not relax those production guards.
Its raw-Read repair preserves both the endpoint-resolution error and the
keeper-tree refusal, which the early captured-authority failure had dropped.
The final stacked-head suite result is recorded below rather than inferred from
the individual patch.

The documentation layer updates the runbook and retains this audit. It does
not mark unrelated open defects as resolved.

## Remaining work not closed by this stack

- **#35934 — Read symlink escape.** The endpoint must confine and open in the
  same filesystem view; another host-side lexical check is insufficient.
- **#36487 — Global case-fold identity.** Registry, filesystem, Board, and
  container naming need one accepted policy. This stack protects only the
  policy-network resource identity.
- **#38890 — Transport wire fidelity.** Payload timeout now maps to the host
  timeout status, but `Lane_unavailable` can still become a synthetic exit 1.
- **#33622 — Docker startup error typing.** Typed classes are still stringified
  before tool-result consumers can use them.
- **#44678 — Credential-copy retention.** Guest GitHub credential copies can
  persist in TMPDIR; an accepted owner and retention policy is required.
- **#40708 — Work-volume retention.** Safe artifact preservation and actual
  host-space reclamation need measurement and design.
- **#35543 — Orphaned Docker containers.** Cleanup authority must outlive a
  deleted workspace.
- **#32799 — Missing execution context.** A Keeper can misdiagnose a closed
  network as a credential failure.
- **#46602 — Apple fleet exec incident.** This source-only naming repair does
  not establish recovery for the observed fleet-wide exec unavailability.
- **Native-TUI Execute stream viewer.** The web Dashboard terminal consumes the
  live SSE feed; no equivalent native-TUI consumer was found in this audit.
  This is a separate UI feature, not evidence that backend streaming is absent.
- **Policy-network teardown.** No production `network delete/rm/remove` argv
  was found. Desired retention and ownership must be settled before adding a
  destructive cleanup path.

## Verification record

- **Naming RED:** GitHub `Test` run `40676389838`, `workflow_dispatch`, head
  `62ce3e2c1b7fa73852cff2a9444e56256b089c9e`, suite
  `test_keeper_sandbox_read_backend`, `minimal=true`: completed/failure, 80
  tests and 4 failures. The new policy-name case failed as intended; the other
  three were existing read/attach failures.
- **Naming repair:** run `40677704864`, head
  `6de3f330662f2f35e939bbd04a3e7d5c8e2a64d7`, suites
  `test_keeper_sandbox_read_backend,test_keeper_sandbox_microvm`:
  completed/failure. The new policy-name case passed. `read_backend` retained
  the same 3 failures; `microvm` had one existing warm-adoption fixture failure
  (114 tests, 1 failure). This run is not called a green suite.
- **Fixture-only run:** run `40693424021`, head
  `2d83d5e34d4cb961ea7a67456ef84355b7f94760`: completed/failure during OCaml
  compilation because the fixture was referenced before its definition. This
  was not a behavioral test result. The ordering was repaired and a
  valid-declaration/failing-preflight regression was added as `59de2f991df`.
- **Preflight diagnostic RED:** run `40696542466` completed/failure at that
  test-only head. The new case lost the original preflight marker as intended;
  `read_backend` had two failures in total, while `microvm` passed 114/114.
  The unresolved-endpoint and attached-guest cases passed. The production fix
  now passes the original capture error into target resolution rather than
  substituting a later resolution error.
- **First final-stack run:** run `40697855534`, head
  `be25646e1d31475d755bd0f5faf652b073873f4c`: completed/failure during OCaml
  compilation (warning 16: the new optional resolver argument needed a final
  `()`). No behavioral result was inferred. That application is now complete.
- **Second final-stack run:** run `40699506153`, head
  `f72a51bb47d0911b062a3468bbb7d6087b1c9139`: completed/failure with only the
  microVM endpoint-profile fixture reporting a missing Eio execution context.
  The new preflight diagnostic passed; `read_backend` ran 81 tests with this
  one failure. `microvm` 114/114, Dashboard output 17/17, remote sandbox 22/22,
  and stream close 9/9 passed. The fixture now uses the same Eio, shim and
  identity preparation as the attached-read test.
- **Focused GREEN:** run `40700857707`, head
  `202539abb1e7ef3382d2ceaae832b0613813bd45`: completed/success.
  `test_keeper_sandbox_read_backend` 81/81, `test_keeper_sandbox_microvm`
  114/114, `test_dashboard_execute_output` 17/17, `test_keeper_sandbox_remote`
  22/22, and `test_keeper_tool_execute_stream_close` 9/9 passed (243/243).
  This verifies the focused code paths, not the whole repository or a live
  fleet.
- **Real-time output:** run `40692203058`, head
  `6de3f330662f2f35e939bbd04a3e7d5c8e2a64d7`: completed/success.
  `test_dashboard_execute_output` 17/17, `test_keeper_sandbox_remote` 22/22,
  and `test_keeper_tool_execute_stream_close` 9/9 passed. These tests exercise
  the live event path; they do not prove browser paint or native-TUI rendering.
- **Full local Dune build and full `@runtest`:** not run under the external
  coding-session protocol. A targeted suite is not a full-regression claim.
- **Live Apple `container network create/list/inspect`:** not run.
- **Live fleet validation, browser paint, native-TUI paint, and #46602
  reproduction:** not run.
