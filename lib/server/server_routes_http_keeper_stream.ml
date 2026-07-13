
open Server_auth

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

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
  turn_instructions : string option;
  surface_context : Yojson.Safe.t option;
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
  let fields = base_fields @ connector_fields in
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
  ; pending_count : int
  ; inflight_count : int
  ; receipt_id : string
  ; shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  ; queue_revision : int64
  }

let dashboard_busy_queue_state ~base_path ~keeper_name =
  let admission = Keeper_turn_admission.snapshot_for ~base_path ~keeper_name in
  let in_flight = admission.snapshot_in_flight in
  let chat_waiting = admission.snapshot_waiting > 0 in
  let shutdown_operation_id = admission.snapshot_shutdown_operation_id in
  let queue_waiting =
    if not (Keeper_chat_queue.persistence_configured ())
    then true
    else
      let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
      snapshot.load_errors <> []
      || snapshot.pending <> []
      || snapshot.inflight <> []
  in
  match in_flight, chat_waiting, queue_waiting, shutdown_operation_id with
  | None, false, false, None -> None
  | _ -> Some (in_flight, chat_waiting, shutdown_operation_id)

let dashboard_deferred_ack_text ~keeper_name deferred =
  match deferred.shutdown_operation_id with
  | Some operation_id ->
    Printf.sprintf
      "%s is stopping under operation %s; your message was durably accepted \
       (receipt_id=%s, pending_count=%d, inflight_count=%d) for the next active \
       lane. The Dashboard will track it through Pending, Inflight, and a \
       terminal Delivered or Failed state."
      keeper_name
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
      deferred.receipt_id
      deferred.pending_count
      deferred.inflight_count
  | None ->
    Printf.sprintf
      "%s is busy; your message was durably accepted (receipt_id=%s, \
       pending_count=%d, inflight_count=%d). The Dashboard will track it through \
       Pending, Inflight, and a terminal Delivered or Failed state."
      keeper_name
      deferred.receipt_id
      deferred.pending_count
      deferred.inflight_count

let dashboard_deferred_chat_to_json ~keeper_name
    ({ in_flight
     ; chat_waiting
     ; pending_count
     ; inflight_count
     ; receipt_id
     ; shutdown_operation_id
     ; queue_revision
     } : dashboard_deferred_chat) =
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
     ; ("pending_count", `Int pending_count)
     ; ("inflight_count", `Int inflight_count)
     ; ("chat_waiting", `Bool chat_waiting)
     ; ("receipt_id", `String receipt_id)
     ; ("queue_revision", `Intlit (Int64.to_string queue_revision))
     ; ( "shutdown_operation_id"
       , match shutdown_operation_id with
         | None -> `Null
         | Some operation_id ->
           `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
     ]
     @ in_flight_fields)

let enqueue_dashboard_payload
      ~clock
      payload
      ~in_flight
      ~chat_waiting
      ~shutdown_operation_id
  =
  match
    Keeper_chat_queue.enqueue ~keeper_name:payload.name
      { Keeper_chat_queue.content = payload.message
      ; user_blocks = payload.user_blocks
      ; attachments = payload.attachments
      ; timestamp = Eio.Time.now clock
      ; source = Keeper_chat_queue.Dashboard
      }
  with
  | Error error -> Error (Keeper_chat_queue.mutation_error_to_string error)
  | Ok receipt ->
      Ok
        { in_flight
        ; chat_waiting
        ; pending_count = receipt.pending_count
        ; inflight_count = receipt.inflight_count
        ; receipt_id = Keeper_chat_queue.Receipt_id.to_string receipt.receipt_id
        ; queue_revision = receipt.revision
        ; shutdown_operation_id
        }

let dashboard_deferred_chat_of_rejection ~clock payload
     ({ Keeper_turn_admission.waiting
     ; in_flight
     ; shutdown_operation_id
     } : Keeper_turn_admission.rejection) =
  (* Dashboard messages remain durable while a shutdown fence is active;
     the queue is the continuation boundary for a later resume/replacement
     lane, rather than starting a turn behind the fence. *)
  enqueue_dashboard_payload
    ~clock
    payload
    ~in_flight
    ~chat_waiting:(waiting > 0)
    ~shutdown_operation_id

let defer_dashboard_payload_if_busy ~base_path ~clock payload =
  match dashboard_busy_queue_state ~base_path ~keeper_name:payload.name with
  | None -> `Not_busy
  | Some (in_flight, chat_waiting, shutdown_operation_id) ->
      (match
         enqueue_dashboard_payload
           ~clock
           payload
           ~in_flight
           ~chat_waiting
           ~shutdown_operation_id
       with
       | Ok queued -> `Queued queued
       | Error message -> `Queue_error message)

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

let http_status_of_access_rejection = function
  | Keeper_msg_async.Invalid_base_path _
  | Keeper_msg_async.Invalid_caller
  | Keeper_msg_async.Invalid_request_id -> `Bad_request
  | Keeper_msg_async.Caller_mismatch -> `Forbidden
;;

let handle_keeper_chat_request_result ~caller state request reqd =
  match parse_keeper_chat_request_result_path request with
  | Error message ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json message)
  | Ok request_id -> (
      match
        Keeper_msg_async.poll
          ~base_path:(Mcp_server.workspace_config state).base_path
          ~caller
          request_id
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
      | Keeper_msg_async.Rejected rejection ->
          respond_json_value_with_cors
            ~status:(http_status_of_access_rejection rejection)
            request
            reqd
            (Keeper_msg_async.access_rejection_to_json rejection)
      | Keeper_msg_async.Found entry ->
          respond_json_value_with_cors ~status:`OK request reqd
            (Keeper_msg_async.entry_to_json entry) )

let handle_keeper_chat_request_cancel ~caller state request reqd =
  match parse_keeper_chat_request_cancel_path request with
  | Error message ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json message)
  | Ok request_id ->
      let result =
        Keeper_msg_async.cancel
          ~base_path:(Mcp_server.workspace_config state).base_path
          ~caller
          request_id
      in
      let status =
        match result with
        | Keeper_msg_async.Cancellation_requested _ ->
            `Accepted
        | Keeper_msg_async.Cancel_not_found -> `Not_found
        | Keeper_msg_async.Cancel_rejected rejection ->
            http_status_of_access_rejection rejection
        | Keeper_msg_async.Cancel_already_terminal _
        | Keeper_msg_async.Cancel_worker_ownership_unknown _ ->
            `Conflict
        | Keeper_msg_async.Cancel_unreadable _
        | Keeper_msg_async.Cancel_persistence_failed _
        | Keeper_msg_async.Cancel_worker_signal_failed _
        | Keeper_msg_async.Cancel_state_invariant_failed _ ->
            `Internal_server_error
      in
      respond_json_value_with_cors ~status request reqd
        (Keeper_msg_async.cancel_result_to_json ~request_id result)

let handle_keeper_turn_interrupt state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let name_result =
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields ->
          (match List.assoc_opt "name" fields with
           | Some (`String s) -> Ok (String.trim s)
           | _ -> Error "name (string) is required")
        | _ -> Error "JSON object body required"
      with
      | Yojson.Json_error msg -> Error ("invalid json: " ^ msg)
    in
    match name_result with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json msg)
    | Ok keeper_name ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json "keeper not registered")
      else (
        match Keeper_registry.interrupt_current_turn ~base_path keeper_name with
        | `Cancelled turn_id ->
          Log.Keeper.info "keeper_turn_interrupt: keeper=%s turn_id=%d" keeper_name turn_id;
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc [ ("cancelled", `Bool true); ("turn_id", `Int turn_id) ])
        | `No_turn_in_flight ->
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               [ ("cancelled", `Bool false)
               ; ("reason", `String "no_in_flight_turn")
               ])))
;;

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

let execute_keeper_stream_tool
      ~sw
      ~clock
      ?auth_token:_
      state
      ~agent_name
      ~arguments
      ~continuation_channel
  =
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
        Keeper_tool_surface.dispatch
          ~continuation_channel
          keeper_ctx
          ~name:"masc_keeper_msg"
          ~args:arguments
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
          match
            Keeper_config.reject_removed_keeper_msg_input_keys
              ~tool_name:"masc_keeper_msg"
              json
          with
          | Error err -> Error err
          | Ok () -> (
            match user_blocks_result with
            | Error err -> Error err
            | Ok user_blocks ->
              let message = message_of_blocks user_blocks in
              if message = "" then
                Error "message is required"
              else
              Ok
                {
                  name;
                  message;
                  user_blocks;
                  turn_instructions;
                  surface_context;
                  channel;
                  channel_user_id;
                  channel_user_name;
                  channel_workspace_id;
                  attachments;
                }
          ))
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

let strip_keeper_visible_reply (reply : string) =
  reply
  |> Keeper_skill_routing.strip_skill_route_lines
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
let execute_keeper_stream_tool_streaming
      ~sw
      ~clock
      ?auth_token:_
      ?on_event
      ?on_admitted
      state
      ~agent_name
      ~arguments
      ~continuation_channel
      ~on_text_delta
  =
  let start_time = Eio.Time.now clock in
  let admission_rejection = ref None in
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
        Keeper_tool_surface.dispatch_stream ~on_text_delta ?on_event
          ~on_admission_rejected:(fun rejection ->
            admission_rejection := Some rejection)
          ?on_admitted
          keeper_ctx
          ~continuation_channel
          ~name:"masc_keeper_msg"
          ~args:arguments
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
  match !admission_rejection with
  | Some rejection -> `Deferred rejection
  | None ->
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
                 ~duration_ms
                 ~source:(Tool_registry.string_of_source Agent_internal)
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

let execute_keeper_stream_tool_streaming_if_free
      ~sw
      ~clock
      ?auth_token:_
      ?on_event
      state
      ~agent_name
      ~arguments
      ~continuation_channel
      ~on_text_delta
  =
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
        Keeper_turn.handle_keeper_msg_if_free
          ~on_text_delta
          ?on_event
          ~continuation_channel
          keeper_ctx
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

type canonical_reply_payload_error =
  | Malformed_reply_json of { parser_detail : string }
  | Reply_payload_not_object
  | Missing_payload_field of string
  | Duplicate_payload_field of string
  | Invalid_payload_field_type of string
  | Unknown_turn_outcome
  | Invalid_turn_ref

type canonical_reply_payload =
  { payload_json : Yojson.Safe.t
  ; turn_outcome : Keeper_turn_outcome.t
  ; turn_ref : Ids.Turn_ref.t
  ; visible_reply : string
  ; poll_body : string
  }

exception Canonical_reply_payload_rejected of canonical_reply_payload_error

let canonical_reply_payload_error_to_string = function
  | Malformed_reply_json _ -> "keeper reply payload is not valid JSON"
  | Reply_payload_not_object -> "keeper reply payload must be a JSON object"
  | Missing_payload_field field ->
    Printf.sprintf "keeper reply payload is missing required field %s" field
  | Duplicate_payload_field field ->
    Printf.sprintf "keeper reply payload contains duplicate field %s" field
  | Invalid_payload_field_type field ->
    Printf.sprintf "keeper reply payload field %s must be a string" field
  | Unknown_turn_outcome ->
    "keeper reply payload contains an unknown turn_outcome"
  | Invalid_turn_ref -> "keeper reply payload contains an invalid turn_ref"
;;

let required_unique_string_field field fields =
  match
    List.filter_map
      (fun (key, value) -> if String.equal key field then Some value else None)
      fields
  with
  | [] -> Error (Missing_payload_field field)
  | [ `String value ] -> Ok value
  | [ _ ] -> Error (Invalid_payload_field_type field)
  | _ -> Error (Duplicate_payload_field field)
;;

let assoc_replace key value fields =
  (key, value)
  :: List.filter (fun (field_key, _) -> not (String.equal field_key key)) fields
;;

let canonical_reply_payload_of_body ~redact_text body =
  let ( let* ) = Result.bind in
  let* fields =
    match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | _ -> Error Reply_payload_not_object
    | exception Yojson.Json_error parser_detail ->
      Error (Malformed_reply_json { parser_detail })
  in
  let* reply_raw = required_unique_string_field "reply" fields in
  let* outcome_label =
    required_unique_string_field Keeper_turn_outcome.wire_key fields
  in
  let* turn_outcome =
    match Keeper_turn_outcome.of_label outcome_label with
    | Some outcome -> Ok outcome
    | None -> Error Unknown_turn_outcome
  in
  let* turn_ref_raw =
    required_unique_string_field Keeper_turn_outcome.turn_ref_wire_key fields
  in
  let* turn_ref =
    match Ids.Turn_ref.of_string turn_ref_raw with
    | Some turn_ref -> Ok turn_ref
    | None -> Error Invalid_turn_ref
  in
  let visible_reply =
    strip_keeper_visible_reply reply_raw |> redact_text |> String.trim
  in
  let payload_json =
    `Assoc (assoc_replace "reply" (`String visible_reply) fields)
  in
  Ok
    { payload_json
    ; turn_outcome
    ; turn_ref
    ; visible_reply
    ; poll_body = Yojson.Safe.to_string payload_json
    }
;;

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

type keeper_stream_terminal_status =
  | Stream_done
  | Stream_error
  | Stream_cancelled
  | Stream_rejected
  | Stream_reconciliation_required

type keeper_request_terminal_status =
  | Request_deferred
  | Request_queued
  | Request_stream of keeper_stream_terminal_status

let keeper_stream_terminal_status_to_string = function
  | Stream_done -> "done"
  | Stream_error -> "error"
  | Stream_cancelled -> "cancelled"
  | Stream_rejected -> "rejected"
  | Stream_reconciliation_required -> "acceptance_uncertain"
;;

let keeper_request_terminal_status_to_string = function
  | Request_deferred -> "deferred"
  | Request_queued -> "queued"
  | Request_stream status -> keeper_stream_terminal_status_to_string status
;;

let keeper_request_terminal_status_ok = function
  | Request_deferred
  | Request_queued
  | Request_stream (Stream_done | Stream_reconciliation_required) ->
    true
  | Request_stream (Stream_error | Stream_cancelled | Stream_rejected) ->
    false
;;

let keeper_request_terminal_status_is_routine = function
  | Request_deferred
  | Request_queued
  | Request_stream (Stream_done | Stream_cancelled | Stream_reconciliation_required) ->
    true
  | Request_stream (Stream_error | Stream_rejected) -> false
;;

let keeper_request_terminal_payload ?request_id ~keeper_name ~status
    ?(message = "") () =
  let status_label = keeper_request_terminal_status_to_string status in
  let fields =
    [ ("keeper_name", `String keeper_name)
    ; ("status", `String status_label)
    ; ("ok", `Bool (keeper_request_terminal_status_ok status))
    ]
  in
  let fields =
    match request_id with
    | Some request_id -> ("request_id", `String request_id) :: fields
    | None -> fields
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
  | Stream_queued_turn_deferred of Keeper_turn_admission.rejection
  | Stream_terminal of
      { status : keeper_stream_terminal_status
      ; body : string
      ; queued_outcome : queued_turn_outcome option
      }

and keeper_stream_completion =
  | Completion_dashboard_queued of dashboard_deferred_chat
  | Completion_queued_turn_deferred of Keeper_turn_admission.rejection
  | Completion_terminal of
      { status : keeper_stream_terminal_status
      ; body : string
      ; queued_outcome : queued_turn_outcome option
      }

and queued_turn_failure_kind =
  | Turn_failed
  | Turn_cancelled
  | No_visible_reply
  | Continuation_checkpoint_without_reply
  | Missing_turn_ref
  | Transcript_persist_failed
  | Stream_projection_failed

and queued_turn_outcome =
  | Delivered of { outcome_ref : string }
  | Failed of
      { kind : queued_turn_failure_kind
      ; detail : string
      }
  | Deferred of { rejection : Keeper_turn_admission.rejection }

let completion_of_worker_settlement ~queued_turn ~staged_completion
    (settlement : Keeper_msg_async.worker_settlement) =
  let queued_failure kind detail =
    if queued_turn then Some (Failed { kind; detail }) else None
  in
  match settlement with
  | Keeper_msg_async.Settlement_projection_error { poll_result } ->
    let body =
      match poll_result with
      | Keeper_msg_async.Unreadable reason -> reason
      | Keeper_msg_async.Absent ->
        "keeper request terminal projection is absent from canonical storage"
      | Keeper_msg_async.Rejected rejection ->
        Keeper_msg_async.access_rejection_to_json rejection
        |> Yojson.Safe.to_string
      | Keeper_msg_async.Found entry ->
        Printf.sprintf
          "keeper request integrity projection is non-terminal (status=%s)"
          (Keeper_msg_async.status_to_string entry.status)
    in
    Some
      (Completion_terminal
         { status = Stream_error
         ; body
         ; queued_outcome = queued_failure Transcript_persist_failed body
         })
  | Keeper_msg_async.Status_settlement { status; durability; origin } ->
    (match durability, origin, status with
     | Keeper_msg_async.Volatile_persistence_failure, _, _ ->
       let body =
         Printf.sprintf
           "keeper request terminal state is not durable (status=%s)"
           (Keeper_msg_async.status_to_string status)
       in
       Some
         (Completion_terminal
            { status = Stream_error
            ; body
            ; queued_outcome = queued_failure Transcript_persist_failed body
            })
     | ( Keeper_msg_async.Durable
       , Keeper_msg_async.Transition_commit
       , Keeper_msg_async.Done { ok; body } ) ->
       (match staged_completion with
        | Some completion -> Some completion
        | None ->
          let stream_status = if ok then Stream_done else Stream_error in
          Some
            (Completion_terminal
               { status = stream_status
               ; body
               ; queued_outcome =
                   (if ok then None else queued_failure Turn_failed body)
               }))
     | ( Keeper_msg_async.Durable
       , Keeper_msg_async.Canonical_reconciliation
       , Keeper_msg_async.Done { ok; body } ) ->
       let stream_status = if ok then Stream_done else Stream_error in
       Some
         (Completion_terminal
            { status = stream_status
            ; body
            ; queued_outcome =
                (if ok then None else queued_failure Turn_failed body)
            })
     | ( Keeper_msg_async.Durable
       , Keeper_msg_async.Transition_commit
       , Keeper_msg_async.Cancelled { reason; cancelled_by } ) ->
       (match staged_completion with
        | Some
            ((Completion_terminal
                { status = (Stream_cancelled | Stream_error); _ }) as completion) ->
          Some completion
        | Some _ | None ->
          let body = Printf.sprintf "%s (cancelled_by=%s)" reason cancelled_by in
          Some
            (Completion_terminal
               { status = Stream_cancelled
               ; body
               ; queued_outcome = queued_failure Turn_cancelled body
               }))
     | ( Keeper_msg_async.Durable
       , Keeper_msg_async.Canonical_reconciliation
       , Keeper_msg_async.Cancelled { reason; cancelled_by } ) ->
       let body = Printf.sprintf "%s (cancelled_by=%s)" reason cancelled_by in
       Some
         (Completion_terminal
            { status = Stream_cancelled
            ; body
            ; queued_outcome = queued_failure Turn_cancelled body
            })
     | ( Keeper_msg_async.Durable
       , _
       , Keeper_msg_async.Persistence_failed { attempted_status; reason } ) ->
       let body =
         Printf.sprintf
           "keeper request terminal persistence failed (attempted_status=%s): %s"
           attempted_status
           reason
       in
       Some
         (Completion_terminal
            { status = Stream_error
            ; body
            ; queued_outcome = queued_failure Transcript_persist_failed body
            })
     | Keeper_msg_async.Durable, _, Keeper_msg_async.Lost { reason } ->
       Some
         (Completion_terminal
            { status = Stream_rejected
            ; body = reason
            ; queued_outcome = queued_failure Turn_failed reason
            })
     | Keeper_msg_async.Durable, _, Keeper_msg_async.Queued
     | Keeper_msg_async.Durable, _, Keeper_msg_async.Running
     | Keeper_msg_async.Durable, _, Keeper_msg_async.Cancelling _ ->
       None)

let admission_rejection_to_json
    ({ Keeper_turn_admission.waiting
     ; in_flight
     ; shutdown_operation_id
     } : Keeper_turn_admission.rejection) =
  let in_flight_fields =
    match in_flight with
    | None -> []
    | Some { Keeper_turn_admission.lane; started_at } ->
        [ ("in_flight_lane", `String (Keeper_turn_admission.lane_to_string lane))
        ; ("in_flight_started_at", `Float started_at)
        ]
  in
  `Assoc
    ([ ("waiting", `Int waiting)
     ; ( "shutdown_operation_id"
       , match shutdown_operation_id with
         | None -> `Null
         | Some operation_id ->
           `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
     ]
     @ in_flight_fields)

let queued_turn_failure_kind_to_string = function
  | Turn_failed -> "turn_failed"
  | Turn_cancelled -> "turn_cancelled"
  | No_visible_reply -> "no_visible_reply"
  | Continuation_checkpoint_without_reply ->
      "continuation_checkpoint_without_reply"
  | Missing_turn_ref -> "missing_turn_ref"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Stream_projection_failed -> "stream_projection_failed"

let queued_delivery_outcome_of_turn_ref = function
  | Some turn_ref ->
      Delivered { outcome_ref = Ids.Turn_ref.to_string turn_ref }
  | None ->
      Failed
        { kind = Missing_turn_ref
        ; detail =
            "queued turn persisted a reply but the reply payload had no valid turn_ref"
        }

type keeper_stream_bridge_state = Keeper_chat_oas_stream_bridge.state

type translated_keeper_stream_event =
  Keeper_chat_oas_stream_bridge.translated_event =
  { bridge_state : keeper_stream_bridge_state
  ; chat_events : Keeper_chat_events.keeper_chat_event list
  }

let empty_keeper_stream_bridge_state = Keeper_chat_oas_stream_bridge.empty_state
let translate_oas_stream_event = Keeper_chat_oas_stream_bridge.translate

(* [connector_user_line_recorded_upstream] and [queued_turn] are required
   labelled arguments, not optional with the "default" their .mli doc
   comments describe: the function ends in labelled args with no positional
   terminator, so a leading optional could not be erased (warning 16). Every
   caller states explicitly whether the gate inbound boundary already owns
   the user line, and whether this turn was dispatched from the queue
   consumer. *)
let process_single_turn ~connector_user_line_recorded_upstream ~queued_turn
    ~delivery_key
    ~state ~clock ~auth_token ~thread_id ~continuation_channel ~closed
    ~client_disconnects
    ~payload ~run_id ~message_id ~agent_name ~submitted_by
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
  (* Stream model text deltas live with per-delta redaction. The typed OAS
     bridge owns per-provider-message state so only the final provider
     message controls terminal resend suppression; canonical terminal content
     always comes from the assembled OAS response carried by [body]. *)
  let worker_events = Eio.Stream.create worker_events_buffer_size in
  let worker_completion, worker_completion_resolver = Eio.Promise.create () in
  let client_disconnect, client_disconnect_resolver = Eio.Promise.create () in
  let terminal_delivery_mu = Eio.Mutex.create () in
  let staged_completion = ref None in
  let terminal_pushed = Atomic.make false in
  let client_disconnected = Atomic.make false in
  let stream_projection_done, stream_projection_done_resolver =
    Eio.Promise.create ()
  in
  let signal_stream_projection_done () =
    (* fire-and-forget: completion is idempotent and may race disconnect cleanup. *)
    ignore (Eio.Promise.try_resolve stream_projection_done_resolver () : bool)
  in
  let publish_completion completion =
    Eio.Mutex.use_rw ~protect:true terminal_delivery_mu (fun () ->
      if not (Atomic.get terminal_pushed)
      then (
        Atomic.set terminal_pushed true;
        ignore
          (Eio.Promise.try_resolve worker_completion_resolver completion : bool)))
  in
  let stage_completion completion =
    Eio.Mutex.use_rw ~protect:true terminal_delivery_mu (fun () ->
      if not (Atomic.get terminal_pushed) then staged_completion := Some completion)
  in
  let publish_committed_completion
      (settlement : Keeper_msg_async.worker_settlement) =
    let completion =
      completion_of_worker_settlement
        ~queued_turn
        ~staged_completion:!staged_completion
        settlement
    in
    match completion with
    | Some completion -> publish_completion completion
    | None ->
      let status =
        match settlement with
        | Keeper_msg_async.Status_settlement { status; _ } ->
          Keeper_msg_async.status_to_string status
        | Keeper_msg_async.Settlement_projection_error _ -> "projection_error"
      in
      Log.Keeper.error
        "keeper_stream: worker settlement callback received non-terminal status keeper=%s status=%s"
        payload.name
        status
  in
  let await_projection_cutoff () =
    let cutoff =
      Eio.Fiber.first
        ~combine:(fun left right ->
          match left, right with
          | `Terminal, _ | _, `Terminal -> `Terminal
          | `Client_disconnected, `Client_disconnected -> `Client_disconnected)
        (fun () ->
           let (_ : keeper_stream_completion) = Eio.Promise.await worker_completion in
           `Terminal)
        (fun () ->
           Eio.Promise.await client_disconnect;
           `Client_disconnected)
    in
    (cutoff :> [ `Added | `Client_disconnected | `Terminal ])
  in
  let observe_stream_event_cutoff reason =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string StreamProjectionEventCutoff)
      ~labels:[ "reason", reason ]
      ()
  in
  let push_worker_event event =
    match event with
    | Stream_dashboard_queued queued ->
        stage_completion (Completion_dashboard_queued queued)
    | Stream_queued_turn_deferred rejection ->
        stage_completion (Completion_queued_turn_deferred rejection)
    | Stream_terminal { status; body; queued_outcome } ->
        stage_completion
          (Completion_terminal { status; body; queued_outcome })
    | Stream_client_disconnected ->
      Atomic.set client_disconnected true;
      let (_ : bool) = Eio.Promise.try_resolve client_disconnect_resolver () in
      ()
    | Stream_event stream_event ->
        if !closed
        then observe_stream_event_cutoff "writer_closed"
        else if Atomic.get terminal_pushed
        then observe_stream_event_cutoff "terminal"
        else if Atomic.get client_disconnected
        then observe_stream_event_cutoff "client_disconnected"
        else (
          match
            Eio.Fiber.first
              ~combine:(fun left right ->
                match left, right with
                | `Added, _ | _, `Added -> `Added
                | `Terminal, _ | _, `Terminal -> `Terminal
                | `Client_disconnected, `Client_disconnected -> `Client_disconnected)
              (fun () ->
                 Eio.Stream.add worker_events stream_event;
                 `Added)
              await_projection_cutoff
          with
          | `Added -> ()
          | `Terminal -> observe_stream_event_cutoff "terminal"
          | `Client_disconnected ->
            observe_stream_event_cutoff "client_disconnected")
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
  let dashboard_direct_stream =
    (not queued_turn)
    && (not connector_user_line_recorded_upstream)
    && not (has_external_speaker payload)
  in
  let direct_delivery_journal = ref None in
  let journal_error error =
    Keeper_chat_delivery_journal.error_to_string error
  in
  let row_id_of_append_once = function
    | Keeper_chat_store.Appended { row_id }
    | Keeper_chat_store.Already_present { row_id } -> row_id
  in
  let set_direct_delivery_journal journal =
    direct_delivery_journal := Some journal
  in
  let on_direct_request_accepted request_id =
    let ( let* ) = Result.bind in
    let* request_id =
      Keeper_chat_delivery_identity.Request_id.of_string request_id
    in
    let delivery_key =
      Keeper_chat_delivery_identity.Direct_request request_id
    in
    let accepted_payload : Keeper_chat_delivery_journal.accepted_payload =
      { keeper_name = payload.name
      ; submitted_by
      ; user_content = payload.message
      ; user_attachments = payload.attachments
      ; surface = chat_surface
      ; conversation_id = None
      ; external_message_id = None
      ; speaker = chat_speaker
      ; user_row_origin = Keeper_chat_delivery_journal.Needs_append
      }
    in
    let* prepared =
      Keeper_chat_delivery_journal.prepare
        ~base_path
        ~delivery_key
        ~payload:accepted_payload
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal prepared;
    let* user_row =
      Keeper_chat_store.append_user_message_once
        ~base_dir:base_path
        ~keeper_name:payload.name
        ~delivery_key
        ~content:payload.message
        ~attachments:payload.attachments
        ~surface:chat_surface
        ~speaker:chat_speaker
        ()
    in
    let* accepted =
      Keeper_chat_delivery_journal.mark_accepted
        ~base_path
        ~expected_revision:prepared.revision
        ~identity:prepared
        ~user_row_id:(Some (row_id_of_append_once user_row))
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal accepted;
    let* running =
      Keeper_chat_delivery_journal.mark_running
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal running;
    Ok ()
  in
  let on_queue_turn_admitted () =
    let ( let* ) = Result.bind in
    let* delivery_key, receipt_ids =
      match delivery_key with
      | Some (Keeper_chat_delivery_identity.Queue_receipts receipt_ids as key) ->
        Ok (key, receipt_ids)
      | Some (Keeper_chat_delivery_identity.Direct_request _) ->
        Error "queued Keeper turn received a direct-request delivery identity"
      | None -> Error "queued Keeper turn is missing its receipt delivery identity"
    in
    let user_row_origin =
      if connector_user_line_recorded_upstream
      then Ok Keeper_chat_delivery_journal.Already_persisted_upstream
      else
        Keeper_chat_delivery_journal.dashboard_queue_user_row_origin
          ~base_path
          ~keeper_name:payload.name
          receipt_ids
        |> Result.map_error journal_error
    in
    let* user_row_origin = user_row_origin in
    let accepted_payload : Keeper_chat_delivery_journal.accepted_payload =
      { keeper_name = payload.name
      ; submitted_by
      ; user_content = payload.message
      ; user_attachments = payload.attachments
      ; surface = chat_surface
      ; conversation_id = None
      ; external_message_id = None
      ; speaker = chat_speaker
      ; user_row_origin
      }
    in
    let* prepared =
      Keeper_chat_delivery_journal.prepare
        ~base_path
        ~delivery_key
        ~payload:accepted_payload
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal prepared;
    let* user_row_id =
      match user_row_origin with
      | Keeper_chat_delivery_journal.Already_persisted_upstream -> Ok None
      | Keeper_chat_delivery_journal.Already_persisted { row_id } ->
        Ok (Some row_id)
      | Keeper_chat_delivery_journal.Needs_append ->
        Keeper_chat_store.append_user_message_once
          ~base_dir:base_path
          ~keeper_name:payload.name
          ~delivery_key
          ~content:payload.message
          ~attachments:payload.attachments
          ~surface:chat_surface
          ~speaker:chat_speaker
          ()
        |> Result.map (fun result -> Some (row_id_of_append_once result))
    in
    let* accepted =
      Keeper_chat_delivery_journal.mark_accepted
        ~base_path
        ~expected_revision:prepared.revision
        ~identity:prepared
        ~user_row_id
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal accepted;
    let* running =
      Keeper_chat_delivery_journal.mark_running
        ~base_path
        ~expected_revision:accepted.revision
        ~identity:accepted
        ~now:(Time_compat.now ())
      |> Result.map_error journal_error
    in
    set_direct_delivery_journal running;
    Ok ()
  in
  let commit_direct_terminal terminal =
    let ( let* ) = Result.bind in
    let rec drive journal =
      match journal.Keeper_chat_delivery_journal.phase with
      | Keeper_chat_delivery_journal.Running _ ->
        let* pending =
          Keeper_chat_delivery_journal.mark_terminal_pending
            ~base_path
            ~expected_revision:journal.revision
            ~identity:journal
            ~terminal
            ~now:(Time_compat.now ())
          |> Result.map_error journal_error
        in
        set_direct_delivery_journal pending;
        drive pending
      | Keeper_chat_delivery_journal.Terminal_pending
          { terminal = persisted_terminal; user_row_id } ->
        let delivery_key = journal.delivery_key in
        let* transcript_row_id =
          match persisted_terminal.delivery with
          | Keeper_chat_delivery_journal.Assistant_reply
              { content; blocks; turn_ref } ->
            Keeper_chat_store.append_assistant_message_once
              ~base_dir:base_path
              ~keeper_name:payload.name
              ~delivery_key
              ~content
              ~surface:chat_surface
              ?blocks
              ?turn_ref
              ~stream_lifecycle:completed_stream_lifecycle
              ()
            |> Result.map row_id_of_append_once
          | Keeper_chat_delivery_journal.Transport_failure { content } ->
            Keeper_chat_store.append_assistant_message_once
              ~base_dir:base_path
              ~keeper_name:payload.name
              ~delivery_key
              ~content
              ~surface:chat_surface
              ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
              ~stream_lifecycle:errored_stream_lifecycle
              ()
            |> Result.map row_id_of_append_once
          | Keeper_chat_delivery_journal.No_assistant_reply
              { reason =
                  ( Keeper_chat_delivery_journal.Continuation_checkpoint
                  | Keeper_chat_delivery_journal.Queued_for_later _ )
              } ->
            (match user_row_id with
             | Some user_row_id -> Ok user_row_id
             | None ->
               Error
                 "continuation checkpoint requires an accepted user transcript row")
        in
        let* committed =
          Keeper_chat_delivery_journal.mark_transcript_committed
            ~base_path
            ~expected_revision:journal.revision
            ~identity:journal
            ~transcript_row_id
            ~now:(Time_compat.now ())
          |> Result.map_error journal_error
        in
        set_direct_delivery_journal committed;
        drive committed
      | Keeper_chat_delivery_journal.Transcript_committed _ ->
        let* final =
          Keeper_chat_delivery_journal.mark_final
            ~base_path
            ~expected_revision:journal.revision
            ~identity:journal
            ~now:(Time_compat.now ())
          |> Result.map_error journal_error
        in
        set_direct_delivery_journal final;
        Ok ()
      | Keeper_chat_delivery_journal.Final _ -> Ok ()
      | Keeper_chat_delivery_journal.Prepared
      | Keeper_chat_delivery_journal.Accepted _ ->
        Error
          (Printf.sprintf
             "direct Keeper delivery reached terminal commit from phase=%s"
             (Keeper_chat_delivery_journal.phase_to_string journal.phase))
    in
    match !direct_delivery_journal with
    | None -> Error "direct Keeper delivery journal is unavailable"
    | Some journal -> drive journal
  in
  (* RFC-0301 item 6: collect generated media from the same stream so the assistant
     turn can persist it as reload-visible chat blocks. The bridge surfaces this
     media live over SSE; the persist site records it durably (see the persist arm
     below). Content-addressed, so the two persists reuse one file. *)
  let worker_media_accum = Keeper_stream_media_accum.create () in
  let on_event evt =
    Keeper_stream_media_accum.on_event worker_media_accum evt;
    push_worker_event (Stream_event evt)
  in
  let persist_user_message_only () =
    (* RFC-connector-deferred-reply-via-chat-queue §3.4: when the gate inbound boundary already recorded this
       connector user line (Discord/Slack busy message enqueued onto the chat
       queue), re-recording it here would double-write. The gate inbound line is
       assistant-less, so the message is already "pending" — nothing to add. *)
    if Option.is_some !direct_delivery_journal then ()
    else if not connector_user_line_recorded_upstream then
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
    let persisted =
      if Option.is_some !direct_delivery_journal
      then
        commit_direct_terminal
          { ok = false
          ; poll_body = err
          ; delivery = Keeper_chat_delivery_journal.Transport_failure { content = persisted_error_reply err }
          }
      else if connector_user_line_recorded_upstream then
       Keeper_chat_store.append_assistant_message_result
         ~base_dir:base_path
         ~keeper_name:payload.name
         ~content:(persisted_error_reply err)
         ~surface:chat_surface
         ~stream_lifecycle:errored_stream_lifecycle
         ()
      else
       Keeper_chat_store.append_turn_result
         ~base_dir:base_path
         ~keeper_name:payload.name
         ~user_content:payload.message
         ~user_attachments:payload.attachments
         ~surface:chat_surface
         ~speaker:chat_speaker
         ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
         ~assistant_content:(persisted_error_reply err)
         ~stream_lifecycle:errored_stream_lifecycle
         ()
    in
    (match persisted with
     | Ok () ->
         Keeper_chat_broadcast.chat_appended
           ~keeper_name:payload.name ~source:chat_source
           ~content:(persisted_error_reply err)
           ()
     | Error _ -> ());
    persisted
  in
  (* masc#23924: [f] below pushes its own [Stream_terminal] once it reaches a
     completion arm, but cancellation cuts [f] off before any of
     those arms run — nothing would ever push to [worker_events], and
     [consume_worker_events]'s [Eio.Stream.take] would block forever.
     [on_worker_aborted] fires from Keeper_msg_async.submit's own catch
     sites (never inside the cancelled [f]) so this turn still gets exactly
     one terminal event via the same serialized [push_worker_event]. *)
  let on_worker_aborted (reason : Keeper_msg_async.worker_abort_reason) =
    let cancellation_status, cancellation_body, failure_kind =
      match reason with
      | Keeper_msg_async.Worker_cancelled { cancelled_by; reason } ->
          let cancelled_by =
            Keeper_msg_async.worker_cancel_source_to_string cancelled_by
          in
          ( Stream_cancelled
          , Printf.sprintf "%s (cancelled_by=%s)" reason cancelled_by
          , Turn_cancelled )
    in
    let persisted = persist_failure_reply cancellation_body in
    let status, body =
      match persisted with
      | Ok () -> cancellation_status, cancellation_body
      | Error persist_error ->
          ( Stream_error
          , Printf.sprintf
              "keeper cancellation transcript persistence failed: %s"
              persist_error )
    in
    let queued_outcome =
      if not queued_turn then None
      else
        match persisted with
        | Ok () -> Some (Failed { kind = failure_kind; detail = cancellation_body })
        | Error persist_error ->
            Some
              (Failed
                 { kind = Transcript_persist_failed
                 ; detail = persist_error
                 })
    in
    push_worker_event (Stream_terminal { status; body; queued_outcome });
    persisted
  in
  let submit_result =
    match Keeper_msg_async.server_background_switch () with
    | Error error ->
        Error
          (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
    | Ok background_sw ->
      let on_accepted =
        if dashboard_direct_stream
        then Some on_direct_request_accepted
        else None
      in
      Keeper_msg_async.submit
        ?on_accepted
        ~background_sw
        ~on_worker_aborted
        ~on_worker_settled:publish_committed_completion
        ~base_path
        ~caller:submitted_by
        ~keeper_name:payload.name
        ~f:(fun request_sw ->
        let start_time = Time_compat.now () in
        let finish_projection_failure kind detail =
          let persisted = persist_failure_reply detail in
          let queued_outcome =
            if not queued_turn
            then None
            else
              match persisted with
              | Ok () -> Some (Failed { kind; detail })
              | Error persist_error ->
                Some
                  (Failed
                     { kind = Transcript_persist_failed
                     ; detail = persist_error
                     })
          in
          push_worker_event
            (Stream_terminal
               { status = Stream_error; body = detail; queued_outcome });
          Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time detail
        in
        let on_admitted =
          if queued_turn then Some on_queue_turn_admitted else None
        in
        let dispatch_result =
          try
            if dashboard_direct_stream then
              match
                execute_keeper_stream_tool_streaming_if_free ~sw:request_sw ~clock
                  ?auth_token
                  state ~agent_name ~arguments:args ~on_event
                  ~continuation_channel
                  ~on_text_delta:(fun _ -> ())
              with
              | `Ran result -> Ok (`Ran result)
              | `Busy rejection ->
                  (match
                   dashboard_deferred_chat_of_rejection ~clock payload rejection
                   with
                   | Ok queued -> Ok (`Queued queued)
                   | Error message -> Error message)
            else
              (match
                 execute_keeper_stream_tool_streaming
                   ~sw:request_sw
                   ~clock
                   ?auth_token
                   state ~agent_name ~arguments:args ~on_event
                   ~continuation_channel ~on_text_delta:(fun _ -> ())
                   ?on_admitted
               with
               | `Ran result -> Ok (`Ran result)
               | `Deferred rejection -> Ok (`Deferred rejection))
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn
                "keeper_stream: streaming dispatch raised: %s"
                (Printexc.to_string exn);
              if dashboard_direct_stream || queued_turn
              then Error (Printexc.to_string exn)
              else
                (try
                   Ok
                     (`Ran
	                        (execute_keeper_stream_tool ~sw:request_sw ~clock
	                           ?auth_token
	                           state ~agent_name ~arguments:args
                            ~continuation_channel))
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn2 -> Error (Printexc.to_string exn2))
        in
        match dispatch_result with
        | Ok (`Deferred rejection) ->
            push_worker_event (Stream_queued_turn_deferred rejection);
            Tool_result.ok
              ~tool_name:"masc_keeper_msg"
              ~start_time
              (Yojson.Safe.to_string
                 (`Assoc
                    [ ("status", `String "deferred")
                    ; ("admission", admission_rejection_to_json rejection)
                    ]))
        | Ok (`Queued queued) ->
            let body =
              Yojson.Safe.to_string
                (dashboard_deferred_chat_to_json ~keeper_name:payload.name queued)
            in
            let committed =
              let ( let* ) = Result.bind in
              let* receipt_id =
                Keeper_chat_delivery_identity.Receipt_id.of_string
                  queued.receipt_id
              in
              commit_direct_terminal
                { ok = true
                ; poll_body = body
                ; delivery =
                    Keeper_chat_delivery_journal.No_assistant_reply
                      { reason =
                          Keeper_chat_delivery_journal.Queued_for_later
                            { receipt_id }
                      }
                }
            in
            (match committed with
             | Ok () ->
               push_worker_event (Stream_dashboard_queued queued);
               Tool_result.ok ~tool_name:"masc_keeper_msg" ~start_time body
             | Error detail ->
               push_worker_event
                 (Stream_terminal
                    { status = Stream_error
                    ; body = detail
                    ; queued_outcome = None
                    });
               Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time detail)
        | Ok (`Ran (true, body)) ->
          (match canonical_reply_payload_of_body ~redact_text body with
           | Error error ->
             let detail = canonical_reply_payload_error_to_string error in
             let internal_detail =
               match error with
               | Malformed_reply_json { parser_detail } ->
                 redact_text parser_detail
               | Reply_payload_not_object
               | Missing_payload_field _
               | Duplicate_payload_field _
               | Invalid_payload_field_type _
               | Unknown_turn_outcome
               | Invalid_turn_ref -> detail
             in
             Log.Keeper.error
               "keeper_stream: canonical terminal projection rejected keeper=%s error=%s"
               payload.name
               internal_detail;
             finish_projection_failure Stream_projection_failed detail
           | Ok canonical_reply ->
            let payload_json_opt = Some canonical_reply.payload_json in
            let body = canonical_reply.poll_body in
            let turn_ref = Some canonical_reply.turn_ref in
            let visible_reply = canonical_reply.visible_reply in
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
                 let queued_outcome =
                   if not queued_turn then None
                   else
                     match persist_failure_reply err with
                     | Ok () -> Some (Failed { kind = Turn_failed; detail = err })
                     | Error persist_error ->
                         Some
                           (Failed
                              { kind = Transcript_persist_failed
                              ; detail = persist_error
                              })
                 in
                 if not queued_turn
                 then
                   (match persist_failure_reply err with
                    | Ok () -> ()
                    | Error persist_error ->
                      Log.Keeper.error
                        "keeper_stream: failed to persist direct-turn failure keeper=%s error=%s"
                        payload.name
                        persist_error);
                 push_worker_event
                   (Stream_terminal
                      { status = Stream_error
                      ; body = err
                      ; queued_outcome
                      });
                 Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err
             | None ->
                 let persist_assistant_reply ~assistant_content =
                   if Option.is_some !direct_delivery_journal
                   then
                     commit_direct_terminal
                       { ok = true
                       ; poll_body = body
                       ; delivery =
                           Keeper_chat_delivery_journal.Assistant_reply
                             { content = assistant_content
                             ; blocks
                             ; turn_ref
                             }
                       }
                   else if connector_user_line_recorded_upstream then
                     Keeper_chat_store.append_assistant_message_result
                       ~base_dir:base_path
                       ~keeper_name:payload.name
                       ~content:assistant_content
                       ~surface:chat_surface
                       ?blocks
                       ?turn_ref
                       ~stream_lifecycle:completed_stream_lifecycle
                       ()
                   else
                     Keeper_chat_store.append_turn_result
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
                 let delivered_after_persist ?content persisted =
                   match persisted with
                   | Ok () ->
                       Keeper_chat_broadcast.chat_appended
                         ~keeper_name:payload.name ~source:chat_source ?content ();
                       if queued_turn
                       then
                         Some (queued_delivery_outcome_of_turn_ref turn_ref)
                       else None
                   | Error persist_error ->
                       if queued_turn
                       then
                         Some
                           (Failed
                              { kind = Transcript_persist_failed
                              ; detail = persist_error
                              })
                       else None
                 in
                 let turn_outcome = canonical_reply.turn_outcome in
                 let queued_outcome =
                   match turn_outcome, String_util.trim_to_option visible_reply with
                   | Keeper_turn_outcome.Continuation_checkpoint, _ when queued_turn ->
                       let detail =
                         "queued turn ended with a continuation checkpoint and no delivered reply"
                       in
                       (match persist_failure_reply detail with
                        | Ok () ->
                            Some
                              (Failed
                                 { kind = Continuation_checkpoint_without_reply
                                 ; detail
                                 })
                        | Error persist_error ->
                            Some
                              (Failed
                                 { kind = Transcript_persist_failed
                                 ; detail = persist_error
                                 }))
                   | Keeper_turn_outcome.Continuation_checkpoint, _ ->
                       (match !direct_delivery_journal with
                        | Some _ ->
                          (match
                             commit_direct_terminal
                               { ok = true
                               ; poll_body = body
                               ; delivery =
                                   Keeper_chat_delivery_journal.No_assistant_reply
                                     { reason =
                                         Keeper_chat_delivery_journal.Continuation_checkpoint
                                     }
                               }
                           with
                           | Ok () -> None
                           | Error detail ->
                             Some
                               (Failed
                                  { kind = Transcript_persist_failed; detail }))
                        | None ->
                          persist_user_message_only ();
                          None)
                   | Keeper_turn_outcome.No_visible_reply, _
                   | Keeper_turn_outcome.Visible_reply, None ->
                       if has_visible_blocks
                       then
                         persist_assistant_reply ~assistant_content:""
                         |> delivered_after_persist
                       else if queued_turn
                       then
                         let detail =
                           "no visible reply was produced for this queued message"
                         in
                         (match persist_failure_reply detail with
                          | Ok () -> Some (Failed { kind = No_visible_reply; detail })
                          | Error persist_error ->
                              Some
                                (Failed
                                   { kind = Transcript_persist_failed
                                   ; detail = persist_error
                                   }))
                       else (
                         persist_user_message_only ();
                         None)
                   | Keeper_turn_outcome.Visible_reply, Some visible_reply ->
                       persist_assistant_reply ~assistant_content:visible_reply
                       |> delivered_after_persist ~content:visible_reply
                 in
                 (match queued_outcome with
                  | Some (Failed { detail; _ }) ->
                      push_worker_event
                        (Stream_terminal
                           { status = Stream_error
                           ; body = detail
                           ; queued_outcome
                      });
                      Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time detail
                  | Some (Deferred { rejection }) ->
                      push_worker_event (Stream_queued_turn_deferred rejection);
                      Tool_result.ok
                        ~tool_name:"masc_keeper_msg"
                        ~start_time
                        (Yojson.Safe.to_string
                           (`Assoc
                              [ ("status", `String "deferred")
                              ; ( "admission"
                                , admission_rejection_to_json rejection )
                              ]))
                  | Some (Delivered _) | None ->
                      push_worker_event
                        (Stream_terminal
                           { status = Stream_done
                           ; body
                           ; queued_outcome
                           });
                      Tool_result.ok ~tool_name:"masc_keeper_msg" ~start_time body)))
        | Ok (`Ran (false, err)) ->
            let persisted = persist_failure_reply err in
            let queued_outcome =
              if not queued_turn then None
              else
                match persisted with
                | Ok () -> Some (Failed { kind = Turn_failed; detail = err })
                | Error persist_error ->
                    Some
                      (Failed
                         { kind = Transcript_persist_failed
                         ; detail = persist_error
                         })
            in
            push_worker_event
              (Stream_terminal
                 { status = Stream_error; body = err; queued_outcome });
            Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err
        | Error err ->
            let persisted = persist_failure_reply err in
            let queued_outcome =
              if not queued_turn then None
              else
                match persisted with
                | Ok () -> Some (Failed { kind = Turn_failed; detail = err })
                | Error persist_error ->
                    Some
                      (Failed
                         { kind = Transcript_persist_failed
                         ; detail = persist_error
                         })
            in
            push_worker_event
              (Stream_terminal
                 { status = Stream_error; body = err; queued_outcome });
            Tool_result.error ~tool_name:"masc_keeper_msg" ~start_time err)
        ()
      |> Result.map_error (fun error ->
        Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
  in
  let request_id, durably_accepted =
    match submit_result with
    | Ok
        ({ acceptance = Keeper_msg_async.Durably_accepted; request_id }
          : Keeper_msg_async.submit_outcome) ->
        Some request_id, true
    | Ok
        ({ acceptance = Keeper_msg_async.Reconciliation_required _; _ } as
          outcome) ->
        let body =
          Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string
        in
        publish_completion
          (Completion_terminal
             { status = Stream_reconciliation_required
             ; body
             ; queued_outcome = None
             });
        Some outcome.request_id, false
    | Error body ->
        let persisted = persist_failure_reply body in
        let queued_outcome =
          if not queued_turn then None
          else
            match persisted with
            | Ok () -> Some (Failed { kind = Turn_failed; detail = body })
            | Error persist_error ->
                Some
                  (Failed
                     { kind = Transcript_persist_failed
                     ; detail = persist_error
                     })
        in
        publish_completion
          (Completion_terminal
             { status = Stream_rejected
             ; body
             ; queued_outcome
             });
        None, false
  in
  (match client_disconnects, request_id with
   | None, _ | _, None -> ()
   | Some (disconnect_sw, disconnects), Some request_id ->
       Eio.Fiber.fork ~sw:disconnect_sw (fun () ->
         match
         Eio.Fiber.first
           ~combine:(fun left right ->
             match left, right with
             | `Projection_done, _ | _, `Projection_done -> `Projection_done
             | `Client_disconnected, `Client_disconnected -> `Client_disconnected)
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
  Option.iter
    (fun request_id ->
       Log.Keeper.info
         "keeper_stream: queued request keeper=%s request_id=%s surface=%s"
         payload.name request_id
         (if has_connector_context payload then payload.channel else "dashboard");
       Keeper_chat_events.publish events
         (Custom
            { name = "KEEPER_QUEUE_REQUEST"
            ; value =
                Gate_protocol.message_request_to_json
                  { request_id
                  ; destination_type = "keeper"
                  ; destination_id = payload.name
                  ; channel =
                      (if has_connector_context payload then payload.channel
                       else "dashboard")
                  ; actor_id = Some agent_name
                  ; status = Gate_protocol.Queued
                  ; modalities = modalities_for_request payload
                  ; transport = Some "sse"
                  ; metadata =
                      [ ("projection", "keeper_chat_stream")
                      ; ("protocol", "gate_message_request")
                      ]
                  }
            }))
    (if durably_accepted then request_id else None);
  let publish_terminal ~status ?(message = "") () =
    let message = redact_text message in
    let status_label = keeper_request_terminal_status_to_string status in
    let payload_json =
      keeper_request_terminal_payload ?request_id ~keeper_name:payload.name
        ~status ~message ()
    in
    if keeper_request_terminal_status_is_routine status
    then
      (match request_id with
       | Some request_id ->
         Log.Keeper.info
           "keeper_stream: request terminal keeper=%s request_id=%s status=%s"
           payload.name request_id status_label
       | None ->
         Log.Keeper.info
           "keeper_stream: request terminal before acceptance keeper=%s status=%s"
           payload.name status_label)
    else
      (match request_id with
       | Some request_id ->
         Log.Keeper.warn
           "keeper_stream: request terminal keeper=%s request_id=%s status=%s message=%s"
           payload.name request_id status_label message
       | None ->
         Log.Keeper.warn
           "keeper_stream: request rejected before acceptance keeper=%s status=%s message=%s"
           payload.name status_label message);
      Keeper_chat_events.publish events
        (Custom { name = "KEEPER_REQUEST_TERMINAL"; value = payload_json })
  in
  let next_worker_projection () =
    if Atomic.get client_disconnected
    then `Client_disconnected
    else (
      match Eio.Stream.take_nonblocking worker_events with
      | Some event -> `Stream_event event
      | None ->
        Eio.Fiber.first
          ~combine:(fun left right ->
            match left, right with
            | `Stream_event _, _ -> left
            | _, `Stream_event _ -> right
            | `Completion _, _ -> left
            | _, `Completion _ -> right
            | `Client_disconnected, `Client_disconnected -> `Client_disconnected)
          (fun () -> `Stream_event (Eio.Stream.take worker_events))
          (fun () ->
             let completion_or_disconnect =
               Eio.Fiber.first
                 ~combine:(fun left right ->
                   match left, right with
                   | `Completion _, _ -> left
                   | _, `Completion _ -> right
                   | `Client_disconnected, `Client_disconnected ->
                     `Client_disconnected)
                 (fun () -> `Completion (Eio.Promise.await worker_completion))
                 (fun () ->
                    Eio.Promise.await client_disconnect;
                    `Client_disconnected)
             in
             (completion_or_disconnect
              :> [ `Client_disconnected
                  | `Completion of keeper_stream_completion
                  | `Stream_event of Agent_sdk.Types.sse_event
                  ])))
  in
  let rec consume_worker_events bridge_state =
    match next_worker_projection () with
    | `Client_disconnected -> None
    | `Stream_event evt ->
        let translated =
          translate_oas_stream_event ~redact_text
            ~base_dir:base_path bridge_state evt
        in
        List.iter (Keeper_chat_events.publish events) translated.chat_events;
        consume_worker_events translated.bridge_state
    | `Completion (Completion_queued_turn_deferred rejection) ->
        let message =
          match rejection.Keeper_turn_admission.shutdown_operation_id with
          | Some operation_id ->
              Printf.sprintf
                "queued receipt remains Pending while shutdown operation %s \
                 fences keeper admission"
                (Keeper_shutdown_types.Operation_id.to_string operation_id)
          | None ->
              Printf.sprintf
                "queued receipt remains Pending because keeper admission is \
                 deferred with %d waiting chat requests"
                rejection.waiting
        in
        publish_terminal ~status:Request_deferred ~message ();
        Keeper_chat_events.publish events
          (Custom
             { name = "KEEPER_QUEUED_TURN_DEFERRED"
             ; value = admission_rejection_to_json rejection
             });
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id });
        Some (Deferred { rejection })
    | `Completion (Completion_dashboard_queued queued) ->
        let message =
          dashboard_deferred_ack_text ~keeper_name:payload.name queued
        in
        publish_terminal ~status:Request_queued ~message ();
        Keeper_chat_events.publish events (Text_delta message);
        Keeper_chat_events.publish events
          (Custom
             { name = "KEEPER_CHAT_QUEUED";
               value = dashboard_deferred_chat_to_json ~keeper_name:payload.name queued
             });
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id });
        None
    | `Completion
        (Completion_terminal
        { status = Stream_cancelled
        ; body = message
        ; queued_outcome
        }) ->
        let message = redact_text message in
        publish_terminal ~status:(Request_stream Stream_cancelled) ~message ();
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id });
        queued_outcome
    | `Completion
        (Completion_terminal
        { status = Stream_reconciliation_required
        ; body = message
        ; queued_outcome
        }) ->
        let message = redact_text message in
        publish_terminal
          ~status:(Request_stream Stream_reconciliation_required)
          ~message
          ();
        Keeper_chat_events.publish events (Text_delta message);
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id });
        queued_outcome
    | `Completion
        (Completion_terminal
        { status = ((Stream_error | Stream_rejected) as status)
        ; body = err
        ; queued_outcome
        }) ->
        let err = redact_text err in
        publish_terminal ~status:(Request_stream status) ~message:err ();
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Event_error { message = err });
        queued_outcome
    | `Completion (Completion_terminal { status = Stream_done; body; queued_outcome }) -> (
        try
          let canonical_reply =
            match canonical_reply_payload_of_body ~redact_text body with
            | Ok canonical_reply -> canonical_reply
            | Error error -> raise (Canonical_reply_payload_rejected error)
          in
          let payload_json_opt = Some canonical_reply.payload_json in
          let visible_reply = canonical_reply.visible_reply in
          let turn_outcome = canonical_reply.turn_outcome in
          let suppress_terminal_reply =
            match turn_outcome with
            | Keeper_turn_outcome.Continuation_checkpoint
            | Keeper_turn_outcome.No_visible_reply ->
                true
            | Keeper_turn_outcome.Visible_reply -> false
          in
          if
            (not suppress_terminal_reply)
            && not
                 (Keeper_chat_oas_stream_bridge.terminal_message_had_text
                    bridge_state)
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
                       (("message", `String visible_reply)
                        :: (match request_id with
                            | Some request_id ->
                                [ ("request_id", `String request_id) ]
                            | None -> []))
                 });
          publish_terminal ~status:(Request_stream Stream_done) ();
          Keeper_chat_events.publish events Text_message_end;
          Keeper_chat_events.publish events (Run_finished { run_id });
          queued_outcome
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | Canonical_reply_payload_rejected error ->
            let message = canonical_reply_payload_error_to_string error in
            publish_terminal ~status:(Request_stream Stream_error) ~message ();
            Keeper_chat_events.publish events Text_message_end;
            Keeper_chat_events.publish events (Event_error { message });
            if queued_turn
            then Some (Failed { kind = Stream_projection_failed; detail = message })
            else None
        | exn ->
            let message = redact_text (Printexc.to_string exn) in
            publish_terminal ~status:(Request_stream Stream_error) ~message ();
            Keeper_chat_events.publish events Text_message_end;
            Keeper_chat_events.publish events
              (Event_error { message });
            if queued_turn
            then Some (Failed { kind = Stream_projection_failed; detail = message })
            else None)
  in
  match consume_worker_events empty_keeper_stream_bridge_state with
  | outcome ->
      signal_stream_projection_done ();
      outcome
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

let handle_keeper_chat_stream ~sw ~clock ~submitted_by state request reqd payload =
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
  let continuation_channel =
    Keeper_continuation_channel.Dashboard { thread_id }
  in

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
            (* [text] is already redacted by the typed OAS stream bridge, or
               is a terminal-reply chunk split from a whole-redacted
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
             else submitted_by
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
             ignore
               (process_single_turn ~connector_user_line_recorded_upstream:false
                  ~queued_turn:false ~delivery_key:None
                  ~state ~clock
                  ~auth_token:(auth_token_from_request request)
                  ~thread_id ~continuation_channel ~closed
                  ~client_disconnects:(Some (stream_sw, client_disconnects))
                  ~payload ~run_id ~message_id ~agent_name ~submitted_by ~events
                : queued_turn_outcome option);
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
                   "keeper_stream: deferred busy dashboard message keeper=%s pending_count=%d inflight_count=%d"
                   payload.name queued.pending_count queued.inflight_count;
                 Keeper_chat_events.publish events
                   (Run_started { run_id; thread_id });
                 Keeper_chat_events.publish events
                   (Text_message_start
                      { message_id; role = Keeper_chat_events.Assistant });
                 Keeper_chat_events.publish events
                   (Text_delta
                      (dashboard_deferred_ack_text
                         ~keeper_name:payload.name
                         queued));
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
  let defer_dashboard_payload_if_busy_evidence ~base_path ~clock payload =
    match defer_dashboard_payload_if_busy ~base_path ~clock payload with
    | `Not_busy -> `Not_busy
    | `Queued queued ->
        `Queued
          ( dashboard_deferred_chat_to_json ~keeper_name:payload.name queued
          , dashboard_deferred_ack_text ~keeper_name:payload.name queued )
    | `Queue_error message -> `Queue_error message

  let defer_dashboard_payload_if_busy ~base_path ~clock payload =
    match defer_dashboard_payload_if_busy ~base_path ~clock payload with
    | `Not_busy -> `Not_busy
    | `Queued queued -> `Queued queued.pending_count
    | `Queue_error message -> `Queue_error message

  let canonical_reply_payload_of_body = canonical_reply_payload_of_body
  let direct_reply_terminal_error = direct_reply_terminal_error
  let queued_delivery_outcome_of_turn_ref =
    queued_delivery_outcome_of_turn_ref
  let format_surface_context = format_surface_context
  let surface_context_to_instructions = surface_context_to_instructions
  let empty_stream_bridge_state = empty_keeper_stream_bridge_state
  let translate_oas_stream_event = translate_oas_stream_event
  let keeper_tool_failure_log_details = keeper_tool_failure_log_details
  let keeper_chat_stream_headers = keeper_chat_stream_headers
  let worker_settlement_terminal_body ~staged_body settlement =
    let staged_completion =
      Option.map
        (fun body ->
           Completion_terminal
             { status = Stream_done; body; queued_outcome = None })
        staged_body
    in
    match
      completion_of_worker_settlement
        ~queued_turn:false
        ~staged_completion
        settlement
    with
    | Some (Completion_terminal { body; _ }) -> Some body
    | Some (Completion_dashboard_queued _ | Completion_queued_turn_deferred _)
    | None ->
      None
  ;;
end
