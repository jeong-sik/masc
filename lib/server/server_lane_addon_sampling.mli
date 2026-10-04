(** Production host sampling for an exact installed worker and its binding.
    Package model preferences never select credentials or a runtime route.
    Only [binding.model_route] selects the configured host route, whose declared
    candidates use the shared one-shot quota/backpressure walk order, excluding
    none. Quota and rate-limit refusals update the shared runtime state; answers
    clear candidate pressure and undated exhausted quota observations. As with
    other one-shot walks, transient failures do not invent a Keeper recorder. Requests and terminal outcomes are retained
    by {!Lane_addon_sampling} before/after the provider boundary.

    Native Agent Core completions carry the requested output limit and
    temperature into the provider request unless the model declares a fixed
    operator temperature. Thinking-only responses are empty text completions
    and continue to the next declared candidate, retaining their stop reason.
    Responses with no model identity also continue the route before admission.
    Temperature support remains owned
    by the model's capability/codec contract; this does not promise that a
    reasoning model applies it. Stop sequences and sampling tools are refused explicitly.
    Official-client adapters currently cannot accept the required per-request
    output limit, so those candidates report an unsupported-control failure
    without being invoked. A route can continue to its next declared candidate;
    no default runtime or package model hint substitutes for the route. *)
val register : config:Workspace.config -> net:Eio_context.eio_net -> unit
(** Bind the process-wide factory to the registering workspace's Lane store.
    A worker belonging to another workspace is refused before provider I/O. *)
val create_handler :
  config:Workspace.config -> net:Eio_context.eio_net -> sw:Eio.Switch.t ->
  store:Lane_addon_store.t -> instance_id:string ->
  package:Lane_addon_types.package -> binding:Yojson.Safe.t ->
  (Lane_addon_sampling.t, string) result
(** Assemble the same worker-bound production handler installed by [register]. *)

module For_testing : sig
  val attempt_captured : sw:Eio.Switch.t -> net:Eio_context.eio_net ->
    Runtime_instance.t -> Mcp_protocol.Sampling.create_message_params ->
    (Mcp_protocol.Sampling.create_message_result, string) result
  val response_content : Llm_provider.Types.api_response ->
    (Mcp_protocol.Sampling.sampling_content, string) result
end
