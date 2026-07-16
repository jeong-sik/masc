(** Single MASC boundary for non-streaming Keeper provider sub-calls.

    Feature modules own prompts and result classification, but they do not own
    cancellation. Production calls forward the one resolved non-streaming
    deadline to {!Llm_provider.Complete.complete}; injected test calls are
    deterministic and receive no synthetic timeout wrapper. *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val complete
  :  ?override:complete_fn
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> config:Llm_provider.Provider_config.t
  -> messages:Agent_sdk.Types.message list
  -> unit
  -> (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result
(** Production calls apply only
    {!Keeper_runtime_resolved.body_timeout_override_sec} at the OAS Provider
    boundary. No feature-local wall-clock timeout is installed. *)
