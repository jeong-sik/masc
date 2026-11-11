(** Typed Agent Core payloads and observation invalidations carried by SSE.

    [Types] and [Json] are generated from [sse_event.atd]. The dashboard's
    TypeScript decoders are generated from the same file. The envelope around a
    payload is built by [Keeper_event_bridge.wrap_event]. *)

(** The generated payload types and their JSON readers and writers. A decoder
    of these events outside the server reads them with these rather than with
    a copy of the field names, so the two sides share one contract. *)
module Types = Sse_event_t

module Json = Sse_event_j

val dashboard_observation_changed_payload_to_json
  : Types.dashboard_observation_changed_payload -> Yojson.Safe.t

val dashboard_observation_changed_payload_of_json
  : Yojson.Safe.t -> (Types.dashboard_observation_changed_payload, string) result
(** Decode the shared topic contract. Unknown topics and non-null empty scope
    identifiers are rejected rather than interpreted as workspace changes. *)

(** Encode the typed [agent_failed] payload without an envelope. Adapter
    boundaries that own a richer canonical envelope can reuse the schema
    encoder without decoding or rebuilding its fields. *)
val agent_failed_payload
  :  agent_name:string
  -> task_id:string
  -> elapsed_s:float
  -> error:string
  -> error_domain:string
  -> error_code:string
  -> error_retryable:bool
  -> error_detail:Yojson.Safe.t
  -> Yojson.Safe.t
