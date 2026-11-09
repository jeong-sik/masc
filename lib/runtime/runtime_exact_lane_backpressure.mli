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
    cell. A slot resting on a rest MASC chose is demoted behind its siblings,
    never removed: a demoted slot still answers when the others cannot, and
    its answer clears the evidence (RFC-0370 §3.3). A slot whose provider
    stated a time is held: the lane does not call it before that time, and
    returns it with the time so a caller can tell a resting lane from a lane
    without slots (RFC-exact-lane-waits-for-a-stated-reset). *)

type held_slot =
  { slot_id : string
  ; until : float  (** The provider-stated time, Unix epoch seconds. *)
  }

type ordered =
  { lane : Runtime_exact_output_registry.resolved_lane
      (** The lane to walk. [selected_slots] holds only the HTTP slots that
          may be called now; [cli_slots] is carried verbatim. *)
  ; held_http : held_slot list
      (** The HTTP slots not to be called before their time, in declared
          order. *)
  }

val order : Runtime_exact_output_registry.resolved_lane -> ordered
(** Split the lane's HTTP slots at the wall clock of the call. A slot whose
    provider stated a time -- its quota scope's stated reset, or the end of
    its own usable Retry-After, whichever is later -- is held until then. A
    slot resting on a rest MASC chose -- a quota observation without a reset,
    or a rate limit inside the configured floor because it carried no usable
    Retry-After -- goes behind the slots nothing rests, keeping declaration
    (or operator preference) order inside each group. A slot id that names
    no runtime carries no evidence: it stays in place and is never held. CLI
    slots are not split here: [Keeper_lane_cli_oneshot.walk] reads the same
    standing before each dispatch. *)

val order_at :
  now:float ->
  Runtime_exact_output_registry.resolved_lane ->
  ordered
(** {!order} read at [now] instead of the wall clock. *)

val observe :
  resolved:Runtime_exact_output_registry.resolved_lane ->
  ( ('accepted, 'rejection) Agent_core.Exact_output.validated_flow_success
  , ('callback_error, 'rejection) Agent_core.Exact_output.validated_flow_error )
  result ->
  unit
(** Record what one finished flow observed: every candidate refused as
    [Rate_limited] notes a rate limit on its runtime with the provider's
    Retry-After when one was sent, and every candidate that returned a
    response -- accepted or semantically rejected -- clears candidate evidence
    and undated quota for the frozen runtime observation captured in [resolved].
    A payment refusal or dispatched typed hard-quota failure records quota on
    that frozen scope. A failure before generation dispatch contributes no
    provider observation. No live ID lookup occurs at completion. *)
