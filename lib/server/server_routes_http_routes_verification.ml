(** HTTP routes for the verification domain.

    Kept as a dedicated file to avoid bloating
    [server_routes_http_routes_runtime.ml] — the verification domain is
    independent of runtime.

    - [GET /api/v1/verification/requests] — immutable verification submissions
      (see {!Dashboard_verification}).
    - [GET /api/v1/verification/summary] — immutable submission count.
    - [GET /api/v1/verification/specs] — TLA+ spec index with clean / buggy
      cfg coverage (see {!Dashboard_tla_specs}).
    - [GET /api/v1/verification/tlc-results] — latest observed TLC log
      projection for each clean / buggy cfg.
    - [GET /api/v1/verification/evidence] — submitted evidence for an
      authenticated operator.
    - [POST /api/v1/verification/verdict] — authenticated operator verdict.

    The two authority routes require a token-bound [CanAdmin] credential. A
    Keeper task action cannot reach them. *)

open Server_auth

module Http = Http_server_eio

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some v when v <> "" -> Some v
  | _ -> None

type operator_verdict_request =
  { task_id : string
  ; verdict : Masc_domain.completion_verdict
  ; notes : string
  }

let non_empty_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (String.trim value)
  | Some _ -> Error (Printf.sprintf "%s must be a non-empty string" key)
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_string_field fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok ""
  | Some (`String value) -> Ok (String.trim value)
  | Some _ -> Error (Printf.sprintf "%s must be a string" key)
;;

let parse_operator_verdict_json = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* task_id = non_empty_string_field fields "task_id" in
    let* verdict_name = non_empty_string_field fields "verdict" in
    let* notes = optional_string_field fields "notes" in
    let* verdict =
      match String.lowercase_ascii verdict_name with
      | "approve" -> Ok Masc_domain.Verdict_approved
      | "reject" ->
        let* reason = non_empty_string_field fields "reason" in
        Ok (Masc_domain.Verdict_rejected { reason })
      | _ -> Error "verdict must be \"approve\" or \"reject\""
    in
    Ok { task_id; verdict; notes }
  | _ -> Error "request body must be a JSON object"
;;

let awaiting_task config task_id =
  match
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) ->
           String.equal task.id task_id)
  with
  | None -> Error (Printf.sprintf "Task %s was not found" task_id)
  | Some
      ({ task_status =
           Masc_domain.AwaitingVerification
             { assignee; verification_id; _ }
       ; _
       } as task) ->
    Ok (task, assignee, verification_id)
  | Some task ->
    Error
      (Printf.sprintf
         "Task %s is %s; operator evidence and verdicts require \
          awaiting_verification"
         task_id
         (Masc_domain.task_status_to_string task.task_status))
;;

let operator_evidence_json ~config ~operator_id ~task_id =
  let open Result.Syntax in
  let* task, producer, verification_id = awaiting_task config task_id in
  let authority = Masc_domain.Human_operator { operator_id } in
  (* RFC-0415 §4.2: the operator clicks with the question in view. A cancel
     claim and a completion claim are different questions about the same
     evidence card, so the card names which one it answers. The intent is read
     off the Task status — the same source the authority reads (#33046), one
     field, one owner. *)
  let intent =
    match task.task_status with
    | Masc_domain.AwaitingVerification { intent; _ } -> (
      match intent with
      | Masc_domain.Complete_task -> "completion"
      | Masc_domain.Cancel_task -> "cancellation")
    (* Unreachable: [awaiting_task] only returns tasks in this status. Kept
       total so a future awaiting_task change fails here, not in JSON. *)
    | _ -> "unknown"
  in
  let evidence =
    Workspace_verification_store.inspect_submitted_evidence_for_authority
      ~base_path:config.Workspace.base_path
      ~request_id:verification_id
      ~task_id
      ~task_worker:producer
      ~authority
  in
  Ok
    (`Assoc
      [ "task_id", `String task_id
      ; "verification_id", `String verification_id
      ; "producer", `String producer
      ; "intent", `String intent
      ; ( "authority_kind"
        , `String (Masc_domain.completion_authority_kind authority) )
      ; ( "authority_actor"
        , `String (Masc_domain.completion_authority_actor authority) )
      ; ( "evidence"
        , Workspace_verification_store.submitted_evidence_access_to_yojson
            evidence )
      ])
;;

let commit_operator_verdict ~config ~operator_id request =
  let open Result.Syntax in
  let* _task, producer, verification_id =
    awaiting_task config request.task_id
  in
  let authority = Masc_domain.Human_operator { operator_id } in
  let* outcome =
    Workspace.commit_verdict_r
      config
      ~authority
      ~verdict:request.verdict
      ~task_id:request.task_id
      ~verification_id
      ~notes:request.notes
      ()
    |> Result.map_error Masc_domain.masc_error_to_string
  in
  (match request.verdict with
   | Masc_domain.Verdict_approved -> ()
   | Masc_domain.Verdict_rejected { reason } ->
     (match
        Completion_authority_wakeup.wake_rejected_producer
          ~config
          ~producer
          ~task_id:request.task_id
          ~verification_id
          ~reason
          ~authority
      with
      | Completion_authority_wakeup.Signaled _ -> ()
      | Completion_authority_wakeup.Durable_deferred
          { keeper_name; wakeup } ->
        (match wakeup with
         | Keeper_registry.Deferred_unregistered ->
           Log.Server.warn
             "operator completion rejection durably queued for unregistered Keeper task_id=%s verification_id=%s keeper=%s"
             request.task_id
             verification_id
             keeper_name
         | Keeper_registry.Deferred_not_running phase ->
           Log.Server.warn
             "operator completion rejection durably queued for inactive Keeper task_id=%s verification_id=%s keeper=%s phase=%s"
             request.task_id
             verification_id
             keeper_name
             (Keeper_state_machine.phase_to_string phase)
         | Keeper_registry.Deferred_lifecycle denial ->
           Log.Server.warn
             "operator completion rejection durably queued after lifecycle wake denial task_id=%s verification_id=%s keeper=%s reason=%s"
             request.task_id
             verification_id
             keeper_name
             (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
         | Keeper_registry.Signaled ->
           Log.Server.error
             "operator completion rejection reported deferred Signaled wake task_id=%s verification_id=%s keeper=%s"
             request.task_id
             verification_id
             keeper_name)
      | Completion_authority_wakeup.Durable_wake_failed { keeper_name; detail } ->
        Log.Server.error
          "operator completion rejection durably queued but live wake failed task_id=%s verification_id=%s keeper=%s detail=%s"
          request.task_id
          verification_id
          keeper_name
          detail
      | Completion_authority_wakeup.Unroutable_producer { producer; task_id } ->
        Log.Server.error
          "operator completion rejection has no registered or persisted Keeper producer binding task_id=%s producer=%s verification_id=%s"
          task_id
          producer
          verification_id
      | Completion_authority_wakeup.Producer_identity_lookup_failed
          { producer; task_id; detail } ->
        Log.Server.error
          "operator completion rejection producer identity lookup failed task_id=%s producer=%s verification_id=%s detail=%s"
          task_id
          producer
          verification_id
          detail
      | Completion_authority_wakeup.Durable_queue_failed { keeper_name; detail } ->
        Log.Server.error
          "operator completion rejection durable queue failed task_id=%s verification_id=%s keeper=%s detail=%s"
          request.task_id
          verification_id
          keeper_name
          detail));
  Ok outcome
;;

let error_json message =
  `Assoc [ "ok", `Bool false; "error", `String message ]
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/verification/requests" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let task_id = trimmed_query_param req "task_id" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json =
           Dashboard_verification.requests_json ~base_path ?task_id ?limit ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = Dashboard_verification.summary_json ~base_path () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/specs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_tla_specs.specs_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/tlc-results" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_tla_specs.tlc_results_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/evidence" (fun request reqd ->
       with_token_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state operator_id req reqd ->
            let config = Mcp_server.workspace_config state in
            match trimmed_query_param req "task_id" with
            | None ->
              respond_json_value_with_cors
                ~status:`Bad_request
                request
                reqd
                (error_json "task_id query parameter is required")
            | Some task_id ->
              (match operator_evidence_json ~config ~operator_id ~task_id with
               | Ok json ->
                 respond_json_value_with_cors
                   request
                   reqd
                   (`Assoc [ "ok", `Bool true; "result", json ])
               | Error message ->
                 respond_json_value_with_cors
                   ~status:`Bad_request
                   request
                   reqd
                   (error_json message)))
         request
         reqd)
  |> Http.Router.post "/api/v1/verification/verdict" (fun request reqd ->
       with_token_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state operator_id _req reqd ->
            Http.Request.read_body_async reqd (fun body ->
              let parsed =
                try
                  Yojson.Safe.from_string body
                  |> parse_operator_verdict_json
                with Yojson.Json_error message ->
                  Error ("invalid JSON: " ^ message)
              in
              match parsed with
              | Error message ->
                respond_json_value_with_cors
                  ~status:`Bad_request
                  request
                  reqd
                  (error_json message)
              | Ok verdict_request ->
                let config = Mcp_server.workspace_config state in
                (match
                   commit_operator_verdict
                     ~config
                     ~operator_id
                     verdict_request
                 with
                 | Error message ->
                   respond_json_value_with_cors
                     ~status:`Bad_request
                     request
                     reqd
                     (error_json message)
                 | Ok outcome ->
                   respond_json_value_with_cors
                     request
                     reqd
                     (`Assoc
                       [ "ok", `Bool true
                       ; "message", `String outcome.Workspace.message
                       ; "noop", `Bool outcome.noop
                       ]))))
         request
         reqd)

module For_testing = struct
  let parse_operator_verdict_json = parse_operator_verdict_json
  let operator_evidence_json = operator_evidence_json
  let commit_operator_verdict = commit_operator_verdict
end
