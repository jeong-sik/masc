(** Private OAS exact-flow resources for one registered Keeper generation. *)

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type t

type 'a current_boundary =
  | Current of 'a
  | Owner_unregistered_deferred

val for_registered
  :  registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> base_path:string
  -> keeper_name:string
  -> surface:surface
  -> (t, string) result

val preference_store : t -> Agent_sdk.Exact_output.flow_preference_store
val scope : t -> Agent_sdk.Exact_output.flow_scope

val with_current
  :  t
  -> registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> (unit -> 'a)
  -> 'a current_boundary
(** Run a generation-sensitive boundary while the Keeper lifecycle key lock is
    held. A retired or replaced owner cannot cross the boundary. *)

val with_librarian_execution_slot
  :  t
  -> capacity:int
  -> (unit -> 'a)
  -> 'a option

val with_librarian_exact_flow_lock : t -> (unit -> 'a) -> 'a

val release_owner
  :  base_path:string
  -> keeper_name:string
  -> expected_lane_id:Keeper_lane.Id.t
  -> unit
(** Retire only the exact registry generation that was removed. *)

val clear : unit -> unit
