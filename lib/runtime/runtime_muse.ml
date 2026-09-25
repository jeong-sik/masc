type effort =
  | Effort_none
  | Effort_minimal
  | Effort_low
  | Effort_medium
  | Effort_high
  | Effort_xhigh
  | Effort_max
  | Effort_ultra

let effort_to_string = function
  | Effort_none -> "none"
  | Effort_minimal -> "minimal"
  | Effort_low -> "low"
  | Effort_medium -> "medium"
  | Effort_high -> "high"
  | Effort_xhigh -> "xhigh"
  | Effort_max -> "max"
  | Effort_ultra -> "ultra"
;;

type approval_mode =
  | Untrusted
  | On_request
  | Never

let approval_mode_to_string = function
  | Untrusted -> "untrusted"
  | On_request -> "on-request"
  | Never -> "never"
;;

let effort_of_reasoning_effort = function
  | Llm_provider.Reasoning_effort.None_ -> Effort_none
  | Llm_provider.Reasoning_effort.Minimal -> Effort_minimal
  | Llm_provider.Reasoning_effort.Low -> Effort_low
  | Llm_provider.Reasoning_effort.Medium -> Effort_medium
  | Llm_provider.Reasoning_effort.High -> Effort_high
  | Llm_provider.Reasoning_effort.XHigh -> Effort_xhigh
  | Llm_provider.Reasoning_effort.Max -> Effort_max
;;

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; reasoning_effort : effort option
  ; approval_mode : approval_mode
  ; output_schema : Yojson.Safe.t option
  ; admission_timeout_s : float
  ; timeout_s : float option
  ; wall_clock_ceiling_s : float option
  }

let default_timeout_s = 300.0

let default_config ~cwd =
  { cli_path = "muse"
  ; cwd
  ; model = None
  ; reasoning_effort = None
  ; approval_mode = On_request
  ; output_schema = None
  ; admission_timeout_s = default_timeout_s
  ; timeout_s = Some default_timeout_s
  ; wall_clock_ceiling_s = None
  }
;;

type session_mode =
  | Start
  | Resume of { session_id : string }

type image_input = { path : string }

type token_usage =
  { input_tokens : int
  ; output_tokens : int
  ; reasoning_tokens : int
  ; cached_tokens : int
  }

type turn_result =
  { session_id : string
  ; turn_id : string option
  ; text : string
  ; usage : token_usage option
  ; resumed : bool
  }

type stream_event =
  | Turn_started of
      { session_id : string
      ; turn_id : string option
      }
  | Text_delta of string
  | Usage_reported of
      { session_id : string
      ; usage : token_usage
      }
  | Turn_finished of { text : string }

type progress =
  { session_id : string option
  ; turn_id : string option
  ; started : bool
  }

let empty_progress = { session_id = None; turn_id = None; started = false }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Turn_failed of
      { terminal : string
      ; reason : string option
      ; usage : token_usage option
      }
  | Process_exited of
      { detail : string
      ; turn_admitted : bool
      }
  | Timeout of float

let error_to_string = function
  | Invalid_config detail -> Printf.sprintf "invalid Muse configuration: %s" detail
  | Spawn_failed detail -> Printf.sprintf "Muse client could not start: %s" detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Muse %s: %s" stage detail
  | Turn_failed { terminal; reason; usage = _ } ->
    (match reason with
     | None -> Printf.sprintf "Muse turn ended as %s" terminal
     | Some reason -> Printf.sprintf "Muse turn ended as %s: %s" terminal reason)
  | Process_exited { detail; turn_admitted } ->
    Printf.sprintf "Muse client exited %s: %s"
      (if turn_admitted then "mid-turn" else "before admitting a turn")
      detail
  | Timeout seconds -> Printf.sprintf "Muse turn timed out after %.0fs" seconds
;;

let protocol_error stage detail = Error (Protocol_error { stage; detail })

let assoc_of_json = function
  | `Assoc fields -> Some fields
  | _ -> None
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let object_field name fields =
  match List.assoc_opt name fields with
  | Some (`Assoc nested) -> Some nested
  | _ -> None
;;

(* Complete counters or nothing: a partial block reports no usage event,
   it never zero-fills the missing counters. *)
let token_usage_of_fields fields =
  match
    ( int_field "inputTokens" fields
    , int_field "outputTokens" fields
    , int_field "reasoningTokens" fields
    , int_field "cachedTokens" fields )
  with
  | Some input_tokens, Some output_tokens, Some reasoning_tokens, Some cached_tokens ->
    Some { input_tokens; output_tokens; reasoning_tokens; cached_tokens }
  | _ -> None
;;

let usage_of_payload payload =
  match object_field "usage" payload with
  | None -> None
  | Some usage_fields -> token_usage_of_fields usage_fields
;;

let apply_record progress json =
  let stage = "stream envelope" in
  match assoc_of_json json with
  | None -> protocol_error stage "expected a JSON object"
  | Some envelope ->
    (match object_field "payload" envelope with
     | None -> protocol_error stage "missing payload object"
     | Some payload ->
       (match string_field "kind" payload with
        | None -> protocol_error stage "missing payload kind"
        | Some kind ->
          let stream_session =
            match object_field "stream" envelope with
            | None -> None
            | Some stream -> string_field "id" stream
          in
          let run_id =
            match object_field "run_stream" payload with
            | None -> None
            | Some run -> string_field "id" run
          in
          let session_id =
            match progress.session_id, stream_session with
            | Some known, _ -> Some known
            | None, observed -> observed
          in
          let turn_id =
            match progress.turn_id, run_id with
            | Some known, _ -> Some known
            | None, observed -> observed
          in
          let base = { progress with session_id; turn_id } in
          let start_events =
            if progress.started then []
            else (
              match session_id with
              | None -> []
              | Some session_id -> [ Turn_started { session_id; turn_id } ])
          in
          let started = progress.started || Option.is_some session_id in
          let base = { base with started } in
          (match kind with
           | "run_output_delta" ->
             (match string_field "text" payload with
              | None -> protocol_error stage "run_output_delta carries no text"
              | Some text -> Ok (base, start_events @ [ Text_delta text ]))
           | "run_terminal" ->
             (match string_field "terminal" payload with
              | None -> protocol_error stage "run_terminal carries no terminal word"
              | Some "completed" ->
                let text =
                  match string_field "text" payload with
                  | Some text -> text
                  | None -> ""
                in
                let usage = usage_of_payload payload in
                let usage_events =
                  match session_id, usage with
                  | Some session_id, Some usage -> [ Usage_reported { session_id; usage } ]
                  | _ -> []
                in
                Ok (base, start_events @ usage_events @ [ Turn_finished { text } ])
              | Some (("failed" | "cancelled") as terminal) ->
                let reason = string_field "reason" payload in
                let usage = usage_of_payload payload in
                Error (Turn_failed { terminal; reason; usage })
              | Some terminal ->
                protocol_error stage
                  (Printf.sprintf "unknown terminal word %S" terminal))
           | _ -> Ok (base, start_events))))
;;

let nonblank ~what value =
  if String.trim value = "" then Error (Invalid_config (what ^ " must not be blank")) else Ok value
;;

let ( let* ) = Result.bind

let command ~prompt_file ~schema_file ~images ~session_mode config =
  let* cli_path = nonblank ~what:"cli_path" config.cli_path in
  let* cwd = nonblank ~what:"cwd" config.cwd in
  let* prompt_file = nonblank ~what:"prompt_file" prompt_file in
  let* session_flag =
    match session_mode with
    | Start -> Ok []
    | Resume { session_id } ->
      (match nonblank ~what:"resume session_id" session_id with
       | Ok session_id -> Ok [ "--session-id"; session_id ]
       | Error _ -> Error (Invalid_config "resume session_id must not be blank"))
  in
  let* model_flag =
    match config.model with
    | None -> Ok []
    | Some model ->
      (match nonblank ~what:"model" model with
       | Ok model -> Ok [ "--model"; model ]
       | Error _ ->
         Error (Invalid_config "model is present but blank; omit it to use the CLI default"))
  in
  let* schema_flag =
    match schema_file with
    | None -> Ok []
    | Some path ->
      (match nonblank ~what:"schema_file" path with
       | Ok path -> Ok [ "--output-schema"; path ]
       | Error _ -> Error (Invalid_config "schema_file is present but blank"))
  in
  let* image_flags =
    List.fold_left
      (fun acc image ->
        let* flags = acc in
        let* path = nonblank ~what:"image path" image.path in
        Ok (flags @ [ "--image"; path ]))
      (Ok [])
      images
  in
  let effort_flag =
    match config.reasoning_effort with
    | None -> []
    | Some effort -> [ "--reasoning-effort"; effort_to_string effort ]
  in
  Ok
    ([ cli_path
     ; "exec"
     ; "--json"
     ; "--prompt-file"; prompt_file
     ; "--workspace"; cwd
     ; "--approval-mode"; approval_mode_to_string config.approval_mode
     ]
    @ model_flag @ effort_flag @ image_flags @ schema_flag @ session_flag)
;;

(* ---- process ---- *)

exception Spawn_failure of string

let process_termination_grace_s = 2.0
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 4096
let max_wire_line_bytes = 8 * 1024 * 1024

let client_environment () =
  [ "HOME"
  ; "USER"
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
  ; "META_API_KEY"
  ; "MODEL_API_KEY"
  ]
  |> List.filter_map (fun name ->
    Option.map (fun value -> name ^ "=" ^ value) (Sys.getenv_opt name))
  |> Array.of_list
;;

let validate_timeouts config =
  if not (Float.is_finite config.admission_timeout_s) || config.admission_timeout_s <= 0.0
  then Error (Invalid_config "admission_timeout_s must be positive and finite")
  else (
    match config.timeout_s with
    | Some seconds when not (Float.is_finite seconds) || seconds <= 0.0 ->
      Error (Invalid_config "a declared timeout_s must be positive and finite")
    | _ ->
      (match config.wall_clock_ceiling_s with
       | Some ceiling when not (Float.is_finite ceiling) || ceiling <= 0.0 ->
         Error (Invalid_config "a declared wall_clock_ceiling_s must be positive and finite")
       | _ -> Ok ()))
;;

let validate_turn config ~prompt ~session_mode =
  let* () = validate_timeouts config in
  if String.trim config.cwd = "" || Filename.is_relative config.cwd
  then Error (Invalid_config "cwd must be an absolute path")
  else if String.trim prompt = ""
  then Error (Invalid_config "prompt must not be empty")
  else (
    match session_mode with
    | Resume { session_id } when String.trim session_id = "" ->
      Error (Invalid_config "resume session_id must not be empty")
    | Start | Resume _ -> Ok ())
;;

(* Prompt and schema bytes never occupy argv. 0600: the prompt carries
   keeper context. Sync-only cleanup, so Fun.protect is the right home. *)
let with_text_file ~prefix ~suffix contents use =
  let path, output = Filename.open_temp_file ~perms:0o600 ~mode:[ Open_binary ] prefix suffix in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr output;
      (try Sys.remove path with
       | Sys_error detail ->
         Log.Runtime_agent.warn "Muse turn file cleanup failed: %s" detail))
    (fun () ->
      output_string output contents;
      close_out output;
      let absolute =
        if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
      in
      use absolute)
;;

let trim_tail buffer =
  let length = Buffer.length buffer in
  if length > stderr_tail_bytes
  then (
    let contents = Buffer.contents buffer in
    Buffer.clear buffer;
    Buffer.add_substring buffer contents (length - stderr_tail_bytes) stderr_tail_bytes)
;;

let drain_stderr flow tail =
  let chunk = Cstruct.create stderr_chunk_bytes in
  try
    while true do
      let read = Eio.Flow.single_read flow chunk in
      Buffer.add_string tail (Cstruct.to_string (Cstruct.sub chunk 0 read));
      trim_tail tail
    done
  with
  | End_of_file -> ()
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Runtime_agent.debug "Muse stderr drain failed: %s" (Printexc.to_string exn)
;;

let terminate_spawned_process ~clock proc =
  Eio.Cancel.protect (fun () ->
    (try Eio.Process.signal proc Sys.sigterm with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.debug "Muse termination signal failed: %s" (Printexc.to_string exn));
    try
      Eio.Time.with_timeout_exn clock process_termination_grace_s (fun () ->
        (* See read_body: the fold already decided the outcome; this await only reaps. *)
        Eio.Process.await proc |> ignore)
    with
    | Eio.Time.Timeout ->
      (try
         Eio.Process.signal proc Sys.sigkill;
         (* See above: the turn already ended; this await only reaps the kill. *)
         Eio.Process.await proc |> ignore
       with
       | EioCancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Runtime_agent.debug "Muse forced reap failed: %s" (Printexc.to_string exn))
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Runtime_agent.debug "Muse reap observed an already-closed process: %s"
        (Printexc.to_string exn))
;;

let parse_json ~stage text =
  try Ok (Yojson.Safe.from_string text) with
  | Yojson.Json_error detail -> protocol_error stage detail
;;

let parse_line line = parse_json ~stage:"stream envelope" line

(* Session and run identity straight from the envelope, kept outside the
   fold so failure paths can still attribute usage and admission. *)
let note_identity json ~session_of ~turn_of =
  match assoc_of_json json with
  | None -> ()
  | Some envelope ->
    (match object_field "stream" envelope with
     | Some stream ->
       (match string_field "id" stream with
        | Some session_id when Option.is_none !session_of -> session_of := Some session_id
        | _ -> ())
     | None -> ());
    (match object_field "payload" envelope with
     | Some payload ->
       (match object_field "run_stream" payload with
        | Some run ->
          (match string_field "id" run with
           | Some turn_id when Option.is_none !turn_of -> turn_of := Some turn_id
           | _ -> ())
        | None -> ())
     | None -> ())
;;

let run_spawned ~mgr ~clock ~cwd ~prompt_file ~schema_file config ~session_mode ~images
    ~on_stream_event ~on_prompt_sent ~on_session_ready =
  let turn_admitted = ref false in
  let answer = ref None in
  let usage = ref None in
  let session_of = ref None in
  let turn_of = ref None in
  let emit event =
    (match event with
     | Usage_reported { usage = reported; _ } -> usage := Some reported
     | Turn_started { session_id; turn_id } -> on_session_ready ~session_id ~turn_id
     | Text_delta _ | Turn_finished _ -> ());
    on_stream_event event
  in
  let* argv = command ~prompt_file ~schema_file ~images ~session_mode config in
  let read_body proc reader stderr_tail =
    let started_at = Eio.Time.now clock in
    let ceiling_at = Option.map (fun span -> started_at +. span) config.wall_clock_ceiling_s in
    let first_record = ref true in
    let budget_s () =
      let idle =
        match config.timeout_s with
        | Some seconds -> seconds
        | None -> Float.infinity
      in
      match ceiling_at with
      | None -> idle
      | Some at -> Float.min idle (Float.max 0.0 (at -. Eio.Time.now clock))
    in
    let read_line () =
      let budget = budget_s () in
      let phase = if !first_record then config.admission_timeout_s else budget in
      let span = Float.min phase budget in
      try
        let line =
          if Float.is_infinite span
          then Eio.Buf_read.line reader
          else Eio.Time.with_timeout clock span (fun () -> Eio.Buf_read.line reader)
        in
        Ok (`Line line)
      with
      | End_of_file -> Ok `Eof
      | Eio.Time.Timeout -> Error (Timeout span)
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> protocol_error "stdout read" (Printexc.to_string exn)
    in
    let progress = ref empty_progress in
    let outcome = ref None in
    while Option.is_none !outcome do
      match read_line () with
      | Error _ as err -> outcome := Some err
      | Ok `Eof -> outcome := Some (Ok `Eof)
      | Ok (`Line line) ->
        first_record := false;
        (match parse_line line with
         | Error _ as err -> outcome := Some err
         | Ok json ->
           note_identity json ~session_of ~turn_of;
           (match apply_record !progress json with
            | Error (Turn_failed failed) as err ->
              (* A terminal record proves the child ran a turn, even a
                 failed one: another candidate must not blindly retry it. *)
              turn_admitted := true;
              (match !session_of, failed.usage with
               | Some session_id, Some failed_usage ->
                 emit (Usage_reported { session_id; usage = failed_usage })
               | _ -> ());
              outcome := Some err
            | Error _ as err -> outcome := Some err
            | Ok (advanced, events) ->
              progress := advanced;
              turn_admitted := advanced.started;
              List.iter emit events;
              (match
                 List.find_opt (function Turn_finished _ -> true | _ -> false) events
               with
               | Some (Turn_finished { text }) ->
                 answer := Some text;
                 outcome := Some (Ok `Terminal)
               | Some _ | None -> ()))
    done;
    let exit_detail () =
      let tail = String.trim (Buffer.contents stderr_tail) in
      if tail = "" then "stdout closed" else tail
    in
    match !outcome with
    | Some (Ok `Terminal) ->
      (match !session_of with
       | None -> Error (Process_exited { detail = exit_detail (); turn_admitted = false })
       | Some session_id ->
         Ok
           { session_id
           ; turn_id = !turn_of
           ; text = (match !answer with Some text -> text | None -> "")
           ; usage = !usage
           ; resumed = (match session_mode with Start -> false | Resume _ -> true)
           })
    | Some (Ok `Eof) ->
      let code =
        match Eio.Process.await proc with
        | `Exited status -> Printf.sprintf "exit %d" status
        | `Signaled signal -> Printf.sprintf "signal %d" signal
      in
      Error
        (Process_exited
           { detail = Printf.sprintf "%s: %s" code (exit_detail ())
           ; turn_admitted = !turn_admitted
           })
    | Some (Error _ as err) -> err
    | None -> Error (Process_exited { detail = exit_detail (); turn_admitted = !turn_admitted })
  in
  try
    Eio.Switch.run (fun sw ->
      let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
      let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
      let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
      let stderr_tail = Buffer.create stderr_tail_bytes in
      let proc =
        try
          Eio.Process.spawn
            ~sw
            mgr
            ~cwd
            ~env:(client_environment ())
            ~stdin:stdin_r
            ~stdout:stdout_w
            ~stderr:stderr_w
            argv
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> raise (Spawn_failure (Printexc.to_string exn))
      in
      Eio.Flow.close stdin_r;
      Eio.Flow.close stdin_w;
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      on_prompt_sent ();
      (* Diagnostics only, so a daemon: the switch cancels it once the body
         returns. A grandchild the CLI leaves behind inherits this pipe's
         write end, so EOF may never come, and a joined fiber would hold
         the switch open after the turn was served. *)
      Eio.Fiber.fork_daemon ~sw
        (fun () ->
          drain_stderr stderr_r stderr_tail;
          `Stop_daemon);
      let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
      Fun.protect
        ~finally:(fun () -> terminate_spawned_process ~clock proc)
        (fun () -> read_body proc reader stderr_tail))
  with
  | Spawn_failure detail -> Error (Spawn_failed detail)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Process_exited { detail = Printexc.to_string exn; turn_admitted = !turn_admitted })
;;

let truncate_detail detail =
  if String.length detail <= 500
  then detail
  else String.sub detail 0 500 ^ "…"
;;

(* One JSON-RPC round trip against a serve host: initialize, initialized,
   usage/read. The three requests go out together; JSON-RPC is a stream
   and the host answers in order. Notifications the host emits between
   (usage/changed) carry no id and are skipped. *)
let serve_usage ~mgr ~clock ~cwd config =
  let ( let* ) = Result.bind in
  let* cli_path = nonblank ~what:"cli_path" config.cli_path in
  (* [config.cwd] is unread here: the serve child inherits the Eio working
     directory, and the usage/read request carries no workspace. *)
  let* () = validate_timeouts config in
    let initialize =
      `Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 1
        ; "method", `String "initialize"
        ; ( "params"
          , `Assoc
              [ ( "clientInfo"
                , `Assoc
                    [ "name", `String "masc"
                    ; "version", `String Runtime_build_version.current
                    ] )
              ] )
        ]
    in
    let initialized =
      `Assoc [ "jsonrpc", `String "2.0"; "method", `String "initialized"; "params", `Assoc [] ]
    in
    let usage_read =
      `Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 2
        ; "method", `String "usage/read"
        ; "params", `Assoc []
        ]
    in
    let stage = "serve usage/read" in
    try
      Eio.Switch.run (fun sw ->
        let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
        let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
        let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
        let stderr_tail = Buffer.create stderr_tail_bytes in
        let proc =
          try
            Eio.Process.spawn
              ~sw
              mgr
              ~cwd
              ~env:(client_environment ())
              ~stdin:stdin_r
              ~stdout:stdout_w
              ~stderr:stderr_w
              [ cli_path; "serve"; "--no-session-log" ]
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> raise (Spawn_failure (Printexc.to_string exn))
        in
        Eio.Flow.close stdin_r;
        Eio.Flow.close stdout_w;
        Eio.Flow.close stderr_w;
        Eio.Fiber.fork_daemon ~sw
          (fun () ->
            drain_stderr stderr_r stderr_tail;
            `Stop_daemon);
        let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
        let started_at = Eio.Time.now clock in
        let ceiling_at =
          Option.map (fun span -> started_at +. span) config.wall_clock_ceiling_s
        in
        let budget_s ~first =
          let idle =
            if first
            then config.admission_timeout_s
            else (
              match config.timeout_s with
              | Some seconds -> seconds
              | None -> Float.infinity)
          in
          match ceiling_at with
          | None -> idle
          | Some at -> Float.min idle (Float.max 0.0 (at -. Eio.Time.now clock))
        in
        let read_response ~first =
          let span = budget_s ~first in
          try
            let line =
              if Float.is_infinite span
              then Eio.Buf_read.line reader
              else Eio.Time.with_timeout clock span (fun () -> Eio.Buf_read.line reader)
            in
            parse_json ~stage line
          with
          | End_of_file ->
            let tail = String.trim (Buffer.contents stderr_tail) in
            let detail = if tail = "" then "stdout closed" else tail in
            Error (Process_exited { detail; turn_admitted = false })
          | Eio.Time.Timeout -> Error (Timeout span)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> protocol_error "stdout read" (Printexc.to_string exn)
        in
        let rpc_error id json_fields =
          match object_field "error" json_fields with
          | Some error_fields ->
            let code =
              match int_field "code" error_fields with
              | Some code -> string_of_int code
              | None -> "?"
            in
            let message =
              match string_field "message" error_fields with
              | Some message -> message
              | None -> "the host refused the request"
            in
            Some (Printf.sprintf "request %d: code %s: %s" id code (truncate_detail message))
          | None -> None
        in
        let await_result ~id ~first =
          let rec loop first =
            let* json = read_response ~first in
            match assoc_of_json json with
            | None -> protocol_error stage "expected a JSON object"
            | Some fields ->
              (match int_field "id" fields with
               | Some response_id when response_id = id ->
                 (match rpc_error id fields with
                  | Some detail -> protocol_error stage detail
                  | None ->
                    (match List.assoc_opt "result" fields with
                     | Some result -> Ok result
                     | None -> protocol_error stage "the response carries no result"))
               | Some _ | None ->
                 (* Another request's answer or a host notification; the
                    answers this read waits for arrive in order. *)
                 loop false)
          in
          loop first
        in
        Fun.protect
          ~finally:(fun () -> terminate_spawned_process ~clock proc)
          (fun () ->
            Eio.Flow.copy_string (Yojson.Safe.to_string initialize ^ "\n") stdin_w;
            Eio.Flow.copy_string (Yojson.Safe.to_string initialized ^ "\n") stdin_w;
            Eio.Flow.copy_string (Yojson.Safe.to_string usage_read ^ "\n") stdin_w;
            let* _initialize = await_result ~id:1 ~first:true in
            let* result = await_result ~id:2 ~first:false in
            let* usage =
              match assoc_of_json result with
              | None -> protocol_error stage "usage/read result is not an object"
              | Some fields ->
                (match List.assoc_opt "usage" fields with
                 | None | Some `Null -> Ok None
                 | Some usage -> Ok (Some usage))
            in
            (* Stdin EOF is the host's clean shutdown; the answer is already
               in hand, so a close or reap that goes wrong here only logs. *)
            (try Eio.Flow.close stdin_w with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Log.Runtime_agent.debug
                 "Muse serve stdin close failed: %s"
                 (Printexc.exn_slot_name exn));
            (* See above: the usage answer is already in hand; this await only reaps. *)
            (try Eio.Process.await proc |> ignore with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Log.Runtime_agent.debug
                 "Muse serve reap failed: %s"
                 (Printexc.exn_slot_name exn));
            Ok usage))
    with
    | Spawn_failure detail -> Error (Spawn_failed detail)
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Process_exited { detail = Printexc.to_string exn; turn_admitted = false })
;;

let run_turn ?(on_stream_event = fun _ -> ()) ?(session_mode = Start)
    ?(on_prompt_sent = fun () -> ())
    ?(on_session_ready = fun ~session_id:_ ~turn_id:_ -> ())
    ~mgr ~clock ~cwd config ~prompt ~images =
  let ( let* ) = Result.bind in
  let* () = validate_turn config ~prompt ~session_mode in
  with_text_file ~prefix:"masc-muse-prompt-" ~suffix:".md" prompt (fun prompt_file ->
    match config.output_schema with
    | None ->
      run_spawned ~mgr ~clock ~cwd ~prompt_file ~schema_file:None config ~session_mode
        ~images ~on_stream_event ~on_prompt_sent ~on_session_ready
    | Some schema ->
      with_text_file ~prefix:"masc-muse-schema-" ~suffix:".json"
        (Yojson.Safe.to_string schema)
        (fun schema_file ->
          run_spawned ~mgr ~clock ~cwd ~prompt_file ~schema_file:(Some schema_file) config
            ~session_mode ~images ~on_stream_event ~on_prompt_sent ~on_session_ready))
;;
