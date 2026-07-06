open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet : Set.S with type elt = string

type history_migration_stats =
  { moved_lines : int
  ; dropped_lines : int
  ; kept_lines : int
  ; malformed_lines : int
  }

val empty_history_migration_stats : history_migration_stats

val split_jsonl_lines : string -> string list

val normalize_system_context_prefix : string -> string

val has_world_state_signature : string -> bool

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

type history_jsonl_line_error =
  | History_jsonl_malformed_json of string
  | History_jsonl_type_error of string

val history_jsonl_line_error_to_string : history_jsonl_line_error -> string

val classify_history_entry : source:string -> content:string -> history_line_action

val classify_history_jsonl_line_result :
  string -> (history_line_action, history_jsonl_line_error) result

val classify_history_jsonl_line : string -> history_line_action option

val render_jsonl_lines : string list -> string

val dedupe_preserve_order : string list -> string list

val migrate_session_history_logs : session_dir:string -> history_migration_stats

val history_path_for_source : session_dir:string -> source:string option -> string

val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit
