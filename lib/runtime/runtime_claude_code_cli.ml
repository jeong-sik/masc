type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; timeout_s : float
  ; max_turns : int
  }

type session_mode =
  | Start of { session_id : string }
  | Resume of { session_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; total_cost_usd : float
  }

type turn_result =
  { session_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; tool_calls : int
  ; permission_mode : string
  ; resumed : bool
  }

type rejection =
  { status : string
  ; reset_at : int option
  ; detail : string
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Turn_rejected of rejection
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

let error_to_string = function
  | Invalid_config detail -> "invalid Claude Code CLI config: " ^ detail
  | Spawn_failed detail -> "failed to start Claude Code CLI: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Claude Code CLI protocol error during %s: %s" stage detail
  | Turn_rejected { status; reset_at; detail } ->
    let reset =
      match reset_at with
      | None -> ""
      | Some timestamp -> Printf.sprintf " (reset_at=%d)" timestamp
    in
    Printf.sprintf "Claude Code CLI turn rejected [%s]%s: %s" status reset detail
  | Turn_failed detail -> "Claude Code CLI turn failed: " ^ detail
  | Process_exited detail -> "Claude Code CLI process failed: " ^ detail
  | Timeout seconds -> Printf.sprintf "Claude Code CLI turn timed out after %.3fs" seconds
;;

let ( let* ) = Result.bind

let protocol_error stage detail = Error (Protocol_error { stage; detail })

let rec validate_unique_object_keys ~stage ~path = function
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok ()
      | (name, value) :: rest ->
        if List.mem name seen
        then protocol_error stage (Printf.sprintf "duplicate object key %S at %s" name path)
        else
          let* () = validate_unique_object_keys ~stage ~path:(path ^ "." ^ name) value in
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

let assoc stage = function
  | `Assoc fields -> Ok fields
  | _ -> protocol_error stage "expected a JSON object"
;;

let required_json stage name fields =
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

let required_plain_string stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
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

let nonnegative_int stage name fields =
  let* value = required_int stage name fields in
  if value < 0
  then protocol_error stage (Printf.sprintf "field %S must be non-negative" name)
  else Ok value
;;

let optional_int stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an integer or null" name)
;;

let optional_nonnegative_int stage name fields =
  let* value = optional_int stage name fields in
  match value with
  | None -> Ok None
  | Some value when value >= 0 -> Ok (Some value)
  | Some _ ->
    protocol_error stage (Printf.sprintf "field %S must be non-negative when present" name)
;;

let optional_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string or null" name)
;;

let required_nonnegative_float stage name fields =
  let value =
    match List.assoc_opt name fields with
    | Some (`Int value) -> Some (Float.of_int value)
    | Some (`Float value) -> Some value
    | Some _ | None -> None
  in
  match value with
  | Some value when Float.is_finite value && value >= 0.0 -> Ok value
  | _ -> protocol_error stage (Printf.sprintf "field %S must be a finite non-negative number" name)
;;

let parse_json_line ~line_number line =
  let stage = Printf.sprintf "stdout line %d" line_number in
  if String.length line > 8 * 1024 * 1024
  then protocol_error stage "stream-json line exceeds 8 MiB"
  else
    try
      let json = Yojson.Safe.from_string line in
      let* () = validate_unique_object_keys ~stage ~path:"$" json in
      Ok (stage, json)
    with
    | Yojson.Json_error detail -> protocol_error stage detail
;;

let expected_tools = [ "Glob"; "Grep"; "Read"; "WebFetch"; "WebSearch" ]

let parse_tools stage fields =
  let* json = required_json stage "tools" fields in
  match json with
  | `List values ->
    let rec loop seen = function
      | [] -> Ok (List.sort String.compare seen)
      | `String name :: rest when String.trim name <> "" && not (List.mem name seen) ->
        loop (name :: seen) rest
      | `String name :: _ when List.mem name seen ->
        protocol_error stage (Printf.sprintf "duplicate tool %S" name)
      | _ -> protocol_error stage "tools must contain unique non-empty strings"
    in
    let* tools = loop [] values in
    if tools = expected_tools
    then Ok ()
    else protocol_error stage "reported tools differ from the fixed read-only tool boundary"
  | _ -> protocol_error stage "field \"tools\" must be an array"
;;

type init =
  { session_id : string
  ; model : string
  ; cwd : string
  ; permission_mode : string
  }

type terminal =
  { session_id : string
  ; subtype : string
  ; is_error : bool
  ; result : string
  ; num_turns : int
  ; usage : usage
  ; terminal_reason : string option
  ; api_error_status : int option
  }

let parse_init stage fields =
  let* subtype = required_string stage "subtype" fields in
  if not (String.equal subtype "init")
  then protocol_error stage (Printf.sprintf "unsupported system subtype %S" subtype)
  else
    let* session_id = required_string stage "session_id" fields in
    let* model = required_string stage "model" fields in
    let* cwd = required_string stage "cwd" fields in
    let* permission_mode = required_string stage "permissionMode" fields in
    let* api_key_source = required_string stage "apiKeySource" fields in
    let* () = parse_tools stage fields in
    if not (String.equal permission_mode "plan")
    then protocol_error stage "Claude Code did not retain permission mode plan"
    else if not (String.equal api_key_source "none")
    then protocol_error stage "Claude Code selected a non-subscription API credential source"
    else Ok { session_id; model; cwd; permission_mode }
;;

let usage_of_fields stage fields =
  let* input_tokens = nonnegative_int stage "input_tokens" fields in
  let* output_tokens = nonnegative_int stage "output_tokens" fields in
  let* cache_creation_input_tokens =
    nonnegative_int stage "cache_creation_input_tokens" fields
  in
  let* cache_read_input_tokens = nonnegative_int stage "cache_read_input_tokens" fields in
  Ok
    { input_tokens
    ; output_tokens
    ; cache_creation_input_tokens
    ; cache_read_input_tokens
    ; total_cost_usd = 0.0
    }
;;

let parse_terminal stage fields =
  let* subtype = required_string stage "subtype" fields in
  let* session_id = required_string stage "session_id" fields in
  let* is_error = required_bool stage "is_error" fields in
  let* result = required_plain_string stage "result" fields in
  let* num_turns = required_int stage "num_turns" fields in
  let* terminal_reason = optional_string stage "terminal_reason" fields in
  let* api_error_status = optional_nonnegative_int stage "api_error_status" fields in
  if num_turns <= 0
  then protocol_error stage "num_turns must be positive"
  else
    let* usage_json = required_json stage "usage" fields in
    let* usage_fields = assoc stage usage_json in
    let* usage = usage_of_fields stage usage_fields in
    let* total_cost_usd = required_nonnegative_float stage "total_cost_usd" fields in
    Ok
      { session_id
      ; subtype
      ; is_error
      ; result
      ; num_turns
      ; usage = { usage with total_cost_usd }
      ; terminal_reason
      ; api_error_status
      }
;;

let session_id_of_event stage fields =
  match List.assoc_opt "session_id" fields with
  | None -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some _ -> protocol_error stage "field \"session_id\" must be a non-empty string"
;;

let count_assistant_tool_calls stage fields =
  let* message_json = required_json stage "message" fields in
  let* message_fields = assoc stage message_json in
  let* content_json = required_json stage "content" message_fields in
  match content_json with
  | `List blocks ->
    List.fold_left
      (fun result block ->
        let* count = result in
        let* block_fields = assoc stage block in
        let* block_type = required_string stage "type" block_fields in
        Ok (if String.equal block_type "tool_use" then count + 1 else count))
      (Ok 0)
      blocks
  | _ -> protocol_error stage "assistant message content must be an array"
;;

let parse_rate_limit stage fields =
  let* info_json = required_json stage "rate_limit_info" fields in
  let* info_fields = assoc stage info_json in
  let* status = required_string stage "status" info_fields in
  let* reset_at = optional_nonnegative_int stage "resetsAt" info_fields in
  Ok (status, reset_at)
;;

let validate_session_id stage ~expected = function
  | None -> Ok ()
  | Some actual when String.equal actual expected -> Ok ()
  | Some _ -> protocol_error stage "event session_id changed"
;;

let parse_output ~expected_model ~expected_cwd ~session_mode output =
  if String.length output > 16 * 1024 * 1024
  then protocol_error "stdout" "stream-json output exceeds 16 MiB"
  else
    let lines =
      output
      |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line <> "")
    in
    if List.length lines > 16_384
    then protocol_error "stdout" "stream-json event count exceeds 16384"
    else
      let expected_session_id, resumed =
        match session_mode with
        | Start { session_id } -> session_id, false
        | Resume { session_id } -> session_id, true
      in
      let rec loop line_number init terminal tool_calls rejection = function
        | [] -> Ok (init, terminal, tool_calls, rejection)
        | _ :: _ when Option.is_some terminal ->
          protocol_error "stdout" "events appeared after the terminal result"
        | line :: rest ->
          let* stage, json = parse_json_line ~line_number line in
          let* fields = assoc stage json in
          let* event_type = required_string stage "type" fields in
          let* () =
            if String.equal event_type "system" || Option.is_some init
            then Ok ()
            else protocol_error stage "event appeared before the init boundary"
          in
          (match event_type with
           | "system" ->
             if Option.is_some init
             then protocol_error stage "duplicate init event"
             else
               let* parsed = parse_init stage fields in
               loop (line_number + 1) (Some parsed) terminal tool_calls rejection rest
           | "assistant" ->
             let* event_session_id = session_id_of_event stage fields in
             let* () = validate_session_id stage ~expected:expected_session_id event_session_id in
             let* count = count_assistant_tool_calls stage fields in
             loop
               (line_number + 1)
               init
               terminal
               (tool_calls + count)
               rejection
               rest
           | "user" ->
             let* event_session_id = session_id_of_event stage fields in
             let* () = validate_session_id stage ~expected:expected_session_id event_session_id in
             loop (line_number + 1) init terminal tool_calls rejection rest
           | "rate_limit_event" ->
             let* event_session_id = session_id_of_event stage fields in
             let* () = validate_session_id stage ~expected:expected_session_id event_session_id in
             let* status, reset_at = parse_rate_limit stage fields in
             let rejection =
               if String.equal status "rejected"
               then Some (status, reset_at)
               else rejection
             in
             loop (line_number + 1) init terminal tool_calls rejection rest
           | "result" ->
             let* parsed = parse_terminal stage fields in
             loop (line_number + 1) init (Some parsed) tool_calls rejection rest
           | other -> protocol_error stage (Printf.sprintf "unsupported event type %S" other))
      in
      let* init, terminal, tool_calls, rejection = loop 1 None None 0 None lines in
      let* init =
        match init with
        | Some init -> Ok init
        | None -> protocol_error "stdout" "missing init event"
      in
      let* terminal =
        match terminal with
        | Some terminal -> Ok terminal
        | None -> protocol_error "stdout" "missing terminal result"
      in
      let* () =
        if String.equal init.session_id expected_session_id
           && String.equal terminal.session_id expected_session_id
        then Ok ()
        else protocol_error "session" "reported session_id differs from requested identity"
      in
      let* () =
        match expected_model with
        | None -> Ok ()
        | Some expected when String.equal expected init.model -> Ok ()
        | Some _ -> protocol_error "init" "reported model differs from requested model"
      in
      let* () =
        if String.equal expected_cwd init.cwd
        then Ok ()
        else protocol_error "init" "reported cwd differs from configured cwd"
      in
      (match rejection, terminal.api_error_status with
       | Some (status, reset_at), _ ->
         Error (Turn_rejected { status; reset_at; detail = terminal.result })
       | None, Some 429 ->
         Error
           (Turn_rejected
              { status = "http_429"; reset_at = None; detail = terminal.result })
       | None, Some _ when not terminal.is_error ->
         protocol_error "result" "api_error_status requires is_error=true"
       | None, None
         when (match terminal.terminal_reason with
               | Some "api_error" -> not terminal.is_error
               | Some _ | None -> false) ->
         protocol_error "result" "terminal_reason=api_error requires is_error=true"
       | None, _ when terminal.is_error ->
         let reason = Option.value terminal.terminal_reason ~default:terminal.subtype in
         Error (Turn_failed (reason ^ ": " ^ terminal.result))
       | None, _ when not (String.equal terminal.subtype "success") ->
         Error (Turn_failed terminal.subtype)
       | None, _ when String.trim terminal.result = "" ->
         protocol_error "result" "successful result must not be empty"
       | None, _ ->
         Ok
           { session_id = terminal.session_id
           ; model = init.model
           ; text = terminal.result
           ; num_turns = terminal.num_turns
           ; usage = terminal.usage
           ; tool_calls
           ; permission_mode = init.permission_mode
           ; resumed
           })
;;

let session_id = function
  | Start { session_id } | Resume { session_id } -> session_id
;;

let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false
;;

let is_canonical_uuid value =
  let rec valid_at index =
    if index = String.length value
    then true
    else
      let valid_character =
        match index with
        | 8 | 13 | 18 | 23 -> Char.equal value.[index] '-'
        | _ -> is_hex_digit value.[index]
      in
      valid_character && valid_at (index + 1)
  in
  String.length value = 36 && valid_at 0
;;

let validate_config (config : config) ~session_mode ~prompt =
  let cwd_is_directory =
    try Sys.file_exists config.cwd && Sys.is_directory config.cwd with
    | Sys_error _ -> false
  in
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if Filename.is_relative config.cwd || String.trim config.cwd = ""
  then Error (Invalid_config "cwd must be an absolute path")
  else if not cwd_is_directory
  then Error (Invalid_config "cwd must name an existing directory")
  else if not (Float.is_finite config.timeout_s) || config.timeout_s <= 0.0
  then Error (Invalid_config "timeout_s must be positive and finite")
  else if config.max_turns <= 0
  then Error (Invalid_config "max_turns must be positive")
  else if Option.exists (fun model -> String.trim model = "") config.model
  then Error (Invalid_config "model must not be empty when provided")
  else if not (is_canonical_uuid (session_id session_mode))
  then Error (Invalid_config "session_id must be a canonical UUID")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else if not (Process_eio.is_initialized ())
  then Error (Invalid_config "initialized Process_eio runtime is required")
  else Ok ()
;;

let validate_run config ~session_mode ~prompt =
  validate_config config ~session_mode ~prompt
;;

let argv config ~session_mode ~prompt =
  let base =
    [ config.cli_path
    ; "--print"
    ; "--safe-mode"
    ; "--disable-slash-commands"
    ; "--no-chrome"
    ; "--permission-mode"
    ; "plan"
    ; "--tools"
    ; String.concat "," expected_tools
    ; "--max-turns"
    ; string_of_int config.max_turns
    ; "--output-format"
    ; "stream-json"
    ; "--verbose"
    ]
  in
  let base =
    match config.model with
    | None -> base
    | Some model -> base @ [ "--model"; model ]
  in
  let base =
    match session_mode with
    | Start { session_id } -> base @ [ "--session-id"; session_id ]
    | Resume { session_id } -> base @ [ "--resume"; session_id ]
  in
  base @ [ prompt ]
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let is_disallowed_environment_override = function
  | "ANTHROPIC_AUTH_TOKEN"
  | "ANTHROPIC_BASE_URL"
  | "CLAUDE_CODE_USE_BEDROCK"
  | "CLAUDE_CODE_USE_VERTEX"
  | "CLAUDE_CODE_USE_FOUNDRY" -> true
  | key -> Runtime_subscription_cli_env.is_metered_api_credential key
;;

let environment () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry -> not (is_disallowed_environment_override (env_key entry)))
  |> Array.of_list
;;

let status_detail status stderr =
  let status =
    match status with
    | Unix.WEXITED code -> Printf.sprintf "exit %d" code
    | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
    | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
  in
  let stderr = String.trim stderr in
  if String.equal stderr ""
  then status
  else
    let stderr =
      if String.length stderr <= 4096 then stderr else String.sub stderr 0 4096 ^ "..."
    in
    status ^ ": " ^ stderr
;;

let run_turn config ~session_mode ~prompt =
  match validate_run config ~session_mode ~prompt with
  | Error _ as error -> error
  | Ok () ->
    let cwd = Unix.realpath config.cwd in
    let config = { config with cwd } in
    (try
       let status, stdout, stderr =
         Process_eio.run_argv_with_status_split
           ~timeout_sec:config.timeout_s
           ~env:(environment ())
           ~cwd
           (argv config ~session_mode ~prompt)
       in
       match status with
       | Unix.WEXITED 0 ->
         parse_output ~expected_model:config.model ~expected_cwd:cwd ~session_mode stdout
       | Unix.WEXITED 124 -> Error (Timeout config.timeout_s)
       | _ -> Error (Process_exited (status_detail status stderr))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Spawn_failed (Printexc.to_string exn)))
;;

module For_testing = struct
  let parse_output = parse_output
  let is_disallowed_environment_override = is_disallowed_environment_override
end
