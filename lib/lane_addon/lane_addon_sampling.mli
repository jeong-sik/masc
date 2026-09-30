(** Host-owned sampling boundary. Retain a request before invoking the host
    model handler, and keep terminal evidence distinct from generated text.
    An [invoke] error is recorded as [host_error], without inferring a policy
    rejection. Invocation exceptions are [outcome_unknown]. Invalid responses
    retain the actual supplied response under [invalid_response]. *)
type t
(** A broker retains its exact package and installation identity. *)
val for_worker : t -> package:Lane_addon_types.package -> instance_id:string ->
  (Agent_core.Mcp.sampling_handler, string) result
(** Refuse a broker created for a different worker before creating a container. *)
val create :
  store:Lane_addon_store.t -> package:Lane_addon_types.package ->
  instance_id:string -> route:string ->
  invoke:(route:string -> request:Lane_addon_types.evidence ->
    Mcp_protocol.Sampling.create_message_params ->
    (Mcp_protocol.Sampling.create_message_result, string) result) ->
  unit -> (t, string) result
