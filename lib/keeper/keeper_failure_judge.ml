type run_error =
  | Runtime_configuration_error of string
  | Prompt_contract_error of string
  | Oas_error of
      { runtime_id : string
      ; error : Agent_sdk.Error.sdk_error
      }
  | Response_contract_error of
      { runtime_id : string
      ; detail : string
      }

type run_result =
  { runtime_id : string
  ; verdict : Keeper_failure_judgment_contract.verdict
  }

type error_disposition = Escalate_judge_failure

let prompt_name = Keeper_prompt_names.failure_judgment
let schema_name = "keeper_failure_judgment"

let error_detail = function
  | Runtime_configuration_error detail ->
    Printf.sprintf "failure judgment runtime configuration: %s" detail
  | Prompt_contract_error detail ->
    Printf.sprintf "failure judgment prompt contract: %s" detail
  | Oas_error { runtime_id; error } ->
    Printf.sprintf
      "failure judgment OAS runtime %s: %s"
      runtime_id
      (Agent_sdk.Error.to_string error)
  | Response_contract_error { runtime_id; detail } ->
    Printf.sprintf
      "failure judgment response contract on runtime %s: %s"
      runtime_id
      detail
;;

let error_disposition _ = Escalate_judge_failure

let error_disposition_label = function
  | Escalate_judge_failure -> "escalate_judge_failure"
;;

let request_json ~keeper_name (request : Keeper_event_queue.failure_judgment) =
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "failed_runtime_id", `String request.fj_runtime_id
    ; ( "judgment_class"
      , `String
          (Keeper_runtime_failure_route.judgment_class_label request.fj_judgment) )
    ; ( "failure_provenance"
      , Keeper_runtime_failure_route.judgment_provenance_to_yojson
          request.fj_provenance )
    ; "failure_detail", `String request.fj_detail
    ]
;;

let build_prompt ~keeper_name request =
  Prompt_registry.render_prompt_template
    prompt_name
    [ "failure_request_json", Yojson.Safe.to_string (request_json ~keeper_name request) ]
;;

let apply_output_schema provider_config =
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"keeper failure judgment output contract"
       Keeper_structured_output_schema.failure_judgment_output_schema
       provider_config)
;;

let reject_unregistered_tool ~name ~args:_ =
  Tool_result.error
    ~tool_name:name
    ~start_time:(Time_compat.now ())
    "failure judgment is a tool-free boundary"
;;

let resolve_runtime_id () =
  match Runtime.runtime_id_for_structured_judge () with
  | runtime_id -> Ok runtime_id
  | exception Failure detail -> Error (Runtime_configuration_error detail)
;;

let parse_response ~runtime_id response =
  match
    Agent_sdk_response.structured_json_of_response ~schema_name response
  with
  | Error detail -> Error (Response_contract_error { runtime_id; detail })
  | Ok json ->
    (match Keeper_failure_judgment_contract.of_yojson json with
     | Ok verdict -> Ok verdict
     | Error detail -> Error (Response_contract_error { runtime_id; detail }))
;;

let run ~keeper_name request =
  match resolve_runtime_id () with
  | Error _ as error -> error
  | Ok runtime_id ->
    (match build_prompt ~keeper_name request with
     | Error detail -> Error (Prompt_contract_error detail)
     | Ok prompt ->
       (match
          Keeper_turn_driver_wrappers.run_named_with_masc_tools
            ~runtime_id
            ~keeper_name
            ~goal:prompt
            ~masc_tools:[]
            ~dispatch:reject_unregistered_tool
            ~temperature:Runtime_provider_defaults.deterministic_temperature
            ~provider_config_transform:apply_output_schema
            ()
        with
        | Error error -> Error (Oas_error { runtime_id; error })
        | Ok result ->
          (match parse_response ~runtime_id result.response with
           | Error _ as error -> error
           | Ok verdict -> Ok { runtime_id; verdict })))
;;
