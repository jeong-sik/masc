(** Keeper_request_wire_observation — the serialized request body size AGENT_CORE
    admitted for one keeper turn.

    AGENT_CORE's provider-specific serialization observer measures admitted requests;
    a refused request instead carries the same exact size in
    [Agent_core.Retry.Request_body_too_large.actual_bytes]. Nothing MASC already
    computes substitutes:
    the canonical checkpoint's bytes cover
    [{system_prompt, messages}] and exclude tool schemas and every
    provider-specific stream field, and [last_input_tokens] is a different unit
    from a byte ceiling — measured 07-28/29, of 3,234 turns that died on the
    byte cap, 2,964 (91.7%) were under 50% token utilization at that moment.

    AGENT_CORE invokes this observer after provider-specific serialization, after every
    stream-field injection, and after its own serialized-body admission check,
    so [body_bytes] is the exact admitted count. The observation is diagnostic:
    AGENT_CORE reports a rejecting or raising callback as typed failure evidence and
    does not rewrite the provider result. The rejected-request projection is
    handled at the typed provider-attempt result boundary, not by this metric
    observer. *)

val metric : Keeper_metrics.t
(** Histogram the admitted byte count lands in, labelled by keeper and the
    exact runtime and body cap whose provider configuration admitted the
    request. *)

val record :
  keeper_name:string ->
  runtime_id:string ->
  max_request_body_bytes:int ->
  body_bytes:int ->
  unit
(** Record one exact wire observation at the upper Keeper consumer. Provider
    dispatch only forwards the typed boundary value and does not depend on the
    metric store. *)

val observer :
  ?on_observation:(runtime_id:string -> body_bytes:int -> unit) ->
  keeper_name:string ->
  runtime_id:string ->
  max_request_body_bytes:int ->
  Agent_core.Agent.pre_dispatch_serialization_observer
(** [observer ?on_observation ~keeper_name ~runtime_id
    ~max_request_body_bytes] records [body_bytes] under {!metric}, forwards the
    same exact boundary value to [on_observation], and admits the observation.
    The cap is the value already validated on the final provider config, so a
    hot-reload that changes a runtime's cap starts a distinct metric series. It
    never rejects: this path exists only to measure, and a rejection would
    manufacture typed failure evidence out of measurement. *)
