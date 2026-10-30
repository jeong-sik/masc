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

(** A tool-host failure on one tool call. The JSON carries
    [surface = "tool_host"] and [entity_kind = "tool_call"]; {!of_yojson}
    refuses any other value for either, as it refuses a [cause_code] that is
    not a tool-host cause. *)
type t = {
  entity_id : string option;
  cause : tool_host_cause;
      (** Written as [cause_code] ({!tool_host_cause_code}). Decoding refuses a
          code that is not a tool host cause. *)
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
