(** Native Muse Code single-turn execution over [muse serve] (MSP v1). *)

module Msp = Runtime_muse_msp

type config =
  { cli_path : string
  ; account_home : string option
  ; model : string option
  ; native : Runtime_native_tools.posture
  ; admission_timeout_s : float
  ; timeout_s : float option
  ; wall_clock_ceiling_s : float option
  }

let default_timeout_s = 300.0
let process_termination_grace_s = 2.0

(* How long an exited [muse serve] is given to be reaped after its stdout
   closes, so the documented exit code can name why it stopped. *)
let exit_reap_grace_s = 2.0
let stderr_chunk_bytes = 4096
let stderr_tail_bytes = 4096
let max_wire_line_bytes = 8 * 1024 * 1024

(* MSP requires [clientInfo.name] to match [a-z0-9_]+. *)
let client_name = "masc"

let default_config () =
  { cli_path = "muse"
  ; account_home = None
  ; model = None
  ; native = Runtime_native_tools.Native_read
  ; admission_timeout_s = default_timeout_s
  ; timeout_s = Some default_timeout_s
  ; wall_clock_ceiling_s = None
  }
;;

type session_mode =
  | Start
  | Resume of { session_id : string }

type image_input =
  { media_type : string
  ; base64_data : string
  }

type exit_status =
  | Exit_clean
  | Exit_unhandled
  | Exit_usage
  | Exit_config_or_credential
  | Exit_session_lease_held
  | Exit_sdk_surface_disabled
  | Exit_code of int
  | Exit_signal of int

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Turn_input_write_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int
      ; message : string
      }
  | Capability_not_granted of Runtime_muse_msp.capability
  | Session_model_mismatch of
      { requested : string
      ; resumed : string option
      }
  | Auth_required of string
  | Turn_failed of Runtime_muse_msp.turn_error
  | Turn_cancelled
  | Unsupported_server_request of string
  | Runtime_shutting_down
  | Process_exited of
      { status : exit_status option
      ; detail : string
      ; turn_accepted : bool
      }
  | Timeout of
      { seconds : float
      ; turn_accepted : bool
      }

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string option
  ; text : string
  ; usage : Runtime_muse_msp.token_usage option
  ; tool_calls : int
  ; approvals_decided : int
  ; resumed : bool
  ; server_version : string
  }

type stream_event =
  | Turn_started of
      { session_id : string
      ; turn_id : string
      ; model : string option
      }
  | Text_delta of string
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Approval_decided of
      { tool_name : string
      ; subject : Runtime_muse_msp.approval_subject_kind
      ; decision : Runtime_muse_msp.approval_decision
      }
  | Subscription_usage_observed of Runtime_muse_msp.subscription_usage
  | Usage_reported of
      { session_id : string
      ; turn_id : string
      ; usage : Runtime_muse_msp.token_usage
      }
  | Turn_finished of { text : string }

let exit_status_to_string = function
  | Exit_clean -> "exit 0"
  | Exit_unhandled -> "exit 1 (unhandled)"
  | Exit_usage -> "exit 2 (usage)"
  | Exit_config_or_credential -> "exit 3 (config or credential)"
  | Exit_session_lease_held -> "exit 4 (session lease held)"
  | Exit_sdk_surface_disabled -> "exit 5 (SDK surface disabled)"
  | Exit_code code -> Printf.sprintf "exit %d" code
  | Exit_signal signal -> Printf.sprintf "signal %d" signal
;;

let capability_to_string = function
  | Msp.Session_mcp -> "sessionMcp"
  | Msp.User_shell -> "userShell"
  | Msp.Session_list_stream -> "sessionListStream"
  | Msp.Unrecognized_capability name -> name
;;

let error_to_string = function
  | Invalid_config detail -> "Muse Code config: " ^ detail
  | Spawn_failed detail -> "Muse Code spawn failed: " ^ detail
  | Turn_input_write_failed detail -> "Muse Code turn input write failed: " ^ detail
  | Protocol_error { stage; detail } ->
    Printf.sprintf "Muse Code protocol error at %s: %s" stage detail
  | Rpc_error { method_; code; message } ->
    Printf.sprintf "Muse Code %s failed (%d): %s" method_ code message
  | Capability_not_granted capability ->
    Printf.sprintf
      "Muse Code did not grant the %s capability this session needs"
      (capability_to_string capability)
  | Session_model_mismatch { requested; resumed } ->
    Printf.sprintf
      "Muse Code resumed a session on %s, but the turn asks for %s"
      (* DET-OK: display text for an absent model id; nothing branches on it. *)
      (Option.value resumed ~default:"the host default model")
      requested
  | Auth_required detail -> "Muse Code has no usable login: " ^ detail
  | Turn_failed { message; retryable; _ } ->
    Printf.sprintf
      "Muse Code turn failed%s: %s"
      (if retryable then " (retryable)" else "")
      message
  | Turn_cancelled -> "Muse Code cancelled the turn"
  | Unsupported_server_request method_ ->
    "Muse Code sent a request MASC does not answer: " ^ method_
  | Runtime_shutting_down -> "MASC is shutting down"
  | Process_exited { status; detail; _ } ->
    Printf.sprintf
      "Muse Code exited (%s): %s"
      (match status with
       | Some status -> exit_status_to_string status
       | None -> "not reaped")
      detail
  | Timeout { seconds; _ } -> Printf.sprintf "Muse Code was silent for %.0fs" seconds
;;

let ( let* ) = Result.bind
let protocol_error stage detail = Error (Protocol_error { stage; detail })

let lift result =
  Result.map_error
    (fun ({ stage; detail } : Msp.error) -> Protocol_error { stage; detail })
    result
;;

module Shared_json = Runtime_official_client_json.Make (struct
  type t = error

  let protocol ~stage ~detail = Protocol_error { stage; detail }
end)

open Shared_json

let bounded_tail = Runtime_official_client_json.bounded_tail

let emit_stream_event on_stream_event event =
  match on_stream_event with
  | None -> ()
  | Some callback ->
    (try callback event with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.warn
         "Muse Code stream callback raised: %s"
         (Printexc.to_string exn))
;;

let exit_status_of = function
  | `Exited 0 -> Exit_clean
  | `Exited 1 -> Exit_unhandled
  | `Exited 2 -> Exit_usage
  | `Exited 3 -> Exit_config_or_credential
  | `Exited 4 -> Exit_session_lease_held
  | `Exited 5 -> Exit_sdk_surface_disabled
  | `Exited code -> Exit_code code
  | `Signaled signal -> Exit_signal signal
;;

let approval_mode_of_posture = function
  | Runtime_native_tools.Native_full -> Ok Msp.Allow_all
  | Runtime_native_tools.Native_read -> Ok Msp.Deny_unmatched
  | Runtime_native_tools.Native_none ->
    Error
      (Invalid_config
         "native posture \"none\" is unrepresentable on Muse Code: MSP has no switch \
          that removes the built-in tools")
;;

(* The choice an [approval/request] is answered with, in order of
   preference. A mode the session declared should already have settled most
   requests; one that still arrives is answered from the same posture rather
   than left waiting on a person MASC does not have. *)
let approval_preferences = function
  | Runtime_native_tools.Native_full -> [ Msp.Approved; Msp.Approved_for_session ]
  | Runtime_native_tools.Native_read | Runtime_native_tools.Native_none ->
    [ Msp.Denied; Msp.Abort ]
;;

let approval_choice posture (approval : Msp.approval_request) =
  List.find_map
    (fun wanted ->
       List.find_opt
         (fun (choice : Msp.approval_choice) -> choice.Msp.decision = wanted)
         approval.Msp.choices)
    (approval_preferences posture)
;;

(* MSP asks for UUIDv7 command ids and never mints one itself. A fresh
   random state per id keeps this free of shared mutable state across
   domains; a turn mints a handful.
   NDT-OK: a UUIDv7 is time- and random-based by the protocol's contract. *)
let new_command_id () =
  (* NDT-OK: the UUIDv7 timestamp and random bits. *)
  let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  Uuidm.v7_non_monotonic_gen ~now_ms (Random.State.make_self_init ()) ()
  |> Uuidm.to_string
;;

(* ── Admission checks ─────────────────────────────────────────────────── *)

let positive_finite name value =
  if Float.is_finite value && value > 0.
  then Ok ()
  else Error (Invalid_config (Printf.sprintf "%s must be a positive number" name))
;;

let valid_utf8 name value =
  if String_util.is_valid_utf8 value
  then Ok ()
  else Error (Invalid_config (name ^ " is not valid UTF-8"))
;;

(* What any spawn needs, with or without a session. *)
let validate_process_config config =
  let* () =
    match config.account_home with
    | None -> Ok ()
    | Some home when String.trim home = "" || Filename.is_relative home ->
      Error (Invalid_config "account_home must be an absolute path")
    | Some home when String.contains home '\000' ->
      Error (Invalid_config "account_home contains a NUL byte")
    | Some home -> valid_utf8 "account_home" home
  in
  let* () =
    if String.trim config.cli_path = ""
    then Error (Invalid_config "cli_path is empty")
    else Ok ()
  in
  let* () = positive_finite "admission_timeout_s" config.admission_timeout_s in
  let* () =
    match config.timeout_s with
    | None -> Ok ()
    | Some seconds -> positive_finite "timeout_s" seconds
  in
  let* () =
    match config.wall_clock_ceiling_s with
    | None -> Ok ()
    | Some seconds -> positive_finite "wall_clock_ceiling_s" seconds
  in
  let* () =
    match config.model with
    | Some model when String.trim model = "" -> Error (Invalid_config "model is empty")
    | Some model -> valid_utf8 "model" model
    | None -> Ok ()
  in
  Ok ()
;;

(* Every string MASC puts on the wire is checked here: the host exits on an
   invalid UTF-8 line, and a refused write would otherwise surface only as a
   request that never gets an answer. *)
let validate_turn ?(session_mode = Start) config ~workspace_root ~prompt ~images =
  let* () = validate_process_config config in
  let* _ = approval_mode_of_posture config.native in
  let* () = valid_utf8 "workspace_root" workspace_root in
  let* () = valid_utf8 "prompt" prompt in
  let* () =
    if Filename.is_relative workspace_root
    then Error (Invalid_config "workspace_root must be an absolute path")
    else Ok ()
  in
  let* () =
    if String.trim prompt = "" then Error (Invalid_config "prompt is empty") else Ok ()
  in
  let* () =
    if List.exists (fun (image : image_input) -> image.base64_data = "") images
    then Error (Invalid_config "an image carries no data")
    else Ok ()
  in
  match session_mode with
  | Resume { session_id } when String.trim session_id = "" ->
    Error (Invalid_config "resumed session id is empty")
  | Resume { session_id } -> valid_utf8 "resumed session id" session_id
  | Start -> Ok ()
;;

let validate_mcp_servers servers =
  List.fold_left
    (fun checked (name, Msp.Streamable_http { url; headers; required = _ }) ->
       let* () = checked in
       let* () = valid_utf8 "MCP server name" name in
       let* () = valid_utf8 "MCP server url" url in
       List.fold_left
         (fun checked (header, value) ->
            let* () = checked in
            let* () = valid_utf8 "MCP header name" header in
            valid_utf8 "MCP header value" value)
         (Ok ())
         headers)
    (Ok ())
    servers
;;

(* ── Process ──────────────────────────────────────────────────────────── *)

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

(* The CLI reads its subscription login from its own home (a file on Linux,
   the Keychain on macOS), so the child needs HOME and the XDG roots and
   nothing that routes billing elsewhere. META_API_KEY is left out on
   purpose: it selects the pay-as-you-go Model API instead of the
   subscription this runtime exists to use. *)
let child_environment_key_allowed = function
  | "HOME"
  | "USER"
  | "LOGNAME"
  | "PATH"
  | "TMPDIR"
  | "XDG_CONFIG_HOME"
  | "XDG_DATA_HOME"
  | "XDG_CACHE_HOME"
  | "XDG_STATE_HOME"
  | "XDG_RUNTIME_DIR"
  | "SSL_CERT_FILE"
  | "SSL_CERT_DIR"
  | "HTTPS_PROXY"
  | "HTTP_PROXY"
  | "NO_PROXY"
  | "https_proxy"
  | "http_proxy"
  | "no_proxy"
  | "LANG"
  | "LC_ALL"
  | "LC_CTYPE"
  | "TERM"
  | "NO_COLOR" -> true
  | _ -> false
;;

let client_environment account_home =
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> child_environment_key_allowed (env_key entry))
  in
  let selected =
    match account_home with
    | None -> inherited
    | Some home ->
      let roots =
        [ "HOME", home
        ; "XDG_CONFIG_HOME", Filename.concat home ".config"
        ; "XDG_DATA_HOME", Filename.concat home ".local/share"
        ; "XDG_CACHE_HOME", Filename.concat home ".cache"
        ; "XDG_STATE_HOME", Filename.concat home ".local/state"
        ; "XDG_RUNTIME_DIR", Filename.concat home ".local/run"
        ]
      in
      List.map (fun (key, value) -> key ^ "=" ^ value) roots
      @ List.filter (fun entry -> not (List.mem_assoc (env_key entry) roots)) inherited
  in
  Array.of_list selected
;;

let client_argv config =
  [ config.cli_path; "serve" ]
  @ (match config.native with
     | Runtime_native_tools.Native_read | Runtime_native_tools.Native_none ->
       [ "--disable-write"; "--disable-shell" ]
     | Runtime_native_tools.Native_full -> [])
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
    Log.Runtime_agent.debug "Muse Code stderr drain failed: %s" (Printexc.to_string exn)
;;

let terminate_spawned_process ~clock proc stdin_w =
  let owning_switch_cancelled = Eio.Fiber.is_cancelled () in
  Eio.Cancel.protect (fun () ->
    (try Eio.Flow.close stdin_w with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.debug "Muse Code stdin close failed: %s" (Printexc.to_string exn));
    (try Eio.Process.signal proc Sys.sigterm with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Runtime_agent.debug
         "Muse Code termination signal failed: %s"
         (Printexc.to_string exn));
    if not owning_switch_cancelled
    then (
      try
        Eio.Time.with_timeout_exn clock process_termination_grace_s (fun () ->
          let (_ : Eio.Process.exit_status) = Eio.Process.await proc in
          ())
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Eio.Time.Timeout ->
        (try
           Eio.Process.signal proc Sys.sigkill;
           let (_ : Eio.Process.exit_status) = Eio.Process.await proc in
           ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.Runtime_agent.warn
             "Muse Code forced reap failed: %s"
             (Printexc.to_string exn))
      | exn ->
        Log.Runtime_agent.debug
          "Muse Code reap observed an already-closed process: %s"
          (Printexc.to_string exn)))
;;

(* Which window one [receive] waits under. Before the [turn/start] reply the
   client is being admitted. During the model turn a silent host is the
   fault the idle window notices. While a tool item the host started is open
   the host may write nothing until it completes, so that silence is not
   measured and only the wall-clock ceiling bounds it. *)
type receive_phase =
  | Awaiting_admission
  | Model_turn
  | Tool_item_running

let window_for_phase config = function
  | Awaiting_admission -> Some config.admission_timeout_s
  | Model_turn -> config.timeout_s
  | Tool_item_running -> None
;;

type io =
  { send : Yojson.Safe.t -> unit
  ; receive : unit -> (Msp.wire_message, error) result
  ; set_receive_phase : receive_phase -> unit
  ; next_id : unit -> int
  }

let with_spawned_client ~mgr ~clock ~cwd config run =
  Eio.Switch.run (fun sw ->
    let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
    match
      Eio.Process.spawn
        ~sw
        mgr
        ~cwd
        ~env:(client_environment config.account_home)
        ~stdin:stdin_r
        ~stdout:stdout_w
        ~stderr:stderr_w
        (client_argv config)
    with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Error (Spawn_failed (Printexc.to_string exn))
    | proc ->
      Eio.Flow.close stdin_r;
      Eio.Flow.close stdout_w;
      Eio.Flow.close stderr_w;
      let stderr_tail = ref "" in
      (* Diagnostics only, so a daemon: a grandchild the CLI leaves behind
         (an MCP server) can hold this pipe open after the turn is served. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
        drain_stderr stderr_r stderr_tail;
        `Stop_daemon);
      let reader = Eio.Buf_read.of_flow ~max_size:max_wire_line_bytes stdout_r in
      let wall_clock =
        Runtime_wall_clock.make
          ?ceiling_s:config.wall_clock_ceiling_s
          ~now:(fun () -> Eio.Time.now clock)
          ()
      in
      let receive_phase = ref Awaiting_admission in
      let last_id = ref 0 in
      let send json =
        with_idle_timeout
          clock
          (Runtime_wall_clock.cap_window wall_clock (Some config.admission_timeout_s))
          (fun () ->
             let payload = Yojson.Safe.to_string json in
             (* The host decodes stdin as UTF-8; refuse the write rather
                than hand it a line it cannot read. *)
             if not (String_util.is_valid_utf8 payload)
             then failwith "muse serve stdin: refusing an invalid UTF-8 payload";
             Eio.Flow.copy_string payload stdin_w;
             Eio.Flow.copy_string "\n" stdin_w)
      in
      let exited () =
        match
          Eio.Time.with_timeout clock exit_reap_grace_s (fun () ->
            Ok (Eio.Process.await proc))
        with
        | Ok status -> Some (exit_status_of status)
        | Error `Timeout -> None
      in
      let receive () =
        if Runtime_wall_clock.expired wall_clock
        then
          Error
            (Timeout
               { seconds =
                   Option.value
                     config.wall_clock_ceiling_s
                     ~default:Runtime_wall_clock.default_ceiling_s
               ; turn_accepted = false
               })
        else (
          try
            with_idle_timeout
              clock
              (Runtime_wall_clock.cap_window
                 wall_clock
                 (window_for_phase config !receive_phase))
              (fun () -> Eio.Buf_read.line reader)
            |> Msp.parse_wire_line
            |> lift
          with
          | End_of_file ->
            if Runtime_host_lifecycle.is_shutting_down ()
            then Error Runtime_shutting_down
            else (
              let status = exited () in
              let detail = String.trim !stderr_tail in
              Error
                (Process_exited
                   { status
                   ; detail = (if detail = "" then "stdout closed" else detail)
                   ; turn_accepted = false
                   }))
          | Idle_timeout seconds -> Error (Timeout { seconds; turn_accepted = false })
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Eio.Time.Timeout as exn -> raise exn
          | exn -> protocol_error "stdout read" (Printexc.to_string exn))
      in
      Fun.protect
        ~finally:(fun () -> terminate_spawned_process ~clock proc stdin_w)
        (fun () ->
           run
             { send
             ; receive
             ; set_receive_phase = (fun phase -> receive_phase := phase)
             ; next_id =
                 (fun () ->
                   incr last_id;
                   !last_id)
             }))
;;

(* ── Protocol ─────────────────────────────────────────────────────────── *)

(* A write to a host that already exited fails. The read that follows sees
   its stdout close and reports the exit status, which says why; the failed
   write alone does not, so it is logged and the read decides. *)
let send_best_effort io ~what json =
  match io.send json with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception (Idle_timeout _ as exn) -> raise exn
  | exception exn ->
    Log.Runtime_agent.debug "Muse Code %s write failed: %s" what (Printexc.to_string exn)
;;

(* A reply to request [id]. Notifications that arrive first are session
   projections this client does not read before the turn; a server request
   before the turn exists is not one MASC answers. *)
let rec await_response io ~id ~method_ =
  let* message = io.receive () in
  match message with
  | Msp.Response { id = Msp.Int_id response_id; result } when response_id = id -> Ok result
  | Msp.Response_error { id = Some (Msp.Int_id response_id); code; message; _ }
    when response_id = id -> Error (Rpc_error { method_; code; message })
  | Msp.Response_error { id = None; code; message; _ } ->
    Error (Rpc_error { method_; code; message })
  | Msp.Response _ | Msp.Response_error _ ->
    protocol_error method_ "received a response to another request"
  | Msp.Notification _ -> await_response io ~id ~method_
  | Msp.Server_request { id = request_id; method_ = requested; _ } ->
    send_best_effort
      io
      ~what:"request refusal"
      (Msp.server_request_error
         request_id
         ~code:Msp.method_not_found
         ~message:"MASC answers no request before its turn starts");
    Error (Unsupported_server_request requested)
;;

let request io ~method_ build =
  let id = io.next_id () in
  send_best_effort io ~what:method_ (build ~id);
  await_response io ~id ~method_
;;

let handshake io ~requested_capabilities =
  let* result =
    request io ~method_:"initialize" (fun ~id ->
      Msp.initialize_request
        ~id
        { Msp.name = client_name; version = Runtime_build_version.current }
        ~requested_capabilities
        ~user_input_dialogs:false)
  in
  let* init = lift (Msp.parse_initialize_result result) in
  let* () =
    match
      List.find_opt
        (fun wanted -> not (List.mem wanted init.Msp.granted_capabilities))
        requested_capabilities
    with
    | Some missing -> Error (Capability_not_granted missing)
    | None -> Ok ()
  in
  if not (String.equal init.Msp.schema_fingerprint Msp.corpus_schema_fingerprint)
  then
    (* Still MSP v1 (the codec refused anything else), but not the surface
       the conformance corpus proved. Reported, not refused: a host upgrade
       that kept the frames MASC reads must keep working. *)
    Log.Runtime_agent.warn
      "Muse Code %s reports MSP schema %s; the codec was proven against %s"
      init.Msp.server_version
      init.Msp.schema_fingerprint
      Msp.corpus_schema_fingerprint;
  send_best_effort io ~what:"initialized" Msp.initialized_notification;
  Ok init
;;

type turn_state =
  { open_items : (string * Msp.item_kind) list
  ; open_tool_items : int
  ; final_text : string option
  ; tool_calls : int
  ; approvals : int
  ; pending_decisions : int list
  }

let observation (item : Msp.item) : Runtime_native_tools.observation =
  { identity =
      Option.map (fun call_id -> Runtime_native_tools.Call_id call_id) item.Msp.call_id
  ; tool_name = item.Msp.tool
  ; origin = Runtime_native_tools.Built_in
  }
;;

let item_in_turn ~turn_id (item : Msp.item) =
  match item.Msp.turn_id with
  | Some item_turn -> String.equal item_turn turn_id
  | None -> false
;;

let rec await_terminal io (config : config) ~session_id ~turn_id ~on_stream_event state =
  let continue state =
    await_terminal io config ~session_id ~turn_id ~on_stream_event state
  in
  let emit = emit_stream_event on_stream_event in
  let ours sid = String.equal sid session_id in
  let* message = io.receive () in
  match message with
  | Msp.Response { id = Msp.Int_id response_id; _ }
    when List.mem response_id state.pending_decisions ->
    continue
      { state with
        pending_decisions = List.filter (( <> ) response_id) state.pending_decisions
      }
  | Msp.Response_error { id = Some (Msp.Int_id response_id); code; message; _ }
    when List.mem response_id state.pending_decisions ->
    Error (Rpc_error { method_ = "approval/decide"; code; message })
  | Msp.Response _ | Msp.Response_error _ ->
    protocol_error "turn" "received an unsolicited JSON-RPC response"
  | Msp.Server_request { id = request_id; method_; params } ->
    let* request = lift (Msp.parse_server_request ~method_ params) in
    (match request with
     | Msp.Approval_request approval ->
       (match approval_choice config.native approval with
        | None ->
          protocol_error
            "approval/request"
            (Printf.sprintf
               "no offered choice for %s matches the session's posture"
               approval.Msp.tool_name)
        | Some choice ->
          send_best_effort io ~what:"approval ack" (Msp.server_request_ack request_id);
          let decide_id = io.next_id () in
          send_best_effort
            io
            ~what:"approval/decide"
            (Msp.approval_decide_request
               ~id:decide_id
               ~command_id:(new_command_id ())
               approval
               choice);
          emit
            (Approval_decided
               { tool_name = approval.Msp.tool_name
               ; subject = approval.Msp.subject_kind
               ; decision = choice.Msp.decision
               });
          continue
            { state with
              approvals = state.approvals + 1
            ; pending_decisions = decide_id :: state.pending_decisions
            })
     | Msp.User_input_request _ | Msp.Unhandled_server_request _ ->
       send_best_effort
         io
         ~what:"request refusal"
         (Msp.server_request_error
            request_id
            ~code:Msp.method_not_found
            ~message:"MASC does not answer this request");
       Error (Unsupported_server_request method_))
  | Msp.Notification { method_; params } ->
    let* notification = lift (Msp.parse_notification ~method_ params) in
    (match notification with
     | Msp.Item_started { session_id = sid; item } when ours sid && item_in_turn ~turn_id item
       ->
       (match item.Msp.kind with
        | Msp.Tool_call ->
          emit (Native_tool_started (observation item));
          io.set_receive_phase Tool_item_running;
          continue
            { state with
              open_items = (item.Msp.item_id, item.Msp.kind) :: state.open_items
            ; open_tool_items = state.open_tool_items + 1
            ; tool_calls = state.tool_calls + 1
            }
        | kind -> continue { state with open_items = (item.Msp.item_id, kind) :: state.open_items })
     | Msp.Item_delta { session_id = sid; item_id; field = Msp.Delta_text; delta }
       when ours sid ->
       (match List.assoc_opt item_id state.open_items with
        | Some Msp.Agent_message ->
          emit (Text_delta delta);
          (* The model is speaking: its window applies again, whatever tool
             items are still open. *)
          io.set_receive_phase Model_turn;
          continue state
        | Some _ | None -> continue state)
     | Msp.Item_completed { session_id = sid; item } when ours sid && item_in_turn ~turn_id item
       ->
       let was_open = List.mem_assoc item.Msp.item_id state.open_items in
       let open_items = List.remove_assoc item.Msp.item_id state.open_items in
       (match item.Msp.kind with
        | Msp.Tool_call ->
          (* MSP allows a completed item that never opened (a single-shot
             item, or one after a gap); it is still one call. *)
          if not was_open then emit (Native_tool_started (observation item));
          emit (Native_tool_finished (observation item));
          let open_tool_items =
            if was_open then max 0 (state.open_tool_items - 1) else state.open_tool_items
          in
          if open_tool_items = 0 then io.set_receive_phase Model_turn;
          continue
            { state with
              open_items
            ; open_tool_items
            ; tool_calls = (if was_open then state.tool_calls else state.tool_calls + 1)
            }
        | Msp.Agent_message ->
          continue
            { state with
              open_items
            ; final_text =
                (match item.Msp.text with
                 | Some text -> Some text
                 | None -> state.final_text)
            }
        | _ -> continue { state with open_items })
     | Msp.Usage_changed usage ->
       emit (Subscription_usage_observed usage);
       continue state
     | Msp.Turn_completed { session_id = sid; turn_id = completed; terminal; usage; _ }
       when ours sid && String.equal completed turn_id ->
       Option.iter (fun usage -> emit (Usage_reported { session_id; turn_id; usage })) usage;
       (match terminal with
        | Msp.Terminal_completed -> Ok (state, usage)
        | Msp.Terminal_failed { kind = Msp.Auth_required; message; _ } ->
          Error (Auth_required message)
        | Msp.Terminal_failed turn_error -> Error (Turn_failed turn_error)
        | Msp.Terminal_cancelled -> Error Turn_cancelled
        | Msp.Unrecognized_terminal terminal ->
          protocol_error "turn/completed" ("unrecognized terminal " ^ terminal))
     | Msp.Turn_started _
     | Msp.Turn_completed _
     | Msp.Item_started _
     | Msp.Item_updated _
     | Msp.Item_completed _
     | Msp.Item_delta _
     | Msp.Unhandled_notification _ -> continue state)
;;

let open_session io (config : config) ~approval_mode ~session_mode ~workspace_root ~session_config =
  match session_mode with
  | Start ->
    let* result =
      request io ~method_:"session/start" (fun ~id ->
        Msp.session_start_request
          ~id
          ~command_id:(new_command_id ())
          ~workspace_root
          ~model_id:config.model
          ~approval_mode:(Some approval_mode)
          ~config:session_config)
    in
    let* session = lift (Msp.parse_session_result ~stage:"session/start" result) in
    Ok (session, false)
  | Resume { session_id } ->
    let* result =
      request io ~method_:"session/resume" (fun ~id ->
        Msp.session_resume_request
          ~id
          ~command_id:(new_command_id ())
          ~session_id
          ~config:session_config)
    in
    let* session = lift (Msp.parse_session_result ~stage:"session/resume" result) in
    let* () =
      if String.equal session.Msp.session_id session_id
      then Ok ()
      else
        protocol_error
          "session/resume"
          (Printf.sprintf
             "resumed session id mismatch: requested %S but the host returned %S"
             session_id
             session.Msp.session_id)
    in
    let* () =
      match config.model with
      | Some requested when session.Msp.model_id <> Some requested ->
        Error (Session_model_mismatch { requested; resumed = session.Msp.model_id })
      | Some _ | None -> Ok ()
    in
    let* (_ : Yojson.Safe.t) =
      request io ~method_:"session/setApprovalMode" (fun ~id ->
        Msp.session_set_approval_mode_request
          ~id
          ~command_id:(new_command_id ())
          ~session_id
          approval_mode)
    in
    Ok (session, true)
;;

let run_protocol
      io
      (config : config)
      ~admission
      ~approval_mode
      ~session_mode
      ~mcp_servers
      ~reasoning_effort
      ~workspace_root
      ~prompt
      ~images
      ~on_session_ready
      ~on_prompt_sent
      ~on_stream_event
  =
  let requested_capabilities =
    match mcp_servers with
    | [] -> []
    | _ :: _ -> [ Msp.Session_mcp ]
  in
  let* init = handshake io ~requested_capabilities in
  let* session, resumed =
    open_session
      io
      config
      ~approval_mode
      ~session_mode
      ~workspace_root
      ~session_config:{ Msp.mcp_servers }
  in
  let session_id = session.Msp.session_id in
  let* () =
    admission (fun () ->
      invoke_state_callback ~stage:"session ready callback" (fun () ->
        on_session_ready ~session_id))
  in
  let input =
    List.map
      (fun (image : image_input) ->
         Msp.Image { media_type = image.media_type; base64_data = image.base64_data })
      images
    @ [ Msp.Text prompt ]
  in
  let turn_request_id = io.next_id () in
  let* () =
    try
      io.send
        (Msp.turn_start_request
           ~id:turn_request_id
           ~session_id
           ~command_id:(new_command_id ())
           ~input
           ~reasoning_effort);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout as exn -> raise exn
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Error (Turn_input_write_failed (Printexc.to_string exn))
  in
  let* () =
    invoke_state_callback ~stage:"prompt sent callback" (fun () ->
      on_prompt_sent ();
      Ok ())
  in
  (* The complete request is outside this process now; only the model turn
     that follows adopts the declared idle policy. *)
  io.set_receive_phase Model_turn;
  let* ack =
    match await_response io ~id:turn_request_id ~method_:"turn/start" with
    (* Written but unanswered: the host takes a command in durably before
       it acknowledges it, so it may be running the turn. *)
    | Error (Timeout { seconds; turn_accepted = _ }) ->
      Error (Timeout { seconds; turn_accepted = true })
    | Error (Process_exited exited) -> Error (Process_exited { exited with turn_accepted = true })
    | response -> response
  in
  let* ack = lift (Msp.parse_turn_start_result ack) in
  let* () =
    match ack.Msp.disposition with
    | Msp.Started -> Ok ()
    | Msp.Queued | Msp.Steered | Msp.Unrecognized_disposition _ ->
      (* A fresh process owns this session; a turn it did not start means
         another client is driving the same session. *)
      protocol_error "turn/start" "the host did not start a new turn for this session"
  in
  let turn_id = ack.Msp.turn_id in
  emit_stream_event
    on_stream_event
    (Turn_started { session_id; turn_id; model = session.Msp.model_id });
  let* state, usage =
    match
      await_terminal
        io
        config
        ~session_id
        ~turn_id
        ~on_stream_event
        { open_items = []
        ; open_tool_items = 0
        ; final_text = None
        ; tool_calls = 0
        ; approvals = 0
        ; pending_decisions = []
        }
    with
    | Error (Timeout { seconds; turn_accepted = _ }) ->
      Error (Timeout { seconds; turn_accepted = true })
    | Error (Process_exited exited) -> Error (Process_exited { exited with turn_accepted = true })
    | outcome -> outcome
  in
  (* DET-OK: a turn that completed with no agent message replied nothing. *)
  let text = Option.value state.final_text ~default:"" in
  emit_stream_event on_stream_event (Turn_finished { text });
  Ok
    { session_id
    ; turn_id
    ; model = session.Msp.model_id
    ; text
    ; usage
    ; tool_calls = state.tool_calls
    ; approvals_decided = state.approvals
    ; resumed
    ; server_version = init.Msp.server_version
    }
;;

let guard_idle_timeout f =
  try f () with
  | Idle_timeout seconds -> Error (Timeout { seconds; turn_accepted = false })
;;

let run_turn
      ?(session_mode = Start)
      ?(mcp_servers = [])
      ?reasoning_effort
      ?(on_session_ready = fun ~session_id:_ -> Ok ())
      ?(on_prompt_sent = fun () -> ())
      ?on_stream_event
      ~mgr
      ~clock
      ~cwd
      config
      ~workspace_root
      ~prompt
      ~images
  =
  let* () = validate_turn ~session_mode config ~workspace_root ~prompt ~images in
  let* () = validate_mcp_servers mcp_servers in
  let* approval_mode = approval_mode_of_posture config.native in
  guard_idle_timeout (fun () ->
    with_spawned_client ~mgr ~clock ~cwd config (fun io ->
      run_protocol
        io
        config
        ~admission:(fun f -> with_idle_timeout clock config.admission_timeout_s f)
        ~approval_mode
        ~session_mode
        ~mcp_servers
        ~reasoning_effort
        ~workspace_root
        ~prompt
        ~images
        ~on_session_ready
        ~on_prompt_sent
        ~on_stream_event))
;;

let read_usage ~mgr ~clock ~cwd config =
  let* () = validate_process_config config in
  guard_idle_timeout (fun () ->
    with_spawned_client ~mgr ~clock ~cwd config (fun io ->
      let* (_ : Msp.initialize_result) = handshake io ~requested_capabilities:[] in
      let* result = request io ~method_:"usage/read" (fun ~id -> Msp.usage_read_request ~id) in
      lift (Msp.parse_usage_read_result result)))
;;
