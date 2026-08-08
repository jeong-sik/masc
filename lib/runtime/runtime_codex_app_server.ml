(** Native Codex app-server single-turn execution.

    The official CLI keeps ownership of ChatGPT credentials. We deliberately
    remove API-key fallback variables from the child environment and then gate
    on [account/read = chatgpt] before starting a thread. *)

type subscription =
  { plan_type : string
  ; email : string option
  }

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; developer_instructions : string option
  ; timeout_s : float
  }

let default_config ~cwd =
  { cli_path = "codex"
  ; cwd
  ; model = None
  ; developer_instructions = None
  ; timeout_s = 300.0
  }
;;

type turn_result =
  { thread_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; subscription : subscription
  ; user_agent : string option
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int option
      ; message : string
      }
  | Subscription_required of string
  | Unsupported_server_request of string
  | Turn_failed of string
  | Turn_interrupted
  | Process_exited of string
  | Timeout of float

let error_to_string = function
  | Invalid_config detail -> "invalid Codex app-server config: " ^ detail
  | Spawn_failed detail -> "failed to start Codex app-server: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Codex app-server protocol error during %s: %s" stage detail
  | Rpc_error { method_; code; message } ->
    let code = Option.fold ~none:"" ~some:(Printf.sprintf " (code %d)") code in
    Printf.sprintf "Codex app-server RPC %s failed%s: %s" method_ code message
  | Subscription_required detail ->
    "Codex ChatGPT subscription login required: " ^ detail
  | Unsupported_server_request method_ ->
    "Codex app-server requested unsupported host action: " ^ method_
  | Turn_failed detail -> "Codex app-server turn failed: " ^ detail
  | Turn_interrupted -> "Codex app-server turn was interrupted"
  | Process_exited detail -> "Codex app-server exited before completion: " ^ detail
  | Timeout seconds ->
    Printf.sprintf "Codex app-server turn timed out after %.3fs" seconds
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })

let assoc_at stage = function
  | `Assoc fields -> Ok fields
  | _ -> protocol_error stage "expected a JSON object"
;;

let required_member stage name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let required_string stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a non-empty string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let optional_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string or null" name)
;;

let required_bool stage name fields =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a boolean" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let required_int stage name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an integer" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let ( let* ) result f = Result.bind result f

type wire_message =
  | Response of
      { id : int
      ; result : Yojson.Safe.t
      }
  | Response_error of
      { id : int
      ; code : int option
      ; message : string
      }
  | Notification of
      { method_ : string
      ; params : Yojson.Safe.t
      }
  | Server_request of
      { id : Yojson.Safe.t
      ; method_ : string
      }

let parse_rpc_error id fields =
  let stage = "JSON-RPC error" in
  let* error_json = required_member stage "error" fields in
  let* error_fields = assoc_at stage error_json in
  let* message = required_string stage "message" error_fields in
  let* code = required_int stage "code" error_fields in
  Ok (Response_error { id; code = Some code; message })
;;

let parse_wire_line line =
  let stage = "JSON-RPC message" in
  let json_result =
    try Ok (Yojson.Safe.from_string line) with
    | Yojson.Json_error detail -> protocol_error stage ("invalid JSON: " ^ detail)
  in
  let* json = json_result in
  let* fields = assoc_at stage json in
  match List.assoc_opt "id" fields, List.assoc_opt "method" fields with
  | Some id, Some (`String method_) -> Ok (Server_request { id; method_ })
  | Some (`Int id), None ->
    (match List.assoc_opt "error" fields with
     | Some _ -> parse_rpc_error id fields
     | None ->
       let* result = required_member stage "result" fields in
       Ok (Response { id; result }))
  | Some _, None -> protocol_error stage "response id must be an integer"
  | None, Some (`String method_) ->
    let params = Option.value ~default:`Null (List.assoc_opt "params" fields) in
    Ok (Notification { method_; params })
  | Some _, Some _ | None, Some _ -> protocol_error stage "method must be a string"
  | None, None -> protocol_error stage "message has neither id nor method"
;;

type io =
  { send : Yojson.Safe.t -> unit
  ; receive : unit -> (wire_message, error) result
  }

let send_request io ~id ~method_ ~params =
  io.send (`Assoc [ "id", `Int id; "method", `String method_; "params", params ])
;;

let send_notification io method_ = io.send (`Assoc [ "method", `String method_ ])

let reject_server_request io id =
  io.send
    (`Assoc
       [ "id", id
       ; ( "error"
         , `Assoc
             [ "code", `Int (-32601)
             ; "message", `String "MASC does not support this app-server host request"
             ] )
       ])
;;

let rec await_response io ~id ~method_ =
  let* message = io.receive () in
  match message with
  | Response { id = response_id; result } when response_id = id -> Ok result
  | Response { id = response_id; _ } ->
    protocol_error method_
      (Printf.sprintf "received response id %d while waiting for %d" response_id id)
  | Response_error { id = response_id; code; message } when response_id = id ->
    Error (Rpc_error { method_; code; message })
  | Response_error { id = response_id; _ } ->
    protocol_error method_
      (Printf.sprintf "received error response id %d while waiting for %d" response_id id)
  | Notification _ -> await_response io ~id ~method_
  | Server_request { id; method_ = requested_method } ->
    reject_server_request io id;
    Error (Unsupported_server_request requested_method)
;;

let parse_initialize result =
  let stage = "initialize" in
  let* fields = assoc_at stage result in
  optional_string stage "userAgent" fields
;;

let parse_subscription result =
  let stage = "account/read" in
  let* fields = assoc_at stage result in
  let* _requires_auth = required_bool stage "requiresOpenaiAuth" fields in
  let* account = required_member stage "account" fields in
  match account with
  | `Null -> Error (Subscription_required "the official CLI has no active account")
  | `Assoc account_fields ->
    let* account_type = required_string stage "type" account_fields in
    if account_type <> "chatgpt"
    then
      Error
        (Subscription_required
           (Printf.sprintf "account/read reported account type %S" account_type))
    else
      let* plan_type = required_string stage "planType" account_fields in
      let* email = optional_string stage "email" account_fields in
      Ok { plan_type; email }
  | _ -> protocol_error stage "account must be an object or null"
;;

let parse_thread_start result =
  let stage = "thread/start" in
  let* fields = assoc_at stage result in
  let* thread_json = required_member stage "thread" fields in
  let* thread_fields = assoc_at stage thread_json in
  let* thread_id = required_string stage "id" thread_fields in
  let* model = required_string stage "model" fields in
  Ok (thread_id, model)
;;

let parse_turn_start result =
  let stage = "turn/start" in
  let* fields = assoc_at stage result in
  let* turn_json = required_member stage "turn" fields in
  let* turn_fields = assoc_at stage turn_json in
  required_string stage "id" turn_fields
;;

let agent_message_of_item ~stage item =
  let* fields = assoc_at stage item in
  match List.assoc_opt "type" fields with
  | Some (`String "agentMessage") ->
    let* text = required_string stage "text" fields in
    let* phase = optional_string stage "phase" fields in
    Ok (Some (phase, text))
  | Some (`String _) -> Ok None
  | Some _ -> protocol_error stage "item type must be a string"
  | None -> protocol_error stage "item is missing type"
;;

let messages_of_items ~stage = function
  | `List items ->
    let rec loop final fallback = function
      | [] -> Ok (final, fallback)
      | item :: rest ->
        let* message = agent_message_of_item ~stage item in
        (match message with
         | Some (Some "final_answer", text) -> loop (Some text) fallback rest
         | Some (_, text) -> loop final (Some text) rest
         | None -> loop final fallback rest)
    in
    loop None None items
  | _ -> protocol_error stage "turn items must be an array"
;;

let turn_error_message fields =
  match List.assoc_opt "error" fields with
  | Some (`Assoc error_fields) ->
    (match List.assoc_opt "message" error_fields with
     | Some (`String message) when String.trim message <> "" -> message
     | _ -> "turn failed without a typed error message")
  | _ -> "turn failed without an error object"
;;

let terminal_result ~thread_id ~turn_id ~seen_final ~seen_fallback params =
  let stage = "turn/completed" in
  let* fields = assoc_at stage params in
  let* terminal_thread_id = required_string stage "threadId" fields in
  if terminal_thread_id <> thread_id
  then protocol_error stage "terminal threadId does not match thread/start"
  else
    let* turn_json = required_member stage "turn" fields in
    let* turn_fields = assoc_at stage turn_json in
    let* terminal_turn_id = required_string stage "id" turn_fields in
    if terminal_turn_id <> turn_id
    then protocol_error stage "terminal turn id does not match turn/start"
    else
      let* status = required_string stage "status" turn_fields in
      match status with
      | "failed" -> Error (Turn_failed (turn_error_message turn_fields))
      | "interrupted" -> Error Turn_interrupted
      | "inProgress" -> protocol_error stage "terminal notification carried inProgress status"
      | "completed" ->
        let* items = required_member stage "items" turn_fields in
        let* terminal_final, terminal_fallback = messages_of_items ~stage items in
        let text =
          match terminal_final, seen_final, terminal_fallback, seen_fallback with
          | Some text, _, _, _ | None, Some text, _, _
          | None, None, Some text, _ | None, None, None, Some text -> Some text
          | None, None, None, None -> None
        in
        (match text with
         | Some text -> Ok text
         | None -> protocol_error stage "completed turn has no assistant message")
      | other -> protocol_error stage (Printf.sprintf "unknown turn status %S" other)
;;

let rec await_turn_terminal io ~thread_id ~turn_id ~seen_final ~seen_fallback =
  let* message = io.receive () in
  match message with
  | Response _ | Response_error _ ->
    protocol_error "turn" "received an unsolicited JSON-RPC response"
  | Server_request { id; method_ } ->
    reject_server_request io id;
    Error (Unsupported_server_request method_)
  | Notification { method_ = "item/completed"; params } ->
    let stage = "item/completed" in
    let* fields = assoc_at stage params in
    let* item_thread_id = required_string stage "threadId" fields in
    let* item_turn_id = required_string stage "turnId" fields in
    if item_thread_id <> thread_id || item_turn_id <> turn_id
    then protocol_error stage "item identity does not match the active turn"
    else
      let* item = required_member stage "item" fields in
      let* message = agent_message_of_item ~stage item in
      let seen_final, seen_fallback =
        match message with
        | Some (Some "final_answer", text) -> Some text, seen_fallback
        | Some (_, text) -> seen_final, Some text
        | None -> seen_final, seen_fallback
      in
      await_turn_terminal io ~thread_id ~turn_id ~seen_final ~seen_fallback
  | Notification { method_ = "error"; params } ->
    let stage = "error notification" in
    let* fields = assoc_at stage params in
    let* will_retry = required_bool stage "willRetry" fields in
    if will_retry
    then await_turn_terminal io ~thread_id ~turn_id ~seen_final ~seen_fallback
    else
      let* error_json = required_member stage "error" fields in
      let* error_fields = assoc_at stage error_json in
      let* message = required_string stage "message" error_fields in
      Error (Turn_failed message)
  | Notification { method_ = "turn/completed"; params } ->
    terminal_result ~thread_id ~turn_id ~seen_final ~seen_fallback params
  | Notification _ ->
    await_turn_terminal io ~thread_id ~turn_id ~seen_final ~seen_fallback
;;

let optional_field name = function
  | None -> []
  | Some value -> [ name, `String value ]
;;

let run_protocol io config ~prompt =
  send_request io ~id:1 ~method_:"initialize"
    ~params:
      (`Assoc
         [ ( "clientInfo"
           , `Assoc
               [ "name", `String "masc"
               ; "title", `String "MASC"
               ; "version", `String "dev"
               ] )
         ; "capabilities", `Assoc [ "experimentalApi", `Bool true ]
         ]);
  let* initialize = await_response io ~id:1 ~method_:"initialize" in
  let* user_agent = parse_initialize initialize in
  send_notification io "initialized";
  send_request io ~id:2 ~method_:"account/read"
    ~params:(`Assoc [ "refreshToken", `Bool false ]);
  let* account = await_response io ~id:2 ~method_:"account/read" in
  let* subscription = parse_subscription account in
  let thread_fields =
    [ "cwd", `String config.cwd
    ; "approvalPolicy", `String "never"
    ; "sandbox", `String "read-only"
    ; "ephemeral", `Bool true
    ]
    @ optional_field "model" config.model
    @ optional_field "developerInstructions" config.developer_instructions
  in
  send_request io ~id:3 ~method_:"thread/start" ~params:(`Assoc thread_fields);
  let* thread = await_response io ~id:3 ~method_:"thread/start" in
  let* thread_id, model = parse_thread_start thread in
  send_request io ~id:4 ~method_:"turn/start"
    ~params:
      (`Assoc
         [ "threadId", `String thread_id
         ; ( "input"
           , `List [ `Assoc [ "type", `String "text"; "text", `String prompt ] ] )
         ]);
  let* turn = await_response io ~id:4 ~method_:"turn/start" in
  let* turn_id = parse_turn_start turn in
  let* text =
    await_turn_terminal io ~thread_id ~turn_id ~seen_final:None ~seen_fallback:None
  in
  Ok { thread_id; turn_id; model; text; subscription; user_agent }
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let subscription_only_environment () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry ->
    match env_key entry with
    | "OPENAI_API_KEY" | "CODEX_API_KEY" -> false
    | _ -> true)
  |> Array.of_list
;;

let bounded_tail ~limit current addition =
  let combined = current ^ addition in
  let length = String.length combined in
  if length <= limit then combined else String.sub combined (length - limit) limit
;;

let drain_stderr flow tail =
  let chunk = Cstruct.create 4096 in
  try
    while true do
      let count = Eio.Flow.single_read flow chunk in
      let text = Cstruct.to_string (Cstruct.sub chunk 0 count) in
      tail := bounded_tail ~limit:4096 !tail text
    done
  with
  | End_of_file -> ()
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> ()
;;

let run_spawned ~mgr ~clock config ~prompt =
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let stderr_tail = ref "" in
    let proc =
      Eio.Process.spawn ~sw mgr
        ~env:(subscription_only_environment ())
        ~stdin:stdin_r ~stdout:stdout_w ~stderr:stderr_w
        [ config.cli_path; "app-server"; "--stdio" ]
    in
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.fork ~sw (fun () -> drain_stderr stderr_r stderr_tail);
    let reader = Eio.Buf_read.of_flow ~max_size:(8 * 1024 * 1024) stdout_r in
    let send json =
      Eio.Flow.copy_string (Yojson.Safe.to_string json) stdin_w;
      Eio.Flow.copy_string "\n" stdin_w
    in
    let receive () =
      try parse_wire_line (Eio.Buf_read.line reader) with
      | End_of_file ->
        let detail = String.trim !stderr_tail in
        Error (Process_exited (if detail = "" then "stdout closed" else detail))
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> protocol_error "stdout read" (Printexc.to_string exn)
    in
    Fun.protect
      ~finally:(fun () ->
        (try Eio.Flow.close stdin_w with _ -> ());
        (try Eio.Process.signal proc Sys.sigterm with _ -> ()))
      (fun () ->
        Eio.Time.with_timeout_exn clock config.timeout_s (fun () ->
          run_protocol { send; receive } config ~prompt)))
;;

let validate_config config ~prompt =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if String.trim config.cwd = "" || Filename.is_relative config.cwd
  then Error (Invalid_config "cwd must be an absolute path")
  else if not (Float.is_finite config.timeout_s) || config.timeout_s <= 0.0
  then Error (Invalid_config "timeout_s must be positive and finite")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else Ok ()
;;

let run_turn ~mgr ~clock config ~prompt =
  match validate_config config ~prompt with
  | Error _ as error -> error
  | Ok () ->
    (try run_spawned ~mgr ~clock config ~prompt with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Time.Timeout -> Error (Timeout config.timeout_s)
     | exn -> Error (Spawn_failed (Printexc.to_string exn)))
;;
