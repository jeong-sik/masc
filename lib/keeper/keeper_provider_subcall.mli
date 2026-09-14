(** Single MASC boundary for non-streaming Keeper provider sub-calls.

    Feature modules own prompts and result classification, but they do not own
    cancellation. Production calls run under one resolved deadline forwarded to
    {!Llm_provider.Complete.complete}; injected test calls are deterministic
    and receive no synthetic timeout wrapper.

    The deadline is the only liveness a sub-call has: a non-streaming call
    shows no progress until it completes, a call waiting for its binding's
    admission permit makes none either, and a call made from inside a tool
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

    Production calls run under two resolved settings.
    {!Keeper_runtime_resolved.provider_call_deadline_sec}, the keeper's
    no-progress threshold, bounds the whole call as
    [Llm_provider.Complete.complete]'s [call_timeout_s]: a call still waiting
    for an admission permit at the threshold ends as
    [TimeoutError { phase = Queue }] without being sent, and one in its round
    trip as [TimeoutError { phase = Non_streaming_body }].
    {!Keeper_runtime_resolved.body_timeout_override_sec}, when declared,
    bounds the round trip inside it as [body_timeout_s]. With neither
    declared the call has no bound. The clock is required because a deadline
    cannot be enforced without one. No feature-local wall-clock timeout is
    installed. *)
