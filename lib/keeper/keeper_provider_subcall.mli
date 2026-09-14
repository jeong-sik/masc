(** Single MASC boundary for non-streaming Keeper provider sub-calls.

    Feature modules own prompts and result classification, but they do not own
    cancellation. Production calls run under one resolved deadline forwarded to
    {!Llm_provider.Complete.complete}; injected test calls are deterministic
    and receive no synthetic timeout wrapper.

    The deadline is the only liveness a sub-call has: a non-streaming call
    shows no progress until it completes, and a call made from inside a tool
    is not seen by the attempt watchdog
    ({!Keeper_turn_driver_try_provider.attempt_stalled} exempts a tool in
    flight). *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_core.Types.message list ->
  ?tools:Yojson.Safe.t list ->
  unit ->
  (Agent_core.Types.api_response, Llm_provider.Http_client.http_error) result

val deadline_s
  :  body_timeout_override_sec:float option
  -> provider_call_deadline_sec:float option
  -> float option
(** The deadline a production sub-call runs under, from the two resolved
    keeper settings. A declared
    {!Keeper_runtime_resolved.body_timeout_override_sec} is the narrower
    statement and wins; otherwise
    {!Keeper_runtime_resolved.provider_call_deadline_sec}, the keeper's
    no-progress threshold, bounds a call that makes no progress until it ends.
    Both absent is the operator's declared choice of no bound. *)

val complete
  :  ?override:complete_fn
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Llm_provider.Provider_config.t
  -> messages:Agent_core.Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> (Agent_core.Types.api_response, Llm_provider.Http_client.http_error) result
(** [tools] is forwarded to the provider unchanged. It exists so a caller
    that needs to observe whether the model {e chooses} a tool can do so
    through this boundary instead of reaching past it into
    {!Llm_provider.Complete}: the boundary owns the resolved deadline, and a
    caller that bypassed it to gain a parameter would silently lose that.

    Production calls run under {!deadline_s} of the resolved settings. The
    clock is required because a deadline cannot be enforced without one. No
    feature-local wall-clock timeout is installed. *)
