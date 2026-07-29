(** Authenticated HTTP boundary for durable pending Keeper chat inputs. *)

module Http = Http_server_eio

let cancel_permission = Masc_domain.CanBroadcast
let keeper_api_prefix = "/api/v1/keepers/"
let request_schema = "keeper_chat_queue.pending_cancel.request.v1"
let cancel_result_schema = "keeper_chat_queue.pending_cancel.result.v1"
let pending_result_schema = "keeper_chat_queue.pending.v1"

let keeper_path_segments path =
  if not (String.starts_with ~prefix:keeper_api_prefix path)
  then None
  else
    Some
      (String.sub
         path
         (String.length keeper_api_prefix)
         (String.length path - String.length keeper_api_prefix)
       |> String.split_on_char '/')
;;

let pending_get_route path =
  match keeper_path_segments path with
  | Some [ keeper_name; "chat"; "pending" ] when keeper_name <> "" ->
    Some keeper_name
  | Some _ | None -> None
;;

let pending_cancel_route path =
  match keeper_path_segments path with
  | Some [ keeper_name; "chat"; "receipts"; receipt_id; "cancel" ]
    when keeper_name <> "" && receipt_id <> "" ->
    Some (keeper_name, receipt_id)
  | Some _ | None -> None
;;

let mutation_error_status = function
  | Keeper_chat_queue.Invalid_input _ -> `Bad_request
  | Keeper_chat_queue.Receipt_already_terminal _
  | Keeper_chat_queue.Receipt_not_recovery_required _
  | Keeper_chat_queue.Receipt_not_pending _
  | Keeper_chat_queue.Recovery_revision_mismatch _
  | Keeper_chat_queue.Recovery_lease_mismatch _ ->
    `Conflict
  | Keeper_chat_queue.Persistence_not_configured
  | Keeper_chat_queue.Snapshot_unavailable _
  | Keeper_chat_queue.Revision_exhausted
  | Keeper_chat_queue.Persist_failed _ ->
    `Service_unavailable
;;

let current_work_json state keeper_name =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match
    (Keeper_turn_admission.snapshot_for ~base_path ~keeper_name).snapshot_in_flight
  with
  | None -> `Null
  | Some { Keeper_turn_admission.lane; started_at } ->
    `Assoc
      [ "lane", `String (Keeper_turn_admission.lane_to_string lane)
      ; "started_at", `Float started_at
      ]
;;

let pending_receipt_json ~keeper_name ~revision
      ({ Keeper_chat_queue.receipt_id; message; state } :
        Keeper_chat_queue.active_receipt)
  =
  `Assoc
    [ ( "receipt"
      , Server_dashboard_http_keeper_api_types.keeper_chat_receipt_json
          ~keeper_name
          ~revision
          { Keeper_chat_queue.receipt_id; state } )
    ; "content", `String message.content
    ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson message.user_blocks
    ; "attachments", Keeper_multimodal_input.attachments_to_yojson message.attachments
    ; "submitted_at", `Float message.timestamp
    ]
;;

let handle_get state request reqd ~keeper_name =
  let respond ?(status = `OK) json =
    Server_auth.respond_json_value_with_cors ~status request reqd json
  in
  if not (Keeper_config.validate_name keeper_name)
  then
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String pending_result_schema
        ; "ok", `Bool false
        ; "error", `String (Printf.sprintf "invalid keeper name: %s" keeper_name)
        ])
  else
    match Keeper_chat_queue.pending_receipts ~keeper_name with
    | Error error ->
      Log.Keeper.warn
        "keeper_chat_pending: projection failed keeper=%s error=%s"
        keeper_name
        (Keeper_chat_queue.mutation_error_to_string error);
      respond
        ~status:(mutation_error_status error)
        (`Assoc
          [ "schema", `String pending_result_schema
          ; "ok", `Bool false
          ; "error", Keeper_chat_queue.mutation_error_to_json error
          ])
    | Ok { revision; receipts } ->
      Log.Keeper.debug
        "keeper_chat_pending: projected keeper=%s revision=%Ld pending_count=%d"
        keeper_name
        revision
        (List.length receipts);
      respond
        (`Assoc
          [ "schema", `String pending_result_schema
          ; "ok", `Bool true
          ; "keeper_name", `String keeper_name
          ; "revision", `String (Int64.to_string revision)
          ; "current_work", current_work_json state keeper_name
          ; ( "pending"
            , `List
                (List.map
                   (pending_receipt_json ~keeper_name ~revision)
                   receipts) )
          ])
;;

let duplicate_assoc_keys fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates
    | (key, _) :: rest ->
      if List.mem key seen
      then loop seen (key :: duplicates) rest
      else loop (key :: seen) duplicates rest
  in
  loop [] [] fields |> List.sort_uniq String.compare
;;

let parse_cancel_request body =
  let ( let* ) = Result.bind in
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
  let* () =
    match duplicate_assoc_keys fields with
    | [] -> Ok ()
    | keys -> Error ("duplicate field(s): " ^ String.concat ", " keys)
  in
  match fields with
  | [ "schema", `String schema ] when String.equal schema request_schema -> Ok ()
  | [ "schema", `String schema ] -> Error ("unsupported schema: " ^ schema)
  | [ "schema", _ ] -> Error "schema must be a string"
  | _ -> Error "request must contain exactly schema"
;;

let audit config ~actor ~keeper_name ~receipt_id ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "keeper_chat_queue_pending_cancel")
      ~details:
        (`Assoc
          [ "keeper_name", `String keeper_name
          ; "receipt_id", `String (Keeper_chat_queue.Receipt_id.to_string receipt_id)
          ])
      ~outcome
      ();
    `Assoc [ "recorded", `Bool true ]
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    `Assoc
      [ "recorded", `Bool false
      ; "error", `String (Observability_redact.redact_text (Printexc.to_string exn))
      ]
;;

let handle_cancel_post state ~actor request reqd ~keeper_name ~raw_receipt_id body =
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request json reqd
  in
  let bad_request message =
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String cancel_result_schema
        ; "ok", `Bool false
        ; "error", `Assoc [ "message", `String message ]
        ])
  in
  if not (Keeper_config.validate_name keeper_name)
  then bad_request (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else
    match Keeper_chat_queue.Receipt_id.of_string raw_receipt_id with
    | Error message -> bad_request message
    | Ok receipt_id ->
      (match parse_cancel_request body with
       | Error message -> bad_request message
       | Ok () ->
         let result =
           Keeper_chat_queue.cancel_pending
             ~keeper_name
             ~receipt_id
             ~cancellation:
               { cancelled_at = Time_compat.now ()
               ; detail = "cancelled by dashboard user before delivery"
               }
         in
         let audit =
           audit
             (Mcp_server.workspace_config state)
             ~actor
             ~keeper_name
             ~receipt_id
             ~outcome:
               (match result with
                | Ok _ -> Audit_log.Success
                | Error error ->
                  Audit_log.Failure
                    (Keeper_chat_queue.mutation_error_to_string error))
         in
         (match result with
          | Ok report ->
            Log.Keeper.info
              "keeper_chat_pending: cancelled keeper=%s receipt=%s revision=%Ld"
              keeper_name
              raw_receipt_id
              report.revision
          | Error error ->
            Log.Keeper.warn
              "keeper_chat_pending: cancel failed keeper=%s receipt=%s error=%s"
              keeper_name
              raw_receipt_id
              (Keeper_chat_queue.mutation_error_to_string error));
         match result with
         | Ok report ->
           let receipt : Keeper_chat_queue.receipt_view =
             { receipt_id = report.receipt_id; state = report.state }
           in
           respond
             (`Assoc
               [ "schema", `String cancel_result_schema
               ; "ok", `Bool true
               ; ( "receipt"
                 , Server_dashboard_http_keeper_api_types.keeper_chat_receipt_json
                     ~keeper_name
                     ~revision:report.revision
                     receipt )
               ; "audit", audit
               ])
         | Error error ->
           respond
             ~status:(mutation_error_status error)
             (`Assoc
               [ "schema", `String cancel_result_schema
               ; "ok", `Bool false
               ; "error", Keeper_chat_queue.mutation_error_to_json error
               ; "audit", audit
               ]))
;;
