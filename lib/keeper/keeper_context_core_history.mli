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

type history_persist_once_outcome =
  | History_message_persisted
  | History_message_already_persisted

type history_persist_once_error =
  | Invalid_history_idempotency_key
  | History_entry_rejected_by_policy of { source : string }
  | History_append_failed of string
  | History_transaction_settlement_failed of string
  | History_io_failed of string

val history_persist_once_error_to_string : history_persist_once_error -> string

val empty_history_migration_stats : history_migration_stats

val split_jsonl_lines : string -> string list

val normalize_system_context_prefix : string -> string

val has_world_state_signature : string -> bool

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

val classify_history_entry : source:string -> content:string -> history_line_action

val classify_history_jsonl_line : string -> history_line_action option

val render_jsonl_lines : string list -> string

val dedupe_preserve_order : string list -> string list

val migrate_session_history_logs : session_dir:string -> history_migration_stats

val history_path_for_source : session_dir:string -> source:string option -> string

val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit

val persist_message_once :
  idempotency_key:string ->
  ?source:string ->
  session_context ->
  Agent_sdk.Types.message ->
  (history_persist_once_outcome, history_persist_once_error) result
