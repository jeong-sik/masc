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
  ; verification_id : string
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

(* [verification_id] is the submission whose evidence the operator read, as
   the evidence route handed it out. The verdict carries it so the commit
   refuses when the producer has since resubmitted or superseded it. *)
let operator_verdict_fields = [ "task_id"; "verification_id"; "verdict"; "reason"; "notes" ]

let parse_operator_verdict_json = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.exists (fun key -> not (List.mem key operator_verdict_fields)) names
       || List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "unknown or duplicate verdict fields"
    else
    let open Result.Syntax in
    let* task_id = non_empty_string_field fields "task_id" in
    let* verification_id = non_empty_string_field fields "verification_id" in
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
    Ok { task_id; verification_id; verdict; notes }
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
  (* RFC-0417 §4.2: the operator clicks with the question in view. A cancel
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
  let authority = Masc_domain.Human_operator { operator_id } in
  (* The shared verdict commit writes the repair obligation atomically and
     wakes the same delivery consumer used by system judgments and boot. It
     compares [request.verification_id] with the Task's live one under the
     backlog lock and answers [VerificationSuperseded] when they differ. *)
  Workspace.commit_verdict_r config ~authority ~verdict:request.verdict
    ~task_id:request.task_id ~verification_id:request.verification_id
    ~notes:request.notes ()
;;

let error_json message =
  `Assoc [ "ok", `Bool false; "error", `String message ]
;;

(* A confirmation the store refused (wrong binding, unknown goal, failed
   write) is the caller's 400 as before. A store this build cannot read is
   not: it answers the RFC-0444 envelope with the status this module already
   uses for a dependency that is not there. *)
type confirmation_error =
  | Confirmation_rejected of string
  | Goal_store_unavailable of Goal_store.unavailable

let confirmation_error_to_string = function
  | Confirmation_rejected detail -> detail
  | Goal_store_unavailable unavailable -> Goal_store.unavailable_to_string unavailable
;;

(* Annotated: [Store_unavailable] is a constructor of three Goal_store sums
   (write_error, delete_goal_error, lookup); without the annotation the
   compiler picks the last one declared. *)
let confirmation_error_of_write_error (error : Goal_store.write_error) =
  match error with
  | Goal_store.Store_unavailable unavailable -> Goal_store_unavailable unavailable
  | Goal_store.Goal_not_found _ | Goal_store.Rejected _ | Goal_store.Persist_failed _ as error ->
    Confirmation_rejected (Goal_store.write_error_to_string error)
;;

let respond_confirmation_error request reqd = function
  | Confirmation_rejected detail ->
    respond_json_value_with_cors ~status:`Bad_request request reqd (error_json detail)
  | Goal_store_unavailable unavailable ->
    respond_json_value_with_cors ~status:`Service_unavailable request reqd
      (Goal_unavailable_envelope.to_yojson unavailable)
;;

let commit_goal_confirmation_json ~config ~operator_id json : (Yojson.Safe.t, confirmation_error) result =
  let rejected = Result.map_error (fun detail -> Confirmation_rejected detail) in
  match json with
               | `Assoc fields ->
                 let names = List.map fst fields in
                 let allowed = ["goal_id"; "criterion_revision"; "request_id"; "verification_run_id"] in
                 if List.exists (fun key -> not (List.mem key allowed)) names
                    || List.length names <> List.length (List.sort_uniq String.compare names)
                 then Error (Confirmation_rejected "unknown or duplicate confirmation fields")
                 else
                   let open Result.Syntax in
                   let* goal_id = rejected (non_empty_string_field fields "goal_id") in
                   let* criterion_revision = rejected (non_empty_string_field fields "criterion_revision") in
                   let* request_id = rejected (non_empty_string_field fields "request_id") in
                   let* verification_run_id = rejected (non_empty_string_field fields "verification_run_id") in
                   Workspace_goals.confirm_completion config
                     ~goal_id ~operator_id ~criterion_revision ~request_id ~verification_run_id
                   |> Result.map_error confirmation_error_of_write_error
               | _ -> Error (Confirmation_rejected "request body must be an object")

;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/goals/confirmation" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _operator_id req reqd ->
           let config = Mcp_server.workspace_config state in
           let result = match trimmed_query_param req "goal_id" with
             | None -> Error (Confirmation_rejected "goal_id is required")
             | Some goal_id -> Goal_store.transact_goal config ~goal_id (fun goal ->
                 Goal_verification.get_record_authoritative config ~goal_id
                 |> Result.map (fun record -> goal, `Assoc ["goal", Goal_store.goal_to_yojson goal;
                     "verification", (match record with None -> `Null | Some record ->
                       Goal_verification.record_to_yojson_for_goal ~goal record)]))
                 |> Result.map snd
                 |> Result.map_error confirmation_error_of_write_error in
           match result with
           | Ok result -> respond_json_value_with_cors request reqd result
           | Error error -> respond_confirmation_error request reqd error)
         request reqd)
  |> Http.Router.post "/api/v1/goals/confirmation" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_id _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let parsed = try
               commit_goal_confirmation_json ~config:(Mcp_server.workspace_config state)
                 ~operator_id (Yojson.Safe.from_string body)
             with Yojson.Json_error detail -> Error (Confirmation_rejected detail) in
             match parsed with
             | Ok result -> respond_json_value_with_cors request reqd result
             | Error error -> respond_confirmation_error request reqd error))
         request reqd)
  |> Http.Router.get "/api/v1/verification/requests" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let task_id = trimmed_query_param req "task_id" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         (* A non-numeric or negative offset is refused rather than rounded to
            the first page. A reader paging forward through the store would
            otherwise re-read page one and conclude it had reached the end. *)
         let offset =
           match trimmed_query_param req "offset" with
           | None -> Ok None
           | Some s ->
             (match int_of_string_opt s with
              | Some n when n >= 0 -> Ok (Some n)
              | Some _ | None ->
                Error
                  (Printf.sprintf "offset %S must be a non-negative integer" s))
         in
         let requested =
           match trimmed_query_param req "view" with
           | None -> Ok Dashboard_verification.Ask_all
           | Some s -> Dashboard_verification.requested_view_of_string s
         in
         (match offset, requested with
          | Error detail, _ | _, Error detail ->
            respond_json_value_with_cors ~status:`Bad_request request reqd
              (error_json detail)
          | Ok offset, Ok requested ->
            let config = Mcp_server.workspace_config state in
            let view =
              match requested with
              | Dashboard_verification.Ask_all ->
                Dashboard_verification.All_requests
              | Dashboard_verification.Ask_awaiting ->
                (* The queue is a join against the backlog, so a backlog this
                   build cannot read yields an empty queue carrying the reason.
                   Falling back to the unfiltered store would answer "what is
                   waiting on me" with every request ever submitted. *)
                Dashboard_verification.Awaiting_operator
                  (match
                     Workspace_backlog
                     .read_backlog_observation_with_source_r config
                   with
                   | Ok { Workspace_backlog.observed_backlog
                        ; recovered_from = None
                        } ->
                     Dashboard_verification.Backlog_read
                       { live =
                           Dashboard_verification.awaiting_tasks
                             observed_backlog
                       }
                   | Ok { Workspace_backlog.observed_backlog
                        ; recovered_from = Some recovery
                        } ->
                     (* The reader that drops this provenance answers [Ok] for
                        a queue computed from a snapshot, which is a queue
                        that looks current and is not: anything submitted
                        after the snapshot is missing from it. *)
                     Dashboard_verification.Backlog_recovered
                       { live =
                           Dashboard_verification.awaiting_tasks
                             observed_backlog
                       ; detail =
                           Printf.sprintf
                             "read from %s after the primary backlog failed: %s"
                             recovery.Workspace_backlog.recovery_path
                             recovery.Workspace_backlog.primary_error
                       }
                   | Error detail ->
                     Dashboard_verification.Backlog_unreadable detail)
            in
            let json =
              Dashboard_verification.requests_json ~base_path:config.base_path
                ?task_id ?limit ?offset ~view ()
            in
            Http.Response.json_value ~compress:true ~request:req json reqd)
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
                 | Error error ->
                   respond_json_value_with_cors
                     ~status:(Server_auth.http_status_of_auth_error error)
                     request
                     reqd
                     (error_json (Masc_domain.masc_error_to_string error))
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
  let commit_goal_confirmation_json = commit_goal_confirmation_json
  let confirmation_error_to_string = confirmation_error_to_string
  let parse_operator_verdict_json = parse_operator_verdict_json
  let operator_evidence_json = operator_evidence_json
  let commit_operator_verdict = commit_operator_verdict
end
