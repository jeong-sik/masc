(** Host-owned sampling boundary. Wire preflight precedes request publication;
    a refusal whose evidence-bearing frame cannot fit retains no request blob.
    Retain every admitted request before invoking the host
    model handler, and keep terminal evidence distinct from generated text.
    An [invoke] error is recorded as [host_error], without inferring a policy
    rejection. Invocation exceptions are [outcome_unknown]. Invalid responses
    retain the actual supplied response under [invalid_response] when it can be
    serialized safely; encoding failures retain a terminal diagnostic. Host-only
    diagnostic strings are never returned to packages. *)
type t
(** A broker retains its exact package and installation identity. *)
val for_worker : t -> package:Lane_addon_types.package -> instance_id:string ->
  (Agent_core.Mcp.sampling_handler, string) result
(** Refuse a broker created for a different worker before creating a container.
    The returned callback rejects calls outside [with_observation] before any
    retention or provider invocation, including initialization/tool discovery. *)
val with_observation : t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  on_error:(string -> 'error) ->
  (unit -> (Lane_addon_types.output, 'error) result) ->
  (Lane_addon_types.output, 'error) result
(** Bind sampling requests to the exact host input envelope, and reject the
    returned output if its own model evidence belongs to different inputs.
    Cached answers may be reused for identical inputs. Upstream workers' model
    references remain lineage. The scope is cleared on exceptions/cancellation.
    Concurrent observations on one broker are refused. All evidence reads share
    the package byte envelope, including blobs that are not model requests. *)
val package_response : Mcp_protocol.Sampling.create_message_result ->
  Mcp_protocol.Sampling.create_message_result
(** Remove all callback metadata before exposing a response to a package.
    The original response remains unchanged in host-retained evidence. *)
val create :
  store:Lane_addon_store.t -> package:Lane_addon_types.package ->
  instance_id:string -> route:string ->
  invoke:(route:string -> request:Lane_addon_types.evidence ->
    Mcp_protocol.Sampling.create_message_params ->
    (Mcp_protocol.Sampling.create_message_result, string) result) ->
  unit -> (t, string) result

val retained_receipts : store:Lane_addon_store.t -> instance_id:string -> max_bytes:int ->
  Lane_addon_types.output -> (Yojson.Safe.t list, string) result
(** Resolve only the selected output's row evidence through exact host request
    records. Artifact bytes alone never attest a model invocation. All request,
    outcome, arbitrary evidence and compact receipts share [max_bytes] in total.
    Interrupted journal publication is repaired separately under the initial
    per-file envelope; repair cannot reset the aggregate query allowance.
    Run off-thread. *)
