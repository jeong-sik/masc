(** Admin-only durable Keeper event-queue control boundary. *)

module Http = Http_server_eio
module Execute = Server_dashboard_http_keeper_event_queue_operator_execute

let ( let* ) = Result.bind
let schema = "keeper_event_queue.operator.request.v2"
let result_schema = "keeper_event_queue.operator.result.v1"
let pending_result_schema = "keeper_event_queue.pending.v2"
let pending_page_limit = 100
let prefix = "/api/v1/keepers/"
let operator_permission = Masc_domain.CanAdmin

let route path =
  if not (String.starts_with ~prefix path)
  then None
  else
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ keeper_name; "events"; "operator" ] when keeper_name <> "" ->
      Some keeper_name
    | _ -> None
;;

let pending_get_route path =
  if not (String.starts_with ~prefix path)
  then None
  else
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ keeper_name; "events"; "pending" ] when keeper_name <> "" ->
      Some keeper_name
    | _ -> None
;;

let pending_page_request request =
  let* limit =
    match Server_utils.query_param request "limit" with
    | None -> Ok pending_page_limit
    | Some value ->
      (match int_of_string_opt value with
       | Some limit when limit > 0 && limit <= pending_page_limit -> Ok limit
       | Some _ | None ->
         Error
           (Printf.sprintf
              "limit must be an integer between 1 and %d"
              pending_page_limit))
  in
  let* after =
    match Server_utils.query_param request "after" with
    | None -> Ok 0
    | Some value ->
      (match int_of_string_opt value with
       | Some after when after >= 0 -> Ok after
       | Some _ | None -> Error "after must be a non-negative integer")
  in
  Ok (after, limit)
;;

let pending_page ~after ~limit pending =
  let rec loop index remaining page_rev = function
    | [] -> List.rev page_rev
    | _ :: rest when index < after ->
      loop (index + 1) remaining page_rev rest
    | _ when remaining = 0 -> List.rev page_rev
    | selection :: rest ->
      let stimulus = selection.Keeper_event_queue_state.source in
      let item =
        `Assoc
          ([ "queue_index", `Int index
          ; "post_id", `String stimulus.Keeper_event_queue.post_id
          ; ( "source_ref"
            , `String
                (Keeper_event_queue_state.source_snapshot_ref stimulus) )
          ; ( "source_incarnation"
            , `String
                (Int64.to_string selection.admitted_revision) )
          ; ( "urgency"
            , `String
                (Keeper_event_queue.urgency_to_string stimulus.urgency) )
          ; "arrived_at_unix", `Float stimulus.arrived_at
          ; ( "payload_kind"
            , `String
                (Keeper_event_queue.payload_kind_label stimulus.payload) )
          ]
          (* [payload_kind] collapses every payload to a constant string, so a
             completion_authority_rejected row reached the operator without the
             rejection's reason — the one field that says why the keeper is
             blocked. Only that field is added: this projection deliberately
             omits raw payload content (a board stimulus carries post text),
             so the whole payload must not be serialized here. Other kinds are
             enumerated rather than folded into a wildcard so a new payload has
             to make an explicit decision about operator visibility. *)
          @ (match stimulus.payload with
             | Keeper_event_queue.Completion_authority_rejected rejection ->
               [ "rejection_reason", `String rejection.car_reason
               ; "rejection_task_id", `String rejection.car_task_id
               ]
             | Keeper_event_queue.Task_cancelled cancellation ->
               (* The reason is emitted only when the canceller gave one, so an
                  operator can tell an unexplained cancellation from one whose
                  stated reason was empty. *)
               [ "cancelled_task_id", `String cancellation.tc_task_id
               ; "cancelled_by", `String cancellation.tc_cancelled_by
               ]
               @ (match cancellation.tc_reason with
                  | None -> []
                  | Some reason -> [ "cancelled_reason", `String reason ])
             | Keeper_event_queue.Workspace_message message ->
               (* Who queued the message and under which workspace request, so
                  an operator reading the queue can find the transcript row. *)
               [ "message_request_id", `String message.wmsg_request_id
               ; "message_from", `String message.wmsg_from
               ]
             | Keeper_event_queue.Board_signal _
             | Keeper_event_queue.Board_attention _
             | Keeper_event_queue.Bootstrap
             | Keeper_event_queue.Fusion_completed _
             | Keeper_event_queue.Schedule_due _
             | Keeper_event_queue.Connector_attention _
             | Keeper_event_queue.Hitl_resolved _
             | Keeper_event_queue.Manual_compaction_requested
             | Keeper_event_queue.Goal_reconciliation_ready _ -> []))
      in
      loop (index + 1) (remaining - 1) (item :: page_rev) rest
  in
  loop 0 limit [] pending
;;

module For_testing = struct
  let pending_page = pending_page
end

let handle_get state request reqd ~keeper_name =
  let respond ?(status = `OK) json =
    Server_auth.respond_json_value_with_cors ~status request reqd json
  in
  let error ~status detail =
    respond
      ~status
      (`Assoc
        [ "schema", `String pending_result_schema
        ; "ok", `Bool false
        ; "error", `String detail
        ])
  in
  if not (Keeper_config.validate_name keeper_name)
  then error ~status:`Bad_request "invalid keeper name"
  else
    match pending_page_request request with
    | Error detail -> error ~status:`Bad_request detail
    | Ok (after, limit) ->
      let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
      (match
         Keeper_event_queue_persistence.load_state_result
           ~base_path
           ~keeper_name
       with
       | Error detail -> error ~status:`Service_unavailable detail
       | Ok queue_state ->
         let revision = Keeper_event_queue_state.revision queue_state in
         let pending = Keeper_event_queue_state.pending_selections queue_state in
         let total_pending = List.length pending in
         let page = pending_page ~after ~limit pending in
         let consumed = after + List.length page in
         let next_after =
           if consumed < total_pending
           then `String (string_of_int consumed)
           else `Null
         in
         respond
           (`Assoc
             [ "schema", `String pending_result_schema
             ; "ok", `Bool true
             ; "keeper_name", `String keeper_name
             ; "revision", `String (Int64.to_string revision)
             ; "total_pending", `Int total_pending
             ; "next_after", next_after
             ; "pending", `List page
             ]))
;;

type request = Execute.request =
  | Cancel of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { source_ref : string
      ; source_incarnation : int64
      ; urgency : Keeper_event_queue.urgency
      }

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")
;;

let source_incarnation fields =
  let* value = string_field "source_incarnation" fields in
  match Int64.of_string_opt value with
  | Some incarnation when Int64.compare incarnation 0L >= 0 ->
    Ok incarnation
  | Some _ | None ->
    Error "source_incarnation must be a non-negative int64 string"
;;

let source_ref fields =
  let* value = string_field "source_ref" fields in
  if String.length value = 64
     && String.for_all
          (function
            | '0' .. '9' | 'a' .. 'f' -> true
            | _ -> false)
          value
  then Ok value
  else Error "source_ref must be exactly 64 lowercase hexadecimal characters"
;;

let operator_operation_id fields =
  let* operation_id = string_field "operator_operation_id" fields in
  if operation_id = ""
     || not (String.equal operation_id (String.trim operation_id))
  then Error "operator_operation_id must be non-empty and trimmed"
  else Ok operation_id
;;

let require_exact_fields expected fields =
  let expected = List.sort String.compare expected in
  let observed = List.map fst fields |> List.sort String.compare in
  if observed = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "request fields must be exactly [%s]"
         (String.concat ", " expected))
;;

let parse body =
  let* fields =
    match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | value ->
      Error
        (Printf.sprintf
           "request body must be an object, received %s"
           (Json_util.kind_name value))
    | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  in
  let keys = List.map fst fields in
  if List.length keys <> List.length (List.sort_uniq String.compare keys)
  then Error "request contains duplicate fields"
  else
    let* request_schema = string_field "schema" fields in
    if not (String.equal request_schema schema)
    then Error ("unsupported schema: " ^ request_schema)
    else
      let* action = string_field "action" fields in
      let* source_ref = source_ref fields in
      let* source_incarnation = source_incarnation fields in
      let common =
        [ "action"
        ; "schema"
        ; "source_incarnation"
        ; "source_ref"
        ]
      in
      match action with
      | "cancel" ->
        let* () =
          require_exact_fields
            ("operator_operation_id" :: "reason" :: common)
            fields
        in
        let* operator_operation_id = operator_operation_id fields in
        let* reason = string_field "reason" fields in
        if reason = "" || not (String.equal reason (String.trim reason))
        then Error "reason must be non-empty and trimmed"
        else
          Ok
            (Cancel
               { source_ref
               ; source_incarnation
               ; operator_operation_id
               ; reason
               })
      | "transfer" ->
        let* () =
          require_exact_fields
            ("operator_operation_id" :: "target_keeper" :: common)
            fields
        in
        let* operator_operation_id = operator_operation_id fields in
        let* target_keeper = string_field "target_keeper" fields in
        if not (Keeper_config.validate_name target_keeper)
        then Error "target_keeper is invalid"
        else
          Ok
            (Transfer
               { source_ref
               ; source_incarnation
               ; operator_operation_id
               ; target_keeper
               })
      | "reprioritize" ->
        let* () = require_exact_fields ("urgency" :: common) fields in
        let* urgency_value = string_field "urgency" fields in
        let* urgency = Keeper_event_queue.urgency_of_string urgency_value in
        Ok
          (Reprioritize
             { source_ref; source_incarnation; urgency })
      | value -> Error ("unknown event queue operator action: " ^ value)
;;

let handle_post state ~actor request reqd ~keeper_name body =
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request json reqd
  in
  if not (Keeper_config.validate_name keeper_name)
  then
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String result_schema
        ; "ok", `Bool false
        ; "error", `String "invalid keeper name"
        ])
  else
    match parse body with
    | Error detail ->
      respond
        ~status:`Bad_request
        (`Assoc
          [ "schema", `String result_schema
          ; "ok", `Bool false
          ; "error", `String detail
          ])
    | Ok operation ->
      let config = Mcp_server.workspace_config state in
      let source_ref, source_incarnation, action, operator_operation_id =
        match operation with
        | Cancel
            { source_ref
            ; source_incarnation
            ; operator_operation_id
            ; _
            } ->
          source_ref, source_incarnation, "cancel", Some operator_operation_id
        | Transfer
            { source_ref
            ; source_incarnation
            ; operator_operation_id
            ; _
            } ->
          source_ref, source_incarnation, "transfer", Some operator_operation_id
        | Reprioritize { source_ref; source_incarnation; _ } ->
          source_ref, source_incarnation, "reprioritize", None
      in
      let result =
        Execute.run
          ~config
          ~keeper_name
          operation
      in
      (match result with
       | Ok _ ->
         Log.Keeper.info
           "keeper_event_queue_operator: applied keeper=%s action=%s"
           keeper_name
           action
       | Error _ ->
         Log.Keeper.warn
           "keeper_event_queue_operator: rejected keeper=%s action=%s"
           keeper_name
           action);
      let audit =
        try
          let source_details =
            match result with
            | Ok (source, _) ->
              [ "post_id", `String source.Keeper_event_queue.post_id
              ; ( "payload_kind"
                , `String
                    (Keeper_event_queue.payload_kind_label source.payload) )
              ]
            | Error _ -> []
          in
          Audit_log.log_action
            config
            ~agent_id:actor
            ~action:(Audit_log.Custom "keeper_event_queue_operator")
            ~details:
              (`Assoc
                (([ "keeper_name", `String keeper_name
                  ; "action", `String action
                  ; "source_ref", `String source_ref
                  ; ( "source_incarnation"
                    , `String (Int64.to_string source_incarnation) )
                  ]
                  @ (match operator_operation_id with
                     | Some value ->
                       [ "operator_operation_id", `String value ]
                     | None -> []))
                 @ source_details))
            ~outcome:
              (match result with
               | Ok _ -> Audit_log.Success
               | Error detail -> Audit_log.Failure detail)
            ();
          `Assoc [ "recorded", `Bool true ]
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          `Assoc
            [ "recorded", `Bool false
            ; "error", `String (Observability_redact.redact_text (Printexc.to_string exn))
            ]
      in
      match result with
      | Ok (_, result) ->
        respond
          (`Assoc
            [ "schema", `String result_schema
            ; "ok", `Bool true
            ; "keeper_name", `String keeper_name
            ; "result", result
            ; "audit", audit
            ])
      | Error detail ->
        respond
          ~status:`Conflict
          (`Assoc
            [ "schema", `String result_schema
            ; "ok", `Bool false
            ; "error", `String detail
            ; "audit", audit
            ])
;;
