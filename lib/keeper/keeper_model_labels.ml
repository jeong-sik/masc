open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let configured_model_labels_of_meta (_m : keeper_meta) : string list =
  (* RFC-0206: default-always — every keeper resolves to the single default
     Runtime's execution labels; no per-meta cascade catalog. *)
  Runtime_model_labels.models ()
