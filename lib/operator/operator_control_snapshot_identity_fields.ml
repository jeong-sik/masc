(** Keeper runtime identity field builders for the operator control
    snapshot, extracted from [operator_control_snapshot.ml]. Three
    helpers: a trimmed-string predicate, the live identity-fields list
    (with cascade resolution), and the degraded fallback that elides
    the resolved-cascade lookup. *)

open Operator_pending_confirm

let non_empty_trimmed_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let keeper_runtime_identity_fields (meta : Keeper_types.keeper_meta) =
  let cascade_name = Keeper_types.cascade_name_of_meta meta in
  let effective_cascade = Keeper_cascade_profile.resolve_live cascade_name in
  [ "cascade_name", string_option_to_json (non_empty_trimmed_string_opt cascade_name)
  ; "cascade_canonical", `String effective_cascade
  ; "selected_cascade_canonical", `String effective_cascade
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

let degraded_keeper_runtime_identity_fields (meta : Keeper_types.keeper_meta) =
  let cascade_name = non_empty_trimmed_string_opt (Keeper_types.cascade_name_of_meta meta) in
  let cascade_json = string_option_to_json cascade_name in
  [ "cascade_name", cascade_json
  ; "cascade_canonical", cascade_json
  ; "selected_cascade_canonical", cascade_json
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

