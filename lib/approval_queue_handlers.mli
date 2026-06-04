(** Approval queue handlers for inline-dispatched approval tools.

    The approval queue is keeper-owned state, but the generic
    [Tool_inline_dispatch] surface must not import keeper modules directly.
    This module is the narrow adapter for the existing
    [masc_approval_pending] / [masc_approval_get] /
    [masc_approval_resolve] tool bodies. *)

val handle :
  tool_name:string ->
  start_time:float ->
  Yojson.Safe.t ->
  Tool_result.result
