(** Coord_task_claim — claim_task, claim_task_r, release/reclaim helpers.

    This module is [include]d by {!Coord_task}; all bindings are part of
    the public Coord interface.  Re-exports {!Coord_utils} and
    {!Coord_state}. *)

include module type of Coord_utils
include module type of Coord_state

(** {1 Reclaim helpers} *)

val is_legacy_auto_cycle_do_not_reclaim_reason : string -> bool

val do_not_reclaim_reason_blocks_claim : string option -> string option
(** Returns [Some reason] only when [reason] is an explicit hard-stop that
    should still block claiming. Legacy automatic cycle reasons such as
    ["auto: 3 releases"] are treated as soft and return [None]. *)

val clear_soft_do_not_reclaim_reason : Types.task -> Types.task
(** Clears legacy automatic cycle block reasons before a task is claimed. *)

(** {1 Task claiming} *)

val claim_task :
  config -> agent_name:string -> task_id:string -> string

val claim_task_r :
  config -> agent_name:string -> task_id:string ->
  ?agent_tool_names:string list -> unit -> string Types.masc_result

(** {1 Release/reclaim helpers} *)

val release_handoff_texts : Types.task_handoff_context option -> string list

val release_hard_stop_markers : string list

val release_should_block_reclaim : Types.task_handoff_context option -> bool

val derive_release_do_not_reclaim_reason :
  Types.task -> Types.task_handoff_context option -> string option
