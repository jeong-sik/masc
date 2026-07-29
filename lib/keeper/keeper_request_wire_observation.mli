(** Keeper_request_wire_observation — the serialized request body size OAS
    admitted for one keeper turn.

    Only a refused request reports its size today
    ([Agent_sdk.Retry.Request_body_too_large] carries [actual_bytes]), so the
    admitted population is unmeasured and nothing can compare a keeper's real
    wire size against its runtime's [max_request_body_bytes]. Nothing MASC
    already computes substitutes:
    [Keeper_context_core_accessors.serialize_context] covers
    [{system_prompt, messages}] and excludes tool schemas and every
    provider-specific stream field, and [last_input_tokens] is a different unit
    from a byte ceiling — measured 07-28/29, of 3,234 turns that died on the
    byte cap, 2,964 (91.7%) were under 50% token utilization at that moment.

    OAS invokes this observer after provider-specific serialization, after every
    stream-field injection, and after its own serialized-body admission check,
    so [body_bytes] is the exact admitted count. The observation is diagnostic:
    OAS reports a rejecting or raising callback as typed failure evidence and
    does not rewrite the provider result. *)

val metric : Keeper_metrics.t
(** Histogram the admitted byte count lands in, labelled by keeper and the
    exact runtime whose provider configuration admitted the request. *)

val observer :
  keeper_name:string ->
  runtime_id:string ->
  Agent_sdk.Agent.pre_dispatch_serialization_observer
(** [observer ~keeper_name ~runtime_id] records [body_bytes] under {!metric}
    and admits the observation. It never rejects: this path exists only to
    measure, and a rejection would manufacture typed failure evidence out of
    measurement. *)
