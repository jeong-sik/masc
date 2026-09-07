type severity =
  | Warn
  | Bad
  | Critical

type recoverability =
  | Operator_action_required
  | Fatal

type tool_host_cause =
  | Tool_host_timeout
  | Tool_host_transport_unavailable

type t = {
  surface : string;
  entity_kind : string;
  entity_id : string option;
  cause_code : string;
  severity : severity;
  summary : string;
  recoverability : recoverability;
  operator_action : string option;
  evidence_ref : Yojson.Safe.t;
}

val tool_host_log_module_name : string
val tool_host_cause_code : tool_host_cause -> string
val tool_host_cause_of_code : string -> (tool_host_cause, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val attach_to_details : Yojson.Safe.t -> t -> Yojson.Safe.t
val find_in_json : Yojson.Safe.t -> t option

val tool_host_failure :
  agent_name:string ->
  client_name:string ->
  tool_name:string ->
  transport:string ->
  ?phase:string ->
  ?request_id:string ->
  ?session_id:string ->
  ?trace_id:string ->
  ?timeout_ms:int ->
  cause:tool_host_cause ->
  message:string ->
  unit ->
  t
