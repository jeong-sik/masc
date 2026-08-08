type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; timeout_s : float
  }

type session_mode =
  | Start
  | Resume of { conversation_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }

type turn_result =
  { conversation_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; tool_calls : int
  ; permission_mode : string
  ; resumed : bool
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

let error_to_string = function
  | Invalid_config detail -> "invalid Antigravity CLI config: " ^ detail
  | Spawn_failed detail -> "failed to start Antigravity CLI: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Antigravity CLI protocol error during %s: %s" stage detail
  | Turn_failed detail -> "Antigravity CLI turn failed: " ^ detail
  | Process_exited detail -> "Antigravity CLI process failed: " ^ detail
  | Timeout seconds ->
    Printf.sprintf "Antigravity CLI turn timed out after %.3fs" seconds
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
          let* () =
            validate_unique_object_keys ~stage ~path:(path ^ "." ^ name) value
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

let assoc stage = function
  | `Assoc fields -> Ok fields
  | _ -> protocol_error stage "expected a JSON object"
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

let optional_object stage name fields =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`Assoc nested) -> Ok (Some nested)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an object" name)
;;

let usage_of_fields stage fields =
  let* input_tokens = nonnegative_int stage "input_tokens" fields in
  let* output_tokens = nonnegative_int stage "output_tokens" fields in
  let* thinking_tokens = nonnegative_int stage "thinking_tokens" fields in
  let* cache_read_tokens = nonnegative_int stage "cache_read_tokens" fields in
  let* total_tokens = nonnegative_int stage "total_tokens" fields in
  if input_tokens > Int.max_int - output_tokens
  then protocol_error stage "input_tokens + output_tokens overflowed"
  else if total_tokens <> input_tokens + output_tokens
  then protocol_error stage "total_tokens must equal input_tokens + output_tokens"
  else
    Ok
      { input_tokens
      ; output_tokens
      ; thinking_tokens
      ; cache_read_tokens
      ; total_tokens
      }
;;

let parse_json_line ~line_number line =
  let stage = Printf.sprintf "stdout line %d" line_number in
  if String.length line > 8 * 1024 * 1024
  then protocol_error stage "NDJSON line exceeds 8 MiB"
  else
    try
      let json = Yojson.Safe.from_string line in
      let* () = validate_unique_object_keys ~stage ~path:"$" json in
      Ok (stage, json)
    with
    | Yojson.Json_error detail -> protocol_error stage detail
;;

type init =
  { conversation_id : string
  ; model : string
  ; cwd : string
  ; permission_mode : string
  }

type terminal =
  { conversation_id : string
  ; status : string
  ; response : string
  ; num_turns : int
  ; usage : usage
  }

let parse_init stage top_fields =
  let* conversation_id = required_string stage "conversation_id" top_fields in
  let* init_json =
    match List.assoc_opt "init" top_fields with
    | Some value -> Ok value
    | None -> protocol_error stage "missing field \"init\""
  in
  let* init_fields = assoc stage init_json in
  let* model = required_string stage "model" init_fields in
  let* cwd = required_string stage "cwd" init_fields in
  let* permission_mode = required_string stage "permission_mode" init_fields in
  (match List.assoc_opt "tools" init_fields with
   | Some (`List tools) ->
     let rec validate_tools = function
       | [] -> Ok ()
       | `String name :: rest when String.trim name <> "" -> validate_tools rest
       | _ -> protocol_error stage "init.tools must contain non-empty strings"
     in
     let* () = validate_tools tools in
     Ok { conversation_id; model; cwd; permission_mode }
   | Some _ -> protocol_error stage "init.tools must be an array"
   | None -> protocol_error stage "missing field \"tools\"")
;;

let parse_step_update stage top_fields =
  let* update_json =
    match List.assoc_opt "step_update" top_fields with
    | Some value -> Ok value
    | None -> protocol_error stage "missing field \"step_update\""
  in
  let* fields = assoc stage update_json in
  let* conversation_id = required_string stage "conversation_id" fields in
  let* step_index = nonnegative_int stage "step_index" fields in
  let* state = required_string stage "state" fields in
  let* step_type = required_string stage "step_type" fields in
  let* usage_fields = optional_object stage "usage" fields in
  let* () =
    match usage_fields with
    | None -> Ok ()
    | Some usage_fields -> usage_of_fields stage usage_fields |> Result.map ignore
  in
  Ok (conversation_id, step_index, state, step_type)
;;

let parse_terminal stage top_fields =
  let* result_json =
    match List.assoc_opt "result" top_fields with
    | Some value -> Ok value
    | None -> protocol_error stage "missing field \"result\""
  in
  let* fields = assoc stage result_json in
  let* conversation_id = required_string stage "conversation_id" fields in
  let* status = required_string stage "status" fields in
  let* response = required_plain_string stage "response" fields in
  let* num_turns = required_int stage "num_turns" fields in
  if num_turns <= 0
  then protocol_error stage "num_turns must be positive"
  else
    let* usage_json =
      match List.assoc_opt "usage" fields with
      | Some value -> Ok value
      | None -> protocol_error stage "missing field \"usage\""
    in
    let* usage_fields = assoc stage usage_json in
    let* usage = usage_of_fields stage usage_fields in
    Ok { conversation_id; status; response; num_turns; usage }
;;

let parse_output ~expected_model ~expected_cwd ~session_mode output =
  let lines =
    output
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  if List.length lines > 16_384
  then protocol_error "stdout" "NDJSON event count exceeds 16384"
  else
    let rec loop line_number init terminal tool_steps = function
      | [] -> Ok (init, terminal, tool_steps)
      | _ :: _ when Option.is_some terminal ->
        protocol_error "stdout" "events appeared after the terminal result"
      | line :: rest ->
        let* stage, json = parse_json_line ~line_number line in
        let* top_fields = assoc stage json in
        let* event = required_string stage "event" top_fields in
        (match event with
         | "init" ->
           if Option.is_some init
           then protocol_error stage "duplicate init event"
           else
             let* parsed = parse_init stage top_fields in
             loop (line_number + 1) (Some parsed) terminal tool_steps rest
         | "step_update" ->
           let* conversation_id, step_index, state, step_type =
             parse_step_update stage top_fields
           in
           (match init with
            | None -> protocol_error stage "step_update arrived before init"
            | Some init when not (String.equal init.conversation_id conversation_id) ->
              protocol_error stage "step_update conversation_id changed"
            | Some _ ->
              let tool_steps =
                if String.equal step_type "tool" && String.equal state "DONE"
                then if List.mem step_index tool_steps then tool_steps else step_index :: tool_steps
                else tool_steps
              in
              loop (line_number + 1) init terminal tool_steps rest)
         | "result" ->
           (match init with
            | None -> protocol_error stage "result arrived before init"
            | Some _ ->
              let* parsed = parse_terminal stage top_fields in
              loop (line_number + 1) init (Some parsed) tool_steps rest)
         | other -> protocol_error stage (Printf.sprintf "unsupported event %S" other))
    in
    let* init, terminal, tool_steps = loop 1 None None [] lines in
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
      if String.equal init.conversation_id terminal.conversation_id
      then Ok ()
      else protocol_error "result" "terminal conversation_id changed"
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
    let* resumed =
      match session_mode with
      | Start when terminal.num_turns = 1 -> Ok false
      | Start -> protocol_error "result" "new conversation did not report num_turns=1"
      | Resume { conversation_id }
        when String.equal conversation_id init.conversation_id
             && terminal.num_turns >= 2 -> Ok true
      | Resume { conversation_id } when not (String.equal conversation_id init.conversation_id) ->
        protocol_error "init" "resumed conversation_id differs from requested identity"
      | Resume _ -> protocol_error "result" "resumed conversation did not advance turn count"
    in
    if not (String.equal terminal.status "SUCCESS")
    then Error (Turn_failed terminal.status)
    else if String.trim terminal.response = ""
    then protocol_error "result" "successful response must not be empty"
    else
      Ok
        { conversation_id = terminal.conversation_id
        ; model = init.model
        ; text = terminal.response
        ; num_turns = terminal.num_turns
        ; usage = terminal.usage
        ; tool_calls = List.length tool_steps
        ; permission_mode = init.permission_mode
        ; resumed
        }
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
  else if not (Process_eio.is_initialized ())
  then Error (Invalid_config "initialized Process_eio runtime is required")
  else if not (Float.is_finite config.timeout_s) || config.timeout_s <= 0.0
  then Error (Invalid_config "timeout_s must be positive and finite")
  else if Option.exists (fun model -> String.trim model = "") config.model
  then Error (Invalid_config "model must not be empty when provided")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else
    match session_mode with
    | Resume { conversation_id } when String.trim conversation_id = "" ->
      Error (Invalid_config "resume conversation_id must not be empty")
    | Start | Resume _ -> Ok ()
;;

let argv config ~session_mode ~prompt =
  let base =
    [ config.cli_path
    ; "--print"
    ; prompt
    ; "--output-format"
    ; "stream-json"
    ; "--mode"
    ; "plan"
    ; "--sandbox"
    ; "--disable-slash-commands"
    ; "--print-timeout"
    ; Printf.sprintf "%.3fs" config.timeout_s
    ]
  in
  let base =
    match config.model with
    | None -> base
    | Some model -> base @ [ "--model"; model ]
  in
  match session_mode with
  | Start -> base
  | Resume { conversation_id } -> base @ [ "--conversation"; conversation_id ]
;;

let status_detail status stderr =
  let status =
    match status with
    | Unix.WEXITED code -> Printf.sprintf "exit %d" code
    | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
    | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
  in
  match String.trim stderr with
  | "" -> status
  | stderr -> status ^ ": " ^ stderr
;;

let run_turn ?(session_mode = Start) config ~prompt =
  match validate_config config ~session_mode ~prompt with
  | Error _ as error -> error
  | Ok () ->
    let cwd = Unix.realpath config.cwd in
    let config = { config with cwd } in
    (try
       let status, stdout, stderr =
         Process_eio.run_argv_with_status_split
           ~timeout_sec:config.timeout_s
           ~env:(Runtime_subscription_cli_env.environment ())
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
end
