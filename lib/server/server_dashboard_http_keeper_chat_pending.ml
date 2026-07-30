(** Authenticated HTTP boundary for durable pending Keeper chat inputs. *)

module Http = Http_server_eio
let ( let* ) = Result.bind

let operator_permission = Masc_domain.CanAdmin
let keeper_api_prefix = "/api/v1/keepers/"
let request_schema = "keeper_chat_queue.pending_cancel.request.v1"
let cancel_result_schema = "keeper_chat_queue.pending_cancel.result.v1"
let pending_result_schema = "keeper_chat_queue.pending.v1"
let edit_request_schema = "keeper_chat_queue.pending_edit.request.v1"
let move_request_schema = "keeper_chat_queue.pending_move_to_end.request.v1"
let mutation_result_schema = "keeper_chat_queue.pending_mutation.result.v1"

type pending_mutation =
  | Cancel
  | Edit
  | Move_to_end

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

let pending_mutation_route path =
  match keeper_path_segments path with
  | Some [ keeper_name; "chat"; "receipts"; receipt_id; "cancel" ]
    when keeper_name <> "" && receipt_id <> "" ->
    Some (keeper_name, receipt_id, Cancel)
  | Some [ keeper_name; "chat"; "receipts"; receipt_id; "edit" ]
    when keeper_name <> "" && receipt_id <> "" ->
    Some (keeper_name, receipt_id, Edit)
  | Some [ keeper_name; "chat"; "receipts"; receipt_id; "move-to-end" ]
    when keeper_name <> "" && receipt_id <> "" ->
    Some (keeper_name, receipt_id, Move_to_end)
  | Some _ | None -> None
;;

let mutation_error_status = function
  | Keeper_chat_queue.Invalid_input _ -> `Bad_request
  | Keeper_chat_queue.Receipt_already_terminal _
  | Keeper_chat_queue.Receipt_not_recovery_required _
  | Keeper_chat_queue.Receipt_not_pending _
  | Keeper_chat_queue.Pending_revision_mismatch _
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

let pending_page_request request =
  let* limit =
    match Server_utils.query_param request "limit" with
    | None -> Ok Keeper_chat_queue.pending_page_limit
    | Some value ->
      (match int_of_string_opt value with
       | Some limit
         when limit > 0 && limit <= Keeper_chat_queue.pending_page_limit ->
         Ok limit
       | Some _ | None ->
         Error
           (Printf.sprintf
              "limit must be an integer between 1 and %d"
              Keeper_chat_queue.pending_page_limit))
  in
  let* after =
    match Server_utils.query_param request "after" with
    | None -> Ok None
    | Some value ->
      (match Int64.of_string_opt value with
       | Some cursor when Int64.compare cursor 0L >= 0 -> Ok (Some cursor)
       | Some _ | None ->
         Error "after must be a non-negative int64 string")
  in
  Ok (after, limit)
;;

let handle_get state request reqd ~keeper_name =
  let respond ?(status = `OK) json =
    Server_auth.respond_json_value_with_cors ~status request reqd json
  in
  let bad_request message =
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String pending_result_schema
        ; "ok", `Bool false
        ; "error", `String message
        ])
  in
  if not (Keeper_config.validate_name keeper_name)
  then bad_request (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else
    match pending_page_request request with
    | Error message -> bad_request message
    | Ok (after, limit) ->
    match Keeper_chat_queue.pending_receipts_page ~keeper_name ~after ~limit with
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
    | Ok { revision; receipts; total_pending; next_after } ->
      Log.Keeper.debug
        "keeper_chat_pending: projected keeper=%s revision=%Ld page_count=%d total_pending=%d"
        keeper_name
        revision
        (List.length receipts)
        total_pending;
      respond
        (`Assoc
          [ "schema", `String pending_result_schema
          ; "ok", `Bool true
          ; "keeper_name", `String keeper_name
          ; "revision", `String (Int64.to_string revision)
          ; "current_work", current_work_json state keeper_name
          ; "total_pending", `Int total_pending
          ; ( "next_after"
            , match next_after with
              | None -> `Null
              | Some cursor -> `String (Int64.to_string cursor) )
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

let audit config ~actor ~keeper_name ~receipt_id ~action ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom action)
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
             ~action:"keeper_chat_queue_pending_cancel"
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

type parsed_mutation =
  | Parsed_edit of { expected_revision : int64; content : string }
  | Parsed_move_to_end of { expected_revision : int64 }

let parse_revision = function
  | `String value ->
    (match Int64.of_string_opt value with
     | Some revision when Int64.compare revision 0L >= 0 -> Ok revision
     | Some _ | None -> Error "expected_revision must be a non-negative int64 string")
  | _ -> Error "expected_revision must be a string"
;;

let parse_mutation_request mutation body =
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
  let fields = List.sort (fun (left, _) (right, _) -> String.compare left right) fields in
  match mutation with
  | Cancel -> Error "cancel uses the pending cancel request schema"
  | Edit ->
    (match fields with
     | [ "content", `String content
       ; "expected_revision", revision
       ; "schema", `String schema
       ]
       when String.equal schema edit_request_schema ->
       let* expected_revision = parse_revision revision in
       Ok (Parsed_edit { expected_revision; content })
     | _ ->
       Error
         "edit request must contain exactly content, expected_revision, and the supported schema")
  | Move_to_end ->
    (match fields with
     | [ "expected_revision", revision; "schema", `String schema ]
       when String.equal schema move_request_schema ->
       let* expected_revision = parse_revision revision in
       Ok (Parsed_move_to_end { expected_revision })
     | _ ->
       Error
         "move request must contain exactly expected_revision and the supported schema")
;;

let pending_message ~keeper_name ~receipt_id =
  let* ({ revision; receipts } : Keeper_chat_queue.pending_snapshot) =
    Keeper_chat_queue.pending_receipts ~keeper_name
  in
  match
    List.find_opt
      (fun (receipt : Keeper_chat_queue.active_receipt) ->
         Keeper_chat_queue.Receipt_id.equal receipt.receipt_id receipt_id)
      receipts
  with
  | Some receipt -> Ok (revision, receipt.message)
  | None ->
    Error
      (Keeper_chat_queue.Receipt_not_pending
         { receipt_id; observed_state = None })
;;

let handle_mutation_post
    state
    ~actor
    request
    reqd
    ~keeper_name
    ~raw_receipt_id
    ~mutation
    body =
  match mutation with
  | Cancel ->
    handle_cancel_post
      state
      ~actor
      request
      reqd
      ~keeper_name
      ~raw_receipt_id
      body
  | Edit | Move_to_end ->
    let respond ?(status = `OK) json =
      Http.Response.json_value ~status ~request json reqd
    in
    let bad_request message =
      respond
        ~status:`Bad_request
        (`Assoc
          [ "schema", `String mutation_result_schema
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
        (match parse_mutation_request mutation body with
         | Error message -> bad_request message
         | Ok parsed ->
           let result, audit_action =
             match parsed with
             | Parsed_edit { expected_revision; content } ->
               ( (let* observed_revision, message =
                    pending_message ~keeper_name ~receipt_id
                  in
                  if not (Int64.equal observed_revision expected_revision)
                  then
                    Error
                      (Keeper_chat_queue.Pending_revision_mismatch
                         { receipt_id
                         ; expected_revision
                         ; observed_revision
                         })
                  else
                    Keeper_chat_queue.edit_pending
                      ~keeper_name
                      ~receipt_id
                      ~expected_revision
                      ~message:{ message with content })
               , "keeper_chat_queue_pending_edit" )
             | Parsed_move_to_end { expected_revision } ->
               ( Keeper_chat_queue.move_pending_to_end
                   ~keeper_name
                   ~receipt_id
                   ~expected_revision
               , "keeper_chat_queue_pending_move_to_end" )
           in
           let audit =
             audit
               (Mcp_server.workspace_config state)
               ~actor
               ~keeper_name
               ~receipt_id
               ~action:audit_action
               ~outcome:
                 (match result with
                  | Ok _ -> Audit_log.Success
                  | Error error ->
                    Audit_log.Failure
                      (Keeper_chat_queue.mutation_error_to_string error))
           in
           match result with
           | Ok report ->
             respond
               (`Assoc
                 [ "schema", `String mutation_result_schema
                 ; "ok", `Bool true
                 ; "keeper_name", `String keeper_name
                 ; "receipt_id", `String raw_receipt_id
                 ; "revision", `String (Int64.to_string report.revision)
                 ; "pending_index", `Int report.pending_index
                 ; "audit", audit
                 ])
           | Error error ->
             respond
               ~status:(mutation_error_status error)
               (`Assoc
                 [ "schema", `String mutation_result_schema
                 ; "ok", `Bool false
                 ; "error", Keeper_chat_queue.mutation_error_to_json error
                 ; "audit", audit
                 ]))
;;
