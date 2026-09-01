(** Admin-only durable Keeper event-queue control boundary. *)

module Http = Http_server_eio
module Execute = Server_dashboard_http_keeper_event_queue_operator_execute

let ( let* ) = Result.bind
let schema = "keeper_event_queue.operator.request.v2"
let result_schema = "keeper_event_queue.operator.result.v1"
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
            | Ok (Some source, _) ->
              [ "post_id", `String source.Execute.post_id
              ; "payload_kind", `String source.payload_kind
              ]
            | Ok (None, _) | Error _ -> []
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
