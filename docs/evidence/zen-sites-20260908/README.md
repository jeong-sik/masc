# Zen Browser Lane: repeated actual use

Open [the static report](index.html) for the measured site matrix and original PNGs.

This run records actual Keeper browser calls on three public sites twice, two
separate MDN supplements, and an owned local fixture for advanced controls.
The model's successful chat-operation state is not treated as task completion.
Across two test Keepers there were 23 model turns and 228 actual executed tool
calls: 212 successes and 16 failures/guards. Unexecuted approval requests and
the operator's independent HTTP observations are excluded from that count.

## Public sites

- Wikipedia: real portal search and Enter submitted for OCaml and Type inference;
  final article reads, scrolling, screenshot artifacts and image analysis verified.
- MDN: observed documentation links, back/read, forward/read and reload/read
  verified twice. Both initial turns omitted requested scroll/capture/vision.
  Two fresh supplemental sessions performed capture, 500 px scroll, capture and
  neutral image analysis; the initial partial results remain unchanged.
- GitHub: observed OCaml release links opened in new tabs; both-tab inventory,
  original-tab closure, remaining release page and reload/read verified twice.
  Both session-close operations timed out once, then observed invalid sessions,
  retried close and left geckodriver ready. They were recovered closures.

The eight public cases contain 128 actual tool calls, 116 successful calls and
12 retained failures/guards: eight initial closed-session observations, two
close timeouts and two following invalid-session observations. Six of the 128
calls were artifact reads linked to offloaded browser output, not unrelated files.

## TUI evidence

The real pinned TUI ran in a PTY with a Kitty capability response. The decoded
image emitted by its Kitty APC output exactly matches the independently read
MDN HTTP PNG: 140,099 bytes, SHA-256
`d28f9f98df87b3deb4fece194df31645444526ad45bfcd9977e301dd83fd50bb`.
Normal exit was 0. This measures the TUI transport and emitted image bytes;
it is not a screenshot of a physical terminal renderer or a terminal-matrix test.

## Failures and intervention

Advanced lab initial execution copied selector `>` as a literal backslash-u003e
sequence three times. The preceding BrowserRead result contained the correct
literal character. The initial partial trace is retained; recovery uses an
explicit follow-up on the same session and does not reset fixture receipts.

The generated synthetic file also omitted its final newline on an attempted
Write. A write approval is separate from expected-byte validation. The first
actual Write then found `microvm_shim_missing`: the isolated scratch runtime
had omitted its Linux sandbox shim. An existing Linux ELF and matching digest
sidecar were copied into that scratch runtime. No local build, backend fallback,
host-file substitution or production-runtime change was used for recovery.

The advanced fixture audits and final cleanup receipts distinguish actual
server effects, successful tool calls, assisted recovery and unsupported scope.
Requested-content fidelity (51 bytes including the final LF) and transport
fidelity (the actual generated file's bytes versus the received HTTP body) are
separate assertions. A 50-byte exact transfer cannot satisfy the original
51-byte expected-content assertion. Model-facing tool inputs already lacked LF;
the upstream provider's raw generation/parsing boundary was not measured.

## Final cleanup observation

Both Keepers reached Finalized and paused with no pending approvals. Both
BrowserSession closes completed and their owned upload leases were removed
automatically. The owned MASC server, geckodriver and fixture received SIGTERM;
each recorded PID was then absent.

The advanced Keeper's VM was still running after Finalized. Its log explicitly
reported `microvm_teardown_backend_unresolved`. An exact-name operator stop
succeeded (exit 0); delete then returned NotFound. Subsequent container list and
exact inspect failed with an Apple API XPC timeout. No matching named runtime
process remained in the separate OS observation, but authoritative inventory
absence remains unverified. The shared container service, images and work volume
were not restarted or deleted. Do not interpret Finalized as full resource cleanup.

The small [follow-up source change (#34169)](https://github.com/jeong-sik/masc/pull/34169)
resolves the effective TOML sandbox backend
before teardown. It is not part of the measured binary and still needs deployed
runtime verification. It resolves the current configuration rather than a
captured immutable boot-time backend.

## Identity and scope

See [binary receipt](binary-receipt.json), [environment](environment-receipt.json),
[public audit](public-audit.json), [MDN supplement audit](mdn-supplement-audit.json),
[combined counts](combined-public-audit.json), [TUI receipt](tui-receipt.json)
and [artifact manifest](receipt.json). Audits retain per-call times, IDs, digests,
observed URL/tab identity and failure classifications without external page bodies.

The run uses one model recorded as
`agent_core-ollama_cloud.ollama-cloud-glm-5-3-flash` and Zen 1.22b on macOS.
The MASC server and TUI were copied into a private immutable directory; source
and binary hashes were checked against the scratch runtime before admission.
The installed sandbox shim has its own digest; its exact source commit was not
established. Source-level or documentation capability is not substituted for a
measured tool invocation.

No authenticated app, connector, posting, payment, operator live browser profile,
cross-origin frame, large/multiple upload, hover, drag/drop, arbitrary JavaScript,
shadow DOM or OS dialog is covered. JavaScript alert/confirm/prompt are distinct
from OS dialogs. Screenshots prove the tested pages, not all websites or models.

Local audit scripts and raw evidence are retained in the task's private scratch
directory. To repeat, create an isolated MASC base with pinned server/TUI/driver,
the existing Linux microvm shim and sandbox image, use fresh BrowserSession
opens and observed tab/selector values, retain each operation's raw tool trace,
compare independent page/effect/capture receipts, and verify actual session and
Keeper shutdown. Do not replace missing model actions with operator actions.
