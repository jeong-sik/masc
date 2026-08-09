
open Server_auth

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

(* Progressive-render hard-wrap width (characters) for streamed keeper replies —
   a UI readability chunk width, NOT an SSE/transport line-length limit. *)
let keeper_reply_chunk_hard_wrap_chars = 180

(* Bounded producer-consumer capacity for the worker-event stream; [Eio.Stream.add]
   blocks (backpressure) when the consumer lags. *)
let worker_events_buffer_size = 512

type operation_live_sink = Ag_ui.event -> unit

let operation_live_sinks :
  (string, (int * operation_live_sink) list) Hashtbl.t =
  Hashtbl.create 16
;;

let operation_live_sinks_mu = Stdlib.Mutex.create ()
let next_operation_live_sink_id = Atomic.make 0

let register_operation_live_sink ~operation_id sink =
  let sink_id = Atomic.fetch_and_add next_operation_live_sink_id 1 in
  Stdlib.Mutex.protect operation_live_sinks_mu (fun () ->
    let current =
      Option.value ~default:[] (Hashtbl.find_opt operation_live_sinks operation_id)
    in
    Hashtbl.replace operation_live_sinks operation_id ((sink_id, sink) :: current));
  fun () ->
    Stdlib.Mutex.protect operation_live_sinks_mu (fun () ->
      match Hashtbl.find_opt operation_live_sinks operation_id with
      | None -> ()
      | Some sinks ->
        let remaining = List.filter (fun (id, _) -> id <> sink_id) sinks in
        if remaining = []
        then Hashtbl.remove operation_live_sinks operation_id
        else Hashtbl.replace operation_live_sinks operation_id remaining)
;;

let publish_operation_live_event ~operation_id event =
  let sinks =
    Stdlib.Mutex.protect operation_live_sinks_mu (fun () ->
      Option.value ~default:[] (Hashtbl.find_opt operation_live_sinks operation_id))
  in
  List.iter
    (fun (_, sink) ->
       try sink event with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "keeper_stream: operation live sink failed operation_id=%s error=%s"
           operation_id
           (Printexc.to_string exn))
    sinks
;;

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
  request_id : Keeper_owner.Chat_operation.Operation_id.t;
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
  direct_message : Keeper_invocation_contract.direct_message;
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

let combined_turn_instructions ~turn_instructions ~surface_context =
  let ctx_text =
    match surface_context with
    | Some ctx -> format_surface_context ctx
    | None -> ""
  in
  match turn_instructions with
  | None -> if ctx_text = "" then None else Some ctx_text
  | Some ti ->
      if ctx_text = "" then Some ti
      else Some (ti ^ "\n\n" ^ ctx_text)

let turn_instructions_for_request payload =
  combined_turn_instructions
    ~turn_instructions:payload.turn_instructions
    ~surface_context:payload.surface_context

let direct_message_of_request payload = payload.direct_message

let modalities_for_request payload =
  match Keeper_multimodal_input.modalities payload.user_blocks with
  | [] -> [ "text" ]
  | labels -> labels

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

(* No cumulative timeout or work budget for keeper_msg. Keeper calls AGENT_CORE with
   unbounded turn/idle sentinels; turn, token, and cost usage are observations,
   not lifecycle authority. Explicit cancellation plus provider/tool progress
   boundaries settle real liveness failures without discarding the request or
   its terminal receipt. *)

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

let keeper_stream_disposition_of_result :
  Tool_result.result ->
  (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition =
  function
  | Tool_result.Completed _ -> Tool_result.Completed ()
  | Tool_result.Deferred _ -> Tool_result.Deferred ()
  | Tool_result.Failed { class_; _ } -> Tool_result.Failed class_

let keeper_stream_success = function
  | Tool_result.Completed () | Tool_result.Deferred () -> true
  | Tool_result.Failed _ -> false

let parse_keeper_chat_stream_request body_str =
  try
    let ( let* ) = Result.bind in
    let json = Yojson.Safe.from_string body_str in
    let* fields =
      match json with
      | `Assoc fields ->
        let allowed =
          [ "request_id"
          ; "name"
          ; "message"
          ; "user_blocks"
          ; "turn_instructions"
          ; "surface_context"
          ; "channel"
          ; "channel_user_id"
          ; "channel_user_name"
          ; "channel_workspace_id"
          ; "attachments"
          ]
        in
        let keys = List.map fst fields in
        if List.length keys <> List.length (List.sort_uniq String.compare keys)
        then Error "request body must contain unique fields"
        else
          (match List.find_opt (fun key -> not (List.mem key allowed)) keys with
           | None -> Ok fields
           | Some key ->
             Error
               (Printf.sprintf
                  "request body field %s is undeclared; accepted fields: %s"
                  key
                  (String.concat ", " allowed)))
      | _ -> Error "request body must be a JSON object"
    in
    let required_string key =
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | Some _ -> Error (key ^ " must be a string")
      | None -> Error (key ^ " is required")
    in
    let optional_string key =
      match List.assoc_opt key fields with
      | None -> Ok ""
      | Some (`String value) -> Ok value
      | Some _ -> Error (key ^ " must be a string")
    in
    let* request_id = required_string "request_id" in
    let* request_id = Keeper_owner.Chat_operation.Operation_id.of_string request_id in
    let* name = required_string "name" |> Result.map String.trim in
    let* raw_message = optional_string "message" |> Result.map String.trim in
    let* channel = optional_string "channel" |> Result.map String.trim in
    let* channel_user_id =
      optional_string "channel_user_id" |> Result.map String.trim
    in
    let* channel_user_name =
      optional_string "channel_user_name" |> Result.map String.trim
    in
    let* channel_workspace_id =
      optional_string "channel_workspace_id" |> Result.map String.trim
    in
    let* turn_instructions =
      match List.assoc_opt "turn_instructions" fields with
      | None -> Ok None
      | Some (`String value) ->
        let value = String.trim value in
        Ok (if String.equal value "" then None else Some value)
      | Some _ -> Error "turn_instructions must be a string"
    in
    let* surface_context =
      match List.assoc_opt "surface_context" fields with
      | None | Some `Null -> Ok None
      | Some (`Assoc _ as context) -> Ok (Some context)
      | Some _ -> Error "surface_context must be an object"
    in
    let* attachments = Keeper_multimodal_input.parse_attachments json in
    let* user_blocks = Keeper_multimodal_input.parse_user_blocks json in
    let message =
      if String.equal raw_message ""
      then Keeper_multimodal_input.fallback_message ~attachments user_blocks
      else raw_message
    in
    let has_connector_context =
      channel <> "" || channel_user_id <> ""
      || channel_user_name <> "" || channel_workspace_id <> ""
    in
    if has_connector_context && (channel = "" || channel_workspace_id = "")
    then
      Error
        "channel and channel_workspace_id are required when connector context is supplied"
    else
      let invocation_prompt =
        if channel <> "" && channel_workspace_id <> "" && channel_user_id <> ""
        then
          Gate_keeper_backend.contextualize_message
            ~channel
            ~channel_user_id
            ~channel_user_name
            ~channel_workspace_id
            ~metadata:[]
            ~content:message
        else message
      in
      let combined_turn_instructions =
        combined_turn_instructions ~turn_instructions ~surface_context
      in
      let* direct_message =
        Keeper_invocation_contract.direct_message
          ~keeper_name:name
          ~prompt:invocation_prompt
          ~direct_reply:true
          ?turn_instructions:combined_turn_instructions
          ~channel
          ~user_blocks
          ~attachments
          ()
        |> Result.map_error Keeper_invocation_contract.request_error_to_string
      in
      Ok
        { request_id
        ; name
        ; message
        ; user_blocks
        ; turn_instructions
        ; surface_context
        ; channel
        ; channel_user_id
        ; channel_user_name
        ; channel_workspace_id
        ; attachments
        ; direct_message
        }
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

type operation_payload =
  { payload : keeper_chat_stream_request
  ; source : Keeper_chat_operation_payload.decoded_source
  }

let operation_input_of_payload payload =
  Keeper_chat_operation_payload.input_to_json
    ~message:payload.message
    ~user_blocks:payload.user_blocks
    ~turn_instructions:payload.turn_instructions
    ~surface_context:payload.surface_context
    ~attachments:payload.attachments
;;

let operation_source_of_payload
      ~thread_id
      ~submitted_by
      ~user_row_origin
      payload
  =
  let ( let* ) = Result.bind in
  let* continuation_channel =
    if has_external_speaker payload
    then Error "connector operations must enter through the typed connector ingress"
    else Keeper_continuation_channel.dashboard ~thread_id
  in
  Keeper_chat_operation_payload.source_to_json
    ~submitted_by
    ~thread_id
    ~continuation_channel
    ~surface:(chat_surface_of_request payload)
    ~channel:payload.channel
    ~channel_user_id:payload.channel_user_id
    ~channel_user_name:payload.channel_user_name
    ~channel_workspace_id:payload.channel_workspace_id
    ~conversation_id:None
    ~external_message_id:None
    ~workspace_id:None
    ~extra_mentions:[]
    ~user_row_origin
;;

let operation_payload_of_json ~keeper_name ~operation_id ~source ~input =
  let ( let* ) = Result.bind in
  let* source = Keeper_chat_operation_payload.source_of_json source in
  let* input = Keeper_chat_operation_payload.input_of_json input in
  let raw_message = String.trim input.message in
  let message =
    if String.equal raw_message ""
    then
      Keeper_multimodal_input.fallback_message
        ~attachments:input.attachments
        input.user_blocks
    else raw_message
  in
  let invocation_prompt =
    if String.trim source.channel_user_id = ""
    then message
    else
      Gate_keeper_backend.contextualize_message
        ~channel:source.channel
        ~channel_user_id:source.channel_user_id
        ~channel_user_name:source.channel_user_name
        ~channel_workspace_id:source.channel_workspace_id
        ~metadata:[]
        ~content:message
  in
  let turn_instructions =
    combined_turn_instructions
      ~turn_instructions:input.turn_instructions
      ~surface_context:input.surface_context
  in
  let* direct_message =
    Keeper_invocation_contract.direct_message
      ~keeper_name
      ~prompt:invocation_prompt
      ~direct_reply:true
      ?turn_instructions
      ~channel:source.channel
      ~user_blocks:input.user_blocks
      ~attachments:input.attachments
      ()
    |> Result.map_error Keeper_invocation_contract.request_error_to_string
  in
  let payload =
    { request_id = operation_id
    ; name = keeper_name
    ; message
    ; user_blocks = input.user_blocks
    ; turn_instructions = input.turn_instructions
    ; surface_context = input.surface_context
    ; channel = source.channel
    ; channel_user_id = source.channel_user_id
    ; channel_user_name = source.channel_user_name
    ; channel_workspace_id = source.channel_workspace_id
    ; attachments = input.attachments
    ; direct_message
    }
  in
  Ok { payload; source }
;;

let strip_keeper_visible_reply (reply : string) =
  String.trim reply

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
    Calls the private direct-delivery stream which forwards MODEL text deltas to [on_text_delta].
    Projects the typed keeper result into the local HTTP stream response pair.
    No external timeout — keeper internal limits control duration
    (aligned with MCP path, see mcp_server_eio_call_tool.ml:139-143). *)
let execute_keeper_stream_tool_streaming
      ~sw
      ~clock
      ?auth_token:_
      ?on_event
      ?on_admitted
      ?admission_token
      state
      ~agent_name
      ~message
      ~continuation_channel
      ~on_text_delta
  =
  let workspace_scope = Mcp_server.workspace_scope state in
  let config = workspace_scope.config in
  let start_time = Eio.Time.now clock in
  let admission_rejection = ref None in
  let body, disposition =
    try
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name;
          sw;
          clock;
          proc_mgr = state.Mcp_server.proc_mgr;
          net = state.Mcp_server.net;
          publication_recovery_provider =
            Mcp_server.publication_recovery_availability_provider state;
        }
      in
      let dispatched =
        match admission_token with
        | None ->
          Keeper_tool_surface.dispatch_keeper_msg_stream
            ~on_text_delta
            ?on_event
            ~on_admission_rejected:(fun rejection ->
              admission_rejection := Some rejection)
            ?on_admitted
            keeper_ctx
            ~continuation_channel
            ~message
        | Some admission_token ->
          Keeper_tool_surface.dispatch_keeper_msg_stream_admitted
            ~admission_token
            ~on_text_delta
            ?on_event
            keeper_ctx
            ~continuation_channel
            ~message
      in
      match dispatched with
      | Some result ->
          let body = Tool_result.message result in
          body, keeper_stream_disposition_of_result result
      | None ->
        ( "masc_keeper_msg stream dispatch unavailable"
        , Tool_result.Failed Tool_result.Runtime_failure )
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Workspace.Not_initialized ->
        ( Masc_domain.masc_error_to_string
            (Masc_domain.System Masc_domain.System_error.NotInitialized)
        , Tool_result.Failed Tool_result.Runtime_failure )
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed (stream): %s" err;
        ( Printf.sprintf "Internal error: %s" err
        , Tool_result.Failed Tool_result.Runtime_failure )
  in
  match !admission_rejection with
  | Some rejection -> `Deferred rejection
  | None ->
      let success = keeper_stream_success disposition in
      let end_time = Eio.Time.now clock in
      let duration_ms = Keeper_timing.elapsed_duration_ms ~start_time ~end_time in
      let error_detail =
        if success then None
        else Some (keeper_tool_failure_error_detail ~duration_ms ~error_body:body)
      in
      Audit_log.log_tool_call config
        ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success
        ~error_msg:error_detail ();
      (match disposition with
       | Tool_result.Failed failure_class ->
         Log.Keeper.emit Log.Error
           ~details:
             (keeper_tool_failure_log_details ~tool_name:"masc_keeper_msg"
                ~agent_name ~duration_ms ~streaming:true ~error_body:body
                ~failure_class)
           "keeper tool call failed: masc_keeper_msg"
       | Tool_result.Completed () | Tool_result.Deferred () -> ());
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
                 match disposition with
                 | Tool_result.Failed failure_class -> Some failure_class
                 | Tool_result.Completed () | Tool_result.Deferred () -> None
               in
               Telemetry_eio.track_tool_called ~fs config
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
        ~tool_name:"masc_keeper_msg"
        ~disposition
        ~duration_ms
        ();
      `Ran (success, body)

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
  match Keeper_turn_outcome.of_reply_payload payload_json_opt with
  | Error error ->
    Some
      ("Keeper reply contract error: "
       ^ Keeper_turn_outcome.decode_error_to_string error)
  | Ok turn_outcome ->
    (match
       turn_outcome, String_util.trim_to_option visible_reply, has_visible_blocks
     with
     | Keeper_turn_outcome.Continuation_checkpoint, _, _ -> None
     | Keeper_turn_outcome.External_effect_completed, _, _ -> None
     | Keeper_turn_outcome.External_effect_pending, _, _ -> None
     | Keeper_turn_outcome.No_visible_reply, _, true -> None
     | Keeper_turn_outcome.Visible_reply, None, true -> None
     | Keeper_turn_outcome.No_visible_reply, _, false ->
       Some empty_direct_reply_error
     | Keeper_turn_outcome.Visible_reply, None, false ->
       Some empty_direct_reply_error
     | Keeper_turn_outcome.Visible_reply, Some _, _ -> None)

let persisted_reply_blocks ~turn_outcome media_blocks =
  match turn_outcome, media_blocks with
  | Keeper_turn_outcome.Continuation_checkpoint, Some media_blocks ->
    Some
      (Keeper_chat_blocks.Status
         { kind = Keeper_chat_blocks.Continuation_checkpoint }
       :: media_blocks)
  | Keeper_turn_outcome.Continuation_checkpoint, None ->
    Some
      [ Keeper_chat_blocks.Status
          { kind = Keeper_chat_blocks.Continuation_checkpoint }
      ]
  | Keeper_turn_outcome.External_effect_pending, Some media_blocks ->
    Some
      (Keeper_chat_blocks.Status
         { kind = Keeper_chat_blocks.External_effect_pending }
       :: media_blocks)
  | Keeper_turn_outcome.External_effect_pending, None ->
    Some
      [ Keeper_chat_blocks.Status
          { kind = Keeper_chat_blocks.External_effect_pending }
      ]
  | ( Keeper_turn_outcome.Visible_reply
    | Keeper_turn_outcome.External_effect_completed
    | Keeper_turn_outcome.No_visible_reply ),
    media_blocks ->
    media_blocks

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

let keeper_request_terminal_status_is_routine = function
  | Request_deferred
  | Request_queued
  | Request_stream (Stream_done | Stream_cancelled | Stream_reconciliation_required) ->
    true
  | Request_stream (Stream_error | Stream_rejected) -> false
;;

let chat_request_terminal_status = function
  | Request_deferred -> Keeper_chat_events.Deferred
  | Request_queued -> Keeper_chat_events.Queued
  | Request_stream Stream_done -> Keeper_chat_events.Done
  | Request_stream Stream_error -> Keeper_chat_events.Error
  | Request_stream Stream_cancelled -> Keeper_chat_events.Cancelled
  | Request_stream Stream_rejected -> Keeper_chat_events.Rejected
  | Request_stream Stream_reconciliation_required ->
      Keeper_chat_events.Acceptance_uncertain
;;

type keeper_stream_worker_event =
  | Stream_event of Agent_core.Types.sse_event
  | Stream_client_disconnected
  | Stream_queued_turn_deferred of Keeper_turn_admission.rejection
  | Stream_terminal of
      { status : keeper_stream_terminal_status
      ; body : string
      ; queued_outcome : queued_turn_outcome option
      }

and keeper_stream_completion =
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

type turn_submission =
  | Direct_request
  | Owner_operation of
      { operation_id : Keeper_owner.Chat_operation.Operation_id.t
      ; admission_token : Keeper_turn_admission.token
      ; execution_sw : Eio.Switch.t
      ; surface : Surface_ref.t
      ; speaker : Keeper_chat_store.speaker
      ; conversation_id : string option
      ; external_message_id : string option
      ; workspace_id : string option
      ; extra_mentions : Keeper_identity.Keeper_id.t list
      }
  | Queued_receipt of
      { receipt_ids : Keeper_chat_delivery_identity.Receipt_ids.t
      ; claim : unit -> (unit, string) result
      ; execution_sw : Eio.Switch.t
      }

let completion_of_worker_settlement ~queued_turn ~staged_completion
    (settlement : Keeper_msg_async.worker_settlement) =
  let queued_failure kind detail =
    if queued_turn then Some (Failed { kind; detail }) else None
  in
  match settlement with
  | Keeper_msg_async.Settlement_projection_error { poll_result; _ } ->
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
  | Keeper_msg_async.Status_settlement { entry; durability; origin } ->
    let status = entry.Keeper_msg_async.status in
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
       , Keeper_msg_async.Done { ok; body; _ } ) ->
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
       , Keeper_msg_async.Done { ok; body; _ } ) ->
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

let queued_turn_deferred_event
    ({ Keeper_turn_admission.waiting
     ; in_flight
     ; shutdown_operation_id
     } : Keeper_turn_admission.rejection) =
  let in_flight =
    match in_flight with
    | None -> None
    | Some { Keeper_turn_admission.lane; started_at } ->
        let lane =
          match lane with
          | Keeper_turn_admission.Autonomous -> Keeper_chat_events.Autonomous_lane
          | Keeper_turn_admission.Chat -> Keeper_chat_events.Chat_lane
        in
        Some { Keeper_chat_events.lane; started_at }
  in
  Keeper_chat_events.Queued_turn_deferred
    { waiting
    ; in_flight
    ; shutdown_operation_id =
        Option.map Keeper_shutdown_types.Operation_id.to_string
          shutdown_operation_id
    }

let queued_turn_failure_kind_to_string = function
  | Turn_failed -> "turn_failed"
  | Turn_cancelled -> "turn_cancelled"
  | No_visible_reply -> "no_visible_reply"
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

let committed_delivery_outcome ~queued_turn ~turn_ref = function
  | Error persist_error -> Error persist_error
  | Ok () ->
      Ok
        (if queued_turn
         then Some (queued_delivery_outcome_of_turn_ref turn_ref)
         else None)

let empty_reply_delivery_plan ~queued_turn ~has_visible_blocks ~has_tool_calls =
  if has_visible_blocks
  then `Visible_blocks
  else if has_tool_calls
  then `Tool_calls_only
  else if queued_turn
  then `Failure
  else `User_only

type keeper_stream_bridge_state = Keeper_chat_agent_core_stream_bridge.state

type translated_keeper_stream_event =
  Keeper_chat_agent_core_stream_bridge.translated_event =
  { bridge_state : keeper_stream_bridge_state
  ; chat_events : Keeper_chat_events.keeper_chat_event list
  }

let empty_keeper_stream_bridge_state = Keeper_chat_agent_core_stream_bridge.empty_state
let translate_agent_core_stream_event = Keeper_chat_agent_core_stream_bridge.translate

(* [user_row_origin] and [submission] are required labelled arguments. Every
   caller presents the typed transcript provenance and execution ownership
   selected at its persistence boundary; this function never infers either
   from a connector label or message content. *)
let process_single_turn ~user_row_origin ~submission
    ~state ~clock ~auth_token ~thread_id ~continuation_channel ~closed
    ~client_disconnects
    ~payload ~run_id ~message_id ~agent_name ~submitted_by
    ~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t) =
  let queued_turn =
    match submission with
    | Direct_request -> false
    | Owner_operation _ | Queued_receipt _ -> true
  in
  let base_path = (Mcp_server.workspace_config state).base_path in
  let direct_delivery_checkpoint : Keeper_chat_direct_delivery.t option ref =
    ref None
  in
  let queue_claim_failure = ref None in
  let queue_claim_committed =
    ref
      (match submission with
       | Owner_operation _ -> true
       | Direct_request | Queued_receipt _ -> false)
  in
  let queued_turn_not_started () =
    queued_turn && not !queue_claim_committed
  in
  let redaction =
    Keeper_secret_redaction.snapshot ~base_path ~keeper_name:payload.name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
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
  let direct_message = direct_message_of_request payload in
  (* Stream model text deltas live with per-delta redaction. The typed AGENT_CORE
     bridge owns per-provider-message state so only the final provider
     message controls terminal resend suppression; canonical terminal content
     always comes from the assembled AGENT_CORE response carried by [body]. *)
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
  let report_direct_checkpoint_error ~operation checkpoint detail =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LifecycleCallbackFailures)
      ~labels:[ "callback", "keeper_chat_direct_delivery"; "operation", operation ]
      ();
    Log.Keeper.error
      "keeper_stream: direct checkpoint %s failed keeper=%s request_id=%s phase=%s error=%s"
      operation
      checkpoint.Keeper_chat_direct_delivery.payload.keeper_name
      (Keeper_chat_direct_delivery.Request_id.to_string checkpoint.request_id)
      (Keeper_chat_direct_delivery.phase_kind_to_string
         (Keeper_chat_direct_delivery.phase_kind checkpoint.phase))
      detail
  in
  let cleanup_direct_checkpoint () =
    match !direct_delivery_checkpoint with
    | None -> ()
    | Some checkpoint ->
      (match checkpoint.Keeper_chat_direct_delivery.phase with
       | Keeper_chat_direct_delivery.Transcript_committed _ ->
         (match
            Keeper_chat_direct_delivery.observe_async_terminal
              ~base_path
              ~identity:checkpoint
          with
          | Error error ->
            report_direct_checkpoint_error
              ~operation:"observe_async_terminal"
              checkpoint
              (Keeper_chat_direct_delivery.error_to_string error)
          | Ok proof ->
            (match
               Keeper_chat_direct_delivery.remove_after_async_terminal
                 ~base_path
                 ~identity:checkpoint
                 ~proof
             with
             | Ok () -> direct_delivery_checkpoint := None
             | Error error ->
               report_direct_checkpoint_error
                 ~operation:"remove_after_async_terminal"
                 checkpoint
                 (Keeper_chat_direct_delivery.error_to_string error)))
       | ( Keeper_chat_direct_delivery.Prepared
         | Keeper_chat_direct_delivery.User_row_committed _
         | Keeper_chat_direct_delivery.Running _
         | Keeper_chat_direct_delivery.Effect_staged _ ) ->
         report_direct_checkpoint_error
           ~operation:"terminal_before_transcript_commit"
           checkpoint
           "canonical request terminal committed while its direct transcript checkpoint remains incomplete")
  in
  let publish_committed_completion
      (settlement : Keeper_msg_async.worker_settlement) =
    cleanup_direct_checkpoint ();
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
        | Keeper_msg_async.Status_settlement { entry; _ } ->
          Keeper_msg_async.status_to_string entry.status
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
  let chat_surface =
    match submission with
    | Owner_operation { surface; _ } -> surface
    | Direct_request | Queued_receipt _ -> chat_surface_of_request payload
  in
  let chat_source = Surface_ref.lane_label chat_surface in
  (* RFC-0223 P1: authority derives from the arrival route. A non-empty
     [channel_user_id] means an arbitrary external person on that channel;
     a channel label without a user id (e.g. dashboard Copilot Dock) is
     still an authenticated dashboard operator, so it keeps Owner authority
     while recording the Gate surface label. *)
  let chat_speaker : Keeper_chat_store.speaker =
    match submission with
    | Owner_operation { speaker; _ } -> speaker
    | Direct_request | Queued_receipt _ -> chat_speaker_of_request payload
  in
  let operation_delivery_coordinates =
    match submission with
    | Owner_operation { conversation_id; external_message_id; workspace_id; _ } ->
      conversation_id, external_message_id, workspace_id
    | Direct_request | Queued_receipt _ -> None, None, None
  in
  let operation_extra_mentions =
    match submission with
    | Owner_operation { extra_mentions; _ } -> extra_mentions
    | Direct_request | Queued_receipt _ -> []
  in
  let dashboard_direct_stream =
    (not queued_turn)
    && (match user_row_origin with
        | Keeper_chat_store.Needs_append -> true
        | Keeper_chat_store.Already_persisted _
        | Keeper_chat_store.Already_persisted_upstream -> false)
    && not (has_external_speaker payload)
  in
  let direct_delivery_error error =
    Keeper_chat_direct_delivery.error_to_string error
  in
  let set_direct_delivery_checkpoint checkpoint =
    direct_delivery_checkpoint := Some checkpoint
  in
  let queue_delivery_key () =
    match submission with
    | Owner_operation { operation_id; _ } ->
      Keeper_chat_delivery_identity.Request_id.of_string
        (Keeper_owner.Chat_operation.Operation_id.to_string operation_id)
      |> Result.map (fun operation_id ->
        Keeper_chat_delivery_identity.Operation operation_id)
    | Queued_receipt { receipt_ids; _ } ->
      Ok (Keeper_chat_delivery_identity.Queue_receipts receipt_ids)
    | Direct_request ->
      Error "non-queued Keeper turn requested queue delivery identity"
  in
  let append_queued_user_row_once () =
    let ( let* ) = Result.bind in
    let* delivery_key = queue_delivery_key () in
    let conversation_id, external_message_id, workspace_id =
      operation_delivery_coordinates
    in
    match user_row_origin with
    | Keeper_chat_store.Needs_append ->
      Keeper_chat_store.append_user_message_once
        ~base_dir:base_path
        ~keeper_name:payload.name
        ~delivery_key
        ~content:payload.message
        ~attachments:payload.attachments
        ~surface:chat_surface
        ~speaker:chat_speaker
        ?conversation_id
        ?external_message_id
        ?workspace_id
        ~extra_mentions:operation_extra_mentions
        ()
      |> Result.map (fun _ -> ())
    | Keeper_chat_store.Already_persisted _
    | Keeper_chat_store.Already_persisted_upstream ->
      Ok ()
  in
  let append_queued_assistant_once ~content ?(tool_calls = []) ?blocks ?turn_ref () =
    let ( let* ) = Result.bind in
    let* delivery_key = queue_delivery_key () in
    let conversation_id, _, _ = operation_delivery_coordinates in
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:payload.name
      ~delivery_key
      ~content
      ~tool_calls
      ~surface:chat_surface
      ?conversation_id
      ?blocks
      ?turn_ref
      ~stream_lifecycle:completed_stream_lifecycle
      ()
    |> Result.map (fun _ -> ())
  in
  let append_queued_transport_failure_once ?(tool_calls = []) ?blocks ?turn_ref content =
    let ( let* ) = Result.bind in
    let* delivery_key = queue_delivery_key () in
    let conversation_id, _, _ = operation_delivery_coordinates in
    Keeper_chat_store.append_assistant_message_once
      ~base_dir:base_path
      ~keeper_name:payload.name
      ~delivery_key
      ~content
      ~tool_calls
      ~surface:chat_surface
      ?conversation_id
      ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
      ?blocks
      ?turn_ref
      ~stream_lifecycle:errored_stream_lifecycle
      ()
    |> Result.map (fun _ -> ())
  in
  let append_queued_tool_calls_once ?turn_ref tool_calls =
    let ( let* ) = Result.bind in
    let* delivery_key = queue_delivery_key () in
    let conversation_id, _, _ = operation_delivery_coordinates in
    Keeper_chat_store.append_tool_calls_once
      ~base_dir:base_path
      ~keeper_name:payload.name
      ~delivery_key
      ~tool_calls
      ~surface:chat_surface
      ?conversation_id
      ?turn_ref
      ()
    |> Result.map (fun _ -> ())
  in
  let on_direct_request_accepted request_id =
    let ( let* ) = Result.bind in
    let* request_id =
      Keeper_chat_delivery_identity.Request_id.of_string request_id
    in
    let accepted_payload : Keeper_chat_direct_delivery.accepted_payload =
      { keeper_name = payload.name
      ; submitted_by
      ; user_content = payload.message
      ; user_attachments = payload.attachments
      ; surface = chat_surface
      ; conversation_id = None
      ; external_message_id = None
      ; speaker = chat_speaker
      }
    in
    let* prepared =
      Keeper_chat_direct_delivery.prepare
        ~base_path
        ~request_id
        ~payload:accepted_payload
        ~now:(Time_compat.now ())
      |> Result.map_error direct_delivery_error
    in
    set_direct_delivery_checkpoint prepared;
    let* user_committed =
      Keeper_chat_direct_delivery.commit_user_row
        ~base_path
        ~identity:prepared
        ~now:(Time_compat.now ())
      |> Result.map_error direct_delivery_error
    in
    set_direct_delivery_checkpoint user_committed;
    let* running =
      Keeper_chat_direct_delivery.mark_running
        ~base_path
        ~identity:user_committed
        ~now:(Time_compat.now ())
      |> Result.map_error direct_delivery_error
    in
    set_direct_delivery_checkpoint running;
    Ok ()
  in
  let on_queue_turn_admitted () =
    let ( let* ) = Result.bind in
    let* () =
      match submission with
      | Queued_receipt { claim; _ } ->
        (match claim () with
         | Ok () ->
           queue_claim_committed := true;
           Ok ()
         | Error detail ->
           queue_claim_failure := Some detail;
           Error detail)
      | Owner_operation _ | Direct_request ->
        let detail =
          "direct Keeper turn reached the queued receipt claim boundary"
        in
        queue_claim_failure := Some detail;
        Error detail
    in
    append_queued_user_row_once ()
  in
  let commit_direct_terminal ~ok ~body ~data transcript_effect =
    let ( let* ) = Result.bind in
    match !direct_delivery_checkpoint with
    | None -> Error "direct Keeper delivery checkpoint is unavailable"
    | Some checkpoint ->
      let* staged =
        Keeper_chat_direct_delivery.stage_effect
          ~base_path
          ~identity:checkpoint
          ~staged:
            { Keeper_chat_direct_delivery.request_result = { ok; body; data }
            ; transcript_effect
            }
          ~now:(Time_compat.now ())
        |> Result.map_error direct_delivery_error
      in
      set_direct_delivery_checkpoint staged;
      let* committed =
        Keeper_chat_direct_delivery.commit_transcript
          ~base_path
          ~identity:staged
          ~now:(Time_compat.now ())
        |> Result.map_error direct_delivery_error
      in
      set_direct_delivery_checkpoint committed;
      Ok ()
  in
  (* RFC-0301 item 6: collect generated media from the same stream so the assistant
     turn can persist it as reload-visible chat blocks. The bridge surfaces this
     media live over SSE; the persist site records it durably (see the persist arm
     below). Content-addressed, so the two persists reuse one file. *)
  let worker_media_accum = Keeper_stream_media_accum.create () in
  (* The same stream carries this turn's tool calls. Without collecting them the
     persist site below has nothing to pass as [?tool_calls], so history rows
     hold no tool rows and a reload loses the tool timeline the live stream
     showed. *)
  let worker_tool_accum = Keeper_stream_tool_accum.create () in
  let on_event evt =
    Keeper_stream_media_accum.on_event worker_media_accum evt;
    Keeper_stream_tool_accum.on_event worker_tool_accum evt;
    push_worker_event (Stream_event evt)
  in
  let accumulated_media_blocks () =
    match
      Keeper_stream_media_accum.to_chat_blocks ~base_dir:base_path
        worker_media_accum
    with
    | [] -> None
    | media_blocks -> Some media_blocks
  in
  let persist_user_message_only () =
    if Option.is_some !direct_delivery_checkpoint || queued_turn
    then ()
    else
      match user_row_origin with
      | Keeper_chat_store.Needs_append ->
        Keeper_chat_store.append_user_message
          ~base_dir:base_path
          ~keeper_name:payload.name
          ~content:payload.message
          ~attachments:payload.attachments
          ~surface:chat_surface
          ~speaker:chat_speaker
          ()
      | Keeper_chat_store.Already_persisted _
      | Keeper_chat_store.Already_persisted_upstream ->
        ()
  in
  let persist_failure_reply ?blocks ?turn_ref err =
    (* The failure marker is typed, not an utterance: it renders for the
       operator but does not advance the lane watermark, so the user
       message it failed to answer stays pending for the keeper's next
       turn — and the keeper never reads the error as its own words. Any
       completed media block was already delivered live, so a failure must
       retain it for reload just as a successful terminal does. *)
    let blocks =
      match blocks with
      | Some _ -> blocks
      | None -> accumulated_media_blocks ()
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatTransportFailures)
      ~labels:[ ("keeper", payload.name); ("source", chat_source) ]
      ();
    let content = persisted_error_reply err in
    let tool_calls = Keeper_stream_tool_accum.to_tool_calls worker_tool_accum in
    let persisted =
      if Option.is_some !direct_delivery_checkpoint
      then
        commit_direct_terminal
          ~ok:false
          ~body:err
          ~data:None
          (Keeper_chat_direct_delivery.Transport_failure
             { content; blocks; turn_ref; tool_calls })
      else if queued_turn
      then append_queued_transport_failure_once ~tool_calls ?blocks ?turn_ref content
      else
        match user_row_origin with
        | Keeper_chat_store.Needs_append ->
          Keeper_chat_store.append_turn_result
            ~base_dir:base_path
            ~keeper_name:payload.name
            ~user_content:payload.message
            ~user_attachments:payload.attachments
            ~surface:chat_surface
            ~speaker:chat_speaker
            ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
            ~tool_calls
            ~assistant_content:content
            ?blocks
            ?turn_ref
            ~stream_lifecycle:errored_stream_lifecycle
            ()
        | Keeper_chat_store.Already_persisted _
        | Keeper_chat_store.Already_persisted_upstream ->
          Keeper_chat_store.append_assistant_message_result
            ~base_dir:base_path
            ~keeper_name:payload.name
            ~content
            ~tool_calls
            ~surface:chat_surface
            ~assistant_kind:Keeper_chat_store.Row_kind.Transport_failure
            ?blocks
            ?turn_ref
            ~stream_lifecycle:errored_stream_lifecycle
            ()
    in
    Result.iter
      (fun () ->
         Keeper_chat_broadcast.chat_appended
           ~keeper_name:payload.name ~source:chat_source
           ~content:(persisted_error_reply err)
           ())
      persisted;
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
  let run_turn request_sw =
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
          Tool_result.error
            ~failure_class:Tool_result.Runtime_failure
            ~tool_name:"masc_keeper_msg"
            ~start_time
            detail
        in
        let on_admitted =
          match submission with
          | Queued_receipt _ -> Some on_queue_turn_admitted
          | Direct_request | Owner_operation _ -> None
        in
        let admission_token =
          match submission with
          | Owner_operation { admission_token; _ } -> Some admission_token
          | Direct_request | Queued_receipt _ -> None
        in
        let payload_identity =
          let direct_target =
            Keeper_invocation_contract.direct_message_target_name direct_message
          in
          if String.equal payload.name direct_target && String.trim payload.name <> ""
          then Ok ()
          else Error "Keeper chat payload identity does not match its direct message"
        in
        let operation_prepare =
          match payload_identity, submission with
          | Error _ as error, _ -> error
          | Ok (), Owner_operation _ -> append_queued_user_row_once ()
          | Ok (), (Direct_request | Queued_receipt _) -> Ok ()
        in
        let dispatch_result =
          match operation_prepare with
          | Error _ as error -> error
          | Ok () ->
           (try
            match
              execute_keeper_stream_tool_streaming
                ~sw:request_sw
                ~clock
                ?auth_token
                state ~agent_name ~message:direct_message ~on_event
                ~continuation_channel ~on_text_delta:(fun _ -> ())
                ?admission_token
                ?on_admitted
            with
            | `Ran result -> Ok (`Ran result)
            | `Deferred rejection -> Ok (`Deferred rejection)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn
                "keeper_stream: streaming dispatch raised: %s"
                (Printexc.to_string exn);
              (* A second non-streaming dispatch is a distinct asynchronous
                 turn whose submission acknowledgement returns before its
                 events. Retrying here can duplicate provider/tool effects,
                 while the outer transcript has already consumed its
                 accumulator. Terminalize the original streaming attempt;
                 [persist_failure_reply] retains the calls and media it
                 actually emitted. *)
              Error (Printexc.to_string exn))
        in
        match !queue_claim_failure, dispatch_result with
        | Some detail, _ ->
            (* The exact Pending receipt was not claimed. Close the local event
               projection without emitting [Event_error]: connector adapters
               treat an empty [Run_finished] as a failed no-op, so no outbound
               message or transcript row can escape for a turn that never
               started. The queue consumer retains the typed claim failure and
               decides whether to re-observe or require reconciliation. *)
            push_worker_event
              (Stream_terminal
                 { status = Stream_cancelled
                 ; body = detail
                 ; queued_outcome = None
                 });
            Tool_result.error
              ~failure_class:Tool_result.Runtime_failure
              ~tool_name:"masc_keeper_msg"
              ~start_time
              detail
        | None, Ok (`Deferred rejection) ->
            push_worker_event (Stream_queued_turn_deferred rejection);
            Tool_result.make_ok
              ~tool_name:"masc_keeper_msg"
              ~start_time
              ~data:
                (`Assoc
                   [ ("status", `String "deferred")
                   ; ("admission", admission_rejection_to_json rejection)
                   ])
              ()
        | None, Ok (`Ran (true, body)) ->
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
              persisted_reply_blocks
                ~turn_outcome:canonical_reply.turn_outcome
                (accumulated_media_blocks ())
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
                     match persist_failure_reply ?turn_ref err with
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
                   (match persist_failure_reply ?turn_ref err with
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
                 Tool_result.error
                   ~failure_class:Tool_result.Runtime_failure
                   ~tool_name:"masc_keeper_msg"
                   ~start_time
                   err
             | None ->
                 let tool_calls =
                   Keeper_stream_tool_accum.to_tool_calls worker_tool_accum
                 in
                 let persist_assistant_reply ~assistant_content =
                   if Option.is_some !direct_delivery_checkpoint
                   then
                     commit_direct_terminal
                       ~ok:true
                       ~body
                       ~data:payload_json_opt
                       (Keeper_chat_direct_delivery.Assistant_reply
                          { content = assistant_content; blocks; turn_ref; tool_calls })
                   else if queued_turn
                   then
                     append_queued_assistant_once
                       ~content:assistant_content
                       ~tool_calls
                       ?blocks
                       ?turn_ref
                       ()
                   else
                     match user_row_origin with
                     | Keeper_chat_store.Needs_append ->
                       Keeper_chat_store.append_turn_result
                         ~base_dir:base_path
                         ~keeper_name:payload.name
                         ~user_content:payload.message
                         ~user_attachments:payload.attachments
                         ~tool_calls
                         ~surface:chat_surface
                         ~speaker:chat_speaker
                         ~assistant_content
                         ?blocks
                         ?turn_ref
                         ~stream_lifecycle:completed_stream_lifecycle
                         ()
                     | Keeper_chat_store.Already_persisted _
                     | Keeper_chat_store.Already_persisted_upstream ->
                       Keeper_chat_store.append_assistant_message_result
                         ~base_dir:base_path
                         ~keeper_name:payload.name
                         ~content:assistant_content
                         ~tool_calls
                         ~surface:chat_surface
                         ?blocks
                         ?turn_ref
                         ~stream_lifecycle:completed_stream_lifecycle
                         ()
                 in
                 let persist_tool_calls_only () =
                   if tool_calls = []
                   then Ok ()
                   else if Option.is_some !direct_delivery_checkpoint
                   then
                     commit_direct_terminal
                       ~ok:true
                       ~body
                       ~data:payload_json_opt
                       (Keeper_chat_direct_delivery.Tool_calls_only { tool_calls; turn_ref })
                   else if queued_turn
                   then append_queued_tool_calls_once ?turn_ref tool_calls
                   else
                     match user_row_origin with
                     | Keeper_chat_store.Needs_append ->
                       Keeper_chat_store.append_user_and_tool_calls_result
                         ~base_dir:base_path
                         ~keeper_name:payload.name
                         ~user_content:payload.message
                         ~user_attachments:payload.attachments
                         ~tool_calls
                         ~surface:chat_surface
                         ~speaker:chat_speaker
                         ?turn_ref
                         ()
                     | Keeper_chat_store.Already_persisted _
                     | Keeper_chat_store.Already_persisted_upstream ->
                       Keeper_chat_store.append_tool_calls_result
                         ~base_dir:base_path
                         ~keeper_name:payload.name
                         ~tool_calls
                         ~surface:chat_surface
                         ?turn_ref
                         ()
                 in
                 let delivered_after_persist ?content persisted =
                   match
                     committed_delivery_outcome ~queued_turn ~turn_ref persisted
                   with
                   | Ok queued_outcome ->
                       Keeper_chat_broadcast.chat_appended
                         ~keeper_name:payload.name ~source:chat_source ?content ();
                       Ok queued_outcome
                   | Error _ as error -> error
                 in
                 let turn_outcome = canonical_reply.turn_outcome in
                 let delivery_result =
                   match turn_outcome, String_util.trim_to_option visible_reply with
                   | Keeper_turn_outcome.Continuation_checkpoint, _ ->
                       (* [persisted_reply_blocks] always returns [Some _] for
                          [Continuation_checkpoint] (a typed status block), so
                          [has_visible_blocks] is always true on this arm: a
                          checkpoint turn always persists a delivered assistant
                          row with [content = ""] plus the status block —
                          including turns that also produced tool calls and
                          turns carrying a direct-delivery checkpoint. There is
                          no tool-calls-only or user-only continuation path. *)
                       persist_assistant_reply ~assistant_content:""
                       |> delivered_after_persist
                   | Keeper_turn_outcome.No_visible_reply, _
                   | Keeper_turn_outcome.Visible_reply, None ->
                       let detail =
                         "no visible reply was produced for this queued message"
                       in
                       (match
                          empty_reply_delivery_plan ~queued_turn
                            ~has_visible_blocks
                            ~has_tool_calls:(tool_calls <> [])
                        with
                        | `Visible_blocks ->
                          persist_assistant_reply ~assistant_content:""
                          |> delivered_after_persist
                        | `Tool_calls_only ->
                          Result.bind
                            (persist_tool_calls_only ())
                            (fun () ->
                               Keeper_chat_broadcast.chat_appended
                                 ~keeper_name:payload.name
                                 ~source:chat_source
                                 ();
                               if queued_turn
                               then Ok (Some (queued_delivery_outcome_of_turn_ref turn_ref))
                               else Ok None)
                        | `Failure ->
                          persist_failure_reply ?turn_ref detail
                          |> Result.map (fun () ->
                                 Some (Failed { kind = No_visible_reply; detail }))
                        | `User_only ->
                          persist_user_message_only ();
                          Ok None)
                   | Keeper_turn_outcome.Visible_reply, Some visible_reply ->
                       persist_assistant_reply ~assistant_content:visible_reply
                       |> delivered_after_persist ~content:visible_reply
                   | Keeper_turn_outcome.External_effect_completed, _ ->
                       Result.bind
                         (persist_tool_calls_only ())
                         (fun () ->
                            Keeper_chat_broadcast.chat_appended
                              ~keeper_name:payload.name
                              ~source:chat_source
                              ();
                            if queued_turn
                            then
                              Ok
                                (Some
                                   (queued_delivery_outcome_of_turn_ref turn_ref))
                            else Ok None)
                   | Keeper_turn_outcome.External_effect_pending, _ ->
                       persist_assistant_reply ~assistant_content:""
                       |> delivered_after_persist
                 in
                 (match delivery_result with
                  | Error persist_error ->
                      let queued_outcome =
                        if queued_turn
                        then
                          Some
                            (Failed
                               { kind = Transcript_persist_failed
                               ; detail = persist_error
                               })
                        else None
                      in
                      push_worker_event
                        (Stream_terminal
                           { status = Stream_error
                           ; body = persist_error
                           ; queued_outcome
                           });
                      Tool_result.error
                        ~failure_class:Tool_result.Runtime_failure
                        ~tool_name:"masc_keeper_msg"
                        ~start_time
                        persist_error
                  | Ok queued_outcome ->
                   (match queued_outcome with
                  | Some (Failed { detail; _ }) ->
                      push_worker_event
                        (Stream_terminal
                           { status = Stream_error
                           ; body = detail
                           ; queued_outcome
                      });
                      Tool_result.error
                        ~failure_class:Tool_result.Runtime_failure
                        ~tool_name:"masc_keeper_msg"
                        ~start_time
                        detail
                  | Some (Deferred { rejection }) ->
                      push_worker_event (Stream_queued_turn_deferred rejection);
                      Tool_result.make_ok
                        ~tool_name:"masc_keeper_msg"
                        ~start_time
                        ~data:
                          (`Assoc
                             [ ("status", `String "deferred")
                             ; ( "admission"
                               , admission_rejection_to_json rejection )
                             ])
                        ()
                  | Some (Delivered _) | None ->
                      push_worker_event
                        (Stream_terminal
                           { status = Stream_done
                           ; body
                           ; queued_outcome
                           });
                      (match payload_json_opt with
                       | Some data ->
                           Tool_result.make_ok
                             ~tool_name:"masc_keeper_msg"
                             ~start_time
                             ~data
                             ()
                       | None ->
                           Tool_result.ok
                             ~tool_name:"masc_keeper_msg"
                             ~start_time
                             body)))))
        | None, Ok (`Ran (false, err)) when queued_turn_not_started () ->
            push_worker_event
              (Stream_terminal
                 { status = Stream_cancelled
                 ; body = err
                 ; queued_outcome = None
                 });
            Tool_result.error
              ~failure_class:Tool_result.Runtime_failure
              ~tool_name:"masc_keeper_msg"
              ~start_time
              err
        | None, Ok (`Ran (false, err)) ->
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
            Tool_result.error
              ~failure_class:Tool_result.Runtime_failure
              ~tool_name:"masc_keeper_msg"
              ~start_time
              err
        | None, Error err when queued_turn_not_started () ->
            push_worker_event
              (Stream_terminal
                 { status = Stream_cancelled
                 ; body = err
                 ; queued_outcome = None
                 });
            Tool_result.error
              ~failure_class:Tool_result.Runtime_failure
              ~tool_name:"masc_keeper_msg"
              ~start_time
              err
        | None, Error err ->
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
            Tool_result.error
              ~failure_class:Tool_result.Runtime_failure
              ~tool_name:"masc_keeper_msg"
              ~start_time
              err
  in
  let publish_inline_completion () =
    match !staged_completion with
    | Some completion -> publish_completion completion
    | None ->
      let detail =
        "queued Keeper turn ended without staging a terminal projection"
      in
      publish_completion
        (Completion_terminal
           { status =
               (if queued_turn_not_started ()
                then Stream_cancelled
                else Stream_error)
           ; body = detail
           ; queued_outcome =
               (if queued_turn_not_started ()
                then None
                else Some (Failed { kind = Turn_failed; detail }))
           })
  in
  let submit_result =
    match submission with
    | Owner_operation { execution_sw; _ } | Queued_receipt { execution_sw; _ } ->
      (try
         Eio.Fiber.fork ~sw:execution_sw (fun () ->
           (match Eio.Switch.run (fun request_sw -> run_turn request_sw) with
            | _ -> publish_inline_completion ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              let detail = Printexc.to_string exn in
              push_worker_event
                (Stream_terminal
                   { status =
                       (if queued_turn_not_started ()
                        then Stream_cancelled
                        else Stream_error)
                   ; body = detail
                   ; queued_outcome =
                       (if queued_turn_not_started ()
                        then None
                        else Some (Failed { kind = Turn_failed; detail }))
                   });
              publish_inline_completion ()));
         Ok `Inline
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> Error (Printexc.to_string exn))
    | Direct_request ->
      (match Keeper_msg_async.server_background_switch () with
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
           ~f:run_turn
           ()
         |> Result.map (fun outcome -> `Async outcome)
         |> Result.map_error (fun error ->
           Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string))
  in
  let request_id, durably_accepted =
    match submit_result with
    | Ok `Inline -> None, false
    | Ok
        (`Async
        ({ acceptance = Keeper_msg_async.Durably_accepted; request_id }
          : Keeper_msg_async.submit_outcome)) ->
        Some request_id, true
    | Ok
        (`Async
          ({ acceptance = Keeper_msg_async.Reconciliation_required _; _ } as
            outcome)) ->
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
        let queued_outcome =
          if queued_turn_not_started ()
          then None
          else
            let persisted = persist_failure_reply body in
            if not queued_turn
            then None
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
             { status =
                 (if queued_turn_not_started ()
                  then Stream_cancelled
                  else Stream_rejected)
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
         (Queue_request
            { request_id
            ; destination_id = payload.name
            ; channel =
                (if has_connector_context payload then payload.channel
                 else "dashboard")
            ; actor_id = Some agent_name
            ; modalities = modalities_for_request payload
            ; metadata =
                [ ("projection", "keeper_chat_stream")
                ; ("protocol", "gate_message_request")
                ]
            }))
    (if durably_accepted then request_id else None);
  let publish_terminal ~status ?(message = "") () =
    let message = redact_text message in
    let status_label = keeper_request_terminal_status_to_string status in
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
      (match submission with
       | Owner_operation _ -> ()
       | Direct_request | Queued_receipt _ ->
         Keeper_chat_events.publish events
           (Request_terminal
              { request_id
              ; keeper_name = payload.name
              ; status = chat_request_terminal_status status
              ; message = String_util.trim_to_option message
              }))
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
                  | `Stream_event of Agent_core.Types.sse_event
                  ])))
  in
  let rec consume_worker_events bridge_state =
    match next_worker_projection () with
    | `Client_disconnected -> None
    | `Stream_event evt ->
        let translated =
          translate_agent_core_stream_event ~redact_text
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
          (queued_turn_deferred_event rejection);
        Keeper_chat_events.publish events Text_message_end;
        Keeper_chat_events.publish events (Run_finished { run_id });
        Some (Deferred { rejection })
    | `Completion (Completion_terminal { body; _ })
      when queued_turn_not_started () ->
        let message = redact_text body in
        publish_terminal
          ~status:(Request_stream Stream_cancelled)
          ~message
          ();
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
          let visible_reply = canonical_reply.visible_reply in
          let turn_outcome = canonical_reply.turn_outcome in
          let suppress_terminal_reply =
            match turn_outcome with
            | Keeper_turn_outcome.Continuation_checkpoint
            | Keeper_turn_outcome.External_effect_completed
            | Keeper_turn_outcome.External_effect_pending
            | Keeper_turn_outcome.No_visible_reply ->
                true
            | Keeper_turn_outcome.Visible_reply -> false
          in
          if
            (not suppress_terminal_reply)
            && not
                 (Keeper_chat_agent_core_stream_bridge.terminal_message_had_text
                    bridge_state)
          then
            split_keeper_reply_chunks visible_reply
            |> List.iter (fun chunk ->
                   Keeper_chat_events.publish events (Text_delta chunk));
          Keeper_chat_events.publish events
            (Reply_details
               { reply = visible_reply
               ; turn_outcome
               ; turn_ref = canonical_reply.turn_ref
               });
          if
            Keeper_turn_outcome.equal turn_outcome
              Keeper_turn_outcome.External_effect_completed
          then
            Keeper_chat_events.publish events External_effect_completed;
          if
            Keeper_turn_outcome.equal turn_outcome
              Keeper_turn_outcome.External_effect_pending
          then
            Keeper_chat_events.publish events
              (Status_block
                 { kind = Keeper_chat_blocks.External_effect_pending });
          if
            Keeper_turn_outcome.equal turn_outcome
              Keeper_turn_outcome.Continuation_checkpoint
          then
            begin
              Keeper_chat_events.publish events
                (Status_block
                   { kind = Keeper_chat_blocks.Continuation_checkpoint });
              Keeper_chat_events.publish events
                (Continuation_checkpoint
                   { message = visible_reply; request_id })
            end;
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

let operation_executor ~state ~clock : Keeper_owner.operation_executor =
  fun ~sw ~keeper_name ~claim ->
  let failed ?outcome_ref kind detail =
    Keeper_owner.Operation_failed { kind; detail; outcome_ref }
  in
  let execute_admitted admission_token =
    match claim () with
    | Error error ->
      failed "Store_unavailable" (Keeper_owner.error_to_string error)
    | Ok None ->
      failed "No_queued_operation" "Owner FIFO head disappeared before claim"
    | Ok (Some operation) ->
      (match operation.input with
       | None ->
         failed "Invalid_input" "Running Keeper chat operation has no execution input"
       | Some input ->
         (match
            operation_payload_of_json
              ~keeper_name
              ~operation_id:operation.operation_id
              ~source:operation.source
              ~input
          with
          | Error detail -> failed "Invalid_input" detail
          | Ok operation_payload ->
            let payload = operation_payload.payload in
            let operation_id =
              Keeper_owner.Chat_operation.Operation_id.to_string operation.operation_id
            in
            let events = Keeper_chat_events.create () in
            let closed = ref false in
            let delivery, resolve_delivery = Eio.Promise.create () in
            let settle_delivery result =
              ignore (Eio.Promise.try_resolve resolve_delivery result : bool)
            in
            let drain_events () =
              let rec loop () =
                match Keeper_chat_events.subscribe events with
                | Keeper_chat_events.Run_finished _
                | Keeper_chat_events.Event_error _ -> ()
                | _ -> loop ()
              in
              loop ()
            in
            let fork_adapter run =
              Eio.Fiber.fork ~sw (fun () ->
                match run () with
                | () -> ()
                | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                | exception exn ->
                  settle_delivery (Error (Printexc.to_string exn));
                  drain_events ())
            in
            (match operation_payload.source.continuation_channel with
             | Keeper_continuation_channel.Dashboard _ ->
               fork_adapter (fun () ->
                 let redaction =
                   Keeper_secret_redaction.snapshot
                     ~base_path:(Mcp_server.workspace_config state).base_path
                     ~keeper_name
                 in
                 let redact_text = Keeper_secret_redaction.redact_text redaction in
                 let redact_json = Keeper_secret_redaction.redact_json redaction in
                 let rec loop projection =
                   let event = Keeper_chat_events.subscribe events in
                   let projection, projected =
                     Server_keeper_chat_agui_projection.project
                       ~timestamp:(Time_compat.now ())
                       ~redact_text
                       ~redact_json
                       projection
                       event
                   in
                   Option.iter
                     (fun event ->
                        Keeper_chat_broadcast.operation_event
                          ~keeper_name
                          ~operation_id
                          ~event;
                        publish_operation_live_event ~operation_id event)
                     projected;
                   if Server_keeper_chat_agui_projection.is_terminal event
                   then settle_delivery (Ok ())
                   else loop projection
                 in
                 loop Server_keeper_chat_agui_projection.initial)
             | Keeper_continuation_channel.Discord { channel_id; _ } ->
               (match Sys.getenv_opt "DISCORD_BOT_TOKEN" with
                | Some token when String.trim token <> "" ->
                  fork_adapter (fun () ->
                    Keeper_chat_discord.adapter_loop
                      ~clock
                      ~token:(String.trim token)
                      ~channel_id
                      ~events
                      ~on_send_result:(fun result ->
                        settle_delivery
                          (Result.map_error
                             (fun error ->
                                Format.asprintf "%a" Keeper_chat_discord.pp_error error)
                             result))
                      ())
                | Some _ | None ->
                  settle_delivery (Error "DISCORD_BOT_TOKEN is not configured");
                  fork_adapter drain_events)
             | Keeper_continuation_channel.Slack { channel_id; thread_ts; _ } ->
               (match Env_config_slack.bot_token_opt () with
                | Some token ->
                  fork_adapter (fun () ->
                    Keeper_chat_slack.adapter_loop
                      ~clock
                      ~token
                      ~channel:channel_id
                      ?thread_ts
                      ~events
                      ~on_send_result:(fun result ->
                        settle_delivery
                          (Result.map_error
                             (fun error ->
                                Format.asprintf "%a" Keeper_chat_slack.pp_error error)
                             result))
                      ())
                | None ->
                  settle_delivery (Error "SLACK_BOT_TOKEN is not configured");
                  fork_adapter drain_events)
             | Keeper_continuation_channel.Unrouted { reason } ->
               settle_delivery (Error ("unrouted Keeper chat operation: " ^ reason));
               fork_adapter drain_events);
            let agent_name =
              if has_external_speaker payload
              then
                Gate_keeper_backend.agent_name_for_channel_actor
                  ~channel:payload.channel
                  ~channel_workspace_id:payload.channel_workspace_id
                  ~channel_user_id:payload.channel_user_id
              else operation_payload.source.submitted_by
            in
            let outcome =
              process_single_turn
                ~user_row_origin:operation_payload.source.user_row_origin
                ~submission:
                  (Owner_operation
                     { operation_id = operation.operation_id
                     ; admission_token
                     ; execution_sw = sw
                     ; surface = operation_payload.source.surface
                     ; speaker = chat_speaker_of_request payload
                     ; conversation_id = operation_payload.source.conversation_id
                     ; external_message_id = operation_payload.source.external_message_id
                     ; workspace_id = operation_payload.source.workspace_id
                     ; extra_mentions = operation_payload.source.extra_mentions
                     })
                ~state
                ~clock
                ~auth_token:None
                ~thread_id:operation_payload.source.thread_id
                ~continuation_channel:operation_payload.source.continuation_channel
                ~closed
                ~client_disconnects:None
                ~payload
                ~run_id:("keeper-operation-run-" ^ operation_id)
                ~message_id:("keeper-operation-message-" ^ operation_id)
                ~agent_name
                ~submitted_by:operation_payload.source.submitted_by
                ~events
            in
            let delivery = Eio.Promise.await delivery in
            (match outcome, delivery with
             | Some (Delivered { outcome_ref }), Ok () ->
               Keeper_owner.Operation_succeeded { outcome_ref }
             | Some (Delivered { outcome_ref }), Error detail ->
               failed ~outcome_ref "Delivery_failed" detail
             | Some (Failed { kind; detail }), _ ->
               failed (queued_turn_failure_kind_to_string kind) detail
             | Some (Deferred _), _ ->
               failed
                 "Admission_invariant"
                 "Owner operation deferred after holding its admission token"
             | None, _ ->
               failed "Turn_invariant" "Owner operation returned no terminal turn outcome")))
  in
  let rec await_admission () =
    match
      Keeper_turn_admission.run_serialized_with_token
        ~base_path:(Mcp_server.workspace_config state).base_path
        ~keeper_name
        execute_admitted
    with
    | `Ran execution -> execution
    | `Rejected { shutdown_operation_id = Some _; _ } ->
      Eio.Time.sleep clock 0.1;
      await_admission ()
    | `Rejected { shutdown_operation_id = None; _ } ->
      failed
        "Admission_invariant"
        "Keeper chat admission rejected without a shutdown owner"
  in
  await_admission ()
;;

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

let operation_submit_error_code = function
  | Keeper_owner_registry.Command_lifecycle_reserved _ -> "owner_stopping"
  | Command_lookup_failed Inventory_stopping -> "owner_stopping"
  | Command_lookup_failed
      (Inventory_not_installed _ | Owner_not_found _ | Owner_unavailable _
      | Owner_initialization_failed _) ->
    "store_unavailable"
  | Command_rejected (Keeper_owner.Owner_stopping | Owner_closed) -> "owner_stopping"
  | Command_rejected (Keeper_owner.Operation_rejected error) ->
    (match Keeper_owner.operation_error_kind error with
     | Invalid_operation_input -> "invalid_input"
     | Unknown_operation -> "unknown_operation"
     | Operation_not_queued -> "not_queued"
     | Operation_idempotency_conflict -> "idempotency_conflict"
     | Operation_store_unavailable -> "store_unavailable")
  | Command_rejected
      (Keeper_owner.Store_unavailable _ | Reducer_rejected _) ->
    "store_unavailable"
;;

let handle_keeper_chat_stream ~sw ~clock ~submitted_by state request reqd payload =
  let origin = get_origin request in
  let headers = keeper_chat_stream_headers origin in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let close_stream () =
    if not !closed
    then begin
      closed := true;
      (try Httpun.Body.Writer.close writer
       with
       | Eio.Cancel.Cancelled _ as e ->
         Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())
       | exn ->
         Log.Misc.warn "keeper_stream writer close: %s"
           (Printexc.to_string exn))
    end
  in
  let thread_id = "keeper:" ^ payload.name in
  let operation_id =
    Keeper_owner.Chat_operation.Operation_id.to_string payload.request_id
  in
  let finished, resolve_finished = Eio.Promise.create () in
  let finish () =
    ignore (Eio.Promise.try_resolve resolve_finished () : bool)
  in
  ignore
    (keeper_stream_send_raw writer mutex closed
       (Printf.sprintf "retry: %d\n\n" sse_dashboard_retry_backoff_ms));
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun stream_sw ->
      Eio.Switch.on_release stream_sw close_stream;
      let accepted = ref false in
      let buffered = ref [] in
      let buffered_mu = Stdlib.Mutex.create () in
      let send_event event =
        let sent = keeper_stream_send_event writer mutex closed event in
        if
          (not sent)
          || match event.Ag_ui.event_type with
             | Ag_ui.Run_finished | Ag_ui.Run_error -> true
             | Run_started | Step_started | Step_finished | Text_message_start
             | Text_message_content | Text_message_end | Tool_call_start
             | Tool_call_args | Tool_call_end | State_snapshot | State_delta
             | Custom -> false
        then finish ()
      in
      let sink event =
        let send_now =
          Stdlib.Mutex.protect buffered_mu (fun () ->
            if !accepted
            then true
            else (
              buffered := event :: !buffered;
              false))
        in
        if send_now then send_event event
      in
      let unregister = register_operation_live_sink ~operation_id sink in
      Eio.Switch.on_release stream_sw unregister;
      let publish_acceptance acceptance =
        let operation = acceptance.Keeper_owner.operation in
        let state =
          match operation.state with
          | Keeper_owner.Chat_operation.Queued -> "Queued"
          | Running _ -> "Running"
          | Succeeded _ -> "Succeeded"
          | Failed _ -> "Failed"
          | Cancelled _ -> "Cancelled"
        in
        let event =
          Ag_ui.of_custom
            ~name:"KEEPER_CHAT_OPERATION_ACCEPTED"
            (`Assoc
               [ "operation_id", `String operation_id
               ; "state", `String state
               ; "queued_count", `Int acceptance.queued_count
               ])
        in
        ignore (keeper_stream_send_event writer mutex closed event);
        let pending =
          Stdlib.Mutex.protect buffered_mu (fun () ->
            accepted := true;
            let pending = List.rev !buffered in
            buffered := [];
            pending)
        in
        List.iter send_event pending;
        if Keeper_owner.Chat_operation.is_terminal operation.state then finish ()
      in
      let submit_result =
        let ( let* ) = Result.bind in
        let* source =
          operation_source_of_payload
            ~thread_id
            ~submitted_by
            ~user_row_origin:Keeper_chat_store.Needs_append
            payload
          |> Result.map_error (fun detail -> `Input detail)
        in
        Keeper_owner_registry.submit_operation
          ~base_path:(Mcp_server.workspace_config state).base_path
          ~keeper_name:payload.name
          ~operation_id:payload.request_id
          ~source
          ~input:(operation_input_of_payload payload)
        |> Result.map_error (fun error -> `Owner error)
      in
      (match submit_result with
       | Ok acceptance -> publish_acceptance acceptance
       | Error (`Input detail) ->
         ignore
           (keeper_stream_send_event
              writer
              mutex
              closed
              (Ag_ui.run_error ~thread_id ~message:detail ~code:"invalid_input" ()));
         finish ()
       | Error (`Owner error) ->
         let detail = Keeper_owner_registry.command_error_to_string error in
         let code = operation_submit_error_code error in
         ignore
           (keeper_stream_send_event
              writer
              mutex
              closed
              (Ag_ui.run_error
                 ~thread_id
                 ~message:detail
                 ~code
                 ()));
         finish ());
      Eio.Promise.await finished))

(** Build routes for MCP server *)

module For_testing = struct
  let parse_request = parse_keeper_chat_stream_request
  let has_connector_context = has_connector_context
  let has_external_speaker = has_external_speaker
  let message_for_request = message_for_request
  let chat_surface_of_request = chat_surface_of_request
  let chat_speaker_of_request = chat_speaker_of_request
  let turn_instructions_for_request = turn_instructions_for_request
  let direct_message_of_request = direct_message_of_request
  let canonical_reply_payload_of_body = canonical_reply_payload_of_body
  let direct_reply_terminal_error = direct_reply_terminal_error
  let persisted_reply_blocks = persisted_reply_blocks
  let queued_delivery_outcome_of_turn_ref =
    queued_delivery_outcome_of_turn_ref
  let committed_delivery_outcome = committed_delivery_outcome
  let empty_reply_delivery_plan = empty_reply_delivery_plan
  let surface_context_to_instructions = surface_context_to_instructions
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
    | Some (Completion_queued_turn_deferred _)
    | None ->
      None
  ;;
end
