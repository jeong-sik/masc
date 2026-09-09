(** Server-owned runtime.toml read: source and status travel together. This is
    distinct from a write receipt, whose commit/skill fields do not exist on GET. *)
type routing_state = Routing_active | Routing_applied
type keeper_state = Not_configured | Pending_restart | Applied | Preempted_by_env | Mixed | Invalid_configuration
type severity = Error_issue | Warning_issue
type issue_kind = Invalid_schema_version | Unknown_key | Type_mismatch | Out_of_range
type issue = { key : string; kind : issue_kind; severity : severity; detail : string }
type validation =
  | Parse_error of string
  | Checked of {
      valid : bool; schema_version : int; current_schema_version : int;
      forward_schema : bool; issues : issue list;
    }
type metadata = {
  source_revision : string;
  validation : validation;
  routing : routing_state;
  routing_requires_restart : bool;
  keeper : keeper_state;
  keeper_requires_restart : bool;
  configured_count : int;
  pending_keys : string list;
  applied_keys : string list;
  preempted_keys : string list;
}
type reading = { path : string; source_text : string; metadata : metadata }
type tone = Neutral | Good | Warning | Bad

val decode : Yojson.Safe.t -> (reading, string) result
val summary_lines : metadata -> (tone * string) list
val detail_lines : metadata -> (tone * string) list
