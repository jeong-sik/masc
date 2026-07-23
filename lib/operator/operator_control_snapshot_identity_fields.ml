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
  let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
  let runtime_id_json =
    Json_util.string_opt_to_json (non_empty_trimmed_string_opt runtime_id)
  in
  (* RFC-0149 §3.3 — use the Result-returning resolver so an unresolved
     runtime surfaces as the original input on the canonical fields
     (matching the degraded-fallback shape below) instead of the silent
     [Keeper_turn] default the legacy [resolve_live] would have written. *)
  let canonical_json = runtime_id_json in
  let active_model = Keeper_status_runtime.active_model_of_meta meta in
  let active_model_label = Keeper_status_runtime.active_model_label_of_meta meta in
  [ "runtime_id", runtime_id_json
  ; "runtime_canonical", canonical_json
  ; "selected_runtime_canonical", canonical_json
  ; "primary_model", `String runtime_id
  ; "active_model", `String active_model
  ; "active_model_label", `String active_model_label
  ; "last_model_used_label", `String active_model_label
  ]
;;
