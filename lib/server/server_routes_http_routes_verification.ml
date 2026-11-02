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
    - [GET /api/v1/verification/evidence] — exact retained Task/submission
      evidence for an authenticated operator.
    - [POST /api/v1/verification/verdict] — authenticated operator verdict.

    - [POST /api/v1/dashboard/tasks/cancel] — operator cancellation.

    The authority routes require a token-bound [CanAdmin] credential. A
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

let operator_evidence_projection ~item_index ~config ~operator_id ~task_id ~verification_id =
  if task_id="" || task_id<>String.trim task_id || verification_id=""
     || verification_id<>String.trim verification_id
     || Filename.basename verification_id<>verification_id then
    Error "exact task_id and verification_id are required"
  else
    let authority=Masc_domain.Human_operator {operator_id} in
    let evidence=Workspace_verification_store.inspect_submitted_evidence_for_operator
      ~base_path:config.Workspace.base_path ~request_id:verification_id ~task_id ~operator_id in
    let producer=match evidence with
      | Workspace_verification_store.Evidence_available {request;_} -> `String request.worker
      | Evidence_unavailable _ -> `Null in
    match item_index with
    | Some index -> Workspace_verification_operator_evidence.file_to_yojson
        ~base_path:config.Workspace.base_path ~index evidence
    | None -> Ok (`Assoc ["task_id",`String task_id;"verification_id",`String verification_id;
      "producer",producer;"authority_kind",`String (Masc_domain.completion_authority_kind authority);
      "authority_actor",`String (Masc_domain.completion_authority_actor authority);
      "evidence",Workspace_verification_operator_evidence.access_to_yojson
        ~base_path:config.Workspace.base_path evidence])
;;

let operator_evidence_json ~config ~operator_id ~task_id ~verification_id =
  operator_evidence_projection ~item_index:None ~config ~operator_id ~task_id ~verification_id
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
   write) is the caller's 400 as before. Goal-store and proof-backend
   unavailability are separate dependency failures. *)
type confirmation_error =
  | Confirmation_rejected of string
  | Goal_store_unavailable of Goal_store.unavailable
  | Proof_backend_unavailable of Goal_verification.authority_backend_error

let confirmation_error_to_string = function
  | Confirmation_rejected detail -> detail
  | Goal_store_unavailable unavailable -> Goal_store.unavailable_to_string unavailable
  | Proof_backend_unavailable unavailable -> Goal_verification.authority_backend_error_to_string unavailable
;;

(* Annotated: [Store_unavailable] is a constructor of three Goal_store sums
   (write_error, delete_goal_error, lookup); without the annotation the
   compiler picks the last one declared. *)
let confirmation_error_of_write_error (error : Goal_store.write_error) =
  match error with
  | Goal_store.Store_unavailable unavailable -> Goal_store_unavailable unavailable
  | Goal_store.Goal_not_found _ | Goal_store.Goal_identity_ambiguous _ | Goal_store.Rejected _ | Goal_store.Persist_failed _ as error ->
    Confirmation_rejected (Goal_store.write_error_to_string error)
;;

(* Preserve the Goal lookup result while reporting an unsupported proof
   backend as a dependency failure. The backend selection is immutable in the
   config; the actual proof operation still checks it at its own boundary. *)
let require_confirmation_backend ~config ~goal_id =
  match Goal_verification.check_authority_backend config with
  | Ok () -> Ok ()
  | Error unavailable ->
    (match Goal_store.transact_goal config ~goal_id (fun goal -> Ok (goal, ())) with
     | Ok _ -> Error (Proof_backend_unavailable unavailable)
     | Error error -> Error (confirmation_error_of_write_error error))
;;

(* Keep the two HTTP transports on the same projection and error contract.
   Both callers authenticate the token-bound operator and validate the read
   workspace before invoking [read_goal_confirmation]. *)
let read_goal_confirmation ~config ~operator_id req =
  match trimmed_query_param req "goal_id" with
  | None -> Error (Confirmation_rejected "goal_id is required")
  | Some goal_id ->
      let open Result.Syntax in
      let* () = require_confirmation_backend ~config ~goal_id in
      Goal_store.transact_goal config ~goal_id (fun goal ->
      Goal_verification.get_record_authoritative config ~goal_id
      |> Result.map (fun record -> goal, `Assoc ["inspection_operator_id", `String operator_id;
          "goal", Goal_store.goal_to_yojson goal;
          "verification", (match record with None -> `Null | Some record ->
            Goal_verification.record_to_yojson_for_goal ~goal record)]))
      |> Result.map snd
      |> Result.map_error confirmation_error_of_write_error
;;

let goal_confirmation_response result : Httpun.Status.t * Yojson.Safe.t =
  match result with
  | Ok json -> `OK, json
  | Error (Confirmation_rejected detail) -> `Bad_request, error_json detail
  | Error (Goal_store_unavailable unavailable) ->
    `Service_unavailable, Goal_unavailable_envelope.to_yojson unavailable
  | Error (Proof_backend_unavailable unavailable) ->
    `Service_unavailable, error_json (Goal_verification.authority_backend_error_to_string unavailable)
;;

(* Confirmation evidence is credential-bound and must be read afresh. The
   general JSON responder applies conditional GETs even when no-store is in
   extra headers, so use an unconditionally emitted JSON body here. *)
let respond_goal_confirmation ~cors reqd result =
  let status, json = goal_confirmation_response result in
  let status = Http.Response.timeout_envelope_status_override ~status json in
  Http.Response.bytes ~status
    ~headers:(("cache-control", "private, no-store") :: Server_dashboard_goal_candle.generation_headers @ cors)
    ~content_type:"application/json; charset=utf-8" (Yojson.Safe.to_string json) reqd
;;

let commit_goal_confirmation_json ~config ~operator_id json : (Yojson.Safe.t, confirmation_error) result =
  let rejected = Result.map_error (fun detail -> Confirmation_rejected detail) in
  match json with
               | `Assoc fields ->
                 let names = List.map fst fields in
                 let allowed = ["goal_id"; "criterion_revision"; "request_id"; "verification_run_id"; "expected_workspace"; "expected_operator_id"; "expected_runtime_instance_id"] in
                 if List.exists (fun key -> not (List.mem key allowed)) names
                    || List.length names <> List.length (List.sort_uniq String.compare names)
                 then Error (Confirmation_rejected "unknown or duplicate confirmation fields")
                 else
                   let open Result.Syntax in
                   let* goal_id = rejected (non_empty_string_field fields "goal_id") in
                   let* criterion_revision = rejected (non_empty_string_field fields "criterion_revision") in
                   let* request_id = rejected (non_empty_string_field fields "request_id") in
                   let* verification_run_id = rejected (non_empty_string_field fields "verification_run_id") in
                   let* expected_operator_id = rejected (non_empty_string_field fields "expected_operator_id") in
                   let* expected_runtime_instance_id = rejected (non_empty_string_field fields "expected_runtime_instance_id") in
                   let* () = if String.equal expected_runtime_instance_id Build_identity.runtime_instance_id then Ok ()
                     else Error (Confirmation_rejected "server instance changed; inspect the proof again") in
                   let* () = if String.equal expected_operator_id operator_id then Ok ()
                     else Error (Confirmation_rejected "operator changed; inspect the proof again") in
                   let* () =
                     if not (List.mem_assoc "expected_workspace" fields) then
                       Error (Confirmation_rejected "expected_workspace precondition is required")
                     else
                       match Workspace.validate_expected_workspace ~config json with
                       | Ok _ -> Ok ()
                       | Error Workspace.Invalid_workspace_precondition ->
                         Error (Confirmation_rejected "invalid expected_workspace precondition")
                       | Error Workspace.Workspace_precondition_failed ->
                         Error (Confirmation_rejected "workspace precondition failed") in
                   let* () = require_confirmation_backend ~config ~goal_id in
                   Workspace_goals.confirm_completion config
                     ~after_confirmation:(Candle_payout_owed.after_confirmation config)
                     ~goal_id ~operator_id ~criterion_revision ~request_id ~verification_run_id
                   |> Result.map_error confirmation_error_of_write_error
                   |> Result.map (function
                     | `Assoc result -> `Assoc (("inspection_operator_id", `String operator_id) :: result)
                     | other -> other)
               | _ -> Error (Confirmation_rejected "request body must be an object")

;;

let commit_goal_confirmation_body ~config ~operator_id body =
  match Yojson.Safe.from_string body with
  | json -> commit_goal_confirmation_json ~config ~operator_id json
  | exception Yojson.Json_error detail -> Error (Confirmation_rejected detail)
;;

(* Task cancellation is an operator lifecycle action, alongside the verdict
   boundary. Neither path grants agent tools authority over another owner. *)
let commit_operator_cancel_json ~config ~operator_id json =
  let open Result.Syntax in
  let invalid message =
    Error (Masc_domain.System (Masc_domain.System_error.ValidationError message))
  in
  match json with
  | `Assoc fields ->
    let names = List.map fst fields in
    let allowed = [ "task_id"; "reason"; "expected_workspace" ] in
    if List.exists (fun name -> not (List.mem name allowed)) names
       || List.length names <> List.length (List.sort_uniq String.compare names)
    then invalid "unknown or duplicate cancellation fields"
    else if not (List.mem_assoc "expected_workspace" fields)
    then invalid "expected_workspace precondition is required"
    else
      let* _ =
        match Workspace.validate_expected_workspace ~config json with
        | Ok args -> Ok args
        | Error Workspace.Invalid_workspace_precondition ->
          invalid "invalid expected_workspace precondition"
        | Error Workspace.Workspace_precondition_failed ->
          Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState
            "workspace precondition failed"))
      in
      let required key =
        match non_empty_string_field fields key with
        | Ok value -> Ok value
        | Error message -> invalid message
      in
      let* task_id = required "task_id" in
      let* reason = required "reason" in
      Workspace.cancel_task_as_operator_r config ~operator_id ~task_id ~reason ()
  | _ -> invalid "request body must be a JSON object"
;;

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/goals/confirmation" (fun state operator_id req reqd ->
           let request = req in let config = Mcp_server.workspace_config state in
           match Server_auth.validate_read_workspace_precondition ~config req with
           | Error error ->
               let body, status = Server_auth.read_workspace_precondition_error_response error in
               respond_json_value_with_cors ~status request reqd body
           | Ok (Server_auth.Workspace_read_unbound | Server_auth.Workspace_read_matched) ->
           read_goal_confirmation ~config ~operator_id req
           |> respond_goal_confirmation ~cors:(public_read_cors_headers request) reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/goals/confirmation" (fun state operator_id request reqd ->
           (* The body callback runs after the request-authority binding ends. *)
           let cors = public_read_cors_headers request in
           Http.Request.read_body_async reqd (fun body ->
             commit_goal_confirmation_body ~config:(Mcp_server.workspace_config state)
               ~operator_id body |> respond_goal_confirmation ~cors reqd))
  |> Server_route.get Server_route.Public_read "/api/v1/verification/requests" (fun state req reqd ->
         let request = req in let task_id = trimmed_query_param req "task_id" in
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
       )
  |> Server_route.get Server_route.Public_read "/api/v1/verification/summary" (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = Dashboard_verification.summary_json ~base_path () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/verification/specs" (fun _state req reqd ->
         let json = Dashboard_tla_specs.specs_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/verification/tlc-results" (fun _state req reqd ->
         let json = Dashboard_tla_specs.tlc_results_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/verification/evidence" (fun state operator_id req reqd ->
            let request = req in let config = Mcp_server.workspace_config state in
            match Server_utils.query_param req "task_id",Server_utils.query_param req "verification_id" with
            | (None,_) | (_,None) ->
              respond_json_value_with_cors
                ~status:`Bad_request
                request
                reqd
                (error_json "task_id and verification_id query parameters are required")
            | Some task_id,Some verification_id ->
              let item_index = match Server_utils.query_param req "item_index" with
                | None -> Ok None
                | Some raw -> (match int_of_string_opt raw with
                    | Some index when index >= 0 -> Ok (Some index)
                    | Some _ | None -> Error "item_index must be a non-negative integer") in
              (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                 Result.bind item_index (fun item_index ->
                   operator_evidence_projection ~item_index ~config ~operator_id ~task_id ~verification_id)) with
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
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/tasks/cancel" (fun state operator_id request reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result =
               try commit_operator_cancel_json
                 ~config:(Mcp_server.workspace_config state) ~operator_id
                 (Yojson.Safe.from_string body)
               with Yojson.Json_error message ->
                 Error (Masc_domain.System (Masc_domain.System_error.ValidationError
                   ("invalid JSON: " ^ message)))
             in
             match result with
             | Error error ->
               respond_json_value_with_cors
                 ~status:(Server_auth.http_status_of_auth_error error)
                 request reqd (error_json (Masc_domain.masc_error_to_string error))
             | Ok outcome ->
               respond_json_value_with_cors request reqd
                 (`Assoc [ "ok", `Bool true
                         ; "message", `String outcome.Workspace.message
                         ; "noop", `Bool outcome.noop ])))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/verification/verdict" (fun state operator_id request reqd ->
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

module For_testing = struct
  let commit_operator_cancel_json = commit_operator_cancel_json
  let commit_goal_confirmation_json = commit_goal_confirmation_json
  let confirmation_error_to_string = confirmation_error_to_string
  let parse_operator_verdict_json = parse_operator_verdict_json
  let operator_evidence_json = operator_evidence_json
  let commit_operator_verdict = commit_operator_verdict
end
