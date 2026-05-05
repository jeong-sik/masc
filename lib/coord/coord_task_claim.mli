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
    ["auto: 3 releases"] and routing handoff reasons such as tool-surface or
    sandbox mismatch are treated as soft and return [None]. *)

val clear_soft_do_not_reclaim_reason : Masc_domain.task -> Masc_domain.task
(** Clears soft cycle/routing reasons before a task is claimed. *)

(** {1 Task claiming} *)

val claim_task :
  config -> agent_name:string -> task_id:string -> string

val claim_task_r :
  config -> agent_name:string -> task_id:string ->
  ?agent_tool_names:string list -> unit -> string Masc_domain.masc_result

(** {1 Release/reclaim helpers} *)

val release_handoff_texts : Masc_domain.task_handoff_context option -> string list

val release_hard_stop_markers : string list

val release_should_block_reclaim : Masc_domain.task_handoff_context option -> bool

val derive_release_do_not_reclaim_reason :
  Masc_domain.task -> Masc_domain.task_handoff_context option -> string option
