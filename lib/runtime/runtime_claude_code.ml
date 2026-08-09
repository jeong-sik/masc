type subscription =
  { auth_method : string
  ; subscription_type : string
  ; api_provider : string
  }

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; system_prompt : string option
  ; timeout_s : float
  }

let default_timeout_s = 300.0
let process_termination_grace_s = 2.0
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 4096
let max_wire_line_bytes = 8 * 1024 * 1024
let mcp_server_name = "masc"

let default_config ~cwd =
  { cli_path = "claude"
  ; cwd
  ; model = None
  ; system_prompt = None
  ; timeout_s = default_timeout_s
  }
;;

type session_mode =
  | Start
  | Resume of { session_id : string }

type rate_limit =
  { status : string
  ; rate_limit_type : string option
  ; resets_at : int option
  ; overage_status : string option
  ; overage_disabled_reason : string option
  }

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; rate_limit : rate_limit option
  ; resumed : bool
  }

type dynamic_tool_result =
  { success : bool
  ; content : string
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Subscription_required of string
  | Unsupported_control_request of string
  | Turn_failed of string
  | Quota_blocked of
      { api_error_status : int option
      ; rate_limit : rate_limit option
      }
  | Process_exited of string
  | Timeout of float

let error_to_string = function
  | Invalid_config detail -> "invalid Claude Code config: " ^ detail
  | Spawn_failed detail -> "failed to start Claude Code: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Claude Code protocol error during %s: %s" stage detail
  | Subscription_required detail ->
    "Claude Code subscription login required: " ^ detail
  | Unsupported_control_request subtype ->
    "Claude Code requested unsupported control action: " ^ subtype
  | Turn_failed detail -> "Claude Code turn failed: " ^ detail
  | Quota_blocked { api_error_status; rate_limit } ->
    let status =
      Option.fold
        ~none:"unknown"
        ~some:(fun value -> value.status)
        rate_limit
    in
    let api_status =
      Option.fold ~none:"unknown" ~some:string_of_int api_error_status
    in
    Printf.sprintf
      "Claude Code subscription quota blocked (rate_limit=%s api_status=%s)"
      status
      api_status
  | Process_exited detail ->
    "Claude Code exited before terminal result: " ^ detail
  | Timeout seconds ->
    Printf.sprintf "Claude Code turn timed out after %.3fs" seconds
;;

let error_kind = function
  | Invalid_config _ -> "invalid_config"
  | Spawn_failed _ -> "spawn_failed"
  | Protocol_error _ -> "protocol_error"
  | Subscription_required _ -> "subscription_required"
  | Unsupported_control_request _ -> "unsupported_control_request"
  | Turn_failed _ -> "turn_failed"
  | Quota_blocked _ -> "quota_blocked"
  | Process_exited _ -> "process_exited"
  | Timeout _ -> "timeout"
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })
let ( let* ) result f = Result.bind result f

let rec validate_unique_object_keys ~stage ~path = function
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok ()
      | (name, value) :: rest ->
        if List.mem name seen
        then
          protocol_error
            stage
            (Printf.sprintf "duplicate object key %S at %s" name path)
        else
          let* () =
            validate_unique_object_keys
              ~stage
              ~path:(path ^ "." ^ name)
              value
          in
          loop (name :: seen) rest
    in
    loop [] fields
  | `List values ->
    let rec loop index = function
      | [] -> Ok ()
      | value :: rest ->
        let* () =
          validate_unique_object_keys
            ~stage
            ~path:(Printf.sprintf "%s[%d]" path index)
            value
        in
        loop (index + 1) rest
    in
    loop 0 values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Ok ()
;;

let parse_json ~stage text =
  let parsed =
    try Ok (Yojson.Safe.from_string text) with
    | Yojson.Json_error detail -> protocol_error stage ("invalid JSON: " ^ detail)
  in
  let* json = parsed in
  let* () = validate_unique_object_keys ~stage ~path:"$" json in
  Ok json
;;

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
  | Some _ ->
    protocol_error stage (Printf.sprintf "field %S must be a non-empty string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let optional_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ ->
    protocol_error stage (Printf.sprintf "field %S must be a string or null" name)
;;

let required_bool stage name fields =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a boolean" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let optional_int stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ ->
    protocol_error stage (Printf.sprintf "field %S must be an integer or null" name)
;;

let subscription_only_environment () =
  let inherited_names =
    [ "HOME"
    ; "PATH"
    ; "TMPDIR"
    ; "XDG_CONFIG_HOME"
    ; "XDG_DATA_HOME"
    ; "XDG_CACHE_HOME"
    ; "SSL_CERT_FILE"
    ; "SSL_CERT_DIR"
    ; "LANG"
    ; "LC_ALL"
    ; "LC_CTYPE"
    ; "TERM"
    ; "NO_COLOR"
    ]
  in
  inherited_names
  |> List.filter_map (fun name ->
    Option.map (fun value -> name ^ "=" ^ value) (Sys.getenv_opt name))
  |> fun inherited ->
  ("CLAUDE_CODE_ENTRYPOINT=masc" :: "CLAUDE_AGENT_SDK_VERSION=masc-ocaml" :: inherited)
  |> Array.of_list
;;

let parse_subscription json =
  let stage = "auth status" in
  let* fields = assoc_at stage json in
  let* logged_in = required_bool stage "loggedIn" fields in
  if not logged_in
  then Error (Subscription_required "claude auth status reported loggedIn=false")
  else
    let* auth_method = required_string stage "authMethod" fields in
    let* subscription_type = required_string stage "subscriptionType" fields in
    let* api_provider = required_string stage "apiProvider" fields in
    if auth_method <> "claude.ai"
    then
      Error
        (Subscription_required
           (Printf.sprintf "authMethod must be claude.ai, got %S" auth_method))
    else if api_provider <> "firstParty"
    then
      Error
        (Subscription_required
           (Printf.sprintf "apiProvider must be firstParty, got %S" api_provider))
    else Ok { auth_method; subscription_type; api_provider }
;;

let read_subscription ~mgr ~cwd config =
  try
    Eio.Process.parse_out
      mgr
      Eio.Buf_read.take_all
      ~cwd
      ~env:(subscription_only_environment ())
      [ config.cli_path; "auth"; "status"; "--json" ]
    |> String.trim
    |> parse_json ~stage:"auth status"
    |> fun result -> Result.bind result parse_subscription
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Subscription_required (Printexc.to_string exn))
;;

let dynamic_tool_spec (tool : dynamic_tool) =
  `Assoc
    [ "name", `String tool.name
    ; "description", `String tool.description
    ; "inputSchema", tool.input_schema
    ]
;;

let find_dynamic_tool tools name =
  List.find_opt (fun (tool : dynamic_tool) -> String.equal tool.name name) tools
;;

type io =
  { send : Yojson.Safe.t -> unit
  ; receive : unit -> (Yojson.Safe.t, error) result
  }

let send_control_success io ~request_id response =
  io.send
    (`Assoc
       [ "type", `String "control_response"
       ; ( "response"
         , `Assoc
             [ "subtype", `String "success"
             ; "request_id", `String request_id
             ; "response", response
             ] )
       ])
;;

let send_control_error io ~request_id detail =
  io.send
    (`Assoc
       [ "type", `String "control_response"
       ; ( "response"
         , `Assoc
             [ "subtype", `String "error"
             ; "request_id", `String request_id
             ; "error", `String detail
             ] )
       ])
;;

let handle_control_request io ~tools ~tool_call_count fields =
  let stage = "control request" in
  let* request_id = required_string stage "request_id" fields in
  let* request = required_member stage "request" fields in
  let* request_fields = assoc_at stage request in
  let* subtype = required_string stage "subtype" request_fields in
  match subtype with
  | "mcp_message" ->
    let* server_name = required_string stage "server_name" request_fields in
    if server_name <> mcp_server_name
    then
      let detail = Printf.sprintf "unknown SDK MCP server %S" server_name in
      send_control_error io ~request_id detail;
      Error (Unsupported_control_request subtype)
    else
      let* message = required_member stage "message" request_fields in
      let tool_specs () = List.map dynamic_tool_spec tools in
      let call_tool ~name ~call_id ~arguments =
        match find_dynamic_tool tools name with
        | None -> None
        | Some tool ->
          let result =
            try tool.call ~call_id arguments with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              Log.Runtime_agent.warn
                "Claude Code MCP tool handler raised (tool=%s error=%s)"
                name
                (Printexc.to_string exn);
              { success = false; content = "MASC tool handler raised" }
          in
          Some
            { Runtime_official_client_mcp.success = result.success
            ; content = result.content
            }
      in
      let* dispatch =
        Runtime_official_client_mcp.handle_message
          ~server_name:mcp_server_name
          ~tool_specs
          ~call_tool
          message
        |> Result.map_error (fun { Runtime_official_client_mcp.stage; detail } ->
          Protocol_error { stage; detail })
      in
      if dispatch.tool_called then incr tool_call_count;
      (match dispatch.response with
       | None -> Ok ()
       | Some mcp_response ->
         send_control_success
           io
           ~request_id
           (`Assoc [ "mcp_response", mcp_response ]);
         Ok ())
  | unsupported ->
    send_control_error
      io
      ~request_id
      (Printf.sprintf "MASC does not support control request %S" unsupported);
    Error (Unsupported_control_request unsupported)
;;

let parse_wire_line line = parse_json ~stage:"stream-json message" line

let wire_fields json =
  let stage = "stream-json message" in
  let* fields = assoc_at stage json in
  let* type_ = required_string stage "type" fields in
  Ok (type_, fields)
;;

let initialize_request request_id =
  `Assoc
    [ "type", `String "control_request"
    ; "request_id", `String request_id
    ; ( "request"
      , `Assoc [ "subtype", `String "initialize"; "hooks", `Null ] )
    ]
;;

let parse_control_response ~expected_request_id fields =
  let stage = "initialize control response" in
  let* response = required_member stage "response" fields in
  let* response_fields = assoc_at stage response in
  let* request_id = required_string stage "request_id" response_fields in
  if request_id <> expected_request_id
  then
    protocol_error
      stage
      (Printf.sprintf
         "response request_id %S does not match %S"
         request_id
         expected_request_id)
  else
    let* subtype = required_string stage "subtype" response_fields in
    match subtype with
    | "success" -> Ok ()
    | "error" ->
      let* detail = required_string stage "error" response_fields in
      Error (Turn_failed ("control initialization failed: " ^ detail))
    | other ->
      protocol_error stage (Printf.sprintf "unknown response subtype %S" other)
;;

let rec await_initialize io ~tools ~tool_call_count ~request_id ~ignored =
  let* json = io.receive () in
  let* type_, fields = wire_fields json in
  match type_ with
  | "control_response" ->
    parse_control_response ~expected_request_id:request_id fields
  | "control_request" ->
    let* () = handle_control_request io ~tools ~tool_call_count fields in
    await_initialize io ~tools ~tool_call_count ~request_id ~ignored
  | ("system" | "rate_limit_event") when ignored < 32 ->
    await_initialize io ~tools ~tool_call_count ~request_id ~ignored:(ignored + 1)
  | other ->
    protocol_error
      "initialize"
      (Printf.sprintf "unexpected message type %S before control response" other)
;;

let invoke_state_callback ~stage callback =
  try
    match callback () with
    | Ok () -> Ok ()
    | Error detail -> protocol_error stage detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> protocol_error stage (Printexc.to_string exn)
;;

let user_message prompt =
  `Assoc
    [ "type", `String "user"
    ; "message", `Assoc [ "role", `String "user"; "content", `String prompt ]
    ; "parent_tool_use_id", `Null
    ; "session_id", `String "default"
    ]
;;

let parse_rate_limit ~expected_session_id fields =
  let stage = "rate_limit_event" in
  let* session_id = required_string stage "session_id" fields in
  let* () =
    if session_id = expected_session_id
    then Ok ()
    else protocol_error stage "session_id does not match the active Claude session"
  in
  let* info = required_member stage "rate_limit_info" fields in
  let* info_fields = assoc_at stage info in
  let* status = required_string stage "status" info_fields in
  if not (List.mem status [ "allowed"; "allowed_warning"; "rejected" ])
  then protocol_error stage (Printf.sprintf "unknown status %S" status)
  else
    let* rate_limit_type = optional_string stage "rateLimitType" info_fields in
    let* resets_at = optional_int stage "resetsAt" info_fields in
    let* overage_status = optional_string stage "overageStatus" info_fields in
    let* overage_disabled_reason =
      optional_string stage "overageDisabledReason" info_fields
    in
    Ok
      { status
      ; rate_limit_type
      ; resets_at
      ; overage_status
      ; overage_disabled_reason
      }
;;

let text_blocks ~stage content =
  match content with
  | `List blocks ->
    let rec loop texts = function
      | [] -> Ok (List.rev texts)
      | `Assoc fields :: rest ->
        let* type_ = required_string stage "type" fields in
        (match type_ with
         | "text" ->
           let* text = required_string stage "text" fields in
           loop (text :: texts) rest
         | "thinking" | "tool_use" -> loop texts rest
         | other ->
           protocol_error
             stage
             (Printf.sprintf "unsupported assistant content type %S" other))
      | _ :: _ -> protocol_error stage "assistant content block must be an object"
    in
    loop [] blocks
  | _ -> protocol_error stage "assistant content must be an array"
;;

let parse_assistant ~expected_session_id fields =
  let stage = "assistant message" in
  let* session_id = required_string stage "session_id" fields in
  if session_id <> expected_session_id
  then protocol_error stage "session_id does not match the active Claude session"
  else
    let* uuid = required_string stage "uuid" fields in
    let* message = required_member stage "message" fields in
    let* message_fields = assoc_at stage message in
    let* model = required_string stage "model" message_fields in
    let* content = required_member stage "content" message_fields in
    let* texts = text_blocks ~stage content in
    Ok (uuid, model, texts)
;;

let parse_result ~expected_session_id ~rate_limit fields =
  let stage = "result message" in
  let* subtype = required_string stage "subtype" fields in
  let* is_error = required_bool stage "is_error" fields in
  let* session_id = required_string stage "session_id" fields in
  if session_id <> expected_session_id
  then protocol_error stage "session_id does not match the active Claude session"
  else
    let* turn_id = required_string stage "uuid" fields in
    let* api_error_status = optional_int stage "api_error_status" fields in
    let result =
      match List.assoc_opt "result" fields with
      | None | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ -> protocol_error stage "field \"result\" must be a string or null"
    in
    let* result = result in
    if is_error
    then
      let structurally_quota_blocked =
        Option.equal Int.equal api_error_status (Some 429)
        || Option.exists
             (fun (limit : rate_limit) -> limit.status = "rejected")
             rate_limit
      in
      if structurally_quota_blocked
      then Error (Quota_blocked { api_error_status; rate_limit })
      else
        Error
          (Turn_failed
             (Printf.sprintf
                "terminal subtype=%s api_status=%s"
                subtype
                (Option.fold
                   ~none:"unknown"
                   ~some:string_of_int
                   api_error_status)))
    else if subtype <> "success"
    then Error (Turn_failed (Printf.sprintf "terminal subtype=%s" subtype))
    else Ok (turn_id, result)
;;

let max_ignored_messages = 256

let rec await_terminal io ~tools ~tool_call_count ~expected_session_id
    ~subscription ~resumed ~rate_limit ~assistant_model ~assistant_texts
    ~on_turn_started ~ignored =
  let* json = io.receive () in
  let* type_, fields = wire_fields json in
  match type_ with
  | "control_request" ->
    let* () = handle_control_request io ~tools ~tool_call_count fields in
    await_terminal
      io ~tools ~tool_call_count ~expected_session_id ~subscription ~resumed
      ~rate_limit ~assistant_model ~assistant_texts ~on_turn_started ~ignored
  | "control_response" ->
    protocol_error "turn" "received an unsolicited control response"
  | "assistant" ->
    let* _uuid, model, texts = parse_assistant ~expected_session_id fields in
    await_terminal
      io ~tools ~tool_call_count ~expected_session_id ~subscription ~resumed
      ~rate_limit ~assistant_model:(Some model)
      ~assistant_texts:(assistant_texts @ texts)
      ~on_turn_started ~ignored
  | "rate_limit_event" ->
    let* rate_limit = parse_rate_limit ~expected_session_id fields in
    await_terminal
      io ~tools ~tool_call_count ~expected_session_id ~subscription ~resumed
      ~rate_limit:(Some rate_limit) ~assistant_model ~assistant_texts
      ~on_turn_started ~ignored
  | "result" ->
    let* turn_id, result =
      parse_result ~expected_session_id ~rate_limit fields
    in
    let* () =
      invoke_state_callback ~stage:"turn started callback" (fun () ->
        on_turn_started ~session_id:expected_session_id ~turn_id)
    in
    let* model =
      match assistant_model with
      | Some model -> Ok model
      | None -> protocol_error "result message" "no measured assistant model"
    in
    let text =
      match result with
      | Some text when String.trim text <> "" -> Some text
      | None | Some _ ->
        assistant_texts
        |> String.concat "\n"
        |> String.trim
        |> fun value -> if value = "" then None else Some value
    in
    let* text =
      match text with
      | Some text -> Ok text
      | None -> protocol_error "result message" "successful turn has no text"
    in
    Ok
      { session_id = expected_session_id
      ; turn_id
      ; model
      ; text
      ; dynamic_tool_calls = !tool_call_count
      ; subscription
      ; rate_limit
      ; resumed
      }
  | ("system" | "user") when ignored < max_ignored_messages ->
    await_terminal
      io ~tools ~tool_call_count ~expected_session_id ~subscription ~resumed
      ~rate_limit ~assistant_model ~assistant_texts ~on_turn_started
      ~ignored:(ignored + 1)
  | other ->
    protocol_error
      "turn"
      (Printf.sprintf "unsupported stream message type %S" other)
;;

let mcp_config tools =
  match tools with
  | [] -> None
  | _ ->
    Some
      (Yojson.Safe.to_string
         (`Assoc
            [ ( "mcpServers"
              , `Assoc
                  [ ( mcp_server_name
                    , `Assoc
                        [ "type", `String "sdk"
                        ; "name", `String mcp_server_name
                        ] )
                  ] )
            ]))
;;

let allowed_tool_name (tool : dynamic_tool) =
  Printf.sprintf "mcp__%s__%s" mcp_server_name tool.name
;;

let reasoning_args = function
  | None -> Ok []
  | Some Llm_provider.Reasoning_effort.None_ ->
    Ok [ "--thinking"; "disabled" ]
  | Some Llm_provider.Reasoning_effort.Minimal ->
    Error
      (Invalid_config
         "Claude Code does not admit reasoning effort minimal; use low, medium, high, xhigh, max, or none")
  | Some effort ->
    Ok [ "--effort"; Llm_provider.Reasoning_effort.to_string effort ]
;;

let command config ~dynamic_tools ~reasoning_effort ~session_mode ~session_id =
  let* reasoning_args = reasoning_args reasoning_effort in
  let args =
    [ config.cli_path
    ; "--output-format"
    ; "stream-json"
    ; "--verbose"
    ; "--system-prompt"
    ; Option.value config.system_prompt ~default:""
    ; "--tools"
    ; ""
    ]
    @ (match dynamic_tools with
       | [] -> []
       | tools ->
         [ "--allowedTools"
         ; String.concat "," (List.map allowed_tool_name tools)
         ])
    @ (match config.model with
       | None -> []
       | Some model -> [ "--model"; model ])
    @ [ "--permission-mode"; "dontAsk" ]
    @ (match session_mode with
       | Start -> [ "--session-id=" ^ session_id ]
       | Resume { session_id } -> [ "--resume=" ^ session_id ])
    @ (match mcp_config dynamic_tools with
       | None -> []
       | Some value -> [ "--mcp-config"; value; "--strict-mcp-config" ])
    @ [ "--setting-sources=" ]
    @ reasoning_args
    @ [ "--input-format"; "stream-json" ]
  in
  Ok args
;;

let bounded_tail ~limit current addition =
  let combined = current ^ addition in
  let length = String.length combined in
  if length <= limit then combined else String.sub combined (length - limit) limit
;;

let drain_stderr flow tail =
  let chunk = Cstruct.create stderr_chunk_bytes in
  try
    while true do
      let count = Eio.Flow.single_read flow chunk in
      let text = Cstruct.to_string (Cstruct.sub chunk 0 count) in
      tail := bounded_tail ~limit:stderr_tail_bytes !tail text
    done
  with
  | End_of_file -> ()
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Runtime_agent.debug
      "Claude Code stderr drain failed: %s"
      (Printexc.to_string exn)
;;

let terminate_spawned_process ~clock proc stdin_w =
  let owning_switch_cancelled = Eio.Fiber.is_cancelled () in
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | exn ->
       Log.Runtime_agent.debug
         "Claude Code stdin close failed: %s"
         (Printexc.to_string exn));
    (try Eio.Process.signal proc Sys.sigterm with
     | exn ->
       Log.Runtime_agent.debug
         "Claude Code termination signal failed: %s"
         (Printexc.to_string exn));
    if not owning_switch_cancelled
    then
      try
        Eio.Time.with_timeout_exn clock process_termination_grace_s (fun () ->
          Eio.Process.await proc |> ignore)
      with
      | Eio.Time.Timeout ->
        (try
           Eio.Process.signal proc Sys.sigkill;
           Eio.Process.await proc |> ignore
         with
         | exn ->
           Log.Runtime_agent.warn
             "Claude Code forced reap failed: %s"
             (Printexc.to_string exn))
      | exn ->
        Log.Runtime_agent.debug
          "Claude Code reap observed an already-closed process: %s"
          (Printexc.to_string exn))
;;

let run_protocol io ~dynamic_tools ~subscription ~session_mode ~session_id
    ~prompt ~on_session_ready ~on_turn_starting ~on_turn_started =
  let tool_call_count = ref 0 in
  let initialize_id = Random_id.prefixed ~prefix:"masc-init-" ~bytes:12 in
  io.send (initialize_request initialize_id);
  let* () =
    await_initialize
      io
      ~tools:dynamic_tools
      ~tool_call_count
      ~request_id:initialize_id
      ~ignored:0
  in
  let* () =
    invoke_state_callback ~stage:"session ready callback" (fun () ->
      on_session_ready ~session_id)
  in
  let* () =
    invoke_state_callback ~stage:"turn starting callback" (fun () ->
      on_turn_starting ~session_id)
  in
  io.send (user_message prompt);
  await_terminal
    io
    ~tools:dynamic_tools
    ~tool_call_count
    ~expected_session_id:session_id
    ~subscription
    ~resumed:
      (match session_mode with
       | Start -> false
       | Resume _ -> true)
    ~rate_limit:None
    ~assistant_model:None
    ~assistant_texts:[]
    ~on_turn_started
    ~ignored:0
;;

let run_spawned ~mgr ~clock ~cwd config ~dynamic_tools ~reasoning_effort
    ~session_mode ~session_id ~subscription ~prompt ~on_session_ready
    ~on_turn_starting ~on_turn_started =
  let* argv =
    command config ~dynamic_tools ~reasoning_effort ~session_mode ~session_id
  in
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let stderr_tail = ref "" in
    let proc =
      Eio.Process.spawn
        ~sw
        mgr
        ~cwd
        ~env:(subscription_only_environment ())
        ~stdin:stdin_r
        ~stdout:stdout_w
        ~stderr:stderr_w
        argv
    in
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.fork ~sw (fun () -> drain_stderr stderr_r stderr_tail);
    let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
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
      ~finally:(fun () -> terminate_spawned_process ~clock proc stdin_w)
      (fun () ->
        Eio.Time.with_timeout_exn clock config.timeout_s (fun () ->
          run_protocol
            { send; receive }
            ~dynamic_tools
            ~subscription
            ~session_mode
            ~session_id
            ~prompt
            ~on_session_ready
            ~on_turn_starting
            ~on_turn_started)))
;;

let validate_config config ~session_mode ~prompt =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if String.trim config.cwd = "" || Filename.is_relative config.cwd
  then Error (Invalid_config "cwd must be an absolute path")
  else if not (Float.is_finite config.timeout_s) || config.timeout_s <= 0.0
  then Error (Invalid_config "timeout_s must be positive and finite")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else
    match session_mode with
    | Resume { session_id } when String.trim session_id = "" ->
      Error (Invalid_config "resume session_id must not be empty")
    | Start | Resume _ -> Ok ()
;;

let validate_dynamic_tools tools =
  let valid_tool_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  let rec loop seen = function
    | [] -> Ok ()
    | (tool : dynamic_tool) :: rest ->
      let name = String.trim tool.name in
      if name = ""
      then Error (Invalid_config "dynamic tool name must not be empty")
      else if List.mem name seen
      then
        Error
          (Invalid_config (Printf.sprintf "duplicate dynamic tool name %S" name))
      else if not (String.for_all valid_tool_character name)
      then
        Error
          (Invalid_config
             (Printf.sprintf
                "dynamic tool name %S contains a character unsupported by Claude Code allowedTools"
                name))
      else loop (name :: seen) rest
  in
  loop [] tools
;;

let validate_turn ?(dynamic_tools = []) ?(session_mode = Start) config ~prompt =
  let* () = validate_config config ~session_mode ~prompt in
  validate_dynamic_tools dynamic_tools
;;

let run_turn ?(dynamic_tools = []) ?reasoning_effort ?(session_mode = Start)
    ~mgr ~clock ~cwd ?(on_session_ready = fun ~session_id:_ -> Ok ())
    ?(on_turn_starting = fun ~session_id:_ -> Ok ())
    ?(on_turn_started = fun ~session_id:_ ~turn_id:_ -> Ok ()) config
    ~prompt =
  let result =
    let* () = validate_turn ~dynamic_tools ~session_mode config ~prompt in
    let* _ = reasoning_args reasoning_effort in
    let* subscription = read_subscription ~mgr ~cwd config in
    let session_id =
      match session_mode with
      | Start -> Random_id.uuid_v7 ()
      | Resume { session_id } -> session_id
    in
    Log.Runtime_agent.info
      "Claude Code subscription turn starting (subscription_type=%s)"
      subscription.subscription_type;
    try
      run_spawned
        ~mgr
        ~clock
        ~cwd
        config
        ~dynamic_tools
        ~reasoning_effort
        ~session_mode
        ~session_id
        ~subscription
        ~prompt
        ~on_session_ready
        ~on_turn_starting
        ~on_turn_started
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout -> Error (Timeout config.timeout_s)
    | exn -> Error (Spawn_failed (Printexc.to_string exn))
  in
  (match result with
   | Ok turn ->
     Log.Runtime_agent.info
       "Claude Code subscription turn completed (session_id=%s turn_id=%s model=%s)"
       turn.session_id
       turn.turn_id
       turn.model
   | Error error ->
     Log.Runtime_agent.warn
       "Claude Code subscription turn failed (kind=%s)"
       (error_kind error));
  result
;;
