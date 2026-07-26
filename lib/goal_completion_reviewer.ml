(** Configured-LLM Goal completion review.

    Goal evidence stays provider/model neutral. The only approving channel is
    one structured [report_goal_completion_verdict] tool call. *)

type review_request =
  { goal_id : string
  ; goal_version : int
  ; operation_id : string
  ; goal_json : Yojson.Safe.t
  ; goal_updated_at : string
  ; completion_claim : string
  ; agent_name : string
  ; linked_tasks_json : Yojson.Safe.t
  ; linked_task_ids : string list
  ; child_goals_json : Yojson.Safe.t
  }

type verdict =
  | Approve
  | Reject of string

let verdict_constructor_name = function
  | Approve -> "APPROVE"
  | Reject _ -> "REJECT"
;;

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

type approval =
  { goal_id : string
  ; expected_version : int
  ; operation_id : string
  ; completion_digest : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; review_prompt_sha256 : string
  ; review_evidence_sha256 : string
  ; completion_claim : string
  ; linked_task_ids : string list
  }

type approval_metadata =
  { evaluator_runtime : string
  ; reviewed_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
  ; linked_task_ids : string list
  }

type review_result =
  { verdict : verdict option
  ; approval : approval option
  ; evaluator_runtime : string
  ; review_prompt_sha256 : string option
  ; gate : gate
  ; fallback_reason : string option
  }

let completion_digest
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
      ~evaluator_runtime
      ~reviewed_at
      ~review_prompt_sha256
      ~review_evidence_sha256
      ~completion_claim
      ~linked_task_ids
  =
  `Assoc
    [ "goal_id", `String goal_id
    ; "expected_version", `Int expected_version
    ; "operation_id", `String operation_id
    ; "current_goal_snapshot", goal_json
    ; "target_phase", `String "completed"
    ; ( "proposed_last_review_note"
      , `String "Configured LLM approved Goal completion" )
    ; "proposed_last_review_at", `String reviewed_at
    ; "proposed_completion_review_failure", `Null
    ; ( "proposed_completion_receipt"
      , `Assoc
          [ "evaluator_runtime", `String evaluator_runtime
          ; "reviewed_at", `String reviewed_at
          ; "reviewed_goal_updated_at", `String reviewed_goal_updated_at
          ; "review_prompt_sha256", `String review_prompt_sha256
          ; "completion_claim", `String completion_claim
          ; ( "linked_task_ids"
            , `List (List.map (fun task_id -> `String task_id) linked_task_ids) )
          ] )
    ; "review_evidence_sha256", `String review_evidence_sha256
    ]
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let approval_authorizes
      approval
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
  =
  let recomputed_digest =
    completion_digest
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
      ~evaluator_runtime:approval.evaluator_runtime
      ~reviewed_at:approval.reviewed_at
      ~review_prompt_sha256:approval.review_prompt_sha256
      ~review_evidence_sha256:approval.review_evidence_sha256
      ~completion_claim:approval.completion_claim
      ~linked_task_ids:approval.linked_task_ids
  in
  String.equal approval.goal_id goal_id
  && approval.expected_version = expected_version
  && String.equal approval.operation_id operation_id
  && String.equal approval.completion_digest recomputed_digest
;;

let approval_metadata approval =
  { evaluator_runtime = approval.evaluator_runtime
  ; reviewed_at = approval.reviewed_at
  ; review_prompt_sha256 = approval.review_prompt_sha256
  ; completion_claim = approval.completion_claim
  ; linked_task_ids = approval.linked_task_ids
  }
;;

let review_evidence_sha256 request =
  `Assoc
    [ "goal_json", request.goal_json
    ; "completion_claim", `String request.completion_claim
    ; "agent_name", `String request.agent_name
    ; "linked_tasks_json", request.linked_tasks_json
    ; "child_goals_json", request.child_goals_json
    ]
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let report_tool_schema : Masc_domain.tool_schema =
  { name = "report_goal_completion_verdict"
  ; description =
      "Report exactly one semantic Goal completion verdict. APPROVE only when \
       the supplied evidence demonstrates that the Goal target was reached."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "verdict"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "APPROVE"; `String "REJECT" ]
                    ] )
              ; "reason", `Assoc [ "type", `String "string" ]
              ] )
        ; "required", `List [ `String "verdict" ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

let parse_verdict_from_json = function
  | `Assoc fields ->
    let values name =
      List.filter_map
        (fun (field, value) -> if String.equal field name then Some value else None)
        fields
    in
    (match
       List.find_opt
         (fun (field, _) ->
            not (String.equal field "verdict" || String.equal field "reason"))
         fields
     with
     | Some (field, _) ->
       Error
         (Printf.sprintf
            "unexpected Goal completion verdict field: %s"
            field)
     | None ->
       (match values "verdict", values "reason" with
        | [ `String "APPROVE" ], [] -> Ok Approve
        | [ `String "APPROVE" ], _ ->
          Error "reason must be omitted for APPROVE"
        | [ `String "REJECT" ], [ `String reason ]
          when String.trim reason <> "" ->
          Ok (Reject reason)
        | [ `String "REJECT" ], _ ->
          Error "reason is required exactly once and must be non-empty for REJECT"
        | [ `String value ], _ ->
          Error
            (Printf.sprintf
               "unexpected Goal completion verdict value: %s"
               value)
        | [ _ ], _ -> Error "verdict must be a string"
        | [], _ -> Error "verdict is required exactly once"
        | _ :: _ :: _, _ -> Error "verdict is required exactly once"))
  | _ -> Error "Goal completion verdict arguments must be an object"
;;

let build_prompt request =
  let vars =
    [ "goal_json", Yojson.Safe.to_string request.goal_json
    ; "completion_claim", request.completion_claim
    ; "agent_name", request.agent_name
    ; "linked_tasks_json", Yojson.Safe.to_string request.linked_tasks_json
    ; "child_goals_json", Yojson.Safe.to_string request.child_goals_json
    ]
  in
  Prompt_registry.render_prompt_template "verification.goal_completion" vars
;;

let run_configured_reviewer ~evaluator_runtime ~prompt =
  let verdict_ref = ref None in
  let protocol_error_ref = ref None in
  let dispatch ~name ~args =
    let start_time = Time_compat.now () in
    match !verdict_ref with
    | Some verdict ->
      let detail =
        Printf.sprintf
          "Goal completion verdict already recorded (%s); \
           report_goal_completion_verdict must be called exactly once"
          (verdict_constructor_name verdict)
      in
      protocol_error_ref := Some detail;
      Tool_result.error ~tool_name:name ~start_time detail
    | None ->
      (match parse_verdict_from_json args with
       | Ok verdict ->
         verdict_ref := Some verdict;
         Tool_result.ok
           ~tool_name:name
           ~start_time
           (match verdict with
            | Approve -> "Goal completion verdict recorded: APPROVE"
            | Reject reason -> "Goal completion verdict recorded: REJECT: " ^ reason)
       | Error msg ->
         protocol_error_ref := Some msg;
         Log.Workspace.warn
           "Goal completion structured verdict parse failed: %s"
           msg;
         Tool_result.error
           ~tool_name:name
           ~start_time
           ("Invalid Goal completion verdict format: " ^ msg))
  in
  let apply_completion_verdict_config provider_cfg =
    Ok
      (Keeper_structured_output_schema.completion_verdict_tool_provider_config
         provider_cfg)
  in
  match
    Masc_oas_bridge.run_safe ~caller:Masc_oas_bridge.Goal_completion (fun () ->
      Keeper_turn_driver_wrappers.run_named_with_masc_tools
        ~runtime_id:evaluator_runtime
        ~base_path:(Env_config_core.base_path ())
        ~goal:prompt
        ~masc_tools:[ report_tool_schema ]
        ~dispatch
        ~provider_config_transform:apply_completion_verdict_config
        ())
  with
  | Ok _ ->
    (match !protocol_error_ref with
     | Some detail ->
       Error
         (Agent_sdk.Error.Internal
            ("Goal completion verdict protocol violation: " ^ detail))
     | None -> Ok !verdict_ref)
  | Error err -> Error err
;;

let resolve_evaluator_runtime () =
  try
    let runtime =
      match (Atomic.get Workspace_hooks.get_cross_verifier_runtime_id_fn) () with
      | Some runtime -> runtime
      | None -> (Atomic.get Workspace_hooks.get_default_runtime_id_fn) ()
    in
    if String.trim runtime = ""
    then Error "Goal completion evaluator runtime is empty"
    else Ok runtime
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "Goal completion evaluator runtime resolution failed: %s"
         (Printexc.to_string exn))
;;

let unavailable ~runtime reason =
  Log.Workspace.warn
    "Goal completion review unavailable runtime=%s: %s"
    runtime
    reason;
  { verdict = None
  ; approval = None
  ; evaluator_runtime = runtime
  ; review_prompt_sha256 = None
  ; gate = Evaluator_unavailable
  ; fallback_reason = Some reason
  }
;;

let review request =
  match resolve_evaluator_runtime () with
  | Error reason -> unavailable ~runtime:"unresolved" reason
  | Ok evaluator_runtime ->
    (match build_prompt request with
     | Error reason -> unavailable ~runtime:evaluator_runtime reason
     | Ok prompt ->
       let review_prompt_sha256 =
         Digestif.SHA256.(digest_string prompt |> to_hex)
       in
       let reviewer_result =
         try
           run_configured_reviewer ~evaluator_runtime ~prompt
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error
             (Agent_sdk.Error.Internal
                (Printf.sprintf
                   "Goal completion evaluator raised unexpectedly: %s"
                   (Printexc.to_string exn)))
       in
       match reviewer_result with
       | Ok (Some verdict) ->
         let approval =
           match verdict with
           | Reject _ -> None
           | Approve ->
             let reviewed_at = Masc_domain.now_iso () in
             let review_evidence_sha256 = review_evidence_sha256 request in
             let completion_digest =
               completion_digest
                 ~goal_json:request.goal_json
                 ~reviewed_goal_updated_at:request.goal_updated_at
                 ~goal_id:request.goal_id
                 ~expected_version:request.goal_version
                 ~operation_id:request.operation_id
                 ~evaluator_runtime
                 ~reviewed_at
                 ~review_prompt_sha256
                 ~review_evidence_sha256
                 ~completion_claim:request.completion_claim
                 ~linked_task_ids:request.linked_task_ids
             in
             Some
               { goal_id = request.goal_id
               ; expected_version = request.goal_version
               ; operation_id = request.operation_id
               ; completion_digest
               ; evaluator_runtime
               ; reviewed_at
               ; review_prompt_sha256
               ; review_evidence_sha256
               ; completion_claim = request.completion_claim
               ; linked_task_ids = request.linked_task_ids
               }
         in
         { verdict = Some verdict
         ; approval
         ; evaluator_runtime
         ; review_prompt_sha256 = Some review_prompt_sha256
         ; gate = Structured_tool
         ; fallback_reason = None
         }
       | Ok None ->
         let reason =
           "Goal completion evaluator did not call \
            report_goal_completion_verdict exactly once"
         in
         { verdict = None
         ; approval = None
         ; evaluator_runtime
         ; review_prompt_sha256 = Some review_prompt_sha256
         ; gate = Invalid_verdict
         ; fallback_reason = Some reason
         }
       | Error error ->
         let result =
           unavailable
             ~runtime:evaluator_runtime
             (Agent_sdk.Error.to_string error)
         in
         { result with review_prompt_sha256 = Some review_prompt_sha256 })
;;
