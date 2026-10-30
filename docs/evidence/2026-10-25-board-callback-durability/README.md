# Board exact callback durability conformance — 2026-10-25

Relates #25860 and its original #25666. Source base:
8d872e10305f4ce1fc7e14c47379d462c184da20. Initial source candidate:
a67bd3a3fc88b5900c85a2f80cc73b0046cf4255.

The current worker converts a partition callback's Visible_sync_unconfirmed
into an error before AGENT_CORE may dispatch or advance. Existing worker
fixtures mention that outcome in setup refusals; those branches do not inject
it at the real callback consumer. This change supplies that missing composed
feature-path proof without requiring one shared fault framework.

## Verification path

The public For_testing entrypoint runs the same worker selection, pre-claim
preparation, real partition write, exact-flow execution and disposition path.
Only the durability outcome returned after a successful partition write is
mapped at the typed Before_dispatch/Before_advance boundary. Production entrypoints
use the identity mapper. There is no global fault state or runtime policy knob.

Three added cases in test_keeper_board_attention_exact_flow require:

- Unconfirmed bind: actual Bound provenance is persisted, no provider HTTP,
  Blocked retains that binding, the candidate is quarantined and no Owner
  delivery enters the durable event queue.
- Unconfirmed advance: the first actual local HTTP answer is rejected, real
  Advancing retains its failed binding and selected next slot, but no successor
  HTTP occurs. The same quarantine/delivery checks apply.
- Confirmed control: first HTTP then actual successor HTTP and Completed.

Fault cases perform a second ordinary worker invocation with a fresh epoch in
THE SAME OS PROCESS and require Idle; final peer request counts must remain
0/0 and1/0 respectively. This is not a process restart or recovery proof.

This is semantic durability-outcome injection after an actual successful write,
not a physical fsync failure. It does not certify low-level settlement errors,
power loss, actual external providers, live Board delivery or deployment.
Other #25860 faults and original feature requirements remain independent.

## Validation

[Selected run 40188028211](https://github.com/jeong-sik/masc/actions/runs/40188028211)
actually checked out exactly `15a61e9a588894123af61d6d1b6fac9ab881cb33`, compiled
the two selected executables and completed SUCCESS: exact-flow **47 cases** in
0.407s and worker **71 cases** in0.509s, **118 total**. The three new callback
durability cases passed as part of those47, not as an extra count.

Actual assertions show binding/failed-anchor/selected-successor persisted before
the injected outcome, retained exact Blocked progress, no owner delivery and
first/successor peer counts. The passed cases also enforce candidate quarantine
and ordinary same-process next invocation Idle. The confirmed control reached
both peers. `run-40188028211.txt` preserves actual checkout/assertion/summary
lines and the full raw-log SHA; `source-sha256.txt` binds the three code/test files.
Later evidence-only commits do not re-label this run as a new execution.

Three changed OCaml source/interfaces parse; full committed whitespace and
changelog checks pass. Two independent source reviews at the executed head/base
found no P0–P2. No local Dune/build/typecheck or full regression was run. This is
actual selected execution with semantic injected outcomes; the physical-fsync,
process-restart, live/deployment and other umbrella limits above remain.
#25860 stays OPEN.
