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

(* config/prompts/keeper.failure_judgment.md states the contract more tightly
   than the schema can: it fixes the exact field set and couples decision to
   guidance (null for await_external_input, non-empty otherwise), which JSON
   Schema cannot express without oneOf. Keeper_failure_judgment_contract
   re-checks every one of those on the way in. *)
let apply_output_schema provider_config =
  Ok (Keeper_structured_output_schema.without_response_format provider_config)
;;

let reject_unregistered_tool ~name ~args:_ =
  Tool_result.error
    ~tool_name:name
    ~start_time:(Time_compat.now ())
    "failure judgment is a tool-free boundary"
;;

(* The configured [runtime].structured_judge value may name a lane or a single
   runtime, the same two-shape identity [runtime].cross_verifier moved to on
   2026-07-25 (runtime.toml: "cross_verifier 는 단일 runtime id 대신 lane 을 받는다").
   Resolving it here yields the ordered candidate list the walk in {!run} needs; a
   single runtime is a one-element list, so both shapes take one code path. *)
let resolve_candidates () =
  match Runtime.runtime_id_for_structured_judge () with
  | exception Failure detail -> Error (Runtime_configuration_error detail)
  | configured ->
    (match Runtime.resolve_assignment configured with
     | `Single_runtime _ -> Ok [ configured ]
     | `Lane lane ->
       (match Runtime_lane.ordered_candidates lane with
        | [] ->
          Error
            (Runtime_configuration_error
               (Printf.sprintf
                  "failure judgment lane %s resolves to no candidate"
                  configured))
        | candidates -> Ok candidates)
     | `Missing ->
       Error
         (Runtime_configuration_error
            (Printf.sprintf
               "failure judgment runtime %s names neither a runtime nor a lane"
               configured)))
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

let attempt_candidate ~base_path ~keeper_name ~prompt runtime_id =
  match
    Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~runtime_id
      ~keeper_name
      ~goal:prompt
      ~base_path
      ~masc_tools:[]
      ~dispatch:reject_unregistered_tool
      ~provider_config_transform:apply_output_schema
      ()
  with
  | Error error -> Error (Oas_error { runtime_id; error })
  | Ok result ->
    (match parse_response ~runtime_id result.response with
     | Error _ as error -> error
     | Ok verdict -> Ok { runtime_id; verdict })
;;

(* Only a response-contract failure advances the walk, and the reason is what the
   error means rather than a preference for fewer failures. The request states its
   object shape in the prompt and asks the provider for no wire format
   ([apply_output_schema] clears both structured-output fields), so whether the
   reply parses is that runtime's formatting behaviour: keeper rondo settled its
   lane on `Invalid token '```json` from glm-coding.glm-5-turbo (event-queue.json
   last_settlement, 2026-07-25T10:44Z) and re-asking the same runtime would fence
   again. Another candidate is a different behaviour, so the refusal orders instead
   of ending the walk.

   The other three classes do not advance. A prompt-contract error is the same for
   every candidate; a runtime-configuration error is about the configured identity,
   not the runtime that answered; and an [Oas_error] has already been through OAS's
   own candidate handling, so re-walking it here would dispatch the same turn twice
   for one stimulus. *)
let advances_walk = function
  | Response_contract_error _ -> true
  | Runtime_configuration_error _ | Prompt_contract_error _ | Oas_error _ -> false
;;

let run ~base_path ~keeper_name request =
  match resolve_candidates () with
  | Error _ as error -> error
  | Ok candidates ->
    (match build_prompt ~keeper_name request with
     | Error detail -> Error (Prompt_contract_error detail)
     | Ok prompt ->
       let rec walk = function
         | [] ->
           (* [resolve_candidates] rejects an empty list, so the walk always holds
              at least one candidate and this is unreachable rather than a silent
              default. *)
           Error
             (Runtime_configuration_error
                "failure judgment walk reached an empty candidate list")
         | runtime_id :: rest ->
           (match attempt_candidate ~base_path ~keeper_name ~prompt runtime_id with
            | Error error when advances_walk error && rest <> [] -> walk rest
            | (Ok _ | Error _) as outcome -> outcome)
       in
       walk candidates)
;;
