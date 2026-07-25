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

type retirement_boundary =
  | Retirement_draining
  | Retirement_not_allocated
  | Retirement_owner_replaced

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

val with_settlement
  :  t
  -> registered_lane_id:(unit -> Keeper_lane.Id.t option)
  -> (unit -> 'a)
  -> 'a current_boundary
(** Finish an already-bound generation while its owner is [Active] or
    [Draining]. It never admits a new dispatch. *)

val with_librarian_execution_slot
  :  t
  -> capacity:int
  -> (unit -> 'a)
  -> 'a option

val begin_retirement
  :  base_path:string
  -> keeper_name:string
  -> expected_lane_id:Keeper_lane.Id.t
  -> retirement_boundary
(** Atomically stop admission for one registered generation without removing
    its registry identity. Already-bound work may still cross
    {!with_settlement}. *)

val release_owner
  :  base_path:string
  -> keeper_name:string
  -> expected_lane_id:Keeper_lane.Id.t
  -> unit
(** Retire only the exact registry generation that was removed. *)

val clear : unit -> unit
