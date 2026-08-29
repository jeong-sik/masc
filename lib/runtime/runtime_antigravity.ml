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
  ; add_dirs : string list
  ; model : string
  ; agent : string option
  ; effort : effort option
  ; execution_mode : execution_mode
  ; sandbox : bool
  ; disable_slash_commands : bool
  ; admission_timeout_s : float
  ; timeout_s : float option
  ; wall_clock_ceiling_s : float option
  ; output_schema : Yojson.Safe.t option
  }

let default_timeout_s = 300.0
let process_termination_grace_s = 2.0

(* How long a CLI that already delivered its result event may take to
   exit before we reap it. A healthy CLI exits well under a second after
   the result; the #28912 shutdown hang ("Waiting for migrations to
   complete", a child language server holding stdout open) never exits at
   all, so anything past this window is the hang, not slow work — the
   turn itself is already complete and none of this wait is on the
   critical path of a healthy turn. *)
let result_exit_grace_s = 5.0

(* [None] installs no deadline. The vendor client owns when its own turn ends;
   a declared bound is the operator's optional liveness guard over a silent
   client, not a limit on how long legitimate work may take. *)
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 8192
let max_wire_line_bytes = 8 * 1024 * 1024

(* [--print-timeout] is a wall-clock deadline owned by agy, not an idle
   deadline. It ended a live turn after 9.45s despite an agent response, a
   completed 4.25s tool, and a checkpoint inside a 10s window (agy 1.1.12,
   2026-08-11). MASC owns liveness below by timing each JSONL read, so the CLI
   deadline must be non-authoritative. This is Go's maximum time.Duration,
   accepted by the installed CLI; it is finite and therefore keeps argv strict
   without imposing a practical wall-clock ceiling. *)
let cli_non_authoritative_timeout = "2562047h47m16.854775807s"

let default_config ~cwd ~model =
  { cli_path = "agy"
  ; cwd
  ; add_dirs = []
  ; model
  ; agent = None
  ; effort = None
  ; execution_mode = Plan
  ; sandbox = false
  ; disable_slash_commands = true
  ; admission_timeout_s = default_timeout_s
  ; timeout_s = Some default_timeout_s
  ; wall_clock_ceiling_s = None
  ; output_schema = None
  }
;;

let timeout_s_for_phase config ~turn_admitted =
  if turn_admitted
  then config.timeout_s
  else Some config.admission_timeout_s
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

(* Nothing in this tree branches on [permission_mode]: the only read of the
   field is its own parse site. It was closed, and the one member the CLI added
   ended a turn, parked the official-client session, and stopped a live Keeper
   after 110 turns in one hour (#28008). Adding that member leaves the
   next one to do it again, so an unseen mode is carried rather than rejected.
   [step_type] took the same route in #28027. *)
type permission_mode =
  | Always_proceed
  | Request_review
  | Unrecognized_permission_mode of string

type turn_result =
  { conversation_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; permission_mode : permission_mode
  ; tool_steps : int
  ; tool_errors : int
  ; trajectory_error : string option
  ; resumed : bool
  ; wall_duration_s : float
  }

type stream_event =
  | Turn_started of
      { conversation_id : string
      ; model : string
      }
  | Text_delta of string
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Turn_finished of { text : string }

let emit_stream_event on_stream_event event =
  match on_stream_event with
  | None -> ()
  | Some emit ->
    (try emit event with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.warn
         "Antigravity stream callback raised (error=%s)"
         (Printexc.to_string exn))
;;

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
  | Timeout seconds -> Printf.sprintf "Antigravity stream was idle for %.3fs" seconds
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })
let ( let* ) result f = Result.bind result f

(* The three official-client runtimes speak the same line-delimited JSON
   protocol and differ only in the error constructor they fail with. The shape
   checks live once in {!Runtime_official_client_json}; this instantiates them
   against this runtime's own [error]. *)
module Shared_json = Runtime_official_client_json.Make (struct
  type t = error

  let protocol ~stage ~detail = Protocol_error { stage; detail }
end)

open Shared_json

let bounded_tail = Runtime_official_client_json.bounded_tail

let required_string ?(nonempty = true) stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when (not nonempty) || String.trim value <> "" -> Ok value
  | Some (`String _) ->
    protocol_error stage (Printf.sprintf "field %S must not be empty" name)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
  | None -> protocol_error stage (Printf.sprintf "missing field %S" name)
;;

(* The init event states the conversation's identity; step_update and result
   restate it. Present and non-blank is a restatement; missing, null, or
   blank is silence. [required_string] cannot express that difference -- it
   rejects a blank before anything decides whether the value was needed. *)
let restated_string stage name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value = "" -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> protocol_error stage (Printf.sprintf "field %S must be a string" name)
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
      ; permission_mode : permission_mode
      }
  | Step_update of
      { conversation_id : string option
      ; step_index : int option
      ; state : step_state
      ; step_type : step_type
      ; tool_name : string option
      }
  | Result of
      { (* [None] two ways: the CLI refuses a bad invocation with a single
           result event and never opens a conversation, or a live result
           restates the identity as blank. Init is the one event that states
           it. *)
        conversation_id : string option
      ; status : result_status
      ; response : string
      ; error : string option
      ; num_turns : int
      ; usage : usage
      }

and step_state =
  | Active
  | Done
  | Step_error

and step_type =
  | Agent_response
  | System_message
  | Tool
  | User_input
  | Internal
  | Checkpoint
  | Unrecognized of string

and result_status =
  | Success
  | Result_error

let closed_string stage name parse value =
  match parse value with
  | Some value -> Ok value
  | None ->
    protocol_error stage (Printf.sprintf "unsupported field %S value %S" name value)
;;

let parse_permission_mode _stage value =
  Ok
    (match value with
     | "always-proceed" -> Always_proceed
     | "request-review" -> Request_review
     | other -> Unrecognized_permission_mode other)
;;

let parse_step_state stage value =
  closed_string
    stage
    "state"
    (function
      | "ACTIVE" -> Some Active
      | "DONE" -> Some Done
      | "ERROR" -> Some Step_error
      | _ -> None)
    value
;;

(* [step_type] decides one thing: whether this step is a tool step, for the two
   tool counters. Every non-[Tool] value is behaviourally identical, so a value
   we have not seen carries no decision we could get wrong -- but rejecting it
   ends the turn and parks the session, which blocks every later turn for that
   Keeper. Live 2026-08-10: Antigravity began emitting "system_message" and
   the affected Keeper stopped (#28027).

   #28029 opened this with [Unrecognized]; #28037 closed it again and named
   [System_message] instead. Naming the member that stalled a keeper leaves the
   next one to stall it again, and nothing branches on [System_message] -- it
   appears at its declaration and at this parse site only. Both are kept here:
   the known member keeps its name, and anything else is carried rather than
   rejected.

   [Unrecognized] carries the value rather than folding it into [Internal] so a
   later consumer cannot read an unseen step as a known one. It does not make
   the drift observable: [step_type] never reaches [turn_result], so nothing
   renders it today.

   [state] and [status] stay closed: each of those does decide something.
   [permission_mode] does not, and is open for the same reason as this one. *)
let parse_step_type _stage value =
  Ok
    (match value with
     | "agent_response" -> Agent_response
     | "system_message" -> System_message
     | "tool" -> Tool
     | "user_input" -> User_input
     | "unknown" -> Internal
     | "checkpoint" -> Checkpoint
     | other -> Unrecognized other)
;;

let parse_result_status stage value =
  closed_string
    stage
    "status"
    (function
      | "SUCCESS" -> Some Success
      | "ERROR" -> Some Result_error
      | _ -> None)
    value
;;

let parse_init fields =
  let stage = "init event" in
  let* conversation_id = required_string stage "conversation_id" fields in
  let* init_json = required_member stage "init" fields in
  let* init_fields = assoc_at stage init_json in
  let* model = required_string stage "model" init_fields in
  let* cwd = required_string stage "cwd" init_fields in
  let* permission_mode_string = required_string stage "permission_mode" init_fields in
  let* permission_mode = parse_permission_mode stage permission_mode_string in
  Ok (Init { conversation_id; model; cwd; permission_mode })
;;

let parse_step_update fields =
  let stage = "step_update event" in
  let* step_json = required_member stage "step_update" fields in
  let* step_fields = assoc_at stage step_json in
  let* conversation_id = restated_string stage "conversation_id" step_fields in
  (* The ordinal is now carried only as optional native-tool identity. An absent
     or drifted value therefore stays [None] instead of turning an otherwise
     usable step update into a terminal protocol failure (#28010). *)
  let step_index =
    match List.assoc_opt "step_index" step_fields with
    | Some (`Int value) when value >= 0 -> Some value
    | Some (`Intlit value) ->
      (match int_of_string_opt value with
       | Some value when value >= 0 -> Some value
       | Some _ | None -> None)
    | Some _ | None -> None
  in
  let* state_string = required_string stage "state" step_fields in
  let* state = parse_step_state stage state_string in
  let* step_type_string = required_string stage "step_type" step_fields in
  let* step_type = parse_step_type stage step_type_string in
  let* tool_name = optional_string stage "tool_name" step_fields in
  Ok (Step_update { conversation_id; step_index; state; step_type; tool_name })
;;

let parse_result fields =
  let stage = "result event" in
  let* result_json = required_member stage "result" fields in
  let* result_fields = assoc_at stage result_json in
  let* conversation_id = restated_string stage "conversation_id" result_fields in
  let* status_string = required_string stage "status" result_fields in
  let* status = parse_result_status stage status_string in
  let* response = required_string ~nonempty:false stage "response" result_fields in
  (* Under --json-schema the CLI validates its answer and re-prompts, and only
     [structured_output] carries what passed. Measured 2026-08-30: [response]
     still held a fenced draft containing a key the schema forbids while
     [structured_output] held the clean object. So where the field is present
     it is the answer, and the prose beside it is narration. *)
  let response =
    match List.assoc_opt "structured_output" result_fields with
    | None | Some `Null -> response
    | Some value -> Yojson.Safe.to_string value
  in
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
  else if
    not (Float.is_finite config.admission_timeout_s)
    || config.admission_timeout_s <= 0.0
  then Error (Invalid_config "admission_timeout_s must be positive and finite")
  else if
    (match config.timeout_s with
     | None -> false
     | Some seconds -> not (Float.is_finite seconds) || seconds <= 0.0)
  then Error (Invalid_config "a declared timeout_s must be positive and finite")
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

let allowed_environment_key key =
  List.mem
    key
    [ "COLORTERM"
    ; "HOME"
    ; "LANG"
    ; "LC_ALL"
    ; "LC_CTYPE"
    ; "LOGNAME"
    ; "PATH"
    ; "SHELL"
    ; "SSL_CERT_DIR"
    ; "SSL_CERT_FILE"
    ; "TEMP"
    ; "TERM"
    ; "TMP"
    ; "TMPDIR"
    ; "TZ"
    ; "USER"
    ; "XDG_CACHE_HOME"
    ; "XDG_CONFIG_HOME"
    ; "XDG_DATA_HOME"
    ; "XDG_RUNTIME_DIR"
    ]
;;

let official_client_environment ?home_dir () =
  let overridden_keys =
    match home_dir with
    | None -> []
    | Some _ -> [ "HOME"; "XDG_CACHE_HOME"; "XDG_CONFIG_HOME"; "XDG_DATA_HOME" ]
  in
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry ->
      let key = env_key entry in
      allowed_environment_key key && not (List.mem key overridden_keys))
  in
  match home_dir with
  | None -> Array.of_list inherited
  | Some home_dir -> Array.of_list (("HOME=" ^ home_dir) :: inherited)
;;

let argv config ~conversation_mode =
  let base =
    [ config.cli_path
    ; "--output-format"
    ; "stream-json"
    ; "--model"
    ; config.model
    ; "--mode"
    ; execution_mode_to_string config.execution_mode
    ]
    (* The keeper base path is always the first workspace root; [add_dirs]
       extends it with the provider-declared extra roots, one [--add-dir]
       per directory. *)
    @ List.concat_map
        (fun dir -> [ "--add-dir"; dir ])
        (config.cwd :: config.add_dirs)
    @ [ "--print-timeout"; cli_non_authoritative_timeout ]
  in
  let with_optional flag value values =
    match value with
    | None -> values
    | Some value -> values @ [ flag; value ]
  in
  base
  |> with_optional
       "--json-schema"
       (* The flag takes an inline schema string or a path. With
          --output-format stream-json the CLI applies it to the terminal
          result event, which is the event this adapter reads, so the
          existing stream shape needs no change. *)
       (Option.map Yojson.Safe.to_string config.output_schema)
  |> with_optional "--agent" config.agent
  |> with_optional "--effort" (Option.map effort_to_string config.effort)
  |> (fun values -> if config.sandbox then values @ [ "--sandbox" ] else values)
  |> (fun values ->
    if config.disable_slash_commands then values @ [ "--disable-slash-commands" ] else values)
  |> (fun values ->
    match conversation_mode with
    | Start -> values @ [ "--new-project" ]
    | Resume { conversation_id } -> values @ [ "--conversation"; conversation_id ])
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

let signal_spawned_process proc stdin_w =
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | _ -> ());
    (try Eio.Process.signal proc Sys.sigterm with
     | _ -> ()))
;;

let terminate_spawned_process ~clock proc stdin_w =
  signal_spawned_process proc stdin_w;
  Eio.Cancel.protect (fun () ->
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
  { init : (string * string * permission_mode) option
  ; result : (result_status * string * string option * int * usage) option
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

(* A restatement the CLI left blank makes no claim, so there is nothing to
   contradict -- and the id the turn carries comes from the init event either
   way. Requiring it non-empty turned a value nothing consumes into a terminal
   parse error: 110 turns over five days died at attempt=1 with
   [field "conversation_id" must not be empty], across three keepers. This is
   the shape #28010 closed for [step_index] and #28008/#28027 closed for
   [permission_mode] and [step_type]. *)
let verify_restatement ~stage ~expected = function
  | None -> Ok ()
  | Some actual -> verify_identity ~stage ~expected:(Some expected) actual
;;

let apply_event (config : config) ~conversation_mode ~on_conversation_ready
    ~on_stream_event state = function
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
          | Eio.Time.Timeout as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        (match callback_result with
         | Error detail -> Error (State_callback_failed detail)
         | Ok () ->
           emit_stream_event
             on_stream_event
             (Turn_started { conversation_id; model });
           Ok { state with init = Some (conversation_id, model, permission_mode) })
  | Step_update
      { conversation_id
      ; step_index
      ; state = step_state
      ; step_type
      ; tool_name
      } ->
    let stage = "step_update event" in
    (match state.init with
     | None -> protocol_error stage "received step_update before init"
     | Some (expected, _, _) ->
       let* () = verify_restatement ~stage ~expected conversation_id in
       if Option.is_some state.result
       then protocol_error stage "received step_update after result"
       else
         let is_tool = step_type = Tool in
         if is_tool
         then (
           let observation : Runtime_native_tools.observation =
             { identity =
                 Option.map
                   (fun step_index ->
                      Runtime_native_tools.Provider_step
                        { conversation_id = expected; step_index })
                   step_index
             ; tool_name
             ; origin =
                 (match tool_name with
                  | Some "call_mcp_tool" -> Runtime_native_tools.Mcp_wrapper
                  | Some _ | None -> Runtime_native_tools.Built_in)
             }
           in
           match step_state with
           | Active ->
             emit_stream_event on_stream_event (Native_tool_started observation)
           | Done | Step_error ->
             emit_stream_event on_stream_event (Native_tool_finished observation));
         Ok
           { state with
             tool_steps =
               state.tool_steps
               + if is_tool && step_state = Active then 1 else 0
           ; tool_errors =
               state.tool_errors
               + if is_tool && step_state = Step_error then 1 else 0
           })
  | Result { conversation_id; status; response; error; num_turns; usage } ->
    let stage = "result event" in
    (match state.init, status with
     (* A rejected invocation is a well-formed stream, not a broken one: the
        CLI emits one result event carrying its own account of the refusal and
        never opens a conversation, so there is no init to match against.
        Reporting a protocol error here would discard the only description of
        what went wrong — a missing --effort read as "conversation_id must not
        be empty" (2026-08-25, gemini-3.7-flash). *)
     | None, Result_error ->
       Error
         (Turn_failed
            (match error with
             | Some detail -> detail
             | None -> "status=ERROR before init"))
     | None, Success -> protocol_error stage "received result before init"
     | Some (expected, _, _), _ ->
       let* () = verify_restatement ~stage ~expected conversation_id in
       if Option.is_some state.result
       then protocol_error stage "received more than one result event"
       else (
         (match status with
          | Success -> emit_stream_event on_stream_event (Text_delta response)
          | Result_error ->
            if Agent_core.Response_shape.has_deliverable_content
                 (Agent_core.Response_shape.summarize_blocks
                    [ Agent_core.Types.Text response ])
            then emit_stream_event on_stream_event (Text_delta response));
         Ok { state with result = Some (status, response, error, num_turns, usage) }))
;;

let status_to_string = function
  | `Exited code -> Printf.sprintf "exit code %d" code
  | `Signaled signal -> Printf.sprintf "signal %d" signal
;;

let run_spawned ?home_dir ?on_spawned ~mgr ~clock ~cwd config ~conversation_mode
    ~prompt ~on_conversation_ready ~on_stream_event =
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    let stderr_tail = ref "" in
    let proc =
      try
        Eio.Process.spawn
          ~sw
          mgr
          ~cwd
          ~env:(official_client_environment ?home_dir ())
          ~stdin:stdin_r
          ~stdout:stdout_w
          ~stderr:stderr_w
          (argv config ~conversation_mode)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> raise (Runtime_error (Spawn_failed (Printexc.to_string exn)))
    in
    Option.iter (fun callback -> callback ()) on_spawned;
    Eio.Flow.close stdin_r;
    Eio.Flow.close stdout_w;
    Eio.Flow.close stderr_w;
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Flow.copy_string prompt stdin_w;
      (* A successful prompt write must deliver EOF to the CLI. If the copy
         raises, the failed fiber cancels [sw] and the pipe's switch-owned
         release handler closes [stdin_w]. *)
      Eio.Flow.close stdin_w);
    Eio.Fiber.fork ~sw (fun () -> drain_stderr stderr_r stderr_tail);
    let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
    let process_settled = ref false in
    let settle_failed_process () =
      if not !process_settled
      then (
        Eio.Cancel.protect (fun () -> terminate_spawned_process ~clock proc stdin_w);
        process_settled := true)
    in
    let abort_with_runtime_error error =
      settle_failed_process ();
      raise (Runtime_error error)
    in
    (* This handler runs before Eio's process release handler (LIFO). It must
       only signal: awaiting here would race the release handler's reap and
       deadlock timeout cancellation. Typed non-cancellation failures reap in
       [settle_failed_process] before leaving the switch. *)
    Eio.Switch.on_release sw (fun () ->
      if not !process_settled then signal_spawned_process proc stdin_w);
    let state = ref initial_protocol_state in
    let wall_clock =
      Runtime_wall_clock.make ?ceiling_s:config.wall_clock_ceiling_s ~now:(fun () -> Eio.Time.now clock) ()
    in
    (try
       (* The result event completes the protocol — nothing after it is
          attribution or content (apply_event rejects post-result events).
          EOF cannot be the completion contract: the CLI's own shutdown can
          hang while a child process keeps stdout open (#28912), which
          turned already-served turns into idle timeouts. *)
       while Option.is_none !state.result do
         if Runtime_wall_clock.expired wall_clock then
           abort_with_runtime_error
             (Timeout
                (Option.value config.wall_clock_ceiling_s
                   ~default:Runtime_wall_clock.default_ceiling_s));
         let timeout_s =
           timeout_s_for_phase config ~turn_admitted:(Option.is_some !state.init)
           |> Runtime_wall_clock.cap_window wall_clock
         in
         let line =
           with_optional_timeout clock timeout_s (fun () ->
             Eio.Buf_read.line reader)
         in
         match parse_wire_line line with
         | Error error -> abort_with_runtime_error error
         | Ok event ->
           (match
              with_optional_timeout clock timeout_s (fun () ->
                apply_event
                  config
                  ~conversation_mode
                  ~on_conversation_ready
                  ~on_stream_event
                  !state
                  event)
            with
            | Error error -> abort_with_runtime_error error
            | Ok next -> state := next)
       done
     with
     | End_of_file -> ()
     | Eio.Cancel.Cancelled _ as exn ->
       signal_spawned_process proc stdin_w;
       process_settled := true;
       raise exn
     | Idle_timeout seconds ->
       abort_with_runtime_error (Timeout seconds)
     | Eio.Time.Timeout as exn -> raise exn
     | Runtime_error _ as exn -> raise exn
     | exn ->
       abort_with_runtime_error
         (Protocol_error
            { stage = "stdout read"; detail = Printexc.to_string exn }));
    let status =
      (* Bounded: after a completed protocol (or EOF) a healthy CLI exits
         almost immediately; a CLI stuck in its shutdown gets reaped. The
         repeated await after terminate is safe — Eio.Process.await is
         idempotent over the cached exit status. *)
      try
        Eio.Time.with_timeout_exn clock result_exit_grace_s (fun () ->
          Eio.Process.await proc)
      with
      | Eio.Time.Timeout ->
        Eio.Cancel.protect (fun () -> terminate_spawned_process ~clock proc stdin_w);
        Eio.Process.await proc
    in
    process_settled := true;
    status, !state, String.trim !stderr_tail)
;;

let run_turn ?(conversation_mode = Start) ?home_dir ?on_spawned ~mgr ~clock ~cwd
    ?(on_conversation_ready = fun ~conversation_id:_ -> Ok ()) ?on_stream_event
    config ~prompt =
  let* () =
    match home_dir with
    | None -> Ok ()
    | Some path when String.trim path = "" || Filename.is_relative path ->
      Error (Invalid_config "home_dir must be an absolute non-empty path")
    | Some _ -> Ok ()
  in
  let* () = validate_config config ~conversation_mode ~prompt in
  let started_at = Eio.Time.now clock in
  let run_result =
    try
      Ok
        (run_spawned
           ?home_dir
           ?on_spawned
           ~mgr
           ~clock
           ~cwd
           config
           ~conversation_mode
           ~prompt
           ~on_conversation_ready
           ~on_stream_event)
    with
    | Idle_timeout seconds -> Error (Timeout seconds)
    | Eio.Time.Timeout as exn -> raise exn
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Runtime_error error -> Error error
    | exn ->
      Error
        (Protocol_error
           { stage = "runtime boundary"; detail = Printexc.to_string exn })
  in
  let* status, state, stderr = run_result in
  let wall_duration_s = max 0.0 (Eio.Time.now clock -. started_at) in
  match status, state.init, state.result with
  (* A parsed Success result is the completion contract regardless of how
     the process ended: the reply is already durable in the CLI's own
     conversation store, and the exit status only describes the CLI's
     shutdown (which can hang and get reaped, #28912). *)
  | _, Some _, Some (Success, text, _, _, _)
    when not
           (Agent_core.Response_shape.has_deliverable_content
              (Agent_core.Response_shape.summarize_blocks
                 [ Agent_core.Types.Text text ])) ->
    Error (Turn_failed "successful result response has no deliverable content")
  | _, Some (conversation_id, model, permission_mode),
    Some (Success, text, _, num_turns, usage) ->
    emit_stream_event on_stream_event (Turn_finished { text });
    Ok
      { conversation_id
      ; model
      ; text
      ; num_turns
      ; usage
      ; permission_mode
      ; tool_steps = state.tool_steps
      ; tool_errors = state.tool_errors
      ; trajectory_error = None
      ; resumed =
          (match conversation_mode with
           | Start -> false
           | Resume _ -> true)
      ; wall_duration_s
      }
  (* The CLI reports status=ERROR whenever any step of the trajectory
     errored, including a tool call the model already corrected and went
     on from. A reply was still produced, so the turn completed; the step
     error is carried as [trajectory_error] and counted in [tool_errors]. *)
  | _, Some (conversation_id, model, permission_mode),
    Some (Result_error, text, error, num_turns, usage)
    when Agent_core.Response_shape.has_deliverable_content
           (Agent_core.Response_shape.summarize_blocks
              [ Agent_core.Types.Text text ]) ->
    emit_stream_event on_stream_event (Turn_finished { text });
    Ok
      { conversation_id
      ; model
      ; text
      ; num_turns
      ; usage
      ; permission_mode
      ; tool_steps = state.tool_steps
      ; tool_errors = state.tool_errors
      ; trajectory_error =
          Some (match error with Some detail -> detail | None -> "status=ERROR")
      ; resumed =
          (match conversation_mode with
           | Start -> false
           | Resume _ -> true)
      ; wall_duration_s
      }
  | _, Some _, Some (Result_error, _, error, _, _) ->
    let detail = match error with Some detail -> detail | None -> "status=ERROR" in
    Error (Turn_failed detail)
  | _, None, Some _ ->
    Error (Protocol_error { stage = "process completion"; detail = "missing init event" })
  | `Exited 0, _, None ->
    Error (Protocol_error { stage = "process completion"; detail = "missing result event" })
  | (`Exited _ | `Signaled _), _, None ->
    let exit = status_to_string status in
    Error (Process_exited (if stderr = "" then exit else exit ^ ": " ^ stderr))
;;
