(** Workspace task scheduling — claim pool state and the [claim_next] entry. *)

open! Workspace_utils

val task_status_label : Masc_domain.task_status -> string
val task_is_claim_pool_candidate : Masc_domain.task -> bool

val claim_next_r
  :  config
  -> agent_name:string
  -> ?auto_start:bool
       (** When [true], atomically transitions the claimed task (or an already
           held [Claimed] task) to [InProgress] inside the same [.backlog]
           lock and commit. Default [false]. *)
  -> unit
  -> Masc_domain.claim_next_result
