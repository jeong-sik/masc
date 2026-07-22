(** Immutable OAS exact-output publication for MASC runtime routing. *)

type t
type error
type prepared_replacement

type selected_slot =
  { slot_id : string
  ; target : Agent_sdk.Exact_output.selected_target
  }

val publish
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> Agent_sdk.Exact_output.resolver_snapshot
  -> (t, error) result
(** Validate and atomically publish one complete resolver-and-lane registry.
    Each successful publication advances the MASC-local generation
    monotonically. Invalid declarations are rejected before the Atomic is
    changed. *)

val prepare_replacement
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> (prepared_replacement, error) result
(** Validate a replacement against the resolver frozen in the currently
    published registry without changing the active generation. *)

val publish_prepared : prepared_replacement -> t
(** Atomically publish a previously validated replacement. This operation has
    no ordinary failure channel and advances the generation monotonically. *)

val current : unit -> (t, error) result
(** Return the currently published registry, or a typed error before bootstrap
    has published one. *)

val generation : t -> int64

val lane_slots : t -> lane_id:string -> (string list, error) result
(** Return one lane's opaque target refs in declaration order from exactly the
    supplied registry generation. *)

val resolve_slots : t -> string list -> (selected_slot, error) result list
(** Resolve an ordered set of opaque slot ids against exactly the supplied
    registry generation. Every input slot produces one outcome in declaration
    order, so a selection failure cannot erase later failover candidates. *)

val error_to_string : error -> string
