(** Keeper_coordination — Room presence, compaction policy, checkpoint persistence, and error logging for keeper agents. MASC coordination domain. *)

open Keeper_types

val log_keeper_exn : label:string -> exn -> unit

val load_context_from_checkpoint :
  trace_id:string ->
  primary_model_max_tokens:int ->
  base_dir:string ->
  Context_manager.session_context * Context_manager.working_context option

val save_checkpoint :
  Context_manager.session_context ->
  Context_manager.working_context ->
  generation:int ->
  Context_manager.checkpoint

val compaction_policy_of_keeper : keeper_meta -> float * int * int

val compact_if_needed :
  meta:keeper_meta ->
  now_ts:float ->
  Context_manager.working_context ->
  Context_manager.working_context * string option * string

val generate_trace_id : unit -> string

val keeper_board_write_tool_names : string list

val keeper_write_done : string list -> bool

val keeper_action_kind_of_tool_names : string list -> string

val effective_model_labels_for_turn :
  keeper_meta -> inline_models:string list -> string list

val room_cursor_for : keeper_meta -> string -> int

val set_room_cursor : keeper_meta -> string -> int -> keeper_meta

val room_ids_for_meta : Room.config -> keeper_meta -> string list

val ensure_keeper_room_presence : Room.config -> keeper_meta -> keeper_meta
