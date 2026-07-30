(** Admin-only durable Keeper event-queue control boundary. *)

module Http = Http_server_eio

let ( let* ) = Result.bind
let schema = "keeper_event_queue.operator.request.v1"
let result_schema = "keeper_event_queue.operator.result.v1"
let prefix = "/api/v1/keepers/"

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

type request =
  | Cancel of
      { expected_revision : int64
      ; source : Keeper_event_queue.stimulus
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { expected_revision : int64
      ; source : Keeper_event_queue.stimulus
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { expected_revision : int64
      ; source : Keeper_event_queue.stimulus
      ; operator_operation_id : string
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

let expected_revision fields =
  let* value = string_field "expected_revision" fields in
  match Int64.of_string_opt value with
  | Some revision when Int64.compare revision 0L >= 0 -> Ok revision
  | Some _ | None -> Error "expected_revision must be a non-negative int64 string"
;;

let source fields =
  let* value = field "source" fields in
  Keeper_event_queue.stimulus_of_yojson value
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
      let* expected_revision = expected_revision fields in
      let* source = source fields in
      let* operator_operation_id = string_field "operator_operation_id" fields in
      let* () =
        if operator_operation_id = ""
           || not (String.equal operator_operation_id (String.trim operator_operation_id))
        then Error "operator_operation_id must be non-empty and trimmed"
        else Ok ()
      in
      let common =
        [ "action"
        ; "expected_revision"
        ; "operator_operation_id"
        ; "schema"
        ; "source"
        ]
      in
      match action with
      | "cancel" ->
        let* () = require_exact_fields ("reason" :: common) fields in
        let* reason = string_field "reason" fields in
        if reason = "" || not (String.equal reason (String.trim reason))
        then Error "reason must be non-empty and trimmed"
        else
          Ok
            (Cancel
               { expected_revision; source; operator_operation_id; reason })
      | "transfer" ->
        let* () = require_exact_fields ("target_keeper" :: common) fields in
        let* target_keeper = string_field "target_keeper" fields in
        if not (Keeper_config.validate_name target_keeper)
        then Error "target_keeper is invalid"
        else
          Ok
            (Transfer
               { expected_revision
               ; source
               ; operator_operation_id
               ; target_keeper
               })
      | "reprioritize" ->
        let* () = require_exact_fields ("urgency" :: common) fields in
        let* urgency_value = string_field "urgency" fields in
        let* urgency = Keeper_event_queue.urgency_of_string urgency_value in
        Ok
          (Reprioritize
             { expected_revision; source; operator_operation_id; urgency })
      | value -> Error ("unknown event queue operator action: " ^ value)
;;

let transition_result_json = function
  | Keeper_registry_event_queue.Transition_applied receipt ->
    `Assoc
      [ "status", `String "applied"
      ; "transition_id", `String receipt.transition_id
      ]
  | Keeper_registry_event_queue.Transition_already_applied receipt ->
    `Assoc
      [ "status", `String "already_applied"
      ; "transition_id", `String receipt.transition_id
      ]
  | Keeper_registry_event_queue.Transition_committed_followup_failed
      { receipt; stage; detail } ->
    `Assoc
      [ "status", `String "committed_followup_failed"
      ; "transition_id", `String receipt.transition_id
      ; ( "stage"
        , `String
            (match stage with
             | `Checkpoint -> "checkpoint"
             | `Wal_compaction -> "wal_compaction"
             | `Projection -> "projection") )
      ; "detail", `String detail
      ]
;;

let run_request ~base_path ~keeper_name request =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Error "keeper is not registered"
  | Some entry ->
    let owner_nonce = entry.meta.runtime.nonce in
    (match
       Keeper_turn_admission.run_admin_if_free ~base_path ~keeper_name (fun () ->
         match Keeper_registry.get ~base_path keeper_name with
         | None -> Error "keeper registration disappeared"
         | Some current when current.meta.runtime.nonce <> owner_nonce ->
           Error "keeper owner nonce changed"
         | Some _ ->
           let applied_at = Time_compat.now () in
           match request with
           | Cancel
               { expected_revision; source; operator_operation_id; reason } ->
             Keeper_registry_event_queue.cancel_pending_accepted_result
               ~base_path
               keeper_name
               ~current_owner_nonce:owner_nonce
               ~applied_at
               ~cancellation:
                 { source
                 ; source_revision = expected_revision
                 ; owner_nonce
                 ; operator_operation_id
                 ; reason
                 }
             |> Result.map transition_result_json
           | Transfer
               { expected_revision
               ; source
               ; operator_operation_id
               ; target_keeper
               } ->
             if String.equal keeper_name target_keeper
             then Error "source and target keeper must differ"
             else
               let transfer : Keeper_registry_event_queue.accepted_transfer =
                 { source
                 ; source_revision = expected_revision
                 ; owner_nonce
                 ; operator_operation_id
                 ; from_keeper = keeper_name
                 ; to_keeper = target_keeper
                 }
               in
               let* source_result =
                 Keeper_registry_event_queue.transfer_pending_accepted_result
                   ~base_path
                   keeper_name
                   ~current_owner_nonce:owner_nonce
                   ~applied_at
                   ~transfer
               in
               let* () =
                 match
                   Keeper_registry_event_queue.project_accepted_transfer_durable_result
                     ~base_path
                     target_keeper
                     ~transfer
                 with
                 | Keeper_registry_event_queue.Stimulus_enqueued
                 | Keeper_registry_event_queue.Stimulus_already_present -> Ok ()
                 | Keeper_registry_event_queue.Stimulus_storage_error detail ->
                   Error
                     ("source transfer committed but target projection failed: " ^ detail)
               in
               ignore
                 (Keeper_registry.wakeup_running
                    ~intent:Keeper_registry.Broadcast_signal
                    ~base_path
                    target_keeper :
                    Keeper_registry.wakeup_outcome);
               Ok (transition_result_json source_result)
           | Reprioritize
               { expected_revision; source; operator_operation_id = _; urgency } ->
             let* revision =
               Keeper_registry_event_queue.reprioritize_pending_result
                 ~base_path
                 keeper_name
                 ~expected_revision
                 ~source
                 ~urgency
             in
             ignore
               (Keeper_registry.wakeup_running
                  ~intent:Keeper_registry.Broadcast_signal
                  ~base_path
                  keeper_name :
                  Keeper_registry.wakeup_outcome);
             Ok
               (`Assoc
                 [ "status", `String "applied"
                 ; "revision", `String (Int64.to_string revision)
                 ]))
     with
     | `Ran result -> result
     | `Busy block ->
       Error
         ("keeper turn is busy: "
          ^ Keeper_turn_admission.autonomous_block_to_string block))
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
      let source, action, operator_operation_id =
        match operation with
        | Cancel { source; operator_operation_id; _ } ->
          source, "cancel", operator_operation_id
        | Transfer { source; operator_operation_id; _ } ->
          source, "transfer", operator_operation_id
        | Reprioritize { source; operator_operation_id; _ } ->
          source, "reprioritize", operator_operation_id
      in
      let result =
        run_request
          ~base_path:config.Workspace.base_path
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
          Audit_log.log_action
            config
            ~agent_id:actor
            ~action:(Audit_log.Custom "keeper_event_queue_operator")
            ~details:
              (`Assoc
                [ "keeper_name", `String keeper_name
                ; "action", `String action
                ; "operator_operation_id", `String operator_operation_id
                ; "post_id", `String source.post_id
                ; "payload_kind",
                  `String (Keeper_event_queue.payload_kind_label source.payload)
                ])
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
      | Ok result ->
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
