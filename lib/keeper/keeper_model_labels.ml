open Keeper_types

let configured_model_labels_of_meta (m : keeper_meta) : string list =
  (* Runtime dispatch must be cascade-catalog authoritative.  Persisted
     [meta.models] and benchmark-canary labels are legacy hints and can carry
     stale provider strings across reconfiguration. *)
  Cascade_runtime.models_of_cascade_name
    (Keeper_cascade_profile.Runtime_name (cascade_name_of_meta m))
