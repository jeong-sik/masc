(** Typed, lane-local settlement of active backlog tasks owned by one Keeper. *)

type release_failure =
  { task_id : Keeper_id.Task_id.t
  ; error : Masc_domain.masc_error
  }

type error =
  | Discovery_failed of string
  | Release_failed of
      { released : Keeper_id.Task_id.t list
      ; failures : release_failure list
      }

(** Discover every Claimed/InProgress task owned by [meta], attempt a typed
    system-authority release for each, and return every released task id.
    Discovery failure performs no release.  Release failure is aggregated
    after attempting the whole lane-local ownership set and preserves the ids
    already released so callers can report an explicit partial commit. *)
val release_owned_active_tasks :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  actor:string ->
  reason_tag:string ->
  handoff_context:Masc_domain.task_handoff_context ->
  (Keeper_id.Task_id.t list, error) result

val error_to_string : error -> string
