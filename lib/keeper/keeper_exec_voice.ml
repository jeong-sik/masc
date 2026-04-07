open Keeper_types
open Keeper_exec_shared

let handle_keeper_voice_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match name with
  | "keeper_voice_speak" ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    let provider =
      Safe_ops.json_string_opt "provider" args
      |> Option.map String.trim
      |> function
      | Some p when p <> "" -> Some p
      | _ -> None
    in
    let priority = max 1 (Safe_ops.json_int ~default:1 "priority" args) in
    if message = ""
    then error_json "message is required. Good: message='Hello team.'. Bad: message=''."

    else (
      match
        ( Eio_context.get_switch_opt ()
        , Eio_context.get_clock_opt ()
        , Eio_context.get_net_opt () )
      with
      | Some sw, Some clock, Some net ->
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
         | Ok json -> Yojson.Safe.to_string json
         | Error err ->
           Yojson.Safe.to_string
             (`Assoc
                 [ "status", `String "error"
                 ; "agent_id", `String meta.name
                 ; "message", `String err
                 ]))
      | _ ->
        Yojson.Safe.to_string (keeper_text_fallback_json ~agent_id:meta.name ~message))
  | "keeper_voice_listen" ->
    let timeout_sec = Safe_ops.json_float ~default:15.0 "timeout_seconds" args in
    let language_code = Safe_ops.json_string_opt "language_code" args in
    (match
       Voice_bridge.record_and_transcribe
         ~agent_id:meta.name
         ~timeout_sec
         ?language_code
         ()
     with
     | Ok json -> Yojson.Safe.to_string json
     | Error err ->
       Yojson.Safe.to_string
         (`Assoc
             [ "status", `String "error"
             ; "error", `String err
             ; "agent_id", `String meta.name
             ]))
  | "keeper_voice_agent" ->
    (match Voice_bridge.get_agent_voice ~agent_id:meta.name with
     | Ok json -> Yojson.Safe.to_string json
     | Error err ->
       Yojson.Safe.to_string
         (`Assoc
             [ "status", `String "error"
             ; "agent_id", `String meta.name
             ; "message", `String err
             ]))
  | "keeper_voice_sessions" ->
    let mgr = Keeper_voice_local.get_session_manager () in
    let sessions = Voice_session_manager.list_sessions mgr in
    Yojson.Safe.to_string
      (`Assoc
          [ "session_count", `Int (List.length sessions)
          ; "sessions", `List (List.map Voice_session_manager.session_to_json sessions)
          ])
  | "keeper_voice_session_start" ->
    let voice =
      Safe_ops.json_string_opt "session_name" args
      |> Option.map String.trim
      |> function
      | Some s when s <> "" -> Some s
      | _ -> None
    in
    let mgr = Keeper_voice_local.get_session_manager () in
    let session = Voice_session_manager.start_session mgr ~agent_id:meta.name ?voice () in
    Yojson.Safe.to_string (Voice_session_manager.session_to_json session)
  | "keeper_voice_session_end" ->
    let mgr = Keeper_voice_local.get_session_manager () in
    let ended = Voice_session_manager.end_session mgr ~agent_id:meta.name in
    Yojson.Safe.to_string
      (`Assoc
          [ "status", `String (if ended then "ended" else "no_active_session")
          ; "agent_id", `String meta.name
          ])
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_voice_tool"
;;

