let ( let* ) = Result.bind

type success =
  { goal : Goal_store.goal
  ; evaluator_runtime : string
  ; reviewed_at : string
  }

type failure =
  | Rejected of
      { reason : string
      ; evaluator_runtime : string
      }
  | Unavailable of
      { reason : string
      ; evaluator_runtime : string
      }
  | Conflict of string
  | Persistence_failed of string

let report_tool_name = "report_goal_completion_verdict"

let report_tool_input_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "verdict"
            , `Assoc
                [ "type", `String "string"
                ; "enum", `List [ `String "APPROVE"; `String "REJECT" ]
                ] )
          ; ( "reason"
            , `Assoc
                [ "type", `String "string"
                ; "minLength", `Int 1
                ] )
          ] )
    ; "required", `List [ `String "verdict" ]
    ; "additionalProperties", `Bool false
    ]
;;

let report_tool_schema : Masc_domain.tool_schema =
  { name = report_tool_name
  ; description =
      "Report exactly one evidence-based Goal completion verdict. APPROVE must omit reason; REJECT must include it."
  ; input_schema = report_tool_input_schema
  }
;;

let evaluator_route () =
  let route_id =
    match Runtime.cross_verifier_runtime_id () with
    | Some route_id -> route_id
    | None -> Runtime.get_default_runtime_id ()
  in
  if String.trim route_id = ""
  then Error "Goal completion evaluator runtime is not configured"
  else Ok route_id
;;

let build_prompt snapshot =
  let evidence =
    `Assoc
      [ "workspace_identity", `String (Goal_state_internal.snapshot_workspace_identity snapshot)
      ; "goal", Goal_state_internal.snapshot_goal_json snapshot
      ; "completion_claim", `String (Goal_state_internal.snapshot_completion_claim snapshot)
      ; "requesting_agent", `String (Goal_state_internal.snapshot_requesting_agent snapshot)
      ; "linked_tasks", Goal_state_internal.snapshot_linked_tasks_json snapshot
      ; ( "linked_task_ids"
        , `List
            (List.map
               (fun id -> `String id)
               (Goal_state_internal.snapshot_linked_task_ids snapshot)) )
      ; "child_goals", Goal_state_internal.snapshot_child_goals_json snapshot
      ]
  in
  let* evidence = Goal_completion_contract.canonical_string evidence in
  Ok
    ("Judge whether the Goal is actually complete from the supplied current evidence. "
     ^ "Do not infer missing evidence. Call report_goal_completion_verdict exactly once. "
     ^ "Use APPROVE only when the completion claim and linked work prove the Goal; otherwise REJECT with a reason.\n\n"
     ^ evidence)
;;

let prompt_sha256 prompt =
  Digestif.SHA256.digest_string prompt |> Digestif.SHA256.to_hex
;;

let run_reviewer ~config ~runtime_id ~prompt =
  let verdict_ref = ref None in
  let protocol_error_ref = ref None in
  let dispatch ~name ~args =
    let start_time = Time_compat.now () in
    if not (String.equal name report_tool_name) then
      Tool_result.error ~tool_name:name ~start_time "Unexpected Goal completion tool"
    else
      match !verdict_ref with
      | Some verdict ->
        let message =
          Printf.sprintf
            "Goal completion verdict already recorded (%s); tool must be called exactly once"
            (Goal_completion_contract.verdict_constructor_name verdict)
        in
        protocol_error_ref := Some message;
        Tool_result.error ~tool_name:name ~start_time message
      | None ->
        (match Goal_completion_contract.parse_verdict_from_json args with
         | Ok verdict ->
           verdict_ref := Some verdict;
           Log.Workspace.info
             "Goal completion verdict accepted runtime=%s verdict=%s"
             runtime_id
             (Goal_completion_contract.verdict_constructor_name verdict);
           Tool_result.ok
             ~tool_name:name
             ~start_time
             ("Goal completion verdict recorded: "
              ^ Goal_completion_contract.verdict_constructor_name verdict)
         | Error message ->
           protocol_error_ref := Some message;
           Tool_result.error ~tool_name:name ~start_time message)
  in
  let provider_config_transform provider_config =
    Ok
      (Keeper_structured_output_schema.completion_verdict_tool_provider_config
         provider_config)
  in
  match
    Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Goal_completion (fun () ->
      Keeper_turn_driver_wrappers.run_named_with_masc_tools
        ~runtime_id
        ~base_path:config.base_path
        ~goal:prompt
        ~system_prompt:
          "Judge only the supplied Goal completion evidence and call the verdict tool exactly once."
        ~masc_tools:[ report_tool_schema ]
        ~dispatch
        ~provider_config_transform
        ())
  with
  | Error error -> Error (Agent_sdk.Error.to_string error)
  | Ok _ ->
    (match !protocol_error_ref, !verdict_ref with
     | Some message, _ -> Error ("Goal completion verdict protocol violation: " ^ message)
     | None, Some verdict -> Ok verdict
     | None, None -> Error "Goal completion evaluator returned without a structured verdict")
;;

let conditional_failure = function
  | Goal_store.Goal_not_found -> Conflict "Goal no longer exists"
  | Goal_store.Goal_snapshot_changed -> Conflict "Goal changed during completion review"
  | Goal_store.Goal_persistence_failed message -> Persistence_failed message
;;

let persist_failed_review ~config ~expected ~failure ~reason outcome =
  match
    Goal_store.record_completion_review_failure_if_unchanged
      config
      ~expected
      ~failure
      ~review_note:reason
      ~reviewed_at:(Masc_domain.now_iso ())
  with
  | Ok _ -> Error outcome
  | Error error -> Error (conditional_failure error)
;;

let request_completion
      ~config
      ~requesting_agent
      ~expected
      ~expected_state_version
      ~completion_claim
  =
  match
    Goal_state_internal.capture_snapshot
      ~config
      ~goal:expected
      ~state_version:expected_state_version
      ~completion_claim
      ~requesting_agent
  with
  | Error reason ->
    persist_failed_review
      ~config
      ~expected
      ~failure:Goal_store.Unavailable
      ~reason
      (Unavailable { reason; evaluator_runtime = "unresolved" })
  | Ok snapshot ->
    (match evaluator_route (), build_prompt snapshot with
     | Error reason, _ | _, Error reason ->
       persist_failed_review
         ~config
         ~expected
         ~failure:Goal_store.Unavailable
         ~reason
         (Unavailable { reason; evaluator_runtime = "unresolved" })
     | Ok evaluator_runtime, Ok prompt ->
       (match run_reviewer ~config ~runtime_id:evaluator_runtime ~prompt with
        | Error reason ->
          persist_failed_review
            ~config
            ~expected
            ~failure:Goal_store.Unavailable
            ~reason
            (Unavailable { reason; evaluator_runtime })
        | Ok (Goal_completion_contract.Reject reason) ->
          persist_failed_review
            ~config
            ~expected
            ~failure:Goal_store.Rejected
            ~reason
            (Rejected { reason; evaluator_runtime })
        | Ok Goal_completion_contract.Approve ->
          let reviewed_at = Masc_domain.now_iso () in
          let seal =
            Goal_state_internal.seal_approved_review
              ~snapshot
              ~operation_id:(Random_id.hex ~bytes:32)
              ~evaluator_runtime
              ~reviewed_at
              ~review_prompt_sha256:(prompt_sha256 prompt)
          in
          (match Goal_state_internal.commit_completed ~config seal with
           | Ok goal -> Ok { goal; evaluator_runtime; reviewed_at }
           | Error (Goal_state_internal.Snapshot_changed message) ->
             Error (Conflict message)
           | Error (Goal_state_internal.Current_evidence_unavailable message) ->
             Error (Unavailable { reason = message; evaluator_runtime })
           | Error (Goal_state_internal.Persistence_failed message) ->
             Error (Persistence_failed message))))
;;
