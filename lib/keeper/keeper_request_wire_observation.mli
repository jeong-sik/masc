(** Keeper_request_wire_observation — the serialized request body size AGENT_CORE
    sent for one keeper turn.

    AGENT_CORE's provider-specific serialization observer measures every request
    just before dispatch. Nothing MASC already computes substitutes: the
    canonical checkpoint's bytes cover [{system_prompt, messages}] and exclude
    tool schemas and every provider-specific stream field, and
    [last_input_tokens] is a different unit from a byte count.

    AGENT_CORE invokes this observer after provider-specific serialization and
    after every stream-field injection, so [body_bytes] is the exact count on
    the wire. The observation is diagnostic: AGENT_CORE reports a raising
    callback as typed failure evidence and does not rewrite the provider
    result. Whether the provider accepts that body is the provider's verdict,
    delivered as a typed refusal at the provider-attempt result boundary. *)

val metric : Keeper_metrics.t
(** Histogram the byte count lands in, labelled by keeper and the exact
    runtime whose provider configuration sent the request. *)

val record : keeper_name:string -> runtime_id:string -> body_bytes:int -> unit
(** Record one exact wire observation at the upper Keeper consumer. Provider
    dispatch only forwards the typed boundary value and does not depend on the
    metric store. *)

val observer :
  ?on_observation:(runtime_id:string -> body_bytes:int -> unit) ->
  keeper_name:string ->
  runtime_id:string ->
  Agent_core.Agent.pre_dispatch_serialization_observer
(** [observer ?on_observation ~keeper_name ~runtime_id] records [body_bytes]
    under {!metric}, forwards the same exact boundary value to
    [on_observation], and admits the observation. It never rejects: this path
    exists only to measure, and a rejection would manufacture typed failure
    evidence out of measurement. *)
