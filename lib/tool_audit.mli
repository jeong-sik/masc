(** Tool_audit - Audit query, statistics, and governance report handlers *)

type context = {
  config: Room.config;
}

(** Audit event record *)
type audit_event = {
  timestamp: float;
  agent: string;
  event_type: string;
  success: bool;
  detail: string option;
  details: Yojson.Safe.t option;
}

(** {1 Governance Report Types} *)

type agent_summary = {
  agent_id : string;
  action_count : int;
  action_types : (string * int) list;
  total_cost : float;
  total_tokens : int;
  failure_rate : float;
}

type governance_report = {
  period_start : string;
  period_end : string;
  agents : agent_summary list;
  total_actions : int;
  total_cost : float;
  total_tokens : int;
  overall_failure_rate : float;
}

(** Dispatch handler. Returns Some (success, result) if handled, None otherwise *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

(** Read audit events since given timestamp *)
val read_audit_events : Room.config -> since:float -> audit_event list

(** Convert audit event to JSON *)
val audit_event_to_json : audit_event -> Yojson.Safe.t

(** Handle masc_audit_query *)
val handle_audit_query : context -> Yojson.Safe.t -> bool * string

(** Handle masc_audit_stats *)
val handle_audit_stats : context -> Yojson.Safe.t -> bool * string

(** Handle masc_audit_trail — query linked audit entries by trace_id *)
val handle_audit_trail : context -> Yojson.Safe.t -> bool * string

(** Generate governance summary from audit trail entries *)
val governance_summary : ?since:string -> ?until_time:string -> Audit_log.audit_entry list -> governance_report

(** Convert governance report to JSON *)
val report_to_json : governance_report -> Yojson.Safe.t

(** Tool schemas for MCP tools/list *)
val schemas : Types.tool_schema list
