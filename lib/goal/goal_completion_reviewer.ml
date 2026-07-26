(** Configured-runtime Goal completion review and opaque completion authority. *)

type review_request =
  { workspace_identity : string
  ; goal_id : string
  ; goal_version : int
  ; operation_id : string
  ; goal_json : Yojson.Safe.t
  ; goal_updated_at : string
  ; completion_claim : string
  ; requesting_agent : string
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
  { workspace_identity : string
  ; goal_id : string
  ; expected_version : int
  ; operation_id : string
  ; completion_digest : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; review_evidence_sha256 : string
  ; completion_claim : string
  ; requesting_agent : string
  ; linked_task_ids : string list
  }

type approval_metadata =
  { workspace_identity : string
  ; goal_id : string
  ; expected_version : int
  ; operation_id : string
  ; completion_digest : string
  ; evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; review_evidence_sha256 : string
  ; completion_claim : string
  ; requesting_agent : string
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

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | `Tuple values -> `Tuple (List.map canonical_json values)
  | `Variant (name, Some value) -> `Variant (name, Some (canonical_json value))
  | value -> value
;;

let canonical_string json = Yojson.Safe.to_string (canonical_json json)

let sha256_json json =
  canonical_string json
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let string_list_json values = `List (List.map (fun value -> `String value) values)

let review_evidence_sha256_values
      ~workspace_identity
      ~goal_json
      ~completion_claim
      ~requesting_agent
      ~linked_tasks_json
      ~linked_task_ids
      ~child_goals_json
  =
  sha256_json
    (`Assoc
       [ "workspace_identity", `String workspace_identity
       ; "goal_json", goal_json
       ; "completion_claim", `String completion_claim
       ; "requesting_agent", `String requesting_agent
       ; "linked_tasks_json", linked_tasks_json
       ; "linked_task_ids", string_list_json linked_task_ids
       ; "child_goals_json", child_goals_json
       ])
;;

let review_evidence_sha256 request =
  review_evidence_sha256_values
    ~workspace_identity:request.workspace_identity
    ~goal_json:request.goal_json
    ~completion_claim:request.completion_claim
    ~requesting_agent:request.requesting_agent
    ~linked_tasks_json:request.linked_tasks_json
    ~linked_task_ids:request.linked_task_ids
    ~child_goals_json:request.child_goals_json
;;

let completion_digest
      ~workspace_identity
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
      ~requesting_agent
      ~linked_task_ids
  =
  sha256_json
    (`Assoc
       [ "workspace_identity", `String workspace_identity
       ; "goal_id", `String goal_id
       ; "expected_version", `Int expected_version
       ; "operation_id", `String operation_id
       ; "current_goal_snapshot", goal_json
       ; "target_phase", `String "completed"
       ; "proposed_last_review_note", `String "Configured runtime approved Goal completion"
       ; "proposed_last_review_at", `String reviewed_at
       ; "proposed_completion_review_failure", `Null
       ; ( "proposed_completion_receipt"
         , `Assoc
             [ "workspace_identity", `String workspace_identity
             ; "expected_state_version", `Int expected_version
             ; "operation_id", `String operation_id
             ; "evaluator_runtime", `String evaluator_runtime
             ; "reviewed_at", `String reviewed_at
             ; "reviewed_goal_updated_at", `String reviewed_goal_updated_at
             ; "review_prompt_sha256", `String review_prompt_sha256
             ; "review_evidence_sha256", `String review_evidence_sha256
             ; "completion_claim", `String completion_claim
             ; "requesting_agent", `String requesting_agent
             ; "linked_task_ids", string_list_json linked_task_ids
             ] )
       ])
;;

let approval_authorizes
      approval
      ~workspace_identity
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
      ~linked_tasks_json
      ~linked_task_ids
      ~child_goals_json
  =
  let current_evidence_sha256 =
    review_evidence_sha256_values
      ~workspace_identity
      ~goal_json
      ~completion_claim:approval.completion_claim
      ~requesting_agent:approval.requesting_agent
      ~linked_tasks_json
      ~linked_task_ids
      ~child_goals_json
  in
  let recomputed_digest =
    completion_digest
      ~workspace_identity
      ~goal_json
      ~reviewed_goal_updated_at
      ~goal_id
      ~expected_version
      ~operation_id
      ~evaluator_runtime:approval.evaluator_runtime
      ~reviewed_at:approval.reviewed_at
      ~review_prompt_sha256:approval.review_prompt_sha256
      ~review_evidence_sha256:current_evidence_sha256
      ~completion_claim:approval.completion_claim
      ~requesting_agent:approval.requesting_agent
      ~linked_task_ids
  in
  String.equal approval.workspace_identity workspace_identity
  && String.equal approval.goal_id goal_id
  && approval.expected_version = expected_version
  && String.equal approval.operation_id operation_id
  && String.equal approval.reviewed_goal_updated_at reviewed_goal_updated_at
  && String.equal approval.review_evidence_sha256 current_evidence_sha256
  && approval.linked_task_ids = linked_task_ids
  && String.equal approval.completion_digest recomputed_digest
;;

let approval_metadata approval =
  { workspace_identity = approval.workspace_identity
  ; goal_id = approval.goal_id
  ; expected_version = approval.expected_version
  ; operation_id = approval.operation_id
  ; completion_digest = approval.completion_digest
  ; evaluator_runtime = approval.evaluator_runtime
  ; reviewed_at = approval.reviewed_at
  ; reviewed_goal_updated_at = approval.reviewed_goal_updated_at
  ; review_prompt_sha256 = approval.review_prompt_sha256
  ; review_evidence_sha256 = approval.review_evidence_sha256
  ; completion_claim = approval.completion_claim
  ; requesting_agent = approval.requesting_agent
  ; linked_task_ids = approval.linked_task_ids
  }
;;

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
          ; "reason", `Assoc [ "type", `String "string" ]
          ] )
    ; "required", `List [ `String "verdict" ]
    ; "additionalProperties", `Bool false
    ]
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
       Error (Printf.sprintf "unexpected Goal completion verdict field: %s" field)
     | None ->
       (match values "verdict", values "reason" with
        | [ `String "APPROVE" ], [] -> Ok Approve
        | [ `String "APPROVE" ], _ -> Error "reason must be omitted for APPROVE"
        | [ `String "REJECT" ], [ `String reason ] when String.trim reason <> "" ->
          Ok (Reject reason)
        | [ `String "REJECT" ], _ ->
          Error "reason is required exactly once and must be non-empty for REJECT"
        | [ `String value ], _ ->
          Error (Printf.sprintf "unexpected Goal completion verdict value: %s" value)
        | [ _ ], _ -> Error "verdict must be a string"
        | [], _ -> Error "verdict is required exactly once"
        | _ :: _ :: _, _ -> Error "verdict is required exactly once"))
  | _ -> Error "Goal completion verdict arguments must be an object"
;;

let build_prompt request =
  Prompt_registry.render_prompt_template
    "verification.goal_completion"
    [ "goal_json", canonical_string request.goal_json
    ; "completion_claim", request.completion_claim
    ; "agent_name", request.requesting_agent
    ; "linked_tasks_json", canonical_string request.linked_tasks_json
    ; "child_goals_json", canonical_string request.child_goals_json
    ]
;;

let report_tool verdict_ref protocol_error_ref =
  Agent_sdk.Tool.create
    ~name:"report_goal_completion_verdict"
    ~description:
      "Report exactly one semantic Goal completion verdict. APPROVE only when the supplied evidence demonstrates that the Goal target was reached."
    ~parameters:(Agent_sdk.Mcp.json_schema_to_params report_tool_input_schema)
    (fun args ->
       match !verdict_ref with
       | Some verdict ->
         let detail =
           Printf.sprintf
             "Goal completion verdict already recorded (%s); report_goal_completion_verdict must be called exactly once"
             (verdict_constructor_name verdict)
         in
         protocol_error_ref := Some detail;
         Error
           { Agent_sdk.Types.message = detail
           ; recoverable = false
           ; error_class = Some Agent_sdk.Types.Deterministic
           }
       | None ->
         (match parse_verdict_from_json args with
          | Ok verdict ->
            verdict_ref := Some verdict;
            Ok
              { Agent_sdk.Types.content =
                  (match verdict with
                   | Approve -> "Goal completion verdict recorded: APPROVE"
                   | Reject reason -> "Goal completion verdict recorded: REJECT: " ^ reason)
              ; _meta = None
              }
          | Error detail ->
            protocol_error_ref := Some detail;
            Error
              { Agent_sdk.Types.message = detail
              ; recoverable = false
              ; error_class = Some Agent_sdk.Types.Deterministic
              }))
;;

let candidate_runtimes route_id =
  match Runtime.resolve_assignment route_id with
  | `Missing -> Error (Printf.sprintf "Goal completion evaluator route %S is missing" route_id)
  | `Single_runtime runtime -> Ok [ runtime ]
  | `Lane lane ->
    let runtimes =
      Runtime_lane.ordered_candidates lane
      |> Runtime_lane_preference.prefer_order ~lane_id:(Runtime_lane.id lane)
      |> List.filter_map Runtime.get_runtime_by_id
    in
    if runtimes = []
    then Error (Printf.sprintf "Goal completion evaluator lane %S has no runtime candidates" route_id)
    else Ok runtimes
;;

let run_candidate ~runtime ~prompt =
  let verdict_ref = ref None in
  let protocol_error_ref = ref None in
  let tool = report_tool verdict_ref protocol_error_ref in
  let provider_cfg =
    { runtime.Runtime.provider_config with
      response_format = Agent_sdk.Types.Off
    ; output_schema = None
    }
  in
  let config =
    Runtime_agent.default_config
      ~name:"goal-completion-reviewer"
      ~provider_cfg
      ~system_prompt:"Judge only the supplied Goal completion evidence and call the verdict tool exactly once."
      ~tools:[ tool ]
  in
  match Runtime_oas_runner.require_eio () with
  | Error reason -> Error reason
  | Ok (sw, net) ->
    (match Runtime_agent.run ~sw ~net ~config prompt with
     | Error error -> Error (Agent_sdk.Error.to_string error)
     | Ok _ ->
       (match !protocol_error_ref, !verdict_ref with
        | Some detail, _ -> Error ("Goal completion verdict protocol violation: " ^ detail)
        | None, Some verdict -> Ok verdict
        | None, None ->
          Error
            "Goal completion evaluator did not call report_goal_completion_verdict exactly once"))
;;

let run_configured_reviewer ~route_id ~prompt =
  match candidate_runtimes route_id with
  | Error _ as error -> error
  | Ok runtimes ->
    let rec attempt failures = function
      | [] -> Error (String.concat "; " (List.rev failures))
      | (runtime : Runtime.t) :: rest ->
        (try
           match run_candidate ~runtime ~prompt with
           | Ok verdict -> Ok (runtime.Runtime.id, verdict)
           | Error reason ->
             attempt
               (Printf.sprintf "%s: %s" runtime.Runtime.id reason :: failures)
               rest
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           attempt
             (Printf.sprintf "%s: %s" runtime.Runtime.id (Printexc.to_string exn) :: failures)
             rest)
    in
    attempt [] runtimes
;;

let resolve_evaluator_route () =
  try
    let route_id =
      match Runtime.cross_verifier_runtime_id () with
      | Some runtime -> runtime
      | None -> Runtime.get_default_runtime_id ()
    in
    if String.trim route_id = ""
    then Error "Goal completion evaluator route is empty"
    else Ok route_id
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "Goal completion evaluator route resolution failed: %s"
         (Printexc.to_string exn))
;;

let unavailable ~runtime reason =
  { verdict = None
  ; approval = None
  ; evaluator_runtime = runtime
  ; review_prompt_sha256 = None
  ; gate = Evaluator_unavailable
  ; fallback_reason = Some reason
  }
;;

let review request =
  match resolve_evaluator_route () with
  | Error reason -> unavailable ~runtime:"unresolved" reason
  | Ok route_id ->
    (match build_prompt request with
     | Error reason -> unavailable ~runtime:route_id reason
     | Ok prompt ->
       let review_prompt_sha256 = Digestif.SHA256.(digest_string prompt |> to_hex) in
       (match run_configured_reviewer ~route_id ~prompt with
        | Error reason ->
          { (unavailable ~runtime:route_id reason) with
            review_prompt_sha256 = Some review_prompt_sha256
          }
        | Ok (evaluator_runtime, verdict) ->
          let approval =
            match verdict with
            | Reject _ -> None
            | Approve ->
              let reviewed_at = Masc_domain.now_iso () in
              let review_evidence_sha256 = review_evidence_sha256 request in
              let completion_digest =
                completion_digest
                  ~workspace_identity:request.workspace_identity
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
                  ~requesting_agent:request.requesting_agent
                  ~linked_task_ids:request.linked_task_ids
              in
              Some
                { workspace_identity = request.workspace_identity
                ; goal_id = request.goal_id
                ; expected_version = request.goal_version
                ; operation_id = request.operation_id
                ; completion_digest
                ; evaluator_runtime
                ; reviewed_at
                ; reviewed_goal_updated_at = request.goal_updated_at
                ; review_prompt_sha256
                ; review_evidence_sha256
                ; completion_claim = request.completion_claim
                ; requesting_agent = request.requesting_agent
                ; linked_task_ids = request.linked_task_ids
                }
          in
          { verdict = Some verdict
          ; approval
          ; evaluator_runtime
          ; review_prompt_sha256 = Some review_prompt_sha256
          ; gate = Structured_tool
          ; fallback_reason = None
          }))
;;

module For_testing = struct
  let completion_digest = completion_digest
  let review_evidence_sha256 = review_evidence_sha256_values
end
