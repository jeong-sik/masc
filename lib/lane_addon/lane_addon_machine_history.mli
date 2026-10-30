(** Retain worker-owned input prefixes before publishing their observation.
    The caller holds the worker RPC serializer throughout [retain]. *)
type t
val create : unit -> t
val retain : t -> store:Lane_addon_store.t -> instance_id:string -> max_response_bytes:int ->
  call:(name:string -> arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, string) result) ->
  Lane_addon_types.output -> (Lane_addon_types.output, string) result
(** Replaces private [input_history] transfer descriptors with durable
    [input_ledger] evidence. Completed prefixes are reused; only missing records
    are requested. A failed page or durable write leaves the observation
    unpublished and never advances the committed cursor. *)
