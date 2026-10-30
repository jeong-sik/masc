(** Producer failure semantics on the private worker protocol. Unrecognized or
    malformed metadata cannot establish an effect boundary. *)
val metadata : Tool_result.result -> Yojson.Safe.t option
(** Preserve existing object metadata and encode the producer's failure class
    and effect disposition. Successful results cannot carry a stale failure. *)
val failure : Mcp_protocol.Mcp_types.tool_result ->
  Tool_result.tool_failure_class * Tool_result.failure_effect_disposition
(** Decode only an error result with one complete, recognized failure record.
    Otherwise return [Runtime_failure, Effect_outcome_unknown]. *)
