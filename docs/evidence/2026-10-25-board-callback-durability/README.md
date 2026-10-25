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

All three changed OCaml source/interfaces parse; full committed whitespace
passes. Two independent source reviews at the initial candidate/base found no
P0–P2, including public type/callers and actual flow/peer assertions. This is not
compilation or execution evidence. Selected CI is requested only for the Board
exact-flow and worker suites; no local Dune/build/typecheck or full regression.
The execution result is not yet observed. #25860 stays OPEN.
