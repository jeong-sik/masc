type t =
  { failure_class : Tool_result.tool_failure_class
  ; is_workflow_rejection : bool
  ; deterministic_classification :
      Keeper_tool_deterministic_error.classification option
  }

let json_field_string_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let json_field_bool ~default key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Bool value) -> value
     | _ -> default)
  | _ -> default
;;

let failure_class_of_json json =
  if json_field_bool ~default:false "ok" json
  then None
  else
    Option.bind
      (json_field_string_opt "failure_class" json)
      Tool_result.tool_failure_class_of_string
;;

let structured_error_json = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String raw) ->
       (try
          match Yojson.Safe.from_string raw with
          | `Assoc _ as json -> Some json
          | _ -> None
        with
        | Yojson.Json_error _ -> None)
     | _ -> None)
  | _ -> None
;;

let classify_raw_failure raw =
  let json =
    try Some (Yojson.Safe.from_string raw) with
    | Yojson.Json_error _ -> None
  in
  let classification_json =
    match json with
    | Some json ->
      (match failure_class_of_json json with
       | Some _ -> Some json
       | None ->
         (match structured_error_json json with
          | Some nested -> Some nested
          | None -> Some json))
    | None -> None
  in
  let failure_class =
    Option.bind classification_json failure_class_of_json
    |> Option.value ~default:Tool_result.Runtime_failure
  in
  let deterministic_classification =
    if Tool_result.is_retryable failure_class
    then None
    else
      Option.bind
        classification_json
        Keeper_tool_deterministic_error.classify_with_source
  in
  { failure_class
  ; is_workflow_rejection = (failure_class = Tool_result.Workflow_rejection)
  ; deterministic_classification
  }
;;
