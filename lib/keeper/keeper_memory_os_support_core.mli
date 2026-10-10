(** Pure support maintenance and snapshot calculation. No clock or storage acquisition. *)
open Keeper_memory_os_types
open Keeper_memory_os_current_types

module Identity_map : Map.S with type key = string
val fact_payload : fact -> string
val derivations_supported : Set_util.StringSet.t -> derivation list -> bool
val missing_premises_for : Set_util.StringSet.t -> derivation list -> string list
val support_closure_ids : fact list -> Set_util.StringSet.t
val maintain_supported_facts : fact list -> fact list * support_invalidation list
val merge_basis : basis -> basis -> basis
val make_snapshot_from_maintained : previous:t option -> now:float -> source:source -> facts:fact list -> invalidated:support_invalidation list -> unit -> (t, string) result
val make_snapshot : previous:t option -> now:float -> source:source -> facts:fact list -> unit -> (t, string) result
val insert_or_reobserve : fact list -> fact -> fact list
val upsert_snapshot : previous:t option -> now:float -> source:source -> fact -> (t, upsert_error) result
