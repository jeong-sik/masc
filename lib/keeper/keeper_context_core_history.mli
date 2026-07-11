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

type history_migration_stage =
  | Internal_history
  | Main_history

type history_migration_error =
  | History_write_not_committed of
      { stage : history_migration_stage
      ; path : string
      ; report : unit Fs_compat.Durable_mutation.report
      }
  | History_write_committed_not_durable of
      { stage : history_migration_stage
      ; path : string
      ; report : unit Fs_compat.Durable_mutation.report
      }
  | History_directory_durability_not_confirmed of
      { stage : history_migration_stage
      ; path : string
      ; report : Fs_compat.Durable_mutation.durability_confirmation_report
      }

val history_migration_error_to_string : history_migration_error -> string

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

val migrate_session_history_logs_blocking :
  session_dir:string -> (history_migration_stats, history_migration_error) result

val migrate_session_history_logs_eio :
  session_dir:string -> (history_migration_stats, history_migration_error) result

module For_testing : sig
  val migrate_session_history_logs_with :
    ?confirm_parent_durable:
      (string -> Fs_compat.Durable_mutation.durability_confirmation_report) ->
    (string -> string -> unit Fs_compat.Durable_mutation.report) ->
    session_dir:string ->
    (history_migration_stats, history_migration_error) result
end

val history_path_for_source : session_dir:string -> source:string option -> string

val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit
