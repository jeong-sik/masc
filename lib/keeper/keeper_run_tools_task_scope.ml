(** Task-scope tool name helpers extracted from keeper_run_tools.ml.

    Pure helpers for selecting task_id-scoped tools and extracting the
    task_id from a tool input JSON object. *)

let task_scope_tool_names =
  [ "masc_transition"
  ; "keeper_task_done"
  ; "keeper_task_submit_for_verification"
  ; "keeper_task_force_done"
  ; "keeper_task_force_release"
  ]
;;

let json_string_opt name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
     | _ -> None)
  | _ -> None
;;

let task_id_scope_of_tool_input ~tool_name input =
  if List.mem tool_name task_scope_tool_names
  then json_string_opt "task_id" input
  else None
;;

let current_task_id_of_meta (meta : Keeper_types.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

let task_id_scope_of_claim_output ~tool_name output_text =
  if not (List.mem tool_name [ "keeper_task_claim"; "masc_claim_next" ])
  then None
  else (
    let output_text =
      match Tool_output.decode_from_oas output_text with
      | Tool_output.Stored { preview; _ } -> preview
      | Tool_output.Inline value -> value
    in
    try
      match Yojson.Safe.from_string (Safe_ops.sanitize_text_utf8 output_text) with
      | `Assoc fields ->
        (match List.assoc_opt "result" fields with
         | Some result ->
           Common.first_some (json_string_opt "task_id" result) (json_string_opt "task_id" (`Assoc fields))
         | None -> json_string_opt "task_id" (`Assoc fields))
      | _ -> None
    with
    | Yojson.Json_error _ -> None)
;;

let task_id_scope_of_tool_call ~tool_name ~input ~output_text ~meta =
  Common.first_some
    (task_id_scope_of_tool_input ~tool_name input)
    (Common.first_some
       (task_id_scope_of_claim_output ~tool_name output_text)
       (current_task_id_of_meta meta))
;;
