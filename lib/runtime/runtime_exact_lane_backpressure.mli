(** Rate-limit evidence shared between Exact-output lanes and Keeper turns.

    An Exact-output lane slot is a runtime id, and that runtime already owns a
    process-local {!Runtime_candidate_backpressure.candidate} which the Keeper
    turn walk reads and writes. Exact lanes used to do neither: a 429 advanced
    only the one flow that received it, so every later Board Attention, HITL,
    Librarian or Workspace Curator call sent its full prompt to the same
    throttled slot first, took the same refusal, and only then reached the
    next slot.

    This module lets an Exact lane read that evidence before it freezes its
    candidate order, and write what its own flow observed back to the same
    cell. A resting slot is demoted behind its siblings, never removed: the
    lane keeps every admitted slot, so a demoted slot still answers when the
    others cannot, and its answer clears the evidence (RFC-0370 §3.3). *)

val order :
  Runtime_exact_output_registry.resolved_lane ->
  Runtime_exact_output_registry.resolved_lane
(** Move every slot whose runtime is resting -- a rate limit inside its path
    rest (the provider's Retry-After, or the configured floor without one,
    clamped to the configured cap), or an exhausted quota window -- behind
    the slots that are not, keeping
    declaration (or operator preference) order inside each group. A slot id
    that names no runtime carries no evidence and stays in place. CLI slots
    are untouched. Read at the wall clock of the call. *)

val observe :
  ( ('accepted, 'rejection) Agent_core.Exact_output.validated_flow_success
  , ('callback_error, 'rejection) Agent_core.Exact_output.validated_flow_error )
  result ->
  unit
(** Record what one finished flow observed: every candidate refused as
    [Rate_limited] notes a rate limit on its runtime with the provider's
    Retry-After when one was sent, and every candidate that returned a
    response -- accepted or semantically rejected -- clears its runtime's
    evidence. *)
