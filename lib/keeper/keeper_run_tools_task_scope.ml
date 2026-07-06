(** Task-scope tool name helpers extracted from keeper_run_tools.ml.

    Pure helpers for selecting task_id-scoped tools and extracting the
    task_id from a tool input JSON object. *)

let task_scope_tool_names =
  [ "masc_transition"
  ; "keeper_task_done"
  ]
;;

let claim_scope_tool_names = [ "keeper_task_claim" ]

let task_id_scope_of_tool_input ~tool_name input =
  if List.mem tool_name task_scope_tool_names
  then Json_util.get_string_nonempty input "task_id"
  else None
;;

let first_some = Dashboard_utils.first_some
;;

let current_task_id_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

type claim_output_scope_error =
  | Claim_output_json_parse_error of string
  | Claim_output_expected_object of { received : string }

let claim_output_scope_error_to_string = function
  | Claim_output_json_parse_error message -> "json_parse_error: " ^ message
  | Claim_output_expected_object { received } ->
    Printf.sprintf "expected object, received %s" received
;;

let decoded_tool_output_text output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let task_id_scope_of_claim_output_result ~tool_name output_text =
  if not (List.mem tool_name claim_scope_tool_names)
  then Ok None
  else
    let output_text = decoded_tool_output_text output_text in
    match Yojson.Safe.from_string (Safe_ops.sanitize_text_utf8 output_text) with
    | `Assoc fields ->
      Ok
        (match List.assoc_opt "result" fields with
         | Some result ->
           first_some
             (Json_util.get_string_nonempty result "task_id")
             (Json_util.get_string_nonempty (`Assoc fields) "task_id")
         | None -> Json_util.get_string_nonempty (`Assoc fields) "task_id")
    | other ->
      Error (Claim_output_expected_object { received = Json_util.kind_name other })
    | exception Yojson.Json_error message ->
      Error (Claim_output_json_parse_error message)
;;

let task_id_scope_of_claim_output ~tool_name output_text =
  match task_id_scope_of_claim_output_result ~tool_name output_text with
  | Ok task_id -> task_id
  | Error _error -> None
;;

type task_id_scope_report = {
  task_id : string option;
  claim_output_error : claim_output_scope_error option;
}

let task_id_scope_of_tool_call_report ~tool_name ~input ~output_text ~meta =
  match task_id_scope_of_tool_input ~tool_name input with
  | Some task_id -> { task_id = Some task_id; claim_output_error = None }
  | None ->
    (match task_id_scope_of_claim_output_result ~tool_name output_text with
     | Ok claim_task_id ->
       {
         task_id = first_some claim_task_id (current_task_id_of_meta meta);
         claim_output_error = None;
       }
     | Error claim_output_error ->
       {
         task_id = current_task_id_of_meta meta;
         claim_output_error = Some claim_output_error;
       })
;;

let task_id_scope_of_tool_call ~tool_name ~input ~output_text ~meta =
  (task_id_scope_of_tool_call_report ~tool_name ~input ~output_text ~meta).task_id
;;
