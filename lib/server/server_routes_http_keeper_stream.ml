
open Server_auth

module Mcp_eio = Mcp_server_eio

type keeper_chat_stream_request = {
  name : string;
  message : string;
  timeout_sec : int option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
}

let keeper_chat_stream_error_json message =
  `Assoc
    [
      ( "error",
        `Assoc [ ("message", `String message) ] );
    ]

(* Empty needle preserves the legacy "matches all" semantic; non-empty
   matching delegates to the SSOT helper, which scans byte-wise with
   inline [Char.lowercase_ascii] and avoids the two
   [String.lowercase_ascii] allocations plus the per-position
   [String.sub] of the old form. *)
let contains_casefold haystack needle =
  String.length needle = 0
  || String_util.contains_substring_ci haystack needle


(* No external timeout for keeper_msg. Keeper has its own internal limits
   (max_turns, max_cost_usd, max_tokens) that control call duration.
   A fixed external timeout conflicts with multi-turn tool-use loops and
   causes lost turn metrics when the timeout fires mid-Agent.run().
   Aligned with MCP path (mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool ~sw ~clock ?auth_token:_ state ~agent_name ~arguments =
  let start_time = Eio.Time.now clock in
  let success, body =
    try
      let keeper_ctx : _ Tool_keeper.context =
        {
          config = state.Mcp_server.room_config;
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:arguments with
      | Some result -> result
      | None -> (false, "masc_keeper_msg dispatch unavailable")
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        let err = Printexc.to_string exn in
        if contains_casefold err "Invalid_argument(\"MASC not initialized" then
          (false, Types.masc_error_to_string Types.NotInitialized)
        else (
          Log.Mcp.error "tools/call crashed: %s" err;
          (false, Printf.sprintf "Internal error: %s" err))
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let error_msg =
    if success then None
    else Some (Printf.sprintf "duration_ms=%d" duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  if not success then
    Log.emit Log.Error ~module_name:"Keeper"
      ~details:
        (`Assoc
          [
            ("event_family", `String "tool_call_failure");
            ("tool_name", `String "masc_keeper_msg");
            ("agent_name", `String agent_name);
            ("duration_ms", `Int duration_ms);
            ("streaming", `Bool false);
          ])
      "keeper tool call failed: masc_keeper_msg";
  let telemetry_enabled = Env_config_core.telemetry_enabled () in
  if telemetry_enabled then (
    match state.Mcp_server.fs with
    | Some fs ->
        (try
           let telemetry_error_kind =
             if success then None
             else Some (Telemetry_eio.error_kind_of_string "tool_failure")
           in
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success ~duration_ms
             ~source:(Tool_registry.string_of_source Keeper_internal)
             ?error_kind:telemetry_error_kind ?error_message:error_msg ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ()
  );
  Tool_registry.record_call_if_known ~source:Keeper_internal
    ~tool_name:"masc_keeper_msg" ~success ~duration_ms ();
  (success, body)

let parse_keeper_chat_stream_request body_str =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body_str in
    if not (match json with `Assoc _ -> true | _ -> false) then
      Error "request body must be a JSON object"
    else
      let name = json |> member "name" |> to_string_option |> Option.value ~default:"" |> String.trim in
      let message =
        json |> member "message" |> to_string_option |> Option.value ~default:""
        |> String.trim
      in
      let channel =
        json |> member "channel" |> to_string_option |> Option.value ~default:""
        |> String.trim
      in
      let channel_user_id =
        json |> member "channel_user_id" |> to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      let channel_user_name =
        json |> member "channel_user_name" |> to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      let channel_room_id =
        json |> member "channel_room_id" |> to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      let has_connector_context =
        channel <> "" || channel_user_id <> ""
        || channel_user_name <> "" || channel_room_id <> ""
      in
      let legacy_models_present =
        match json |> member "models" with
        | `Null -> false
        | _ -> true
      in
      let timeout_sec =
        match json |> member "timeout_sec" with
        | `Null -> Ok None
        | `Int value when value > 0 -> Ok (Some (max 5 (min 300 value)))
        | `Float value when value > 0.0 ->
            Ok (Some (max 5 (min 300 (int_of_float (Float.ceil value)))))
        | `Int _ | `Float _ -> Ok None
        | _ -> Error "timeout_sec must be a positive number"
      in
      if name = "" then
        Error "name is required"
      else if message = "" then
        Error "message is required"
      else if has_connector_context
              && (channel = "" || channel_user_id = "" || channel_room_id = "")
      then
        Error
          "channel, channel_user_id, and channel_room_id are required when connector context is supplied"
      else if legacy_models_present then
        Error
          "legacy keeper model args removed for masc_keeper_msg: models. Keepers now use cascade_name and last_model_used only."
      else
        match timeout_sec with
        | Ok timeout_sec ->
            Ok
              {
                name;
                message;
                timeout_sec;
                channel;
                channel_user_id;
                channel_user_name;
                channel_room_id;
              }
        | Error err -> Error err
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

let strip_keeper_visible_reply (reply : string) =
  reply
  |> Keeper_skill_routing.strip_skill_route_lines
  |> Keeper_execution.strip_state_blocks_text
  |> String.trim

let split_keeper_reply_chunks (text : string) : string list =
  let len = String.length text in
  if len = 0 then
    []
  else
    let whitespace = function
      | ' ' | '\n' | '\t' -> true
      | _ -> false
    in
    let chunks = ref [] in
    let start = ref 0 in
    let last_space = ref None in
    let push stop =
      if stop > !start then
        chunks := String.sub text !start (stop - !start) :: !chunks;
      start := stop;
      last_space := None
    in
    for i = 0 to len - 1 do
      let ch = text.[i] in
      if ch = ' ' then last_space := Some i;
      let next_is_boundary =
        i + 1 >= len || whitespace text.[i + 1]
      in
      let hard_wrap =
        i - !start >= 180
        &&
        match !last_space with
        | Some idx -> idx > !start
        | None -> false
      in
      let should_break =
        (match ch with
         | '.' | '!' | '?' -> next_is_boundary
         | '\n' -> i + 1 < len && text.[i + 1] = '\n'
         | _ -> false)
        || hard_wrap
      in
      if should_break then
        match !last_space with
        | Some idx when hard_wrap -> push (idx + 1)
        | _ -> push (i + 1)
    done;
    if !start < len then
      chunks := String.sub text !start (len - !start) :: !chunks;
    List.rev !chunks |> List.filter (fun chunk -> String.trim chunk <> "")

let keeper_stream_send_raw writer mutex closed data =
  if !closed || Httpun.Body.Writer.is_closed writer then begin
    closed := true;
    false
  end else
    try
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          Httpun.Body.Writer.write_string writer data;
          Httpun.Body.Writer.flush writer (fun _ -> ()));
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn "keeper_stream_send_raw write failed: %s" (Printexc.to_string exn);
      closed := true;
      false

let keeper_stream_send_event writer mutex closed event =
  keeper_stream_send_raw writer mutex closed (Ag_ui.event_to_sse event)

(** Execute keeper dispatch with real-time streaming.
    Calls [dispatch_stream] which forwards MODEL text deltas to [on_text_delta].
    Returns the same [(bool, string)] result as the batch path.
    No external timeout — keeper internal limits control duration
    (aligned with MCP path, see mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool_streaming ~sw ~clock ?auth_token:_ state
    ~agent_name ~arguments ~on_text_delta =
  let start_time = Eio.Time.now clock in
  let success, body =
    try
      let keeper_ctx : _ Tool_keeper.context =
        {
          config = state.Mcp_server.room_config;
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match
        Tool_keeper.dispatch_stream ~on_text_delta keeper_ctx
          ~name:"masc_keeper_msg" ~args:arguments
      with
      | Some result -> result
      | None -> (false, "masc_keeper_msg stream dispatch unavailable")
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        let err = Printexc.to_string exn in
        if contains_casefold err "Invalid_argument(\"MASC not initialized" then
          (false, Types.masc_error_to_string Types.NotInitialized)
        else (
          Log.Mcp.error "tools/call crashed (stream): %s" err;
          (false, Printf.sprintf "Internal error: %s" err))
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let error_msg =
    if success then None
    else Some (Printf.sprintf "duration_ms=%d" duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.room_config ~agent_id:agent_name
    ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  if not success then
    Log.emit Log.Error ~module_name:"Keeper"
      ~details:
        (`Assoc
          [
            ("event_family", `String "tool_call_failure");
            ("tool_name", `String "masc_keeper_msg");
            ("agent_name", `String agent_name);
            ("duration_ms", `Int duration_ms);
            ("streaming", `Bool true);
          ])
      "keeper tool call failed: masc_keeper_msg";
  let telemetry_enabled = Env_config_core.telemetry_enabled () in
  if telemetry_enabled then (
    match state.Mcp_server.fs with
    | Some fs ->
        (try
           let telemetry_error_kind =
             if success then None
             else Some (Telemetry_eio.error_kind_of_string "tool_failure")
           in
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success
             ~duration_ms ~source:(Tool_registry.string_of_source Keeper_internal)
             ?error_kind:telemetry_error_kind ?error_message:error_msg ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ());
  Tool_registry.record_call_if_known ~source:Keeper_internal
    ~tool_name:"masc_keeper_msg" ~success ~duration_ms ();
  (success, body)

(** Send a Run_error AG-UI event with the given message. *)
let send_keeper_error writer mutex closed ~thread_id ~run_id err =
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(
         make_event ~thread_id ~run_id:(Some run_id)
           ~custom_name:(Some "KEEPER_CHAT_ERROR")
           ~custom_value:(Some (`Assoc [ ("message", `String err) ]))
           Run_error))

(** Send Text_message_end + Run_finished sequence to complete the stream. *)
let send_keeper_stream_finish writer mutex closed ~thread_id ~run_id
    ~message_id =
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(
         make_event ~thread_id ~run_id:(Some run_id)
           ~message_id:(Some message_id) Text_message_end));
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(make_event ~thread_id ~run_id:(Some run_id) Run_finished))

(** Extract visible reply from the keeper pipeline result body.
    Parses JSON if possible and strips internal markers. *)
let extract_visible_reply body =
  let payload_json_opt =
    try Some (Yojson.Safe.from_string body)
    with Yojson.Json_error _ -> None
  in
  let visible_reply =
    match payload_json_opt with
    | Some payload_json ->
        let reply_raw =
          payload_json
          |> Yojson.Safe.Util.member "reply"
          |> Yojson.Safe.Util.to_string_option
          |> Option.value ~default:""
        in
        let visible =
          if String.trim reply_raw = "" then String.trim body
          else strip_keeper_visible_reply reply_raw
        in
        if visible = "" then
          Option.value ~default:"(empty reply)"
            (Yojson.Safe.Util.to_string_option payload_json)
        else visible
    | None ->
        let visible = strip_keeper_visible_reply body in
        if visible = "" then "(empty reply)" else visible
  in
  (payload_json_opt, visible_reply)

let handle_keeper_chat_stream ~sw ~clock state request reqd payload =
  let origin = get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let close_stream () =
    if not !closed then begin
      closed := true;
      (* Catch all exceptions including Cancelled — this function is called
         from Switch.on_release where re-raising would mask the original exn. *)
      (try Httpun.Body.Writer.close writer
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Misc.warn "keeper_stream writer close: %s"
           (Printexc.to_string exn))
    end
  in
  let now_id () = int_of_float (Time_compat.now () *. 1000.0) in
  let thread_id = "keeper:" ^ payload.name in
  let run_id = Printf.sprintf "keeper-run-%d" (now_id ()) in
  let message_id = Printf.sprintf "keeper-msg-%d" (now_id ()) in
  ignore (keeper_stream_send_raw writer mutex closed "retry: 1500\n\n");
  Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Eio.Switch.run @@ fun stream_sw ->
           Eio.Switch.on_release stream_sw close_stream;
          (* --- 1. Lifecycle: Run_started + Text_message_start --- *)
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id) Run_started));
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id)
                   ~message_id:(Some message_id)
                   ~role:(Some Assistant) Text_message_start));
          let has_connector_context =
            payload.channel <> "" && payload.channel_user_id <> ""
          in
          let message =
            if has_connector_context then
              Gate_keeper_backend.contextualize_message
                ~channel:payload.channel
                ~channel_user_id:payload.channel_user_id
                ~channel_user_name:payload.channel_user_name
                ~channel_room_id:payload.channel_room_id
                ~content:payload.message
            else
              payload.message
          in
          let args =
            `Assoc
              [ ("name", `String payload.name);
                ("message", `String message);
                ("direct_reply", `Bool true) ]
          in
          let agent_name =
            if has_connector_context then
              Gate_keeper_backend.agent_name_for_channel_actor
                ~channel:payload.channel
                ~channel_room_id:payload.channel_room_id
                ~channel_user_id:payload.channel_user_id
            else
              match agent_from_request request with
              | Some raw when String.trim raw <> "" -> String.trim raw
              | _ -> "unknown"
          in
          (* Track whether any text deltas were streamed to the client.
             When streaming is active, the MODEL text is sent token-by-token
             during the call; we only need to send the final batch chunks
             if no deltas were emitted (fallback path). *)
          let deltas_sent = ref false in
          let on_text_delta text =
            if String.length text > 0 then begin
              deltas_sent := true;
              ignore
                (keeper_stream_send_event writer mutex closed
                   Ag_ui.(
                     make_event ~thread_id ~run_id:(Some run_id)
                       ~message_id:(Some message_id)
                       ~delta:(Some text) Text_message_content))
            end
          in

          (* --- 2. Try real streaming path first --- *)
          let dispatch_result =
            try
              Ok
                (execute_keeper_stream_tool_streaming ~sw ~clock
                   ?auth_token:(auth_token_from_request request)
                   state ~agent_name ~arguments:args ~on_text_delta)
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Keeper.warn
                "keeper_stream: streaming dispatch raised: %s"
                (Printexc.to_string exn);
              (* --- 3. Fallback to batch on exception --- *)
              (try
                 Ok
                   (execute_keeper_stream_tool ~sw ~clock
                      ?auth_token:(auth_token_from_request request)
                      state ~agent_name ~arguments:args)
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn2 -> Error (Printexc.to_string exn2))
          in
          match dispatch_result with
          | Error err ->
              send_keeper_error writer mutex closed ~thread_id ~run_id err
          | Ok (false, err) ->
              send_keeper_error writer mutex closed ~thread_id ~run_id err
          | Ok (true, body) -> (
              try
                let payload_json_opt, visible_reply =
                  extract_visible_reply body
                in
                (* If no deltas were streamed during the MODEL call
                   (batch fallback or tool-call-only response),
                   send the visible reply as chunked content now. *)
                if not !deltas_sent then
                  split_keeper_reply_chunks visible_reply
                  |> List.iter (fun chunk ->
                         ignore
                           (keeper_stream_send_event writer mutex closed
                              Ag_ui.(
                                make_event ~thread_id
                                  ~run_id:(Some run_id)
                                  ~message_id:(Some message_id)
                                  ~delta:(Some chunk)
                                  Text_message_content)));
                (* Always send the structured reply details *)
                (match payload_json_opt with
                 | Some payload_json ->
                     ignore
                       (keeper_stream_send_event writer mutex closed
                          Ag_ui.(
                            make_event ~thread_id ~run_id:(Some run_id)
                              ~custom_name:(Some "KEEPER_REPLY_DETAILS")
                              ~custom_value:(Some payload_json) Custom))
                 | None -> ());
                (* Persist user + assistant messages in a single write *)
                Keeper_chat_store.append_pair
                  ~base_dir:state.Mcp_server.room_config.base_path
                  ~keeper_name:payload.name
                  ~user_content:payload.message
                  ~assistant_content:visible_reply;
                send_keeper_stream_finish writer mutex closed ~thread_id
                  ~run_id ~message_id
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                send_keeper_error writer mutex closed ~thread_id ~run_id
                  (Printexc.to_string exn))))

(** Build routes for MCP server *)
