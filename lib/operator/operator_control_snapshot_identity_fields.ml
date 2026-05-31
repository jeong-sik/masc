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

let keeper_runtime_identity_fields (meta : Keeper_meta_contract.keeper_meta) =
  let runtime_name = Keeper_meta_contract.runtime_name_of_meta meta in
  let cascade_name_json =
    Json_util.string_opt_to_json (non_empty_trimmed_string_opt runtime_name)
  in
  (* RFC-0149 §3.3 — use the Result-returning resolver so an unresolved
     cascade surfaces as the original input on the canonical fields
     (matching the degraded-fallback shape below) instead of the silent
     [Keeper_turn] default the legacy [resolve_live] would have written. *)
  let canonical_json =
    match Keeper_cascade_profile.resolve_live_result runtime_name with
    | Ok runtime ->
      `String (runtime)
    | Error (`Unresolved _) -> cascade_name_json
  in
  [ "runtime_name", cascade_name_json
  ; "runtime_canonical", canonical_json
  ; "selected_runtime_canonical", canonical_json
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

let degraded_keeper_runtime_identity_fields (meta : Keeper_meta_contract.keeper_meta) =
  let runtime_name = non_empty_trimmed_string_opt (Keeper_meta_contract.runtime_name_of_meta meta) in
  let cascade_json = Json_util.string_opt_to_json runtime_name in
  [ "runtime_name", cascade_json
  ; "runtime_canonical", cascade_json
  ; "selected_runtime_canonical", cascade_json
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

