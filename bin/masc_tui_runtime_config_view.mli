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
type reading = { path : string; source_text : string; metadata : metadata;
  model_bindings : (Runtime_config_models.t, string) result;
  account_groups : (string list list, string) result;
  account_emails : (Masc_tui_account_login.account_emails, string) result }
type tone = Neutral | Good | Warning | Bad

val decode : Yojson.Safe.t -> (reading, string) result
val decode_source : Yojson.Safe.t -> (reading, string) result
(** Document-only reads retain existing source/status/account observations but
    do not decode unused model rows. Their [model_bindings] result is unavailable;
    only [decode] prepares model evidence for Config snapshots. *)
val summary_lines : ko:bool -> metadata -> (tone * string) list
val source_heading : ko:bool -> string
(** The title of the block that identifies the configuration source. *)
val detail_blocks :
  ko:bool ->
  ?notices:Masc_tui_page_line.t list ->
  lead:Masc_tui_page_line.t list ->
  metadata ->
  (string * Masc_tui_page_line.t list) list
(** Validation and application precede source identifiers and key lists.
    [notices] precede the status facts, including when a failed refresh leaves
    only a retained observation. [lead] opens the source block with what only
    the caller knows, such as the file path. The key block is absent when no
    key is pending, preempted or applied. *)
