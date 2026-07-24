(** Configured-LLM Goal completion review.

    Goal evidence stays provider/model neutral. The only approving channel is
    one structured [report_goal_completion_verdict] tool call. *)

type review_request =
  { goal : Goal_store.goal
  ; completion_claim : string
  ; agent_name : string
  ; linked_tasks : Masc_domain.task list
  ; child_goals : Goal_store.goal list
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

type review_result =
  { verdict : verdict option
  ; evaluator_runtime : string
  ; review_prompt_sha256 : string option
  ; gate : gate
  ; fallback_reason : string option
  }

let run_llm_reviewer_fn
  : (?sw:Eio.Switch.t ->
     evaluator_runtime:string ->
     prompt:string ->
     report_tool_schema:Types_core.tool_schema ->
     unit ->
     (verdict option, Agent_sdk.Error.sdk_error) result)
      Atomic.t
  =
  Atomic.make
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
       Error
         (Agent_sdk.Error.Internal
            "Goal_completion_reviewer.run_llm_reviewer_fn is not connected"))
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
    [ "goal_json", Goal_store.goal_to_yojson request.goal |> Yojson.Safe.to_string
    ; "completion_claim", request.completion_claim
    ; "agent_name", request.agent_name
    ; ( "linked_tasks_json"
      , `List (List.map Masc_domain.task_to_yojson request.linked_tasks)
        |> Yojson.Safe.to_string )
    ; ( "child_goals_json"
      , `List (List.map Goal_store.goal_to_yojson request.child_goals)
        |> Yojson.Safe.to_string )
    ]
  in
  Prompt_registry.render_prompt_template "verification.goal_completion" vars
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
           (Atomic.get run_llm_reviewer_fn)
             ~evaluator_runtime
             ~prompt
             ~report_tool_schema
             ()
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
         { verdict = Some verdict
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
