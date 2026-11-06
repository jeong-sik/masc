(** Decoders for an activation and a transition rejection.

    [decode_activation] and [decode_transition_rejection] decode one
    activation or one transition rejection from JSON, and refuse a turn
    reference that does not belong to the trace [expected_trace_id].
    [activation_of_yojson] calls [decode_activation].
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors

val decode_transition_rejection :
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (transition_rejection,
   decode_error)
  result

val decode_activation :
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (activation,
   decode_error)
  result

val activation_of_yojson :
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (activation, decode_error) result
