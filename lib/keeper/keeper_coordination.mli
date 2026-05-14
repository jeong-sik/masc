(** Keeper_coordination — Coord presence, compaction policy, checkpoint persistence, and error logging for keeper agents. MASC coordination domain. *)

open Keeper_types

val log_keeper_exn : label:string -> exn -> unit

val load_context_from_checkpoint :
  max_checkpoint_messages:int ->
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  Keeper_exec_context.session_context * Keeper_exec_context.working_context option

val save_checkpoint :
  Keeper_exec_context.session_context ->
  Keeper_exec_context.working_context ->
  generation:int ->
  Keeper_exec_context.checkpoint

val compaction_policy_of_keeper : keeper_meta -> float * int * int

val generate_trace_id : ?now:float -> unit -> string

val keeper_board_write_tool_names : string list

val keeper_write_done : string list -> bool

val keeper_action_kind_of_tool_names : string list -> string

val effective_model_labels_for_turn : keeper_meta -> string list

val room_cursor_for : keeper_meta -> string -> int

val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

val room_ids_for_meta : Coord.config -> keeper_meta -> string list

val ensure_keeper_room_presence : Coord.config -> keeper_meta -> keeper_meta
