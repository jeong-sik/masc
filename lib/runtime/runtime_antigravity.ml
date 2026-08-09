(** Official Antigravity CLI single-turn execution.

    The [agy] process owns its OAuth session, model turn, and built-in agent
    tools. MASC owns argv construction, environment admission, process
    lifetime, strict stream-json decoding, and durable conversation identity. *)

type effort =
  | Low
  | Medium
  | High

type execution_mode =
  | Plan
  | Accept_edits

type config =
  { cli_path : string
  ; cwd : string
  ; model : string
  ; agent : string option
  ; effort : effort option
  ; execution_mode : execution_mode
  ; sandbox : bool
  ; disable_slash_commands : bool
  ; timeout_s : float
  }

let default_timeout_s = 300.0
let process_termination_grace_s = 2.0
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 8192
let max_wire_line_bytes = 8 * 1024 * 1024

let default_config ~cwd ~model =
  { cli_path = "agy"
  ; cwd
  ; model
  ; agent = None
  ; effort = None
  ; execution_mode = Plan
  ; sandbox = false
  ; disable_slash_commands = true
  ; timeout_s = default_timeout_s
  }
;;

type conversation_mode =
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
  ; permission_mode : string
  ; tool_steps : int
  ; tool_errors : int
  ; resumed : bool
  ; wall_duration_s : float
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | State_callback_failed of string
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

exception Runtime_error of error

let error_to_string = function
  | Invalid_config detail -> "invalid Antigravity CLI config: " ^ detail
  | Spawn_failed detail -> "failed to start Antigravity CLI: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Antigravity stream-json protocol error during %s: %s" stage detail
  | State_callback_failed detail -> "Antigravity conversation state callback failed: " ^ detail
  | Turn_failed detail -> "Antigravity turn failed: " ^ detail
  | Process_exited detail -> "Antigravity CLI exited before completion: " ^ detail
  | Timeout seconds -> Printf.sprintf "Antigravity turn timed out after %.3fs" seconds
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })
let ( let* ) result f = Result.bind result f

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

let assoc_at stage = function
  | `Assoc fields -> Ok fields
  | _ -> protocol_error stage "expected a JSON object"
;;

let required_member stage name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let required_string ?(nonempty = true) stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when (not nonempty) || String.trim value <> "" -> Ok value
  | Some (`String _) ->
    protocol_error stage (Printf.sprintf "field %S must not be empty" name)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let optional_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string or null" name)
;;

let required_nonnegative_int stage name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some (`Int _) ->
    protocol_error stage (Printf.sprintf "field %S must be non-negative" name)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be an integer" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

let parse_usage stage fields =
  let* usage_json = required_member stage "usage" fields in
  let* usage_fields = assoc_at stage usage_json in
  let* input_tokens = required_nonnegative_int stage "input_tokens" usage_fields in
  let* output_tokens = required_nonnegative_int stage "output_tokens" usage_fields in
  let* thinking_tokens = required_nonnegative_int stage "thinking_tokens" usage_fields in
  let* cache_read_tokens = required_nonnegative_int stage "cache_read_tokens" usage_fields in
  let* total_tokens = required_nonnegative_int stage "total_tokens" usage_fields in
  if total_tokens <> input_tokens + output_tokens
  then
    protocol_error
      stage
      "usage.total_tokens must equal input_tokens + output_tokens"
  else Ok { input_tokens; output_tokens; thinking_tokens; cache_read_tokens; total_tokens }
;;

type wire_event =
  | Init of
      { conversation_id : string
      ; model : string
      ; cwd : string
      ; permission_mode : string
      }
  | Step_update of
      { conversation_id : string
      ; state : string
      ; step_type : string
      }
  | Result of
      { conversation_id : string
      ; status : string
      ; response : string
      ; error : string option
      ; num_turns : int
      ; usage : usage
      }

let parse_init fields =
  let stage = "init event" in
  let* conversation_id = required_string stage "conversation_id" fields in
  let* init_json = required_member stage "init" fields in
  let* init_fields = assoc_at stage init_json in
  let* model = required_string stage "model" init_fields in
  let* cwd = required_string stage "cwd" init_fields in
  let* permission_mode = required_string stage "permission_mode" init_fields in
  Ok (Init { conversation_id; model; cwd; permission_mode })
;;

let parse_step_update fields =
  let stage = "step_update event" in
  let* step_json = required_member stage "step_update" fields in
  let* step_fields = assoc_at stage step_json in
  let* conversation_id = required_string stage "conversation_id" step_fields in
  let* _step_index = required_nonnegative_int stage "step_index" step_fields in
  let* state = required_string stage "state" step_fields in
  let* step_type = required_string stage "step_type" step_fields in
  Ok (Step_update { conversation_id; state; step_type })
;;

let parse_result fields =
  let stage = "result event" in
  let* result_json = required_member stage "result" fields in
  let* result_fields = assoc_at stage result_json in
  let* conversation_id = required_string stage "conversation_id" result_fields in
  let* status = required_string stage "status" result_fields in
  let* response = required_string ~nonempty:false stage "response" result_fields in
  let* error = optional_string stage "error" result_fields in
  let* num_turns = required_nonnegative_int stage "num_turns" result_fields in
  let* usage = parse_usage stage result_fields in
  Ok (Result { conversation_id; status; response; error; num_turns; usage })
;;

let parse_wire_line line =
  let stage = "stream-json message" in
  let json_result =
    try Ok (Yojson.Safe.from_string line) with
    | Yojson.Json_error detail -> protocol_error stage ("invalid JSON: " ^ detail)
  in
  let* json = json_result in
  let* () = validate_unique_object_keys ~stage ~path:"$" json in
  let* fields = assoc_at stage json in
  let* event = required_string stage "event" fields in
  match event with
  | "init" -> parse_init fields
  | "step_update" -> parse_step_update fields
  | "result" -> parse_result fields
  | other -> protocol_error stage (Printf.sprintf "unsupported event %S" other)
;;

let effort_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
;;

let execution_mode_to_string = function
  | Plan -> "plan"
  | Accept_edits -> "accept-edits"
;;

let validate_config config ~conversation_mode ~prompt =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must not be empty")
  else if String.trim config.cwd = "" || Filename.is_relative config.cwd
  then Error (Invalid_config "cwd must be an absolute path")
  else if String.trim config.model = ""
  then Error (Invalid_config "model must not be empty")
  else if not (Float.is_finite config.timeout_s) || config.timeout_s <= 0.0
  then Error (Invalid_config "timeout_s must be positive and finite")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else
    match config.agent, conversation_mode with
    | Some agent, _ when String.trim agent = "" ->
      Error (Invalid_config "agent must not be empty when present")
    | _, Resume { conversation_id } when String.trim conversation_id = "" ->
      Error (Invalid_config "resume conversation_id must not be empty")
    | (None | Some _), (Start | Resume _) -> Ok ()
;;

let validate_turn ?(conversation_mode = Start) config ~prompt =
  validate_config config ~conversation_mode ~prompt
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let contains_substring value needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > value_length
    then false
    else if String.equal (String.sub value offset needle_length) needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let forbidden_environment_key key =
  contains_substring key "API_KEY"
  || contains_substring key "API_TOKEN"
  || List.mem
       key
       [ "GOOGLE_APPLICATION_CREDENTIALS"
       ; "GOOGLE_GENAI_USE_VERTEXAI"
       ; "GOOGLE_CLOUD_PROJECT"
       ; "GOOGLE_CLOUD_LOCATION"
       ; "GOOGLE_CREDENTIALS"
       ; "GOOGLE_OAUTH_ACCESS_TOKEN"
       ; "GOOGLE_ACCESS_TOKEN"
       ; "CLOUDSDK_AUTH_ACCESS_TOKEN"
       ; "VERTEX_AI_PROJECT"
       ; "VERTEX_AI_LOCATION"
       ; "AGY_ADC_AUTH"
       ]
;;

let official_client_environment () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry -> not (forbidden_environment_key (env_key entry)))
  |> Array.of_list
;;

let duration_argument seconds = Printf.sprintf "%.3fs" seconds

let cli_timeout_s timeout_s = max 0.001 (timeout_s *. 0.95)

let argv config ~conversation_mode ~prompt =
  let base =
    [ config.cli_path
    ; "--print"
    ; prompt
    ; "--output-format"
    ; "stream-json"
    ; "--model"
    ; config.model
    ; "--mode"
    ; execution_mode_to_string config.execution_mode
    ; "--add-dir"
    ; config.cwd
    ; "--print-timeout"
    ; duration_argument (cli_timeout_s config.timeout_s)
    ]
  in
  let with_optional flag value values =
    match value with
    | None -> values
    | Some value -> values @ [ flag; value ]
  in
  base
  |> with_optional "--agent" config.agent
  |> with_optional "--effort" (Option.map effort_to_string config.effort)
  |> (fun values -> if config.sandbox then values @ [ "--sandbox" ] else values)
  |> (fun values ->
    if config.disable_slash_commands then values @ [ "--disable-slash-commands" ] else values)
  |> (fun values ->
    match conversation_mode with
    | Start -> values
    | Resume { conversation_id } -> values @ [ "--conversation"; conversation_id ])
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
      tail :=
        bounded_tail
          ~limit:stderr_tail_bytes
          !tail
          (Cstruct.to_string (Cstruct.sub chunk 0 count))
    done
  with
  | End_of_file -> ()
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Runtime_agent.debug
      "Antigravity CLI stderr drain failed: %s"
      (Printexc.to_string exn)
;;

let terminate_spawned_process ~clock proc stdin_w =
  let owning_switch_cancelled = Eio.Fiber.is_cancelled () in
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | _ -> ());
    (try Eio.Process.signal proc Sys.sigterm with
     | _ -> ());
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
         | _ -> ())
      | _ -> ())
;;

type protocol_state =
  { init : (string * string * string) option
  ; result : (string * string * string option * int * usage) option
  ; tool_steps : int
  ; tool_errors : int
  }

let initial_protocol_state =
  { init = None; result = None; tool_steps = 0; tool_errors = 0 }
;;

let expected_conversation_id = function
  | Start -> None
  | Resume { conversation_id } -> Some conversation_id
;;

let verify_identity ~stage ~expected actual =
  match expected with
  | Some value when not (String.equal value actual) ->
    protocol_error
      stage
      (Printf.sprintf "conversation identity mismatch: expected %S, got %S" value actual)
  | None | Some _ -> Ok ()
;;

let apply_event (config : config) ~conversation_mode ~on_conversation_ready state = function
  | Init { conversation_id; model; cwd; permission_mode } ->
    let stage = "init event" in
    if Option.is_some state.init
    then protocol_error stage "received more than one init event"
    else if Option.is_some state.result
    then protocol_error stage "received init after result"
    else
      let* () =
        verify_identity
          ~stage
          ~expected:(expected_conversation_id conversation_mode)
          conversation_id
      in
      if not (String.equal model config.model)
      then
        protocol_error
          stage
          (Printf.sprintf "model mismatch: expected %S, got %S" config.model model)
      else if not (String.equal cwd config.cwd)
      then
        protocol_error
          stage
          (Printf.sprintf "cwd mismatch: expected %S, got %S" config.cwd cwd)
      else
        let callback_result =
          try on_conversation_ready ~conversation_id with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        (match callback_result with
         | Error detail -> Error (State_callback_failed detail)
         | Ok () ->
           Ok { state with init = Some (conversation_id, model, permission_mode) })
  | Step_update { conversation_id; state = step_state; step_type } ->
    let stage = "step_update event" in
    (match state.init with
     | None -> protocol_error stage "received step_update before init"
     | Some (expected, _, _) ->
       let* () = verify_identity ~stage ~expected:(Some expected) conversation_id in
       if Option.is_some state.result
       then protocol_error stage "received step_update after result"
       else
         let is_tool = String.equal step_type "tool" in
         Ok
           { state with
             tool_steps =
               state.tool_steps
               + if is_tool && String.equal step_state "ACTIVE" then 1 else 0
           ; tool_errors =
               state.tool_errors
               + if is_tool && String.equal step_state "ERROR" then 1 else 0
           })
  | Result { conversation_id; status; response; error; num_turns; usage } ->
    let stage = "result event" in
    (match state.init with
     | None -> protocol_error stage "received result before init"
     | Some (expected, _, _) ->
       let* () = verify_identity ~stage ~expected:(Some expected) conversation_id in
       if Option.is_some state.result
       then protocol_error stage "received more than one result event"
       else Ok { state with result = Some (status, response, error, num_turns, usage) })
;;

let status_to_string = function
  | `Exited code -> Printf.sprintf "exit code %d" code
  | `Signaled signal -> Printf.sprintf "signal %d" signal
;;

let run_spawned ~mgr ~clock ~cwd config ~conversation_mode ~prompt ~on_conversation_ready =
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
        ~env:(official_client_environment ())
        ~stdin:stdin_r
        ~stdout:stdout_w
        ~stderr:stderr_w
        (argv config ~conversation_mode ~prompt)
    in
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdin_w;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.fork ~sw (fun () -> drain_stderr stderr_r stderr_tail);
    let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
    let process_status = ref None in
    Fun.protect
      ~finally:(fun () ->
        match !process_status with
        | Some _ -> ()
        | None -> terminate_spawned_process ~clock proc stdin_w)
      (fun () ->
        let state = ref initial_protocol_state in
        (try
           while true do
             let line = Eio.Buf_read.line reader in
             match parse_wire_line line with
             | Error error -> raise (Runtime_error error)
             | Ok event ->
               (match
                  apply_event
                    config
                    ~conversation_mode
                    ~on_conversation_ready
                    !state
                    event
                with
                | Error error -> raise (Runtime_error error)
                | Ok next -> state := next)
           done
         with
         | End_of_file -> ()
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | Runtime_error _ as exn -> raise exn
         | exn ->
           raise
             (Runtime_error
                (Protocol_error
                   { stage = "stdout read"; detail = Printexc.to_string exn })));
        let status = Eio.Process.await proc in
        process_status := Some status;
        status, !state, String.trim !stderr_tail))
;;

let run_turn ?(conversation_mode = Start) ~mgr ~clock ~cwd
    ?(on_conversation_ready = fun ~conversation_id:_ -> Ok ()) config ~prompt =
  let* () = validate_config config ~conversation_mode ~prompt in
  let started_at = Eio.Time.now clock in
  let run_result =
    try
      Ok
        (Eio.Time.with_timeout_exn clock config.timeout_s (fun () ->
           run_spawned
             ~mgr
             ~clock
             ~cwd
             config
             ~conversation_mode
             ~prompt
             ~on_conversation_ready))
    with
    | Eio.Time.Timeout -> Error (Timeout config.timeout_s)
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Runtime_error error -> Error error
    | exn -> Error (Spawn_failed (Printexc.to_string exn))
  in
  let* status, state, stderr = run_result in
  let wall_duration_s = max 0.0 (Eio.Time.now clock -. started_at) in
  match status, state.init, state.result with
  | `Exited 0, Some (conversation_id, model, permission_mode),
    Some ("SUCCESS", text, _, num_turns, usage) ->
    Ok
      { conversation_id
      ; model
      ; text
      ; num_turns
      ; usage
      ; permission_mode
      ; tool_steps = state.tool_steps
      ; tool_errors = state.tool_errors
      ; resumed =
          (match conversation_mode with
           | Start -> false
           | Resume _ -> true)
      ; wall_duration_s
      }
  | _, Some _, Some (result_status, _, error, _, _)
    when not (String.equal result_status "SUCCESS") ->
    let detail =
      match error with
      | Some detail -> detail
      | None -> "status=" ^ result_status
    in
    Error (Turn_failed detail)
  | `Exited 0, _, None ->
    Error (Protocol_error { stage = "process completion"; detail = "missing result event" })
  | `Exited 0, None, Some _ ->
    Error (Protocol_error { stage = "process completion"; detail = "missing init event" })
  | (`Exited _ | `Signaled _), _, _ ->
    let exit = status_to_string status in
    Error (Process_exited (if stderr = "" then exit else exit ^ ": " ^ stderr))
;;
