open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let configured_model_labels_of_meta (m : keeper_meta) : string list =
  (* Runtime dispatch must be cascade-catalog authoritative.  Persisted
     [meta.models] and benchmark-canary labels are legacy hints and can carry
     stale provider strings across reconfiguration. *)
  Provider_runtime_projection.default_execution_model_strings
    ((runtime_name_of_meta m))
