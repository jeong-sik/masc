(** Keeper runtime identity field builders for the operator control
    snapshot, extracted from [operator_control_snapshot.ml]. Three
    helpers: a trimmed-string predicate, the live identity-fields list
    (with runtime resolution), and the degraded fallback that elides
    the resolved-runtime lookup. *)

open Operator_pending_confirm

let non_empty_trimmed_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let keeper_runtime_identity_fields (meta : Keeper_meta_contract.keeper_meta) =
  let cascade_name = Keeper_meta_contract.runtime_id_of_meta meta in
  let cascade_name_json =
    Json_util.string_opt_to_json (non_empty_trimmed_string_opt cascade_name)
  in
  (* RFC-0149 §3.3 — use the Result-returning resolver so an unresolved
     runtime surfaces as the original input on the canonical fields
     (matching the degraded-fallback shape below) instead of the silent
     [Keeper_turn] default the legacy [resolve_live] would have written. *)
  let canonical_json =
    match Keeper_cascade_profile.resolve_live_result cascade_name with
    | Ok runtime ->
      `String (runtime)
    | Error (`Unresolved _) -> cascade_name_json
  in
  [ "runtime_id", cascade_name_json
  ; "runtime_canonical", canonical_json
  ; "selected_runtime_canonical", canonical_json
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

let degraded_keeper_runtime_identity_fields (meta : Keeper_meta_contract.keeper_meta) =
  let cascade_name = non_empty_trimmed_string_opt (Keeper_meta_contract.runtime_id_of_meta meta) in
  let cascade_json = Json_util.string_opt_to_json cascade_name in
  [ "runtime_id", cascade_json
  ; "runtime_canonical", cascade_json
  ; "selected_runtime_canonical", cascade_json
  ; "primary_model", `Null
  ; "active_model", `Null
  ; "active_model_label", `Null
  ; "last_model_used_label", `Null
  ]
;;

