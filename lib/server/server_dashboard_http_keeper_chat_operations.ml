module Http = Http_server_eio
module Operation = Keeper_owner.Chat_operation
module Operation_id = Operation.Operation_id
module Owner = Keeper_owner
module Registry = Keeper_owner_registry

let mutation_permission = Masc_domain.CanBroadcast

type get_route =
  | Operation_list of { keeper_name : string }
  | Operation_exact of
      { keeper_name : string
      ; raw_operation_id : string
      }
  | Chat_events of { keeper_name : string }

(* Operation reads carry state and input the dashboard already shows. The
   event log carries the turn's reasoning in full, which /raw-trace and
   /trajectory?include_thinking already put behind CanAdmin: same data, same
   gate (server_dashboard_http_keeper_api_types.ml, keeper_get_permission). *)
let get_permission = function
  | Operation_list _ | Operation_exact _ -> Masc_domain.CanReadState
  | Chat_events _ -> Masc_domain.CanAdmin
;;

type mutation =
  | Edit
  | Move_to_end
  | Cancel

type mutation_route =
  { keeper_name : string
  ; raw_operation_id : string
  ; mutation : mutation
  }

type api_error =
  { status : Httpun.Status.t
  ; code : string
  ; message : string
  }

let path_segments path =
  path
  |> String.split_on_char '/'
  |> List.filter_map (fun value ->
    let value = Uri.pct_decode value |> String.trim in
    if String.equal value "" then None else Some value)
;;

let get_route path =
  match path_segments path with
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations" ] ->
    Some (Operation_list { keeper_name })
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"; raw_operation_id ] ->
    Some (Operation_exact { keeper_name; raw_operation_id })
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "events" ] ->
    Some (Chat_events { keeper_name })
  | _ -> None
;;

let mutation_route path =
  match path_segments path with
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"
    ; raw_operation_id; action
    ] ->
    let mutation =
      match action with
      | "edit" -> Some Edit
      | "move-to-end" -> Some Move_to_end
      | "cancel" -> Some Cancel
      | _ -> None
    in
    Option.map
      (fun mutation -> { keeper_name; raw_operation_id; mutation })
      mutation
  | _ -> None
;;

let error_json error =
  `Assoc
    [ "schema", `String "masc.keeper_chat_operation.error.v1"
    ; "error", `String error.code
    ; "message", `String error.message
    ]
;;

let respond_error request reqd error =
  Log.Dashboard.warn "keeper_chat_operation_api error=%s" error.code;
  Server_auth.respond_json_value_with_cors
    ~status:error.status
    request
    reqd
    (error_json error)
;;

let invalid_input message = { status = `Bad_request; code = "invalid_input"; message }
let unknown_operation message = { status = `Not_found; code = "unknown_operation"; message }

let conflict code message =
  { status = `Conflict; code; message }
;;

let unavailable code message =
  { status = `Service_unavailable; code; message }
;;

let gone code message = { status = `Gone; code; message }

let api_error_of_command_error error =
  let message = Registry.command_error_to_string error in
  match error with
  | Registry.Command_lookup_failed
      (Owner_not_found _ | Owner_unavailable _ | Inventory_not_installed _) ->
    unknown_operation message
  | Command_lookup_failed (Owner_initialization_failed _ | Inventory_stopping) ->
    unavailable "store_unavailable" message
  | Command_lifecycle_reserved _ -> unavailable "owner_stopping" message
  | Command_rejected (Owner.Operation_rejected operation_error) ->
    (match Owner.operation_error_kind operation_error with
     | Invalid_operation_input -> invalid_input message
     | Unknown_operation -> unknown_operation message
     | Operation_not_queued -> conflict "not_queued" message
     | Operation_idempotency_conflict -> conflict "idempotency_conflict" message
     | Operation_store_unavailable ->
       unavailable "store_unavailable" message)
  | Command_rejected (Owner.Store_unavailable _) ->
    unavailable "store_unavailable" message
  | Command_rejected (Owner.Owner_stopping | Owner.Owner_closed) ->
    unavailable "owner_stopping" message
  | Command_rejected (Owner.Reducer_rejected _) ->
    unavailable "store_unavailable" message
;;

let operation_id raw =
  Operation_id.of_string raw |> Result.map_error invalid_input
;;

let base_path state =
  (Mcp_server.workspace_config state).Workspace.base_path
;;

let parse_after_sequence request =
  match Server_utils.query_param request "after_sequence" with
  | None -> Ok None
  | Some raw ->
    (match Int64.of_string_opt (String.trim raw) with
     | Some value when Int64.compare value 0L >= 0 -> Ok (Some value)
     | Some _ | None -> Error (invalid_input "after_sequence must be a non-negative int64"))
;;

(* RFC-0412 §3.2, v2 events endpoint: the journal as written, paged over seq.
   The default page and the ceiling are the journal's own
   ([Keeper_chat_event_log.page_default_limit], [page_max_limit]), read here
   and by the TUI that pages at the ceiling. *)

(* The wire's absence rule lives in [Keeper_chat_event_log.replay_position_of_wire]:
   no [since_seq] is the whole journal, [n >= 0] is the last seq already held. *)
let parse_since_seq request =
  let rejected =
    Error
      (invalid_input
         "since_seq must be an integer >= 0, the last seq already held; omit it for \
          the whole journal")
  in
  let raw =
    match Server_utils.query_param request "since_seq" with
    | None -> Ok None
    | Some raw ->
      (match int_of_string_opt (String.trim raw) with
       | Some value -> Ok (Some value)
       | None -> rejected)
  in
  match raw with
  | Error _ as error -> error
  | Ok raw ->
    (match Keeper_chat_event_log.replay_position_of_wire raw with
     | Some position -> Ok position
     | None -> rejected)
;;

let parse_limit request =
  match Server_utils.query_param request "limit" with
  | None -> Ok Keeper_chat_event_log.page_default_limit
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value when value >= 1 && value <= Keeper_chat_event_log.page_max_limit ->
       Ok value
     | Some _ | None ->
       Error
         (invalid_input
            (Printf.sprintf
               "limit must be an integer in 1..%d"
               Keeper_chat_event_log.page_max_limit)))
;;

let parse_operation_id_query request =
  match Server_utils.query_param request "operation_id" with
  | None -> Error (invalid_input "operation_id is required")
  | Some raw -> operation_id (String.trim raw)
;;

let rec take_at_most n acc = function
  | rest when n = 0 -> List.rev acc, rest
  | [] -> List.rev acc, []
  | entry :: rest -> take_at_most (n - 1) (entry :: acc) rest
;;

(* What a missing journal means depends on what the store holds for the
   operation. Queued or Running: nothing journaled yet, so an empty page is
   the truth. Terminal: there is no journal and the row does not say why —
   the retention sweep removes finished operations' journals, but a fail-open
   append that never created the file (mkdir or first append failure) and an
   operation that ran before journaling existed leave the same absence — so
   an empty page would draw an empty conversation with no error, and the
   caller is told only what is known: no journal. No row at all: an operation
   nobody submitted. *)
type missing_journal =
  | Nothing_journaled_yet
  | No_journal_for_settled_operation
  | Unknown_operation

let classify_missing_journal = function
  | None -> Unknown_operation
  | Some state ->
    if Operation.is_terminal state
    then No_journal_for_settled_operation
    else Nothing_journaled_yet
;;

let no_journal_for_settled_operation_message ~operation_id =
  "no journal exists for Keeper chat operation " ^ operation_id ^ ", which has ended"
;;

let chat_events_page ~operation_id ~since_seq ~limit ~redact_json entries =
  let page, rest =
    entries
    |> List.filter (fun (entry : Keeper_chat_event_log.journaled_event) ->
      Keeper_chat_event_log.seq_is_after since_seq entry.seq)
    |> take_at_most limit []
  in
  (* The position to feed back: after the last event served, or the caller's
     own position when the page is empty — [null] when that was the whole
     journal, since a response field cannot be absent the way a request field
     can. *)
  let next_since_seq =
    match List.rev page with
    | [] -> since_seq
    | (last : Keeper_chat_event_log.journaled_event) :: _ ->
      Keeper_chat_event_log.After_seq last.seq
  in
  `Assoc
    [ "schema", `String "masc.keeper_chat_events.v2"
    ; "operation_id", `String operation_id
    ; ( "events"
      , `List
          (List.map
             (fun entry -> redact_json (Keeper_chat_event_log.journaled_event_to_json entry))
             page) )
    ; "has_more", `Bool (not (List.is_empty rest))
    ; "next_since_seq", Keeper_chat_event_log.replay_position_to_yojson next_since_seq
    ]
;;

let handle_get state request reqd = function
  | Chat_events { keeper_name } ->
    let ( let* ) = Result.bind in
    (match
       let* operation_id = parse_operation_id_query request in
       let* since_seq = parse_since_seq request in
       let* limit = parse_limit request in
       Ok (operation_id, since_seq, limit)
     with
     | Error error -> respond_error request reqd error
     | Ok (operation_id, since_seq, limit) ->
       let base_path = base_path state in
       let operation_id_text = Operation_id.to_string operation_id in
       let path =
         Keeper_chat_event_log.journal_path
           ~base_dir:base_path
           ~keeper_name
           ~operation_id:operation_id_text
       in
       let respond entries =
         Log.Dashboard.debug
           "keeper_chat_events keeper=%s operation_id=%s since_seq=%s limit=%d journaled=%d"
           keeper_name
           operation_id_text
           (Keeper_chat_event_log.replay_position_to_string since_seq)
           limit
           (List.length entries);
         (* Same second redaction layer the SSE projection and the reconnect
            replay apply: the journal is redacted at publish, this covers
            lines written before that held. *)
         let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
         Server_auth.respond_json_value_with_cors
           request
           reqd
           (chat_events_page
              ~operation_id:operation_id_text
              ~since_seq
              ~limit
              ~redact_json:(Keeper_secret_redaction.redact_json redaction)
              entries)
       in
       (match Keeper_chat_event_log.read_journal_path_result path with
        | Ok entries -> respond entries
        | Error Keeper_chat_event_log.Journal_missing ->
          (match Registry.exact_operation ~base_path ~keeper_name operation_id with
           | Ok operation ->
             (match
                classify_missing_journal
                  (Option.map (fun (operation : Operation.t) -> operation.state) operation)
              with
              | Nothing_journaled_yet -> respond []
              | No_journal_for_settled_operation ->
                (* The [journal_pruned] code is the client's contract for
                   "nothing to reload, now or later"; the message states only
                   what the server knows. *)
                respond_error
                  request
                  reqd
                  (gone
                     "journal_pruned"
                     (no_journal_for_settled_operation_message
                        ~operation_id:operation_id_text))
              | Unknown_operation ->
                respond_error
                  request
                  reqd
                  (unknown_operation
                     ("unknown Keeper chat operation: " ^ operation_id_text)))
           | Error error -> respond_error request reqd (api_error_of_command_error error))
        | Error (Journal_unreadable detail) ->
          (* This endpoint exists to serve the log, so the log's failure is
             the response (RFC-0412 §3.5: loud from day one on v2). *)
          respond_error request reqd (unavailable "journal_unreadable" detail)
        | Error (Journal_corrupt detail) ->
          respond_error request reqd (unavailable "journal_corrupt" detail)))
  | Operation_exact { keeper_name; raw_operation_id } ->
    (match operation_id raw_operation_id with
     | Error error -> respond_error request reqd error
     | Ok operation_id ->
       (match Registry.exact_operation ~base_path:(base_path state) ~keeper_name operation_id with
        | Error error -> respond_error request reqd (api_error_of_command_error error)
        | Ok None ->
          respond_error
            request
            reqd
            (unknown_operation
               ("unknown Keeper chat operation: " ^ Operation_id.to_string operation_id))
        | Ok (Some operation) ->
          Log.Dashboard.debug
            "keeper_chat_operation_get keeper=%s operation_id=%s state=%s"
            keeper_name
            (Operation_id.to_string operation.operation_id)
            (Operation.state_to_string operation.state);
          Server_auth.respond_json_value_with_cors
            request
            reqd
            (Operation.to_json operation)))
  | Operation_list { keeper_name } ->
    let state_filter = Server_utils.query_param request "state" in
    (match parse_after_sequence request with
     | Error error -> respond_error request reqd error
     | Ok after_sequence ->
       (match state_filter with
        | Some "queued" ->
       (match
          Registry.list_queued_operations
            ~base_path:(base_path state)
            ~keeper_name
            ~after_sequence
            ~limit:100
        with
        | Error error -> respond_error request reqd (api_error_of_command_error error)
        | Ok operations ->
          Log.Dashboard.debug
            "keeper_chat_operation_list keeper=%s state=queued count=%d"
            keeper_name
            (List.length operations);
          Server_auth.respond_json_value_with_cors
            request
            reqd
            (`Assoc
               [ "schema", `String "masc.keeper_chat_operations.list.v1"
               ; "state", `String "Queued"
               ; "operations", `List (List.map Operation.to_json operations)
               ]))
        | Some _ | None ->
          respond_error request reqd (invalid_input "state=queued is required")))
;;

let strict_object body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then Error (invalid_input "request body must contain unique fields")
      else Ok fields
    | _ -> Error (invalid_input "request body must be a JSON object")
  with
  | Yojson.Json_error detail -> Error (invalid_input ("invalid json: " ^ detail))
;;

let parse_edit body =
  match strict_object body with
  | Error _ as error -> error
  | Ok [ "input", input ] ->
    (match Keeper_chat_operation_payload.input_of_json input with
     | Ok _ -> Ok input
     | Error detail -> Error (invalid_input ("input: " ^ detail)))
  | Ok _ -> Error (invalid_input "edit body must contain exactly the input field")
;;

let parse_empty mutation body =
  match strict_object body with
  | Ok [] -> Ok ()
  | Ok _ -> Error (invalid_input (mutation ^ " body must be an empty object"))
  | Error _ as error -> error
;;

let mutation_to_string = function
  | Edit -> "edit"
  | Move_to_end -> "move_to_end"
  | Cancel -> "cancel"
;;

let handle_mutation state request reqd route body =
  match operation_id route.raw_operation_id with
  | Error error -> respond_error request reqd error
  | Ok operation_id ->
    let result =
      match route.mutation with
      | Edit ->
        (match parse_edit body with
         | Error error -> Error error
         | Ok input ->
           Registry.edit_queued_operation
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             ~operation_id
             ~input
           |> Result.map_error api_error_of_command_error)
      | Move_to_end ->
        (match parse_empty "move-to-end" body with
         | Error error -> Error error
         | Ok () ->
           Registry.move_queued_operation_to_end
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             operation_id
           |> Result.map_error api_error_of_command_error)
      | Cancel ->
        (match parse_empty "cancel" body with
         | Error error -> Error error
         | Ok () ->
           Registry.cancel_queued_operation
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             operation_id
           |> Result.map_error api_error_of_command_error)
    in
    (match result with
     | Error error -> respond_error request reqd error
     | Ok operation ->
       Log.Dashboard.info
         "keeper_chat_operation_mutation keeper=%s operation_id=%s action=%s state=%s"
         route.keeper_name
         (Operation_id.to_string operation.operation_id)
         (mutation_to_string route.mutation)
         (Operation.state_to_string operation.state);
       Server_auth.respond_json_value_with_cors
         request
         reqd
       (Operation.to_json operation))
;;

module For_testing = struct
  let no_journal_for_settled_operation_message = no_journal_for_settled_operation_message

  let parse_mutation_body mutation body =
    match mutation with
    | Edit ->
      parse_edit body
      |> Result.map Option.some
      |> Result.map_error (fun error -> error.code)
    | Move_to_end ->
      parse_empty "move-to-end" body
      |> Result.map (fun () -> None)
      |> Result.map_error (fun error -> error.code)
    | Cancel ->
      parse_empty "cancel" body
      |> Result.map (fun () -> None)
      |> Result.map_error (fun error -> error.code)
  ;;
end
