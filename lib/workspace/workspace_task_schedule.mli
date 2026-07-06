(** Workspace task scheduling — claim pool gating, verification block
    state, and the [claim_next] / [release_stale_claims] entries. *)

open Masc_domain
include module type of Workspace_utils
include module type of Workspace_state

val task_status_label : Masc_domain.task_status -> string
val task_is_claim_pool_candidate : Masc_domain.task -> bool

(* RFC-0220 §3.2: claim-pool verification gate functions removed
   (verification no longer gates the claim pool). *)

val underscore_name : string -> string
val hyphen_name : string -> string
val keeper_name_from_agent_name : string -> string option
type receipt_read_error = Workspace_task_receipts.receipt_read_error =
  | Agent_record_read_failed of { path : string; message : string }
  | Directory_stat_failed of { path : string; message : string }
  | Directory_list_failed of { path : string; message : string }
  | Receipt_line_read_failed of { path : string; message : string }
  | Receipt_json_parse_failed of { path : string; message : string }

val receipt_read_error_to_string : receipt_read_error -> string
val agent_record_keeper_name_result :
  config -> agent_name:string -> (string option, receipt_read_error) result

val agent_record_keeper_name : config -> agent_name:string -> string option
val keeper_receipt_candidate_names_result :
  config -> agent_name:string -> (string list, receipt_read_error) result

val keeper_receipt_candidate_names : config -> agent_name:string -> string list
val directory_exists_result : string -> (bool, receipt_read_error) result
val directory_exists : string -> bool
val directory_entries_result : string -> (string list, receipt_read_error) result
val directory_entries : string -> string list
val jsonl_files_under_result : string -> (string list, receipt_read_error) result
val jsonl_files_under : string -> string list
val last_nonempty_line_result : string -> (string option, receipt_read_error) result
val last_nonempty_line : string -> string option
val latest_json_in_receipt_dir_result
  :  string
  -> (Yojson.Safe.t option, receipt_read_error) result

val latest_json_in_receipt_dir : string -> Yojson.Safe.t option
val json_member_path : string list -> Yojson.Safe.t -> Yojson.Safe.t
val json_raw_string_path : string list -> Yojson.Safe.t -> string option
val json_string_path : string list -> Yojson.Safe.t -> string option
val receipt_sort_key : Yojson.Safe.t -> string
val latest_execution_receipt_json_result
  :  config
  -> agent_name:string
  -> (Yojson.Safe.t option, receipt_read_error) result

val latest_execution_receipt_json : config -> agent_name:string -> Yojson.Safe.t option

val active_task_assignees_by_task_id : Masc_domain.backlog -> (string, string) Hashtbl.t

val agent_current_task_matches_assignments
  :  (string, string) Hashtbl.t
  -> agent_name:string
  -> string
  -> bool

val agent_current_task_matches_backlog
  :  Masc_domain.backlog
  -> agent_name:string
  -> string
  -> bool

val reconcile_agent_current_task_with_backlog
  :  config
  -> ?touch_last_seen:bool
  -> agent_name:string
  -> Masc_domain.backlog
  -> unit

val reconcile_agent_current_task_with_backlog_result
  :  config
  -> ?touch_last_seen:bool
  -> agent_name:string
  -> Masc_domain.backlog
  -> (unit, string) result

val reconcile_all_agent_current_tasks_with_backlog
  :  config
  -> ?touch_last_seen:bool
  -> Masc_domain.backlog
  -> unit

val reconcile_all_agent_current_tasks_with_backlog_result
  :  config
  -> ?touch_last_seen:bool
  -> Masc_domain.backlog
  -> (unit, string) result

val reconcile_all_agent_current_tasks_with_fresh_backlog
  :  ?touch_last_seen:bool
  -> config
  -> Masc_domain.backlog

val reconcile_all_agent_current_tasks_with_fresh_backlog_result
  :  ?touch_last_seen:bool
  -> config
  -> (Masc_domain.backlog, string) result

val claim_next_r
  :  config
  -> agent_name:string
  -> ?exclude_task_ids:string list
  -> ?task_filter:(Masc_domain.task -> bool)
  -> ?allow_scope_fallback:bool
       (** When [true] and no goal-scoped task passes [task_filter], widen the
           claim pool to all_tasks. Result carries [scope_widened = true].
           Default [false] preserves the hard scope. *)
  -> unit
  -> Masc_domain.claim_next_result

val claim_next : config -> agent_name:string -> string
val release_stale_claims_result :
  config -> ttl_seconds:float -> ((string * string) list, string) result

val release_stale_claims : config -> ttl_seconds:float -> (string * string) list
