
open Server_auth

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

(* Keeper-chat stream tunables (CLAUDE.md Magic Number 규칙: 의미를 드러내는 리터럴은
   named constant로). Bounds are keeper-message-specific and distinct from the
   env_config turn/orchestrator clamps. *)

(* Clamp bounds for the client-supplied per-message timeout (seconds). *)
let keeper_msg_timeout_sec_min = 5
let keeper_msg_timeout_sec_max = 300

let clamp_keeper_msg_timeout_sec v =
  max keeper_msg_timeout_sec_min (min keeper_msg_timeout_sec_max v)
;;

(* Progressive-render hard-wrap width (characters) for streamed keeper replies —
   a UI readability chunk width, NOT an SSE/transport line-length limit. *)
let keeper_reply_chunk_hard_wrap_chars = 180

(* Bounded producer-consumer capacity for the worker-event stream; [Eio.Stream.add]
   blocks (backpressure) when the consumer lags. *)
let worker_events_buffer_size = 512

(* SSE reconnect backoff (ms) primed on the dashboard keeper-chat streams. Shared
   with {!Server_routes_http_routes_dashboard} (via [open]) so the two dashboard
   priming sites cannot silently diverge. Intentionally distinct from
   {!Server_mcp_transport_http_headers.sse_retry_ms} (3000, the MCP transport). *)
let sse_dashboard_retry_backoff_ms = 1500

type user_media_block = Keeper_multimodal_input.user_media_block = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int option;
}

type user_input_block = Keeper_multimodal_input.user_input_block =
  | User_text of string
  | User_image of user_media_block
  | User_document of user_media_block
  | User_audio of user_media_block

type keeper_chat_stream_request = {
  name : string;
  message : string;
  user_blocks : user_input_block list;
  timeout_sec : int option;
  turn_instructions : string option;
  surface_context : Yojson.Safe.t option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  attachments : Keeper_chat_store.attachment list;
  (* RFC-0320 W2b: typed originating connector for the turn. Unlike the flat
     [channel]/[channel_*] strings above (a lossy projection), this rides
     losslessly to the approval queue so a HITL resolution can route back.
     [Unrouted] when the request carries no typed channel (e.g. the HTTP path,
     whose flat fields cannot be reconstructed without a string classifier). *)
  continuation_channel : Keeper_continuation_channel.t;
}

let keeper_chat_stream_error_json message =
  `Assoc
    [
      ( "error",
        `Assoc [ ("message", `String message) ] );
    ]

(* Co-view context formatting is owned by the single SSOT
   [Keeper_turn.surface_context_to_instructions], shared with the
   masc_keeper_msg MCP tool path so the HTTP copilot route and the tool path
   cannot drift (and so both accept the dashboard's `List of {k,v} fields
   shape). [format_surface_context] keeps the string-returning shape that
   [turn_instructions_for_request] consumes. *)
let surface_context_to_instructions = Keeper_turn.surface_context_to_instructions

let format_surface_context ctx =
  (* NDT-OK: sound-partial; the shared formatter returns [None] for absent
     co-view instructions, while this HTTP helper preserves its legacy
     string-returning boundary for [turn_instructions_for_request]. *)
  Option.value ~default:"" (surface_context_to_instructions ctx)

let has_connector_context (payload : keeper_chat_stream_request) =
  payload.channel <> "" && payload.channel_workspace_id <> ""

let has_external_speaker (payload : keeper_chat_stream_request) =
  has_connector_context payload && payload.channel_user_id <> ""

let gate_address_of_request payload =
  let field key value =
    let value = String.trim value in
    if value = "" then [] else [ (key, value) ]
  in
  field "connector" payload.channel
  @ field "workspace_id" payload.channel_workspace_id

let message_for_request payload =
  if has_external_speaker payload then
    Gate_keeper_backend.contextualize_message
      ~channel:payload.channel
      ~channel_user_id:payload.channel_user_id
      ~channel_user_name:payload.channel_user_name
      ~channel_workspace_id:payload.channel_workspace_id
      ~metadata:[]
      ~content:payload.message
  else
    payload.message

let chat_surface_of_request payload =
  if has_connector_context payload then
    Surface_ref.Gate
      { label = payload.channel; address = gate_address_of_request payload }
  else Surface_ref.Dashboard { session_id = None }

let chat_speaker_of_request payload =
  if has_external_speaker payload then
    { Keeper_chat_store.speaker_id = Some payload.channel_user_id;
      speaker_name =
        (let name = String.trim payload.channel_user_name in
         if name = "" then None else Some name);
      speaker_authority = Keeper_chat_store.External }
  else
    { Keeper_chat_store.speaker_id = None;
      speaker_name = None;
      speaker_authority = Keeper_chat_store.Owner }

let turn_instructions_for_request payload =
  let ctx_text =
    match payload.surface_context with
    | Some ctx -> format_surface_context ctx
    | None -> ""
  in
  match payload.turn_instructions with
  | None -> if ctx_text = "" then None else Some ctx_text
  | Some ti ->
      if ctx_text = "" then Some ti
      else Some (ti ^ "\n\n" ^ ctx_text)

let args_of_request payload : Yojson.Safe.t =
  let message = message_for_request payload in
  let base_fields =
    [ ("name", `String payload.name);
      ("message", `String message);
      ("direct_reply", `Bool true) ]
    @
    (match payload.timeout_sec with
     | Some timeout_sec -> [ ("timeout_sec", `Int timeout_sec) ]
     | None -> [])
    @
    (match turn_instructions_for_request payload with
     | Some instructions when String.trim instructions <> "" ->
         [ ("turn_instructions", `String instructions) ]
     | _ -> [])
  in
  let connector_fields =
    (if has_connector_context payload then
       [ ("channel", `String payload.channel);
         ("channel_workspace_id", `String payload.channel_workspace_id) ]
     else [])
    @
    (if payload.channel_user_id <> "" then
       [ ("channel_user_id", `String payload.channel_user_id) ]
     else [])
    @
    (if payload.channel_user_name <> "" then
       [ ("channel_user_name", `String payload.channel_user_name) ]
     else [])
  in
  (* RFC-0320 W2b: carry the typed continuation channel losslessly when it is
     routable; an [Unrouted] channel is omitted so the reader fail-closes to
     [None] rather than round-tripping a diagnostic placeholder. *)
  let continuation_channel_fields =
    if Keeper_continuation_channel.is_routable payload.continuation_channel then
      [ ( "continuation_channel",
          Keeper_continuation_channel.to_yojson payload.continuation_channel ) ]
    else []
  in
  let fields = base_fields @ connector_fields @ continuation_channel_fields in
  let fields =
    if payload.user_blocks = [] then fields
    else
      ("user_blocks", Keeper_multimodal_input.user_blocks_to_yojson payload.user_blocks)
      :: fields
  in
  `Assoc
    (if payload.attachments = [] then fields
     else
       ("attachments", Keeper_multimodal_input.attachments_to_yojson payload.attachments)
       :: fields)

let modalities_for_request payload =
  match Keeper_multimodal_input.modalities payload.user_blocks with
  | [] -> [ "text" ]
  | labels -> labels

type dashboard_deferred_chat =
  { in_flight : Keeper_turn_admission.in_flight_info option
  ; chat_waiting : bool
  ; queue_length : int
  }

let dashboard_busy_queue_state ~base_path ~keeper_name =
  let in_flight = Keeper_turn_admission.in_flight ~base_path ~keeper_name in
  let chat_waiting = Keeper_turn_admission.chat_waiting ~base_path ~keeper_name in
  let queue_waiting = Keeper_chat_queue.length ~keeper_name > 0 in
  match in_flight, chat_waiting, queue_waiting with
  | None, false, false -> None
  | None, false, true -> Some (None, false)
  | None, true, _ -> Some (None, true)
  | Some info, false, _ -> Some (Some info, false)
  | Some info, true, _ -> Some (Some info, true)

let dashboard_deferred_ack_text ~keeper_name =
  Printf.sprintf
    "%s is busy; your message is queued and will be answered after the current \
     turn finishes."
    keeper_name

let dashboard_deferred_chat_to_json ~keeper_name
    ({ in_flight; chat_waiting; queue_length } : dashboard_deferred_chat) =
  let in_flight_fields =
    match in_flight with
    | None -> []
    | Some { Keeper_turn_admission.lane; started_at } ->
        [ ( "in_flight_lane"
          , `String (Keeper_turn_admission.lane_to_string lane) )
        ; ( "in_flight_started_at"
          , `Float started_at )
        ]
  in
  `Assoc
    ([ ("keeper_name", `String keeper_name)
     ; ("status", `String "queued")
     ; ("queue", `String "keeper_chat_queue")
     ; ("queue_length", `Int queue_length)
     ; ("chat_waiting", `Bool chat_waiting)
     ]
     @ in_flight_fields)

let enqueue_dashboard_payload ~clock payload ~in_flight ~chat_waiting =
  Keeper_chat_queue.enqueue ~keeper_name:payload.name
    { Keeper_chat_queue.content = payload.message
    ; user_blocks = payload.user_blocks
    ; attachments = payload.attachments
    ; timestamp = Eio.Time.now clock
    ; source = Keeper_chat_queue.Dashboard
    };
  { in_flight
  ; chat_waiting
  ; queue_length = Keeper_chat_queue.length ~keeper_name:payload.name
  }

let dashboard_deferred_chat_of_rejection ~clock payload
    ({ Keeper_turn_admission.waiting; in_flight } : Keeper_turn_admission.rejection) =
  enqueue_dashboard_payload ~clock payload ~in_flight ~chat_waiting:(waiting > 0)

let defer_dashboard_payload_if_busy ~base_path ~clock payload =
  match dashboard_busy_queue_state ~base_path ~keeper_name:payload.name with
  | None -> `Not_busy
  | Some (in_flight, chat_waiting) ->
      `Queued (enqueue_dashboard_payload ~clock payload ~in_flight ~chat_waiting)

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
          ~base_path:(Mcp_server.workspace_config state).base_path request_id
      with
      | Keeper_msg_async.Absent ->
          respond_json_value_with_cors ~status:`Not_found request reqd
            (keeper_chat_stream_error_json "request_id not found")
      | Keeper_msg_async.Unreadable reason ->
          respond_json_value_with_cors ~status:`Internal_server_error request
            reqd
            (keeper_chat_stream_error_json
               (Printf.sprintf
                  "request record unreadable: %s — request was accepted but \
                   its result is lost"
                  reason))
      | Keeper_msg_async.Found entry ->
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
          ~base_path:(Mcp_server.workspace_config state).base_path request_id
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

(** Build a compact error-detail string for audit/telemetry, mirroring the
    MCP tool path.  Keeps long error bodies from dominating log/JSONL rows
    while preserving a diagnostic preview. *)
let keeper_tool_failure_error_detail ~duration_ms ~error_body =
  let error_preview_max = 200 in
  let truncated =
    String_util.utf8_safe ~max_bytes:(error_preview_max + 3) ~suffix:"..." error_body
    |> String_util.to_string
  in
  Printf.sprintf "duration_ms=%d|detail=%s" duration_ms truncated

(** Structured details for the dashboard [tool_call_failure] log event.
    Includes the typed [failure_class] and a bounded error preview. The full
    provider/tool body can be large or sensitive, so log rows carry size and
    truncation metadata instead of the raw body. *)
let keeper_tool_failure_log_details ~tool_name ~agent_name ~duration_ms
    ~streaming ~error_body ~failure_class =
  let preview =
    String_util.utf8_safe ~max_bytes:200 ~suffix:"..." error_body
  in
  `Assoc
    [
      ("event_family", `String "tool_call_failure");
      ( "failure_class",
        `String (Tool_result.tool_failure_class_to_string failure_class) );
      ("tool_name", `String tool_name);
      ("agent_name", `String agent_name);
      ("duration_ms", `Int duration_ms);
      ("streaming", `Bool streaming);
      ("error_body_preview", `String (String_util.to_string preview));
      ("error_body_truncated", `Bool (String_util.was_truncated preview));
      ("error_body_bytes", `Int (String.length error_body));
    ]

let execute_keeper_stream_tool ~sw ~clock ?auth_token:_ state ~agent_name ~arguments =
  let start_time = Eio.Time.now clock in
  let success, body, failure_class =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config = (Mcp_server.workspace_config state);
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match Keeper_tool_surface.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:arguments with
      | Some result ->
          let success = Tool_result.is_success result in
          let body = Tool_result.message result in
          let failure_class =
            match Tool_result.failure_class result with
            | Some cls -> cls
            | None -> Tool_result.Runtime_failure
          in
          success, body, failure_class
      | None -> false, "masc_keeper_msg dispatch unavailable", Tool_result.Runtime_failure
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        ( false,
          Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized),
          Tool_result.Runtime_failure )
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed: %s" err;
        false, Printf.sprintf "Internal error: %s" err, Tool_result.Runtime_failure
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
  let error_detail =
    if success then None
    else Some (keeper_tool_failure_error_detail ~duration_ms ~error_body:body)
  in
  Audit_log.log_tool_call (Mcp_server.workspace_config state)
    ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success ~error_msg:error_detail ();
  if not success then
    Log.Keeper.emit Log.Error
      ~details:
        (keeper_tool_failure_log_details ~tool_name:"masc_keeper_msg"
           ~agent_name ~duration_ms ~streaming:false ~error_body:body
           ~failure_class)
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
           let telemetry_failure_class =
             if success then None else Some failure_class
           in
           Telemetry_eio.track_tool_called ~fs (Mcp_server.workspace_config state)
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success ~duration_ms
             ~source:(Tool_registry.string_of_source Agent_internal)
             ?failure_class:telemetry_failure_class
             ?error_kind:telemetry_error_kind ?error_message:error_detail ()
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
      let raw_message =
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
      let turn_instructions =
        match Json_util.get_string json "turn_instructions" with
        | None -> None
        | Some s ->
            let s = String.trim s in
            if s = "" then None else Some s
      in
      let surface_context : Yojson.Safe.t option =
        match Json_util.assoc_member_opt "surface_context" json with
        | Some (`Assoc _ as obj) -> Some obj
        | Some `Null | None -> None
        | Some _ -> None
      in
      let has_connector_context =
        channel <> "" || channel_user_id <> ""
        || channel_user_name <> "" || channel_workspace_id <> ""
      in
      let timeout_sec =
        match Json_util.assoc_member_opt "timeout_sec" json with
        | None | Some `Null -> Ok None
        | Some (`Int value) when value > 0 ->
            Ok (Some (clamp_keeper_msg_timeout_sec value))
        | Some (`Float value) when value > 0.0 ->
            (* int_of_float is unspecified (not exception-raising) for
               out-of-range floats (e.g. 1e300, infinity); clamp_keeper_msg_timeout_sec
               below bounds whatever int comes out into [5, 300] regardless. *)
            Ok (Some (clamp_keeper_msg_timeout_sec (int_of_float (Float.ceil value))))
        | Some (`Int _) | Some (`Float _) -> Ok None
        | Some _ -> Error "timeout_sec must be a positive number"
      in
      let attachments = Keeper_multimodal_input.parse_attachments json in
      let user_blocks_result = Keeper_multimodal_input.parse_user_blocks json in
      let message_of_blocks user_blocks =
        match raw_message with
        | "" ->
            Keeper_multimodal_input.fallback_message ~attachments user_blocks
        | message -> message
      in
      if name = "" then
        Error "name is required"
      else if has_connector_context
              && (channel = "" || channel_workspace_id = "")
      then
        Error
          "channel and channel_workspace_id are required when connector context is supplied"
      else
        match
          Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_msg" json
        with
        | Error err -> Error err
        | Ok () -> (
          match user_blocks_result, timeout_sec with
          | Error err, _ -> Error err
          | Ok _, Error err -> Error err
          | Ok user_blocks, Ok timeout_sec ->
              let message = message_of_blocks user_blocks in
              if message = "" then
                Error "message is required"
              else
              Ok
                {
                  name;
                  message;
                  user_blocks;
                  timeout_sec;
                  turn_instructions;
                  surface_context;
                  channel;
                  channel_user_id;
                  channel_user_name;
                  channel_workspace_id;
                  attachments;
                  (* RFC-0320 W2b: this HTTP parse path is fail-closed to
                     [Unrouted]. External-connector requests carry only flat
                     strings that cannot be reconstructed into the typed variant
                     without a forbidden content classifier. Dashboard-origin
                     requests on the idle/direct run_now branch COULD derive a
                     typed Dashboard channel from the structural [not
                     has_external_speaker] predicate, but the dashboard
                     re-engagement thread-id convention is not yet pinned (the
                     busy path stamps ["keeper-consumer:" ^ name], the SSE stream
                     ["keeper:" ^ name], and no consumer validates either).
                     Capturing it here now would add a third unvalidated
                     placeholder, so idle-path Dashboard capture is deferred to
                     W3, where the routing target is defined. Known asymmetry
                     with the busy chat-queue path, not an oversight. *)
                  continuation_channel =
                    Keeper_continuation_channel.unrouted
                      "http chat request: typed connector deferred to RFC-0320 W3";
                }
          )
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
        i - !start >= keeper_reply_chunk_hard_wrap_chars
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

let notify_closed on_closed =
  match on_closed with
  | None -> ()
  | Some f -> f ()

let mark_closed ?on_closed closed =
  if not !closed then begin
    closed := true;
    notify_closed on_closed
  end

let keeper_stream_send_raw ?on_closed writer mutex closed data =
  if !closed || Httpun.Body.Writer.is_closed writer then begin
    mark_closed ?on_closed closed;
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
      mark_closed ?on_closed closed;
      false

let keeper_stream_send_event ?on_closed writer mutex closed event =
  keeper_stream_send_raw ?on_closed writer mutex closed (Ag_ui.event_to_sse event)

(** Execute keeper dispatch with real-time streaming.
    Calls [dispatch_stream] which forwards MODEL text deltas to [on_text_delta].
    Projects the typed keeper result into the local HTTP stream response pair.
    No external timeout — keeper internal limits control duration
    (aligned with MCP path, see mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool_streaming ~sw ~clock ?auth_token:_ ?on_event state
    ~agent_name ~arguments ~on_text_delta =
  let start_time = Eio.Time.now clock in
  let success, body, failure_class =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config = (Mcp_server.workspace_config state);
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match
        Keeper_tool_surface.dispatch_stream ~on_text_delta ?on_event keeper_ctx
          ~name:"masc_keeper_msg" ~args:arguments
      with
      | Some result ->
          let success = Tool_result.is_success result in
          let body = Tool_result.message result in
          let failure_class =
            match Tool_result.failure_class result with
            | Some cls -> cls
            | None -> Tool_result.Runtime_failure
          in
          success, body, failure_class
      | None -> false, "masc_keeper_msg stream dispatch unavailable", Tool_result.Runtime_failure
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        ( false,
          Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized),
          Tool_result.Runtime_failure )
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed (stream): %s" err;
        false, Printf.sprintf "Internal error: %s" err, Tool_result.Runtime_failure
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
  let error_detail =
    if success then None
    else Some (keeper_tool_failure_error_detail ~duration_ms ~error_body:body)
  in
  Audit_log.log_tool_call (Mcp_server.workspace_config state) ~agent_id:agent_name
    ~tool_name:"masc_keeper_msg" ~success ~error_msg:error_detail ();
  if not success then
    Log.Keeper.emit Log.Error
      ~details:
        (keeper_tool_failure_log_details ~tool_name:"masc_keeper_msg"
           ~agent_name ~duration_ms ~streaming:true ~error_body:body
           ~failure_class)
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
           let telemetry_failure_class =
             if success then None else Some failure_class
           in
           Telemetry_eio.track_tool_called ~fs (Mcp_server.workspace_config state)
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success
             ~duration_ms ~source:(Tool_registry.string_of_source Agent_internal)
             ?failure_class:telemetry_failure_class
             ?error_kind:telemetry_error_kind ?error_message:error_detail ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ());
  Tool_registry.record_call_if_known ~source:Agent_internal
    ~tool_name:"masc_keeper_msg" ~success ~duration_ms ();
  (success, body)

let execute_keeper_stream_tool_streaming_if_free ~sw ~clock ?auth_token:_ ?on_event state
    ~agent_name ~arguments ~on_text_delta =
  let start_time = Eio.Time.now clock in
  let outcome =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config = (Mcp_server.workspace_config state);
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
        }
      in
      match
        Keeper_turn.handle_keeper_msg_if_free ~on_text_delta ?on_event keeper_ctx
          arguments
      with
      | `Busy rejection -> `Busy rejection
      | `Ran result ->
          let success = Tool_result.is_success result in
          let body = Tool_result.message result in
          let failure_class =
            match Tool_result.failure_class result with
            | Some cls -> cls
            | None -> Tool_result.Runtime_failure
          in
          `Ran (success, body, failure_class)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        `Ran
          ( false
          , Masc_domain.masc_error_to_string
              (Masc_domain.System Masc_domain.System_error.NotInitialized)
          , Tool_result.Runtime_failure )
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed (stream if-free): %s" err;
        `Ran (false, Printf.sprintf "Internal error: %s" err, Tool_result.Runtime_failure)
  in
  match outcome with
  | `Busy rejection -> `Busy rejection
  | `Ran (success, body, failure_class) ->
      let end_time = Eio.Time.now clock in
      let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
      let error_detail =
        if success then None
        else Some (keeper_tool_failure_error_detail ~duration_ms ~error_body:body)
      in
      Audit_log.log_tool_call (Mcp_server.workspace_config state)
        ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success
        ~error_msg:error_detail ();
      if not success then
        Log.Keeper.emit Log.Error
          ~details:
            (keeper_tool_failure_log_details ~tool_name:"masc_keeper_msg"
               ~agent_name ~duration_ms ~streaming:true ~error_body:body
               ~failure_class)
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
               let telemetry_failure_class =
                 if success then None else Some failure_class
               in
               Telemetry_eio.track_tool_called ~fs
                 (Mcp_server.workspace_config state)
                 ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success
                 ~duration_ms ~source:(Tool_registry.string_of_source Agent_internal)
                 ?failure_class:telemetry_failure_class
                 ?error_kind:telemetry_error_kind ?error_message:error_detail ()
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Misc.error "telemetry tracking failed: %s"
                 (Printexc.to_string exn))
        | None -> ());
      Tool_registry.record_call_if_known ~source:Agent_internal
        ~tool_name:"masc_keeper_msg" ~success ~duration_ms ();
      `Ran (success, body)

(** Send a Run_error AG-UI event with the given message. *)
let send_keeper_error ?on_closed writer mutex closed ~thread_id ~run_id err =
  ignore
    (keeper_stream_send_event ?on_closed writer mutex closed
       Ag_ui.(
         make_event ~thread_id ~run_id:(Some run_id)
           ~custom_name:(Some "KEEPER_CHAT_ERROR")
           ~custom_value:(Some (`Assoc [ ("message", `String err) ]))
           Run_error))

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
        let visible = strip_keeper_visible_reply reply_raw in
        if visible = "" then
          match payload_json with
          | `String s -> strip_keeper_visible_reply s
          | _ -> ""
        else visible
    | None ->
        let visible = strip_keeper_visible_reply body in
        visible
  in
  (payload_json_opt, visible_reply)

let persisted_error_reply err =
  let detail =
    match String.trim err with
    | "" -> "unknown error"
    | trimmed -> trimmed
  in
  "Keeper request failed: " ^ detail

let empty_direct_reply_error =
  "Keeper completed without a visible reply; the runtime returned only thinking or internal state."

let direct_reply_terminal_error ?(has_visible_blocks = false) payload_json_opt visible_reply =
  let turn_outcome = Keeper_turn_outcome.of_reply_payload payload_json_opt in
  match (turn_outcome, String_util.trim_to_option visible_reply, has_visible_blocks) with
  | Keeper_turn_outcome.Continuation_checkpoint, _, _ -> None
  | Keeper_turn_outcome.No_visible_reply, _, true -> None
  | Keeper_turn_outcome.Visible_reply, None, true -> None
  | Keeper_turn_outcome.No_visible_reply, _, false -> Some empty_direct_reply_error
  | Keeper_turn_outcome.Visible_reply, None, false -> Some empty_direct_reply_error
  | Keeper_turn_outcome.Visible_reply, Some _, _ -> None

let visible_reply_with_stream_fallback ~streamed_text visible_reply =
  match String.trim visible_reply with
  | "" -> String.trim streamed_text
  | visible_reply -> visible_reply

let redacted_visible_reply_with_stream_fallback ~redact ~streamed_text visible_reply =
  visible_reply_with_stream_fallback ~streamed_text visible_reply |> redact

let assoc_replace key value fields =
  (key, value)
  :: List.filter (fun (field_key, _) -> not (String.equal field_key key)) fields

let reply_payload_with_streamed_visible_reply payload_json_opt ~visible_reply
    ~streamed_text_present =
  match String_util.trim_to_option visible_reply with
  | None -> payload_json_opt
  | Some visible_reply -> (
      match Keeper_turn_outcome.of_reply_payload payload_json_opt with
      | Keeper_turn_outcome.Continuation_checkpoint -> payload_json_opt
      | Keeper_turn_outcome.No_visible_reply when not streamed_text_present ->
          payload_json_opt
      | Keeper_turn_outcome.No_visible_reply
      | Keeper_turn_outcome.Visible_reply -> (
          match payload_json_opt with
          | Some (`Assoc fields) ->
              let fields =
                assoc_replace "reply" (`String visible_reply) fields
              in
              let fields =
                assoc_replace Keeper_turn_outcome.wire_key
                  (`String
                    (Keeper_turn_outcome.to_label
                       Keeper_turn_outcome.Visible_reply))
                  fields
              in
              Some (`Assoc fields)
          | Some _ | None -> payload_json_opt))

let body_with_rewritten_payload ~fallback payload_json_opt =
  match payload_json_opt with
  | Some (`Assoc _ as payload_json) -> Yojson.Safe.to_string payload_json
  | Some _ | None -> fallback

let keeper_request_terminal_payload ~request_id ~keeper_name ~status ~ok
    ?(message = "") () =
  let fields =
    [
      ("request_id", `String request_id);
      ("keeper_name", `String keeper_name);
      ("status", `String status);
      ("ok", `Bool ok);
    ]
  in
  let fields =
    if String.trim message = "" then fields
    else ("message", `String message) :: fields
  in
  `Assoc fields

type keeper_stream_worker_event =
  | Stream_event of Agent_sdk.Types.sse_event
  | Stream_client_disconnected
  | Stream_dashboard_queued of dashboard_deferred_chat
  | Stream_terminal of
      { ok : bool
      ; status : string
      ; body : string
      }

type keeper_stream_bridge_state = Keeper_chat_oas_stream_bridge.state

type translated_keeper_stream_event =
  Keeper_chat_oas_stream_bridge.translated_event =
  { bridge_state : keeper_stream_bridge_state
  ; chat_events : Keeper_chat_events.keeper_chat_event list
  }

let empty_keeper_stream_bridge_state = Keeper_chat_oas_stream_bridge.empty_state
let translate_oas_stream_event = Keeper_chat_oas_stream_bridge.translate

(* [connector_user_line_recorded_upstream] is a required labelled argument: the
   function ends in labelled args with no positional terminator, so a leading
   optional could not be erased (warning 16). Every caller states explicitly
   whether the gate inbound boundary already owns the user line. *)
let process_single_turn ~connector_user_line_recorded_upstream
    ~state ~clock ~sw ~auth_token ~thread_id ~closed
    ~client_disconnects
    ~payload ~run_id ~message_id ~agent_name
    ~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t) =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let redaction =
    Keeper_secret_redaction.snapshot ~base_path ~keeper_name:payload.name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let redact_json = Keeper_secret_redaction.redact_json redaction in
  Keeper_chat_events.publish events
    (Run_started { run_id; thread_id });
  Keeper_chat_events.publish events
    (Text_message_start { message_id; role = Assistant });
  let completed_stream_lifecycle =
    [ Keeper_chat_store.Run_started
    ; Keeper_chat_store.Text_message_start
    ; Keeper_chat_store.Text_message_end
    ; Keeper_chat_store.Run_finished
    ]
  in
  let errored_stream_lifecycle =
    [ Keeper_chat_store.Run_started
    ; Keeper_chat_store.Text_message_start
    ; Keeper_chat_store.Text_message_end
    ; Keeper_chat_store.Run_error
    ]
  in
  let args = args_of_request payload in
  (* Stream model text deltas live with per-delta redaction — the same
     treatment ThinkingDelta and Tool_call_args already get in
     [consume_worker_events]. The once-only invariant (live emit + terminal
     re-send suppression + raw fallback) is owned by
     [Keeper_stream_text_accum]; see its interface for the #20825/#20854/
     #20869 history this guards against. *)
  let text_accum = Keeper_stream_text_accum.create () in
  let worker_events = Eio.Stream.create worker_events_buffer_size in
  let terminal_pushed = Atomic.make false in
  let client_disconnected = Atomic.make false in
  let stream_projection_done, stream_projection_done_resolver =
    Eio.Promise.create ()
  in
  let signal_stream_projection_done () =
    (* fire-and-forget: completion is idempotent and may race disconnect cleanup. *)
    ignore (Eio.Promise.try_resolve stream_projection_done_resolver () : bool)
  in
  let push_worker_event event =
    match event with
    | Stream_dashboard_queued _ | Stream_terminal _ ->
        if Atomic.compare_and_set terminal_pushed false true then
          (try Eio.Stream.add worker_events event
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn
                 "keeper_stream: worker terminal push failed: %s"
                 (Printexc.to_string exn))
    | Stream_client_disconnected ->
        (try Eio.Stream.add worker_events event
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn
               "keeper_stream: client-disconnect push failed: %s"
               (Printexc.to_string exn))
    | Stream_event _ ->
        if not !closed then
          try Eio.Stream.add worker_events event
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn
                "keeper_stream: worker event push failed: %s"
                (Printexc.to_string exn)
  in
  (* RFC-0232 P5: the typed surface is the write-side truth; the label
     [chat_source] is its derivation, used for broadcast metadata. *)
  let chat_surface = chat_surface_of_request payload in
  let chat_source = Surface_ref.lane_label chat_surface in
  (* RFC-0223 P1: authority derives from the arrival route. A non-empty
     [channel_user_id] means an arbitrary external person on that channel;
     a channel label without a user id (e.g. dashboard Copilot Dock) is
     still an authenticated dashboard operator, so it keeps Owner authority
     while recording the Gate surface label. *)
  let chat_speaker : Keeper_chat_store.speaker = chat_speaker_of_request payload in
  let worker_text_accum = Keeper_stream_text_accum.create () in
  (* RFC-0301 item 6: collect generated media from the same stream so the assistant
     turn can persist it as reload-visible chat blocks. The bridge surfaces this
     media live over SSE; the persist site records it durably (see the persist arm
     below). Content-addressed, so the two persists reuse one file. *)
  let worker_media_accum = Keeper_stream_media_accum.create () in
  let on_event evt =
    (match evt with
     | Agent_sdk.Types.ContentBlockDelta
         { delta = Agent_sdk.Types.TextDelta text; _ } ->
         ignore
           (Keeper_stream_text_accum.on_delta worker_text_accum ~redact:redact_text text
            : string)
     | _ -> ());
    Keeper_stream_media_accum.on_event worker_media_accum evt;
    push_worker_event (Stream_event evt)
  in
  let persist_user_message_only () =
    (* RFC-connector-deferred-reply-via-chat-queue §3.4: when the gate inbound boundary already recorded this
       connector user line (Discord/Slack busy message enqueued onto the chat
       queue), re-recording it here would double-write. The gate inbound line is
       assistant-less, so the message is already "pending" — nothing to add. *)
    if not connector_user_line_recorded_upstream then
      Keeper_chat_store.append_user_message
        ~base_dir:base_path
        ~keeper_name:payload.name
        ~content:payload.message
        ~attachments:payload.attachments
        ~surface:chat_surface
        ~speaker:chat_speaker
        ()
  in
  let persist_failure_reply err =
    (* The failure marker is typed, not an utterance: it renders for the
       operator but does not advance the lane watermark, so the user
       message it failed to answer stays pending for the keeper's next
       turn — and the keeper never reads the error as its own words. *)
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatTransportFailures)
      ~labels:[ ("keeper", payload.name); ("source", chat_source) ]
      ();
    (* RFC-connector-deferred-reply-via-chat-queue §3.4: the failure must be
       DURABLE on both paths — a post-ACK deferred turn that fails must not
       vanish on restart/replay (counter + live broadcast alone is silent
       failure under this feature's "queued, will answer" contract).
       - Dashboard route ([recorded_upstream = false]): the turn owns the user
         line, so record the paired [Transport_failure] row (user message stays
         pending for the next turn; keeper never reads the error as its words).
       - Connector route ([recorded_upstream = true]): the gate inbound boundary
         already persisted the user line (assistant-less). The paired
         [append_turn] would double-record that user line, so persist an
         assistant-only durable failure marker instead — the failure survives a
         restart and stays joined to the already-pending user line. *)
    (if connector_user_line_recorded_upstream then
       Keeper_chat_store.append_assistant_message
         ~base_dir:base_path
         ~keeper_name:payload.name
         ~content:(persisted_error_reply err)
         ~surface:chat_surface
         ~stream_lifecycle:errored_stream_lifecycle
         ()
     else
       Keeper_chat_store.append_turn
         ~base_dir:base_path
         ~keeper_name:payload.name
         ~user_content:payload.message
         ~user_attachments:payload.attachments
         ~surface:chat_surface
         ~speaker:chat_speaker
         ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
         ~assistant_content:(persisted_error_reply err)
         ~stream_lifecycle:errored_stream_lifecycle
         ());
    Keeper_chat_broadcast.chat_appended
      ~keeper_name:payload.name ~source:chat_source
      ~content:(persisted_error_reply err)
      ()
  in
  let timeout_sec = Option.map float_of_int payload.timeout_sec in
  let dashboard_direct_stream =
    (not connector_user_line_recorded_upstream) && not (has_external_speaker payload)
  in
  let request_id =
    Keeper_msg_async.submit ?timeout_sec ~clock ~sw
      ~base_path
      ~keeper_name:payload.name
      ~f:(fun () ->
        let start_time = Time_compat.now () in
        let dispatch_result =
          try
            if dashboard_direct_stream then
              match
                execute_keeper_stream_tool_streaming_if_free ~sw ~clock
                  ?auth_token
                  state ~agent_name ~arguments:args ~on_event
                  ~on_text_delta:(fun _ -> ())
              with
              | `Ran result -> Ok (`Ran result)
              | `Busy rejection ->
                  let queued =
                    dashboard_deferred_chat_of_rejection ~clock payload rejection
                  in
                  push_worker_event (Stream_dashboard_queued queued);
                  Ok (`Queued queued)
            else
              Ok
                (`Ran
                   (execute_keeper_stream_tool_streaming ~sw ~clock
                      ?auth_token
                      state ~agent_name ~arguments:args ~on_event
                      ~on_text_delta:(fun _ -> ())))
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn
                "keeper_stream: streaming dispatch raised: %s"
                (Printexc.to_string exn);
              if dashboard_direct_stream then Error (Printexc.to_string exn)
              else
                (try
                   Ok
                     (`Ran
                        (execute_keeper_stream_tool ~sw ~clock
                           ?auth_token
                           state ~agent_name ~arguments:args))
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn2 -> Error (Printexc.to_string exn2))
        in
        match dispatch_result with
        | Ok (`Queued queued) ->
            Tool_result.ok
              ~tool_name:"masc_keeper_msg"
              ~start_time
              (Yojson.Safe.to_string
                 (dashboard_deferred_chat_to_json ~keeper_name:payload.name queued))
        | Ok (`Ran (true, body)) ->
            let payload_json_opt, visible_reply = extract_visible_reply body in
            let streamed_text =
              Keeper_stream_text_accum.streamed_text worker_text_accum
            in
            let streamed_text_present =
              Option.is_some (String_util.trim_to_option streamed_text)
            in
            let visible_reply =
              redacted_visible_reply_with_stream_fallback
                ~redact:redact_text
                ~streamed_text
                visible_reply
            in
            let payload_json_opt =
              reply_payload_with_streamed_visible_reply payload_json_opt
                ~visible_reply ~streamed_text_present
            in
            let body =
              body_with_rewritten_payload ~fallback:body payload_json_opt
            in
            (* RFC-0233 §7: the keeper minted this turn's join key into the
               reply payload (keeper_turn.ml). Decode it via the shared
               reply-payload parser — never repair: a malformed or absent
               value reads as None and the row simply carries no turn_ref. *)
            let turn_ref =
              Keeper_turn_outcome.turn_ref_of_reply_payload payload_json_opt
            in
            let visible_reply = String.trim visible_reply in
            (* RFC-0301 item 6: attach any generated media (accumulated from
               this turn's stream) as reload-visible chat blocks so a dashboard
               reload shows media-only replies too, not just text-bearing
               replies. *)
            let blocks =
              match
                Keeper_stream_media_accum.to_chat_blocks ~base_dir:base_path
                  worker_media_accum
              with
              | [] -> None
              | media_blocks -> Some media_blocks
            in
            let has_visible_blocks = Option.is_some blocks in
            (match
               direct_reply_terminal_error ~has_visible_blocks payload_json_opt
                 visible_reply
             with
             | Some err ->
                 persist_failure_reply err;
                 push_worker_event
                   (Stream_terminal { ok = false; status = "error"; body = err });
                 Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err
             | None ->
                 let persist_assistant_reply ~assistant_content =
                   if connector_user_line_recorded_upstream then
                     Keeper_chat_store.append_assistant_message
                       ~base_dir:base_path
                       ~keeper_name:payload.name
                       ~content:assistant_content
                       ~surface:chat_surface
                       ?blocks
                       ?turn_ref
                       ~stream_lifecycle:completed_stream_lifecycle
                       ()
                   else
                     Keeper_chat_store.append_turn
                       ~base_dir:base_path
                       ~keeper_name:payload.name
                       ~user_content:payload.message
                       ~user_attachments:payload.attachments
                       ~surface:chat_surface
                       ~speaker:chat_speaker
                       ~assistant_content
                       ?blocks
                       ?turn_ref
                       ~stream_lifecycle:completed_stream_lifecycle
                       ()
                 in
                 let broadcast_chat_appended ?content () =
                   Keeper_chat_broadcast.chat_appended
                     ~keeper_name:payload.name ~source:chat_source ?content ()
                 in
                 (match
                    ( Keeper_turn_outcome.of_reply_payload payload_json_opt,
                      String_util.trim_to_option visible_reply )
                  with
                 | Keeper_turn_outcome.Continuation_checkpoint, _ ->
                     persist_user_message_only ()
                 | Keeper_turn_outcome.No_visible_reply, _
                 | Keeper_turn_outcome.Visible_reply, None ->
                     if has_visible_blocks then (
                       persist_assistant_reply ~assistant_content:"";
                       broadcast_chat_appended ())
                     else persist_user_message_only ()
                 | Keeper_turn_outcome.Visible_reply, Some visible_reply ->
                     (* RFC-connector-deferred-reply-via-chat-queue §3.4: gate-recorded connector message → the user
                        line is already persisted at the gate inbound boundary,
                        so pair the reply by appending the assistant line only
                        (mirrors [append_direct_chat_pair_if_reply]'s connector
                        arm). The dashboard route records the full pair. *)
                     persist_assistant_reply ~assistant_content:visible_reply;
                     broadcast_chat_appended ~content:visible_reply ());
                 push_worker_event
                   (Stream_terminal { ok = true; status = "done"; body });
                 Tool_result.ok ~tool_name:"masc_keeper_msg" ~start_time body)
        | Ok (`Ran (false, err)) ->
            persist_failure_reply err;
            push_worker_event (Stream_terminal { ok = false; status = "error"; body = err });
            Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err
        | Error err ->
            persist_failure_reply err;
            push_worker_event (Stream_terminal { ok = false; status = "error"; body = err });
            Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err)
      ()
  in
  (match client_disconnects with
   | None -> ()
   | Some (disconnect_sw, disconnects) ->
       Eio.Fiber.fork ~sw:disconnect_sw (fun () ->
         match
           Eio.Fiber.first
             (fun () ->
               Eio.Stream.take disconnects;
               `Client_disconnected)
             (fun () ->
               Eio.Promise.await stream_projection_done;
               `Projection_done)
         with
         | `Projection_done -> ()
         | `Client_disconnected ->
             if not (Atomic.get terminal_pushed) then begin
               Atomic.set client_disconnected true;
               Log.Keeper.info
                 "keeper_stream: client disconnected keeper=%s request_id=%s; request continues for polling"
                 payload.name request_id;
               push_worker_event Stream_client_disconnected
             end));
  Log.Keeper.info
    "keeper_stream: queued request keeper=%s request_id=%s surface=%s"
    payload.name request_id
    (if has_connector_context payload then payload.channel else "dashboard");
  Keeper_chat_events.publish events
    (Custom
       { name = "KEEPER_QUEUE_REQUEST";
         value =
           Gate_protocol.message_request_to_json
             { request_id;
               destination_type = "keeper";
               destination_id = payload.name;
               channel =
                 (if has_connector_context payload then payload.channel
                  else "dashboard");
               actor_id = Some agent_name;
               status = Gate_protocol.Queued;
               modalities = modalities_for_request payload;
               transport = Some "sse";
               metadata =
                 [
                   ("projection", "keeper_chat_stream");
                   ("protocol", "gate_message_request");
                 ];
             }
       });
  let publish_terminal ~status ~ok ?(message = "") () =
    let message = redact_text message in
    let payload_json =
      keeper_request_terminal_payload ~request_id ~keeper_name:payload.name
        ~status ~ok ~message ()
    in
    if ok || String.equal status "cancelled" then
      Log.Keeper.info
        "keeper_stream: request terminal keeper=%s request_id=%s status=%s"
        payload.name request_id status
    else
      Log.Keeper.warn
        "keeper_stream: request terminal keeper=%s request_id=%s status=%s message=%s"
        payload.name request_id status message;
      Keeper_chat_events.publish events
        (Custom { name = "KEEPER_REQUEST_TERMINAL"; value = payload_json })
  in
  let rec consume_worker_events bridge_state =
    if Atomic.get client_disconnected then ()
    else match Eio.Stream.take worker_events with
    | Stream_client_disconnected -> ()
    | Stream_event evt ->
        let translated =
          translate_oas_stream_event ~redact_text
            ~on_text_delta:
              (Keeper_stream_text_accum.on_delta text_accum ~redact:redact_text)
            ~base_dir:base_path bridge_state evt
        in
        List.iter (Keeper_chat_events.publish events) translated.chat_events;
        consume_worker_events translated.bridge_state
    | Stream_dashboard_queued queued ->
        let message = dashboard_deferred_ack_text ~keeper_name:payload.name in
        publish_terminal ~status:"queued" ~ok:true ~message ();
        Keeper_chat_events.publish events (Text_delta message);
        Keeper_chat_events.publish events
          (Custom
             { name = "KEEPER_CHAT_QUEUED";
               value = dashboard_deferred_chat_to_json ~keeper_name:payload.name queued
             });
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id })
    | Stream_terminal { ok = false; status = "cancelled"; body = message } ->
        let message = redact_text message in
        publish_terminal ~status:"cancelled" ~ok:false ~message ();
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id })
    | Stream_terminal { ok = false; status; body = err } ->
        let err = redact_text err in
        publish_terminal ~status ~ok:false ~message:err ();
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Event_error { message = err })
    | Stream_terminal { ok = true; body; _ } -> (
        try
          let payload_json_opt, visible_reply = extract_visible_reply body in
          let visible_reply =
            match String.trim visible_reply with
            | "" ->
                let streamed =
                  Keeper_stream_text_accum.streamed_text text_accum |> String.trim
                in
                if streamed = "" then visible_reply else streamed
            | _ -> visible_reply
          in
          let visible_reply = redact_text visible_reply in
          let turn_outcome =
            Keeper_turn_outcome.of_reply_payload payload_json_opt
          in
          let suppress_terminal_reply =
            match turn_outcome with
            | Keeper_turn_outcome.Continuation_checkpoint
            | Keeper_turn_outcome.No_visible_reply ->
                true
            | Keeper_turn_outcome.Visible_reply -> false
          in
          if
            (not suppress_terminal_reply)
            && not (Keeper_stream_text_accum.suppress_terminal_resend text_accum)
          then
            split_keeper_reply_chunks visible_reply
            |> List.iter (fun chunk ->
                   Keeper_chat_events.publish events (Text_delta chunk));
          (match payload_json_opt with
           | Some payload_json ->
               Keeper_chat_events.publish events
                 (Custom
                    { name = "KEEPER_REPLY_DETAILS";
                      value = redact_json payload_json })
           | None -> ());
          if
            Keeper_turn_outcome.equal turn_outcome
              Keeper_turn_outcome.Continuation_checkpoint
          then
            Keeper_chat_events.publish events
              (Custom
                 { name = "KEEPER_CONTINUATION_CHECKPOINT";
                   value =
                     `Assoc
                       [ ("request_id", `String request_id);
                         ("message", `String visible_reply) ]
                 });
          publish_terminal ~status:"done" ~ok:true ();
          Keeper_chat_events.publish events Text_message_end;
          Keeper_chat_events.publish events (Run_finished { run_id })
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            let message = redact_text (Printexc.to_string exn) in
            publish_terminal ~status:"error" ~ok:false ~message ();
            Keeper_chat_events.publish events Text_message_end;
            Keeper_chat_events.publish events
              (Event_error { message }))
  in
  match consume_worker_events empty_keeper_stream_bridge_state with
  | () -> signal_stream_projection_done ()
  | exception exn ->
      signal_stream_projection_done ();
      raise exn

let keeper_chat_stream_headers origin =
  Httpun.Headers.of_list
    ([
       ("content-type", "text/event-stream");
       ("cache-control", "no-cache");
       (* This route is a per-turn SSE response. Httpun does not add a
          Content-Length for streaming bodies, so the terminal delimiter is the
          writer close; advertising keep-alive makes clients wait for a
          response end that cannot be framed. *)
       ("connection", "close");
       ("x-accel-buffering", "no");
     ]
    @ cors_headers origin)

let handle_keeper_chat_stream ~sw ~clock state request reqd payload =
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:(Mcp_server.workspace_config state).base_path
      ~keeper_name:payload.name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let redact_json = Keeper_secret_redaction.redact_json redaction in
  let origin = get_origin request in
  let headers = keeper_chat_stream_headers origin in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let client_disconnects = Eio.Stream.create 1 in
  let disconnect_notified = ref false in
  let notify_disconnect () =
    if not !disconnect_notified then begin
      disconnect_notified := true;
      Eio.Stream.add client_disconnects ()
    end
  in
  let close_stream () =
    if not !closed then begin
      closed := true;
      (* Catch all exceptions including Cancelled — this function is called
         from Switch.on_release where re-raising would mask the original exn. *)
      (try Httpun.Body.Writer.close writer
       with exn ->
         Log.Misc.warn "keeper_stream writer close: %s"
           (Printexc.to_string exn))
    end
  in
  let now_id () = int_of_float (Time_compat.now () *. 1000.0) in
  let thread_id = "keeper:" ^ payload.name in

  let sse_adapter_loop ~events ~writer ~mutex ~closed ~on_closed ~on_finished =
    let current_thread_id = ref Ag_ui.default_thread_id in
    let current_run_id = ref None in
    let current_message_id = ref None in
    let ag_role (role : Keeper_chat_events.role) =
      match role with
      | Keeper_chat_events.User -> Ag_ui.User
      | Keeper_chat_events.Assistant -> Ag_ui.Assistant
    in
    let send_error message =
      let message = redact_text message in
      match !current_run_id with
      | Some run_id ->
          send_keeper_error ~on_closed writer mutex closed
            ~thread_id:!current_thread_id ~run_id message
      | None ->
          ignore
            (keeper_stream_send_event ~on_closed writer mutex closed
               Ag_ui.(
                 make_event ~thread_id:!current_thread_id
                   ~custom_name:(Some "KEEPER_CHAT_ERROR")
                   ~custom_value:(Some (`Assoc [ ("message", `String message) ]))
                   Run_error))
    in
    let json_opt key value =
      match value with
      | None -> []
      | Some value -> [ (key, value) ]
    in
    let send_custom name value =
      keeper_stream_send_event ~on_closed writer mutex closed
        Ag_ui.(
          make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
            ~custom_name:(Some name)
            ~custom_value:(Some (redact_json value))
            Custom)
    in
    let rec loop () =
      if not !closed then
        match Keeper_chat_events.subscribe events with
        | Run_started { run_id; thread_id } ->
            current_thread_id := thread_id;
            current_run_id := Some run_id;
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(make_event ~thread_id ~run_id:(Some run_id) Run_started)
            then loop ()
        | Text_message_start { message_id; role } ->
            current_message_id := Some message_id;
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~message_id:(Some message_id) ~role:(Some (ag_role role))
                    Text_message_start)
            then loop ()
        | Text_delta text ->
            (* [text] is already redacted at ingest — streaming tokens via
               [Keeper_stream_text_accum.on_delta ~redact:redact_text] and
               terminal-reply chunks split from a whole-redacted
               [visible_reply].  Re-redacting here doubled the per-token
               regex cost with no effect (redact is idempotent on already-
               redacted text).  Do not re-redact. *)
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~message_id:!current_message_id
                    ~delta:(Some text)
                    Text_message_content)
            then loop ()
        | Text_message_end ->
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~message_id:!current_message_id Text_message_end)
            then loop ()
        | Oas_stream_connected ->
            if send_custom "KEEPER_CONNECTED" `Null then loop ()
        | Oas_stream_message_start { provider_message_id; model; usage } ->
            let value =
              `Assoc
                ([
                   ("provider_message_id", `String provider_message_id);
                   ("model", `String model);
                 ]
                @ json_opt "usage"
                    (Option.map Keeper_chat_events.api_usage_to_json usage))
            in
            if send_custom "KEEPER_STREAM_MESSAGE_START" value then loop ()
        | Oas_stream_message_delta { stop_reason; usage } ->
            let value =
              `Assoc
                (json_opt "stop_reason"
                   (Option.map
                      (fun reason ->
                        `String (Agent_sdk.Types.stop_reason_to_string reason))
                      stop_reason)
                @ json_opt "usage"
                    (Option.map Keeper_chat_events.api_usage_to_json usage))
            in
            if send_custom "KEEPER_STREAM_MESSAGE_DELTA" value then loop ()
        | Oas_stream_message_stop ->
            if send_custom "KEEPER_STREAM_MESSAGE_STOP" `Null then loop ()
        | Oas_stream_ping ->
            if send_custom "KEEPER_STREAM_PING" `Null then loop ()
        | Oas_content_block_start
            { index; content_type; tool_call_id; tool_call_name } ->
            if
              send_custom "KEEPER_CONTENT_BLOCK_START"
                (`Assoc
                  ([
                     ("index", `Int index);
                     ("content_type", `String content_type);
                   ]
                  @ json_opt "tool_call_id"
                      (Option.map (fun value -> `String value) tool_call_id)
                  @ json_opt "tool_call_name"
                      (Option.map (fun value -> `String value) tool_call_name)))
            then loop ()
        | Oas_content_block_stop { index } ->
            if
              send_custom "KEEPER_CONTENT_BLOCK_STOP"
                (`Assoc [ ("index", `Int index) ])
            then loop ()
        | Oas_thinking_delta { index; delta } ->
            if
              send_custom "KEEPER_THINKING_DELTA"
                (`Assoc [ ("index", `Int index); ("delta", `String delta) ])
            then loop ()
        | Oas_thinking_signature_delta { index; signature_bytes } ->
            if
              send_custom "KEEPER_THINKING_SIGNATURE_DELTA"
                (`Assoc
                  [
                    ("index", `Int index);
                    ("signature_bytes", `Int signature_bytes);
                  ])
            then loop ()
        | Oas_media_delta { index; media_type; source_type; media_ref } ->
            (* RFC-0301: emit the reader-facing media URL so the dashboard can
               fetch + render the payload (GET /api/v1/media/<token>), replacing
               the pre-RFC byte count. *)
            if
              send_custom "KEEPER_MEDIA_DELTA"
                (`Assoc
                  [
                    ("index", `Int index);
                    ("media_type", `String media_type);
                    ( "source_type",
                      `String
                        (Agent_sdk.Types.media_source_kind_to_string source_type)
                    );
                    ("media_ref", `String media_ref);
                  ])
            then loop ()
        | Oas_stream_protocol_error error ->
            if
              send_custom "KEEPER_STREAM_PROTOCOL_ERROR"
                (Keeper_chat_events.stream_protocol_error_to_json error)
            then loop ()
        | Custom { name; value } ->
            if send_custom name value then loop ()
        | Tool_call_start { tool_call_id; tool_call_name } ->
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~tool_call_id:(Some tool_call_id) ~tool_call_name:(Some tool_call_name)
                    Tool_call_start)
            then loop ()
        | Tool_call_args { tool_call_id; delta } ->
            (* [delta] is already redacted at publish
               ([Tool_call_args { delta = redact_text args; _ }]).  *)
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~tool_call_id:(Some tool_call_id)
                    ~delta:(Some delta)
                    Tool_call_args)
            then loop ()
        | Tool_call_args_snapshot { tool_call_id; snapshot } ->
            (* [snapshot] is already redacted at publish. OAS
               [InputJsonSnapshot] is a whole replacement value, not an
               append fragment, so preserve that distinction on the wire. *)
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~tool_call_id:(Some tool_call_id)
                    ~snapshot:(Some (`String snapshot))
                    Tool_call_args)
            then loop ()
        | Tool_call_end { tool_call_id } ->
            if
              keeper_stream_send_event ~on_closed writer mutex closed
                Ag_ui.(
                  make_event ~thread_id:!current_thread_id ~run_id:!current_run_id
                    ~tool_call_id:(Some tool_call_id)
                    Tool_call_end)
            then loop ()
        | Link_block _ | Image_block _ | Audio_block _ | Tool_context_block _ ->
            (* Connector rich blocks are delivered by non-dashboard adapters;
               the SSE stream already receives the underlying text/audio
               through other events. *)
            loop ()
        | Event_error { message } -> send_error message
        | Run_finished { run_id } ->
            current_run_id := Some run_id;
            ignore
              (keeper_stream_send_event ~on_closed writer mutex closed
                 Ag_ui.(
                   make_event ~thread_id:!current_thread_id ~run_id:(Some run_id)
                     Run_finished))
    in
    match loop () with
    | () -> on_finished ()
    | exception exn ->
        on_finished ();
        raise exn
  in


  ignore
    (keeper_stream_send_raw ~on_closed:notify_disconnect writer mutex closed
       (Printf.sprintf "retry: %d\n\n" sse_dashboard_retry_backoff_ms));
  Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Eio.Switch.run @@ fun stream_sw ->
           Eio.Switch.on_release stream_sw close_stream;
           let has_external_actor = has_external_speaker payload in
           let agent_name =
             if has_external_actor then
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
           let events = Keeper_chat_events.create () in
           let adapter_finished, adapter_finished_resolver =
             Eio.Promise.create ()
           in
           let signal_adapter_finished () =
             (* fire-and-forget: the adapter-finished signal is idempotent. *)
             ignore (Eio.Promise.try_resolve adapter_finished_resolver () : bool)
           in
           Eio.Fiber.fork ~sw:stream_sw (fun () ->
             sse_adapter_loop ~events ~writer ~mutex ~closed
               ~on_closed:notify_disconnect ~on_finished:signal_adapter_finished);
           let base_path = (Mcp_server.workspace_config state).base_path in
           let wait_for_adapter_finished () =
             Eio.Promise.await adapter_finished
           in
           let run_now () =
             (* Dashboard stream route: no gate inbound boundary recorded this
                user line, so the turn owns recording both sides (RFC-connector-deferred-reply-via-chat-queue §3.4). *)
             process_single_turn ~connector_user_line_recorded_upstream:false
               ~state ~clock ~sw
               ~auth_token:(auth_token_from_request request)
               ~thread_id ~closed
               ~client_disconnects:(Some (stream_sw, client_disconnects))
               ~payload ~run_id ~message_id ~agent_name ~events;
             wait_for_adapter_finished ()
           in
           if has_external_speaker payload then run_now ()
           else
             match
               try defer_dashboard_payload_if_busy ~base_path ~clock payload
               with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn -> `Queue_error (Printexc.to_string exn)
             with
             | `Not_busy -> run_now ()
             | `Queued queued ->
                 Log.Keeper.info
                   "keeper_stream: deferred busy dashboard message keeper=%s queue_length=%d"
                   payload.name queued.queue_length;
                 Keeper_chat_events.publish events
                   (Run_started { run_id; thread_id });
                 Keeper_chat_events.publish events
                   (Text_message_start
                      { message_id; role = Keeper_chat_events.Assistant });
                 Keeper_chat_events.publish events
                   (Text_delta
                      (dashboard_deferred_ack_text ~keeper_name:payload.name));
                 Keeper_chat_events.publish events
                   (Custom
                      { name = "KEEPER_CHAT_QUEUED";
                        value =
                          dashboard_deferred_chat_to_json
                            ~keeper_name:payload.name queued
                 });
                 Keeper_chat_events.publish events Text_message_end;
                 Keeper_chat_events.publish events (Run_finished { run_id });
                 wait_for_adapter_finished ()
             | `Queue_error message ->
                 Log.Keeper.error
                   "keeper_stream: failed to defer busy dashboard message keeper=%s: %s"
                   payload.name message;
                 Keeper_chat_events.publish events
                   (Run_started { run_id; thread_id });
                 Keeper_chat_events.publish events
                   (Event_error
                      { message =
                          "keeper chat queue persistence failed: " ^ message
                      });
                 Keeper_chat_events.publish events (Run_finished { run_id });
                 wait_for_adapter_finished ();
           (* Queue drain is handled by Keeper_chat_consumer
              (started in server_bootstrap_loops). *)
           ))

(** Build routes for MCP server *)

module For_testing = struct
  let parse_request = parse_keeper_chat_stream_request
  let has_connector_context = has_connector_context
  let has_external_speaker = has_external_speaker
  let message_for_request = message_for_request
  let chat_surface_of_request = chat_surface_of_request
  let chat_speaker_of_request = chat_speaker_of_request
  let turn_instructions_for_request = turn_instructions_for_request
  let args_of_request = args_of_request
  let modalities_for_request = modalities_for_request
  let defer_dashboard_payload_if_busy ~base_path ~clock payload =
    match defer_dashboard_payload_if_busy ~base_path ~clock payload with
    | `Not_busy -> `Not_busy
    | `Queued queued -> `Queued queued.queue_length

  let extract_visible_reply = extract_visible_reply
  let direct_reply_terminal_error = direct_reply_terminal_error
  let visible_reply_with_stream_fallback = visible_reply_with_stream_fallback
  let redacted_visible_reply_with_stream_fallback =
    redacted_visible_reply_with_stream_fallback
  let reply_payload_with_streamed_visible_reply =
    reply_payload_with_streamed_visible_reply
  let format_surface_context = format_surface_context
  let surface_context_to_instructions = surface_context_to_instructions
  let empty_stream_bridge_state = empty_keeper_stream_bridge_state
  let translate_oas_stream_event = translate_oas_stream_event
  let keeper_tool_failure_log_details = keeper_tool_failure_log_details
  let keeper_chat_stream_headers = keeper_chat_stream_headers
end
