(** Keeper runtime identity field builders for the operator control
    snapshot, extracted from [operator_control_snapshot.ml]. Three
    helpers: a trimmed-string predicate, the live identity-fields list
    (with cascade resolution), and the degraded fallback that elides
    the resolved-cascade lookup. *)

open Operator_pending_confirm

let non_empty_trimmed_string_opt = String_util.trim_nonempty
;;

let keeper_runtime_identity_fields (meta : Keeper_types.keeper_meta) =
  let cascade_name = Keeper_types.cascade_name_of_meta meta in
  let cascade_name_json =
    string_option_to_json (non_empty_trimmed_string_opt cascade_name)
  in
  (* RFC-0149 §3.3 — use the Result-returning resolver so an unresolved
     cascade surfaces as the original input on the canonical fields
     (matching the degraded-fallback shape below) instead of the silent
     [Keeper_turn] default the legacy [resolve_live] would have written. *)
  let canonical_json =
    match Keeper_cascade_profile.resolve_live_result cascade_name with
    | Ok runtime ->
      `String (Cascade_name.to_string runtime)
    | Error (`Unresolved _) -> cascade_name_json
  in
  [ "cascade_name", cascade_name_json
  ; "cascade_canonical", canonical_json
  ; "selected_cascade_canonical", canonical_json
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

