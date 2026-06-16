open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

(** Runtime adapter for client-intercepted voice agent tools.

    The string [name] arriving from the descriptor dispatch layer is
    parsed into a typed [voice_command] at the module boundary; every
    branch downstream operates on the variant. The OCaml type checker
    then forces every new variant to update [command_to_string] and
    the dispatch match in [handle], eliminating the silent-drift
    failure mode of an open string-classifier. *)

type voice_command =
  | Speak
  | Listen
  | Agent
  | Sessions
  | Session_start
  | Session_end

(** Canonical enumeration. Must list every constructor of
    [voice_command]; adding a variant without appending here is the
    one remaining drift vector — guarded by
    [test_voice_command_descriptor_parity], which compares this list
    against the registered [keeper_voice_*] descriptors. *)
let all_commands : voice_command list =
  [ Speak; Listen; Agent; Sessions; Session_start; Session_end ]

let command_to_string = function
  | Speak -> "keeper_voice_speak"
  | Listen -> "keeper_voice_listen"
  | Agent -> "keeper_voice_agent"
  | Sessions -> "keeper_voice_sessions"
  | Session_start -> "keeper_voice_session_start"
  | Session_end -> "keeper_voice_session_end"

(** Derived from [all_commands] + [command_to_string] so that adding a
    variant requires only the [command_to_string] branch + the
    [all_commands] entry — never a separate string-literal match. *)
let command_of_string (s : string) : voice_command option =
  List.find_opt (fun c -> String.equal (command_to_string c) s) all_commands

type voice_memory_status =
  { recorded : bool
  ; rows_written : int
  ; error : string option
  }

let record_voice_output
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(provider : string option)
      ~priority
      ~execution
      ~message
  =
  match
    Keeper_memory_bank.append_voice_output
      config
      meta
      ?provider
      ~execution
      ~voice_priority:priority
      ~turn:meta.runtime.usage.total_turns
      ~message
      ()
  with
  | Ok rows_written ->
    { recorded = rows_written > 0; rows_written; error = None }
  | Error err ->
    Log.Keeper.warn
      ~keeper_name:meta.name
      "keeper_voice_speak memory write failed: %s"
      err;
    { recorded = false; rows_written = 0; error = Some err }

let memory_status_fields status =
  [ "memory_recorded", `Bool status.recorded
  ; "memory_rows_written", `Int status.rows_written
  ; "memory_source", `String "voice_output"
  ; "memory_error", Json_util.string_opt_to_json status.error
  ]

let attach_memory_status json status =
  match json with
  | `Assoc fields -> `Assoc (fields @ memory_status_fields status)
  | other -> `Assoc (("result", other) :: memory_status_fields status)

let handle_speak
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
  let provider =
    Safe_ops.json_string_opt "provider" args
    |> Option.map String.trim
    |> function
    | Some p when p <> "" -> Some p
    | _ -> None
  in
  let priority = max 1 (Safe_ops.json_int ~default:1 "priority" args) in
  let sync_mode = Safe_ops.json_bool ~default:false "sync" args in
  if message = ""
  then error_json "message is required. Good: message='Hello team.'. Bad: message=''."
  else (
    match
      ( Eio_context.get_root_switch_opt ()
      , Eio_context.get_clock_opt ()
      , Eio_context.get_net_opt () )
    with
    | Some sw, Some clock, Some net ->
      (* Synchronous on purpose: the tool schema promises "blocks until
         playback finishes". The former fire-and-forget queue returned
         status="queued" immediately, so the model never saw playback
         complete and re-spoke the same content every sub-turn
         (2026-06-10 sangsu voice repeat incident). *)
      (match
         Voice_bridge.agent_speak
           ~sw
           ~clock
           ~net
           ~agent_id:meta.name
           ~message
           ?provider
           ~priority
           ()
       with
       | Ok json ->
         let spoken =
           match Json_util.get_string json "status" with
           | Some "spoken" -> true
           | Some _ | None -> false
         in
         if spoken
         then (
           let memory_status =
             record_voice_output
               ~config
               ~meta
               ~provider
               ~priority
               ~execution:"synchronous"
               ~message
           in
           Yojson.Safe.to_string (attach_memory_status json memory_status))
         else Yojson.Safe.to_string json
       | Error err ->
         Tool_args.error_response_with
           [ "agent_id", `String meta.name
           ; "message", `String err
           ])
    | _ ->
      let memory_status =
        record_voice_output
          ~config
          ~meta
          ~provider
          ~priority
          ~execution:"text_fallback"
          ~message
      in
      Yojson.Safe.to_string
        (attach_memory_status
           (keeper_text_fallback_json ~agent_id:meta.name ~message)
           memory_status))

let handle_listen ~(meta : keeper_meta) ~(args : Yojson.Safe.t) () =
  let timeout_sec = Safe_ops.json_float ~default:60.0 "timeout_seconds" args in
  let language_code = Safe_ops.json_string_opt "language_code" args in
  match
    Voice_bridge.record_and_transcribe
      ~agent_id:meta.name
      ~timeout_sec
      ?language_code
      ()
  with
  | Ok json -> Yojson.Safe.to_string json
  | Error err ->
    Tool_args.error_response_with
      [ "error", `String err
      ; "agent_id", `String meta.name
      ]

let handle_agent ~(meta : keeper_meta) =
  match Voice_bridge.get_agent_voice ~agent_id:meta.name with
  | Ok json -> Yojson.Safe.to_string json
  | Error err ->
    Tool_args.error_response_with
      [ "agent_id", `String meta.name
      ; "message", `String err
      ]

let handle_sessions () =
  let mgr = Keeper_voice_local.get_session_manager () in
  let sessions = Voice_session_manager.list_sessions mgr in
  Yojson.Safe.to_string
    (`Assoc
        [ "session_count", `Int (List.length sessions)
        ; "sessions", `List (List.map Voice_session_manager.session_to_json sessions)
        ])

let handle_session_start ~(meta : keeper_meta) ~(args : Yojson.Safe.t) =
  let voice =
    Safe_ops.json_string_opt "voice" args
    |> Option.map String.trim
    |> function
    | Some s when s <> "" -> Some s
    | _ -> None
  in
  let mgr = Keeper_voice_local.get_session_manager () in
  let session = Voice_session_manager.start_session mgr ~agent_id:meta.name ?voice () in
  Yojson.Safe.to_string (Voice_session_manager.session_to_json session)

let handle_session_end ~(meta : keeper_meta) =
  let mgr = Keeper_voice_local.get_session_manager () in
  let ended = Voice_session_manager.end_session mgr ~agent_id:meta.name in
  Yojson.Safe.to_string
    (`Assoc
        [ "status", `String (if ended then "ended" else "no_active_session")
        ; "agent_id", `String meta.name
        ])

let handle
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(command : voice_command)
      ~(args : Yojson.Safe.t)
      ()
  =
  match command with
  | Speak -> handle_speak ~config ~meta ~args
  | Listen -> handle_listen ~meta ~args ()
  | Agent -> handle_agent ~meta
  | Sessions -> handle_sessions ()
  | Session_start -> handle_session_start ~meta ~args
  | Session_end -> handle_session_end ~meta

let handle_voice_tool
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
      ()
  =
  match command_of_string name with
  | Some command -> handle ~config ~meta ~command ~args ()
  | None -> error_json ~fields:[ "tool", `String name ] "unknown_voice_tool"
