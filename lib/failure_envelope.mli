type severity =
  | Warn
  | Bad
  | Critical

type recoverability =
  | Retryable
  | Operator_action_required
  | Fatal

type t =
  { surface : string
  ; entity_kind : string
  ; entity_id : string option
  ; cause_code : string
  ; severity : severity
  ; summary : string
  ; recoverability : recoverability
  ; operator_action : string option
  ; evidence_ref : Yojson.Safe.t
  }

val tool_host_log_module_name : string
val severity_to_string : severity -> string
val to_severity : severity -> Severity.t
val recoverability_to_string : recoverability -> string
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val attach_to_details : Yojson.Safe.t -> t -> Yojson.Safe.t
val find_in_json : Yojson.Safe.t -> t option

val tool_host_failure
  :  agent_name:string
  -> client_name:string
  -> tool_name:string
  -> transport:string
  -> ?phase:string
  -> ?request_id:string
  -> ?session_id:string
  -> ?trace_id:string
  -> ?timeout_ms:int
  -> message:string
  -> unit
  -> t
