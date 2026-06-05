
open Server_auth

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

type keeper_chat_stream_request = {
  name : string;
  message : string;
  timeout_sec : int option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  attachments : Keeper_chat_store.attachment list;
}

let keeper_chat_stream_error_json message =
  `Assoc
    [
      ( "error",
        `Assoc [ ("message", `String message) ] );
    ]

let keeper_chat_request_prefixes =
  [
    "/api/v1/gate/message/requests/";
    "/api/v1/keepers/chat/requests/";
  ]

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix

let keeper_chat_request_suffix request =
  let path = Http.Request.path request in
  let rec loop = function
    | [] -> None
    | prefix :: rest ->
        if has_prefix ~prefix path then
          Some
            (String.sub path (String.length prefix)
               (String.length path - String.length prefix))
        else loop rest
  in
  loop keeper_chat_request_prefixes

let parse_keeper_chat_request_result_path request =
  match keeper_chat_request_suffix request with
  | Some suffix -> (
      match String.split_on_char '/' suffix with
      | [ request_id ] when String.trim request_id <> "" -> Ok request_id
      | _ -> Error "expected /api/v1/gate/message/requests/<request_id>" )
  | None -> Error "invalid keeper chat request path"

let parse_keeper_chat_request_cancel_path request =
  match keeper_chat_request_suffix request with
  | Some suffix -> (
      match String.split_on_char '/' suffix with
      | [ request_id; "cancel" ] when String.trim request_id <> "" ->
          Ok request_id
      | _ -> Error "expected /api/v1/gate/message/requests/<request_id>/cancel" )
  | None -> Error "invalid keeper chat request path"

let handle_keeper_chat_request_result state request reqd =
  match parse_keeper_chat_request_result_path request with
  | Error message ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json message)
  | Ok request_id -> (
      match
        Keeper_msg_async.poll
          ~base_path:state.Mcp_server.workspace_config.base_path request_id
      with
      | None ->
          respond_json_value_with_cors ~status:`Not_found request reqd
            (keeper_chat_stream_error_json "request_id not found")
      | Some entry ->
          respond_json_value_with_cors ~status:`OK request reqd
            (Keeper_msg_async.entry_to_json entry) )

let handle_keeper_chat_request_cancel state request reqd =
  match parse_keeper_chat_request_cancel_path request with
  | Error message ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json message)
  | Ok request_id ->
      let cancelled =
        Keeper_msg_async.cancel
          ~base_path:state.Mcp_server.workspace_config.base_path request_id
      in
      if cancelled then
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
            [
              ("request_id", `String request_id);
              ("status", `String "cancelled");
              ("message", `String "Keeper turn cancelled successfully.");
            ])
      else
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json
             "request_id not found or already finished")

(* No external timeout for keeper_msg. Keeper has its own internal limits
   (max_turns, max_cost_usd, max_tokens) that control call duration.
   A fixed external timeout conflicts with multi-turn tool-use loops and
   causes lost turn metrics when the timeout fires mid-Agent.run().
   Aligned with MCP path (mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool ~sw ~clock ?auth_token:_ state ~agent_name ~arguments =
  let start_time = Eio.Time.now clock in
  let success, body =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config = state.Mcp_server.workspace_config;
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match Keeper_tool_surface.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:arguments with
      | Some result -> Tool_result.is_success result, Tool_result.message result
      | None -> (false, "masc_keeper_msg dispatch unavailable")
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        (false, Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized))
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed: %s" err;
        (false, Printf.sprintf "Internal error: %s" err)
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
  let error_msg =
    if success then None
    else Some (Printf.sprintf "duration_ms=%d" duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.workspace_config
    ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  if not success then
    Log.Keeper.emit Log.Error
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
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.workspace_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success ~duration_ms
             ~source:(Tool_registry.string_of_source Agent_internal)
             ?error_kind:telemetry_error_kind ?error_message:error_msg ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ()
  );
  Tool_registry.record_call_if_known ~source:Agent_internal
    ~tool_name:"masc_keeper_msg" ~success ~duration_ms ();
  (success, body)

let parse_keeper_chat_stream_request body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    if not (match json with `Assoc _ -> true | _ -> false) then
      Error "request body must be a JSON object"
    else
      let name = Json_util.get_string_with_default json ~key:"name" ~default:"" |> String.trim in
      let message =
        Json_util.get_string_with_default json ~key:"message" ~default:""
        |> String.trim
      in
      let channel =
        Json_util.get_string_with_default json ~key:"channel" ~default:""
        |> String.trim
      in
      let channel_user_id =
        Json_util.get_string_with_default json ~key:"channel_user_id" ~default:""
        |> String.trim
      in
      let channel_user_name =
        Json_util.get_string json "channel_user_name"
        |> Option.value ~default:""
        |> String.trim
      in
      let channel_workspace_id =
        Json_util.get_string json "channel_workspace_id"
        |> Option.value ~default:""
        |> String.trim
      in
      let has_connector_context =
        channel <> "" || channel_user_id <> ""
        || channel_user_name <> "" || channel_workspace_id <> ""
      in
      let timeout_sec =
        match Json_util.assoc_member_opt "timeout_sec" json with
        | None | Some `Null -> Ok None
        | Some (`Int value) when value > 0 -> Ok (Some (max 5 (min 300 value)))
        | Some (`Float value) when value > 0.0 ->
            Ok (Some (max 5 (min 300 (int_of_float (Float.ceil value)))))
        | Some (`Int _) | Some (`Float _) -> Ok None
        | Some _ -> Error "timeout_sec must be a positive number"
      in
      let attachments : Keeper_chat_store.attachment list =
        match Json_util.assoc_member_opt "attachments" json with
        | Some (`List att_list) ->
            List.filter_map
              (fun att_json ->
                match att_json with
                | `Assoc _ -> (
                    try
                      let id =
                        Json_util.get_string_with_default att_json ~key:"id" ~default:""
                      in
                      let att_type =
                        Json_util.get_string_with_default att_json ~key:"type" ~default:""
                      in
                      let name =
                        Json_util.get_string_with_default att_json ~key:"name" ~default:""
                      in
                      let size =
                        match Json_util.assoc_member_opt "size" att_json with
                        | Some (`Int i) -> i
                        | _ -> 0
                      in
                      let mime_type =
                        Json_util.get_string_with_default att_json ~key:"mime_type" ~default:""
                      in
                      let data =
                        Json_util.get_string_with_default att_json ~key:"data" ~default:""
                      in
                      if id = "" || data = "" then None
                      else Some { Keeper_chat_store.id; att_type; name; size; mime_type; data }
                    with _ -> None)
                | _ -> None)
              att_list
        | _ -> []
      in
      if name = "" then
        Error "name is required"
      else if message = "" then
        Error "message is required"
      else if has_connector_context
              && (channel = "" || channel_user_id = "" || channel_workspace_id = "")
      then
        Error
          "channel, channel_user_id, and channel_workspace_id are required when connector context is supplied"
      else
        match
          Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_msg" json
        with
        | Error err -> Error err
        | Ok () -> (
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
                  channel_workspace_id;
                  attachments;
                }
          | Error err -> Error err )
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

let strip_keeper_visible_reply (reply : string) =
  reply
  |> Keeper_skill_routing.strip_skill_route_lines
  |> Keeper_execution.strip_state_blocks_text
  |> String.trim

let continuation_checkpoint_prefix = "Continuation checkpoint saved;"

let is_continuation_checkpoint_reply text =
  has_prefix ~prefix:continuation_checkpoint_prefix (String.trim text)

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
    Projects the typed keeper result into the local HTTP stream response pair.
    No external timeout — keeper internal limits control duration
    (aligned with MCP path, see mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool_streaming ~sw ~clock ?auth_token:_ state
    ~agent_name ~arguments ~on_text_delta =
  let start_time = Eio.Time.now clock in
  let success, body =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config = state.Mcp_server.workspace_config;
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match
        Keeper_tool_surface.dispatch_stream ~on_text_delta keeper_ctx
          ~name:"masc_keeper_msg" ~args:arguments
      with
      | Some result -> Tool_result.is_success result, Tool_result.message result
      | None -> (false, "masc_keeper_msg stream dispatch unavailable")
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        (false, Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized))
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed (stream): %s" err;
        (false, Printf.sprintf "Internal error: %s" err)
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
  let error_msg =
    if success then None
    else Some (Printf.sprintf "duration_ms=%d" duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.workspace_config ~agent_id:agent_name
    ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  if not success then
    Log.Keeper.emit Log.Error
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
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.workspace_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success
             ~duration_ms ~source:(Tool_registry.string_of_source Agent_internal)
             ?error_kind:telemetry_error_kind ?error_message:error_msg ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ());
  Tool_registry.record_call_if_known ~source:Agent_internal
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
          Json_util.get_string payload_json "reply"
          |> Option.value ~default:""
        in
        let visible =
          if String.trim reply_raw = "" then String.trim body
          else strip_keeper_visible_reply reply_raw
        in
        if visible = "" then
          Option.value ~default:"(empty reply)"
            (match payload_json with `String s -> Some s | _ -> None)
        else visible
    | None ->
        let visible = strip_keeper_visible_reply body in
        if visible = "" then "(empty reply)" else visible
  in
  (payload_json_opt, visible_reply)

type keeper_stream_worker_event =
  | Stream_delta of string
  | Stream_terminal of bool * string

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

  let process_single_turn ~payload ~run_id ~message_id ~agent_name =
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
          ~channel_workspace_id:payload.channel_workspace_id
          ~content:payload.message
      else
        payload.message
    in
    let attachment_json att =
      `Assoc
        [ ("id", `String att.Keeper_chat_store.id);
          ("type", `String att.att_type);
          ("name", `String att.name);
          ("size", `Int att.size);
          ("mime_type", `String att.mime_type);
          ("data", `String att.data) ]
    in
    let args =
      let base_fields =
        [ ("name", `String payload.name);
          ("message", `String message);
          ("direct_reply", `Bool true) ]
        @
        (match payload.timeout_sec with
         | Some timeout_sec -> [ ("timeout_sec", `Int timeout_sec) ]
         | None -> [])
      in
      `Assoc
        (if payload.attachments = [] then base_fields
         else ("attachments", `List (List.map attachment_json payload.attachments)) :: base_fields)
    in
    (* Track whether any text deltas were streamed to the client.
       When streaming is active, the MODEL text is sent token-by-token
       during the call; we only need to send the final batch chunks
       if no deltas were emitted (fallback path). *)
    let deltas_sent = ref false in
    let worker_events = Eio.Stream.create 512 in
    let push_worker_event event =
      if not !closed then
        try Eio.Stream.add worker_events event
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn
              "keeper_stream: worker event push failed: %s"
              (Printexc.to_string exn)
    in
    let on_text_delta text =
      if String.length text > 0 then
        push_worker_event (Stream_delta text)
    in
    let timeout_sec = Option.map float_of_int payload.timeout_sec in
    let request_id =
      Keeper_msg_async.submit ?timeout_sec ~clock ~sw
        ~base_path:state.Mcp_server.workspace_config.base_path
        ~keeper_name:payload.name
        ~f:(fun () ->
          let start_time = Time_compat.now () in
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
          | Ok (true, body) ->
              let _payload_json_opt, visible_reply = extract_visible_reply body in
              if not (is_continuation_checkpoint_reply visible_reply) then
                Keeper_chat_store.append_pair
                  ~base_dir:state.Mcp_server.workspace_config.base_path
                  ~keeper_name:payload.name
                  ~user_content:payload.message
                  ~user_attachments:payload.attachments
                  ~assistant_content:visible_reply;
              push_worker_event (Stream_terminal (true, body));
              Tool_result.ok ~tool_name:"masc_keeper_msg" ~start_time body
          | Ok (false, err) ->
              push_worker_event (Stream_terminal (false, err));
              Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err
          | Error err ->
              push_worker_event (Stream_terminal (false, err));
              Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err)
        ()
    in
    ignore
      (keeper_stream_send_event writer mutex closed
         Ag_ui.(
           make_event ~thread_id ~run_id:(Some run_id)
             ~custom_name:(Some "KEEPER_QUEUE_REQUEST")
             ~custom_value:
               (Some
                  (Gate_protocol.message_request_to_json
                     { request_id;
                       destination_type = "keeper";
                       destination_id = payload.name;
                       channel =
                         (if has_connector_context then payload.channel
                          else "dashboard");
                       actor_id = Some agent_name;
                       status = Gate_protocol.Queued;
                       modalities = [ "text" ];
                       transport = Some "sse";
                       metadata =
                         [
                           ("projection", "keeper_chat_stream");
                           ("protocol", "gate_message_request");
                         ];
                     }))
             Custom));
    let rec consume_worker_events () =
      match Eio.Stream.take worker_events with
      | Stream_delta text ->
          deltas_sent := true;
          if
            keeper_stream_send_event writer mutex closed
              Ag_ui.(
                make_event ~thread_id ~run_id:(Some run_id)
                  ~message_id:(Some message_id)
                  ~delta:(Some text) Text_message_content)
          then consume_worker_events ()
      | Stream_terminal (false, err) ->
          send_keeper_error writer mutex closed ~thread_id ~run_id err
      | Stream_terminal (true, body) -> (
          try
            let payload_json_opt, visible_reply = extract_visible_reply body in
            let is_checkpoint =
              is_continuation_checkpoint_reply visible_reply
            in
            if (not !deltas_sent) && not is_checkpoint then
              split_keeper_reply_chunks visible_reply
              |> List.iter (fun chunk ->
                     ignore
                       (keeper_stream_send_event writer mutex closed
                          Ag_ui.(
                            make_event ~thread_id ~run_id:(Some run_id)
                              ~message_id:(Some message_id)
                              ~delta:(Some chunk) Text_message_content)));
            (match payload_json_opt with
             | Some payload_json ->
                 ignore
                   (keeper_stream_send_event writer mutex closed
                      Ag_ui.(
                        make_event ~thread_id ~run_id:(Some run_id)
                          ~custom_name:(Some "KEEPER_REPLY_DETAILS")
                          ~custom_value:(Some payload_json) Custom))
             | None -> ());
            if is_checkpoint then
              ignore
                (keeper_stream_send_event writer mutex closed
                   Ag_ui.(
                     make_event ~thread_id ~run_id:(Some run_id)
                       ~custom_name:(Some "KEEPER_CONTINUATION_CHECKPOINT")
                       ~custom_value:
                         (Some
                            (`Assoc
                              [ ("request_id", `String request_id);
                                ("message", `String visible_reply) ]))
                       Custom));
            send_keeper_stream_finish writer mutex closed ~thread_id ~run_id
              ~message_id
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              send_keeper_error writer mutex closed ~thread_id ~run_id
                (Printexc.to_string exn))
    in
    consume_worker_events ()
  in

  ignore (keeper_stream_send_raw writer mutex closed "retry: 1500\n\n");
  Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Eio.Switch.run @@ fun stream_sw ->
           Eio.Switch.on_release stream_sw close_stream;
           let has_connector_context =
             payload.channel <> "" && payload.channel_user_id <> ""
           in
           let agent_name =
             if has_connector_context then
               Gate_keeper_backend.agent_name_for_channel_actor
                 ~channel:payload.channel
                 ~channel_workspace_id:payload.channel_workspace_id
                 ~channel_user_id:payload.channel_user_id
             else
               match agent_from_request request with
               | Some raw ->
                   let trimmed = String.trim raw in
                   if trimmed <> "" then trimmed else "unknown"
               | None -> "unknown"
           in
           let run_id = Printf.sprintf "keeper-run-%d" (now_id ()) in
           let message_id = Printf.sprintf "keeper-msg-%d" (now_id ()) in
           process_single_turn ~payload ~run_id ~message_id ~agent_name;
           let rec drain_queue () =
             match Keeper_chat_queue.dequeue ~keeper_name:payload.name with
             | None -> ()
             | Some queued ->
                 (match queued.source with
                  | Keeper_chat_queue.Dashboard ->
                      let run_id = Printf.sprintf "keeper-run-%d" (now_id ()) in
                      let message_id = Printf.sprintf "keeper-msg-%d" (now_id ()) in
                      let queued_payload =
                        { payload with
                          message = queued.content;
                          attachments = queued.attachments }
                      in
                      process_single_turn ~payload:queued_payload ~run_id ~message_id
                        ~agent_name
                  | Keeper_chat_queue.Discord _ | Keeper_chat_queue.Slack _ ->
                      Log.Keeper.warn
                        "keeper_chat_queue: non-Dashboard source dropped for keeper=%s"
                        payload.name);
                 drain_queue ()
           in
           drain_queue ()))

(** Build routes for MCP server *)
