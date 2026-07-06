type t =
  { failure_class : Tool_result.tool_failure_class
  ; is_workflow_rejection : bool
  ; deterministic_classification :
      Keeper_tool_deterministic_error.classification option
  ; parse_observations : parse_observation list
  }

and parse_observation =
  | Raw_failure_payload_json_decode_error of string
  | Structured_error_json_decode_error of string
  | Structured_error_json_non_object

let parse_observation_kind = function
  | Raw_failure_payload_json_decode_error _ ->
    "raw_failure_payload_json_decode_error"
  | Structured_error_json_decode_error _ -> "structured_error_json_decode_error"
  | Structured_error_json_non_object -> "structured_error_json_non_object"

let parse_observation_to_json observation =
  let fields = [ "kind", `String (parse_observation_kind observation) ] in
  let fields =
    match observation with
    | Raw_failure_payload_json_decode_error message
    | Structured_error_json_decode_error message ->
      ("message", `String message) :: fields
    | Structured_error_json_non_object -> fields
  in
  `Assoc fields

let parse_observations_json observations =
  `List (List.map parse_observation_to_json observations)

let parse_observation_log_fields t =
  match t.parse_observations with
  | [] -> []
  | observations ->
    [ "failure_boundary_parse_observations", parse_observations_json observations ]

let decode_raw_failure_payload raw =
  match Yojson.Safe.from_string raw with
  | json -> Ok json
  | exception Yojson.Json_error message ->
    Error (Raw_failure_payload_json_decode_error message)


let failure_class_of_json json =
  if Json_util.get_bool json "ok" |> Option.value ~default:false
  then None
  else
    Option.bind
      (Json_util.get_string json "failure_class")
      Tool_result.tool_failure_class_of_string
;;

let structured_error_json = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String raw) ->
       (match Yojson.Safe.from_string raw with
        | `Assoc _ as json -> Some json, []
        | _ -> None, [ Structured_error_json_non_object ]
        | exception Yojson.Json_error message ->
          None, [ Structured_error_json_decode_error message ])
     | _ -> None, [])
  | _ -> None, []
;;

let classify_raw_failure raw =
  let classification_json, parse_observations =
    match decode_raw_failure_payload raw with
    | Ok json ->
      (match failure_class_of_json json with
       | Some _ -> Some json, []
       | None ->
         let nested, parse_observations = structured_error_json json in
         (match nested with
          | Some nested -> Some nested, parse_observations
          | None -> Some json, parse_observations))
    | Error parse_observation -> None, [ parse_observation ]
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
  ; parse_observations
  }
;;
