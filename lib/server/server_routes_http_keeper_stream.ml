
open Server_auth

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

(* Progressive-render hard-wrap width (characters) for streamed keeper replies —
   a UI readability chunk width, NOT an SSE/transport line-length limit. *)
let keeper_reply_chunk_hard_wrap_chars = 180

(* Bounded producer-consumer capacity for the worker-event stream; [Eio.Stream.add]
   blocks (backpressure) when the consumer lags. *)
let worker_events_buffer_size = 512

(* Wire-terminal accounting for keeper chat operations (#28811). The Dashboard
   projection publishes AG-UI events while the turn runs inside the child
   switch; a cancelled turn kills the projection fiber before it can emit
   RUN_ERROR, so the stream used to close with no terminal receipt. Track
   which operations have a live wire audience and whether a terminal made it
   out; the Owner settle hook synthesizes the missing terminal from the
   execution verdict after the child switch has unwound.

   The stream counts as OPEN from sink registration, not from the first
   projected event: a turn that fails after claim but before the projection
   ever runs (missing input, payload parse failure) projects nothing, yet the
   attached client is already waiting on a terminal (#28849 review). When the
   last sink unregisters the record is dropped — with no audience there is
   nothing to close, and the durable operation state stays the authority. *)
type operation_wire_stream = Wire_started | Wire_terminal_sent

let operation_wire_streams : (string, operation_wire_stream) Hashtbl.t =
  Hashtbl.create 32

let operation_wire_streams_mu = Stdlib.Mutex.create ()

let ag_ui_terminal_event (event : Ag_ui.event) =
  match event.Ag_ui.event_type with
  | Ag_ui.Run_finished | Ag_ui.Run_error -> true
  | Run_started | Step_started | Step_finished | Text_message_start
  | Text_message_content | Text_message_end | Tool_call_start
  | Tool_call_args | Tool_call_end | State_snapshot | State_delta
  | Custom -> false

let note_operation_wire_opened ~operation_id =
  Stdlib.Mutex.protect operation_wire_streams_mu (fun () ->
    if not (Hashtbl.mem operation_wire_streams operation_id)
    then Hashtbl.replace operation_wire_streams operation_id Wire_started)

let note_operation_wire_event ~operation_id event =
  let terminal = ag_ui_terminal_event event in
  Stdlib.Mutex.protect operation_wire_streams_mu (fun () ->
    match Hashtbl.find_opt operation_wire_streams operation_id, terminal with
    | Some Wire_terminal_sent, _ -> ()
    | _, true ->
      Hashtbl.replace operation_wire_streams operation_id Wire_terminal_sent
    | None, false ->
      Hashtbl.replace operation_wire_streams operation_id Wire_started
    | Some Wire_started, false -> ())

let drop_operation_wire_stream ~operation_id =
  Stdlib.Mutex.protect operation_wire_streams_mu (fun () ->
    Hashtbl.remove operation_wire_streams operation_id)

let take_operation_wire_stream ~operation_id =
  Stdlib.Mutex.protect operation_wire_streams_mu (fun () ->
    let state = Hashtbl.find_opt operation_wire_streams operation_id in
    Hashtbl.remove operation_wire_streams operation_id;
    state)

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
      match Hashtbl.find_opt operation_live_sinks operation_id with
      | None -> []
      | Some sinks -> sinks
    in
    Hashtbl.replace operation_live_sinks operation_id ((sink_id, sink) :: current);
    (* An attached sink IS the open wire stream (#28849 review): mark it under
       the sinks lock so registration and the last-sink drop below cannot
       interleave into an attached-client/no-record state. Lock order is
       always sinks_mu -> streams_mu; the streams lock never takes sinks_mu. *)
    note_operation_wire_opened ~operation_id);
  fun () ->
    Stdlib.Mutex.protect operation_live_sinks_mu (fun () ->
      match Hashtbl.find_opt operation_live_sinks operation_id with
      | None -> ()
      | Some sinks ->
        let remaining = List.filter (fun (id, _) -> id <> sink_id) sinks in
        if remaining = []
        then (
          Hashtbl.remove operation_live_sinks operation_id;
          (* Last sink gone -> no audience: drop the wire record so settle
             stays silent instead of synthesizing into the void. *)
          drop_operation_wire_stream ~operation_id)
        else Hashtbl.replace operation_live_sinks operation_id remaining)
;;

let publish_operation_live_event ~operation_id event =
  let sinks =
    Stdlib.Mutex.protect operation_live_sinks_mu (fun () ->
      match Hashtbl.find_opt operation_live_sinks operation_id with
      | None -> []
      | Some sinks -> sinks)
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

(* How long a held tool call waits for an operator.

   Long enough to read the question and decide -- an operator glancing away
   should not come back to a denied call. Short enough that a turn does not
   sit on a provider connection all afternoon when the reader has walked
   away: the chat stream's own silence bound is the same order, and a wait
   outliving it would hold a turn whose reader is already gone. *)
let keeper_tool_approval_timeout_sec = 180.0

(* Answer a held tool call.

   The reply says whether a wait was actually released. A late answer -- one
   whose call already timed out, or was never held -- reports [settled: false]
   rather than reading as success, so an operator is not told a call was
   approved when nothing was listening for it.

   A late answer is not discarded, though: when the wait it names timed out
   here, the decision is remembered in {!Keeper_late_approval} and the reply
   says [remembered: true]. The operator's decision is about the call, and
   the retried call -- same tool, same arguments, new call id -- is then
   settled by it once instead of asking the same question again. An answer
   that names no wait this process ever held matches nothing and is dropped,
   as before. *)
let handle_keeper_tool_approval state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let parsed =
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields ->
          let field name =
            match List.assoc_opt name fields with
            | Some (`String value) -> Ok (String.trim value)
            | Some _ | None ->
              Error (Printf.sprintf "%s (string) is required" name)
          in
          let ( let* ) = Result.bind in
          let* keeper_name = field "name" in
          let* tool_call_id = field "tool_call_id" in
          let* decision_raw = field "decision" in
          (match Keeper_tool_approval_registry.decision_of_string decision_raw with
           | Some decision -> Ok (keeper_name, tool_call_id, decision)
           | None ->
             Error
               (Printf.sprintf "decision must be approve or deny, got %S"
                  decision_raw))
        | _ -> Error "JSON object body required"
      with
      | Yojson.Json_error msg -> Error ("invalid json: " ^ msg)
    in
    match parsed with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json msg)
    | Ok (keeper_name, tool_call_id, decision) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json "keeper not registered")
      else (
        let settled =
          Keeper_tool_approval_registry.settle
            (Keeper_tool_approval_registry.shared ())
            ~keeper_name ~tool_call_id decision
        in
        let remembered =
          if settled then false
          else
            (* The wait is gone, but if it timed out here the answer still
               descends from a question this operator was really shown, so it
               stands for the identical retried call. *)
            match
              Keeper_late_approval.remember_late
                (Keeper_late_approval.shared ())
                ~keeper_name ~tool_call_id decision ()
            with
            | Keeper_late_approval.Remembered _ -> true
            | Keeper_late_approval.No_matching_ask -> false
        in
        Log.Keeper.info
          "keeper_tool_approval: keeper=%s tool_call_id=%s decision=%s settled=%b remembered=%b"
          keeper_name tool_call_id
          (Keeper_tool_approval_registry.decision_to_string decision)
          settled remembered;
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
             [ ("settled", `Bool settled)
             ; ("remembered", `Bool remembered)
             ; ( "decision"
               , `String (Keeper_tool_approval_registry.decision_to_string decision) )
             ])))
;;

(* The waits live only in the registry while their turns are parked, so this
   is a projection of live state, not a store read. Listing them is what lets
   an operator answer a turn whose owning stream watcher is gone — without
   this, such a call could only time out (masc#30034). [asked_at] is the
   registry clock's epoch reading; the consumer derives display age against
   its own clock rather than trusting one computed here. *)
let handle_keeper_tool_approvals_list _state request reqd =
  let held =
    Keeper_tool_approval_registry.pending
      (Keeper_tool_approval_registry.shared ())
  in
  respond_json_value_with_cors ~status:`OK request reqd
    (`Assoc
       [ ( "pending"
         , `List
             (List.map
                (fun (p : Keeper_tool_approval_registry.pending) ->
                  `Assoc
                    [ ("keeper", `String p.keeper_name)
                    ; ("tool_call_id", `String p.tool_call_id)
                    ; ("tool", `String p.tool_name)
                    ; ("args", `String p.args)
                    ; ("question", `String p.question)
                    ; ("because", `String p.because)
                    ; ("asked_at", `Float p.asked_at)
                    ; ("timeout_sec", `Float p.timeout_sec)
                    ])
                held) )
       ])
;;

(* Which keepers are mid-turn right now, one row per registered keeper. The
   running-turn slot lives in the Keeper Owner (process memory), not in the
   durable meta a keeper list is read from, so surfaces that want an
   "answering now" badge poll this projection instead of growing the meta
   contract. [started_at_unix] is the owner clock's epoch reading; the
   consumer derives display age against its own clock (same policy as
   [asked_at] above). An unreadable name census is an error response, not an
   empty fleet: reading unreadable as "nobody is running" would hide every
   badge exactly when the store is broken. *)
let handle_keeper_turns_list state request reqd =
  let config = Mcp_server.workspace_config state in
  match Keeper_meta_store.keeper_names config with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    respond_json_value_with_cors ~status:`Internal_server_error request reqd
      (`Assoc
         [ ( "error"
           , `String
               (Printf.sprintf "keeper name census failed: %s"
                  (Printexc.to_string exn)) )
         ])
  | keeper_names ->
    let row keeper_name =
      match
        Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name
      with
      | Error error ->
        `Assoc
          [ ("keeper_name", `String keeper_name)
          ; ("status", `String "unavailable")
          ; ( "detail"
            , `String (Keeper_owner_registry.lookup_error_to_string error) )
          ; ("turn", `Null)
          ]
      | Ok owner ->
        let turn_json =
          match Keeper_owner.turn_in_flight owner with
          | None -> `Null
          | Some (turn : Keeper_owner.turn_in_flight) ->
            (* The live glance rides only a running turn: the preview plane
               is process memory that outlives turn end unread, and gating
               it here is what keeps a stale tail unreachable. *)
            let preview_json =
              match Keeper_turn_preview.current ~keeper_name with
              | None -> `Null
              | Some (preview : Keeper_turn_preview.t) ->
                `Assoc
                  [ ("text_tail", `String preview.text_tail)
                  ; ( "current_tool"
                    , match preview.current_tool with
                      | None -> `Null
                      | Some tool_name -> `String tool_name )
                  ; ("updated_at_unix", `Float preview.updated_at)
                  ]
            in
            `Assoc
              [ ("lane", `String (Keeper_owner.turn_lane_to_string turn.lane))
              ; ("started_at_unix", `Float turn.started_at)
              ; ("preview", preview_json)
              ]
        in
        Tool_args.ok_assoc
          [ ("keeper_name", `String keeper_name); ("turn", turn_json) ]
    in
    respond_json_value_with_cors ~status:`OK request reqd
      (`Assoc
         [ ("schema", `String "masc.keeper_turns.v1")
         ; ("keepers", `List (List.map row (List.sort String.compare keeper_names)))
         ])
;;

(* The per-keeper approval stance. GET lists the overrides — a keeper absent
   from the list is [auto] — and POST sets one. Setting is logged at the
   server, not only echoed to the caller: [yolo] means every tool call runs
   unasked, and the operator who set it is not always the operator reading
   the logs later. *)
let handle_keeper_tool_approval_mode_get _state request reqd =
  let overrides =
    Keeper_tool_approval_mode.overrides (Keeper_tool_approval_mode.shared ())
  in
  respond_json_value_with_cors ~status:`OK request reqd
    (`Assoc
       [ ( "overrides"
         , `List
             (List.map
                (fun (keeper_name, mode) ->
                  `Assoc
                    [ ("keeper", `String keeper_name)
                    ; ( "mode"
                      , `String (Keeper_tool_approval_mode.mode_to_string mode)
                      )
                    ])
                overrides) )
       ; ("default", `String "auto")
       ])
;;

let handle_keeper_tool_approval_mode_set ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let parsed =
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields ->
          let field name =
            match List.assoc_opt name fields with
            | Some (`String value) -> Ok (String.trim value)
            | Some _ | None ->
              Error (Printf.sprintf "%s (string) is required" name)
          in
          let ( let* ) = Result.bind in
          let* keeper_name = field "name" in
          let* mode_raw = field "mode" in
          (match Keeper_tool_approval_mode.mode_of_string mode_raw with
           | Some mode -> Ok (keeper_name, mode)
           | None ->
             Error
               (Printf.sprintf "mode must be auto or yolo, got %S" mode_raw))
        | _ -> Error "JSON object body required"
      with
      | Yojson.Json_error msg -> Error ("invalid json: " ^ msg)
    in
    match parsed with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json msg)
    | Ok (keeper_name, mode) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json "keeper not registered")
      else (
        Keeper_tool_approval_mode.set
          (Keeper_tool_approval_mode.shared ())
          ~keeper_name
          mode;
        Log.Keeper.info
          "keeper_tool_approval_mode: keeper=%s mode=%s actor=%s"
          keeper_name
          (Keeper_tool_approval_mode.mode_to_string mode)
          actor;
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
             [ ("keeper", `String keeper_name)
             ; ( "mode"
               , `String (Keeper_tool_approval_mode.mode_to_string mode) )
             ])))
;;

let handle_keeper_turn_interrupt state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let target_result =
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields ->
          (match List.assoc_opt "name" fields with
           | Some (`String s) when String.trim s <> "" ->
             let request_id_result =
               match List.assoc_opt "request_id" fields with
               | None -> Ok None
               | Some (`String value) when String.trim value <> "" ->
                 Ok (Some (String.trim value))
               | Some (`String _) -> Error "request_id must be non-blank"
               | Some _ -> Error "request_id must be a string when present"
             in
             Result.map
               (fun request_id -> String.trim s, request_id)
               request_id_result
           (* A blank name trims to "" and then reads as an unregistered
              keeper, so the caller saw 404 for what is a bad request. The
              request_id check below already worked this way. *)
           | Some (`String _) -> Error "name must be non-blank"
           | _ -> Error "name (string) is required")
        | _ -> Error "JSON object body required"
      with
      | Yojson.Json_error msg -> Error ("invalid json: " ^ msg)
    in
    match target_result with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (keeper_chat_stream_error_json msg)
    | Ok (keeper_name, request_id) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json "keeper not registered")
      else
        match request_id with
        | Some request_id ->
          (match Keeper_chat_operation.Operation_id.of_string request_id with
           | Error detail ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (keeper_chat_stream_error_json detail)
           | Ok operation_id ->
             (match
                Keeper_owner_registry.interrupt_running_operation ~base_path
                  ~keeper_name operation_id
              with
              | Ok Keeper_owner.Operation_interrupt_signalled ->
                Log.Keeper.info ~keeper_name
                  "keeper_turn_interrupt: request_id=%s exact=true"
                  request_id;
                respond_json_value_with_cors ~status:`OK request reqd
                  (`Assoc
                     [ "signalled", `Bool true
                     ; "request_id", `String request_id
                     ])
              | Ok
                  (Keeper_owner.Operation_not_current
                     { running_operation_id }) ->
                respond_json_value_with_cors ~status:`OK request reqd
                  (`Assoc
                     ([ "signalled", `Bool false
                      ; "reason", `String "operation_not_current"
                      ; "request_id", `String request_id
                      ]
                      @
                      match running_operation_id with
                      | None -> []
                      | Some current ->
                        [ ( "current_request_id"
                          , `String
                              (Keeper_chat_operation.Operation_id.to_string
                                 current) ) ]))
              | Ok (Keeper_owner.Operation_interrupt_failed detail) ->
                respond_json_value_with_cors ~status:`OK request reqd
                  (`Assoc
                     [ "signalled", `Bool false
                     ; "reason", `String "cancel_failed"
                     ; "request_id", `String request_id
                     ; "detail", `String detail
                     ])
              | Error error ->
                respond_json_value_with_cors ~status:`OK request reqd
                  (`Assoc
                     [ "signalled", `Bool false
                     ; "reason", `String "owner_unavailable"
                     ; "request_id", `String request_id
                     ; ( "detail"
                       , `String
                           (Keeper_owner_registry.command_error_to_string error)
                       )
                     ])))
        | None ->
        (* The server fails the turn switch and learns nothing more within this
           request: whether the signal reaches the running fiber, and whether
           that fiber then terminates, are later events. [signalled] reports
           what happened here. A turn parked in an uncancellable section keeps
           running after a [signalled: true] response, so an operator has to
           read the turn state to know the outcome. The former [cancelled:
           true] read as that outcome and hid a 63-minute hang (#29229). *)
        (match Keeper_registry.interrupt_current_turn ~base_path keeper_name with
        | Keeper_registry.Exact_turn_cancelled turn_id ->
          Log.Keeper.info ~keeper_name ~turn_id
            "keeper_turn_interrupt: exact turn cancelled";
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc [ ("signalled", `Bool true); ("turn_id", `Int turn_id) ])
        | Keeper_registry.Exact_no_turn_in_flight ->
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               [ ("signalled", `Bool false)
               ; ("reason", `String "no_in_flight_turn")
               ])
        | Keeper_registry.Exact_turn_cancel_failed { turn_id; detail } ->
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               ([ ("signalled", `Bool false)
                ; ("reason", `String "cancel_failed")
                ; ("detail", `String detail)
                ]
                @ (match turn_id with
                   | Some turn_id -> [ ("turn_id", `Int turn_id) ]
                   | None -> [])))))
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
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ~admission_token
      state
      ~agent_name
      ~message
      ~continuation_channel
      ~on_text_delta
  =
  let workspace_scope = Mcp_server.workspace_scope state in
  let config = workspace_scope.config in
  let start_time = Eio.Time.now clock in
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
        Keeper_tool_surface.dispatch_keeper_msg_stream_admitted
          ~admission_token
          ~on_text_delta
          ?on_event
          ?on_tool_stream_observation
          ?on_tool_result_ready
          ?approval_gate
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
    | exn when Keeper_registry_types.is_operator_interrupt exn ->
        (* #28810: operator-requested turn interrupt is a typed cancellation,
           not a crash. The guard covers every Eio delivery shape — bare,
           [Finally_raised], [Multiple] — while genuinely cancelled fibers
           re-raise above (#28868 review). *)
        Log.Mcp.info "tools/call interrupted by operator (stream)";
        ( Keeper_registry_types.operator_interrupt_detail
        , Tool_result.Failed Tool_result.Operator_cancelled )
    | exn ->
        let err = Printexc.to_string exn in
        Log.Mcp.error "tools/call crashed (stream): %s" err;
        ( Printf.sprintf "Internal error: %s" err
        , Tool_result.Failed Tool_result.Runtime_failure )
  in
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
         (* SSOT: the failure class owns its log level (Runtime_failure ->
            Error, the rest -> Warn). This site was the last Error hardcode;
            the MCP twin already routes through the helper (#28878 review). *)
         Log.Keeper.emit (Tool_result.log_level_of_failure_class failure_class)
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
      (* Carry the full disposition, not a collapsed bool: the queued-outcome
         consumer needs the failure class to keep an operator interrupt from
         being written as a crash (#28868 review P0). *)
      `Ran (disposition, body)

type canonical_reply_payload_error =
  | Malformed_reply_json of { parser_detail : string }
  | Reply_payload_not_object
  | Missing_payload_field of string
  | Duplicate_payload_field of string
  | Invalid_payload_field_type of string
  | Unknown_turn_outcome
  | Invalid_turn_ref
  | Invalid_external_effect_target of string

type canonical_reply_payload =
  { payload_json : Yojson.Safe.t
  ; turn_outcome : Keeper_turn_outcome.t
  ; turn_ref : Ids.Turn_ref.t
  ; external_effect_target : Keeper_surface_post.delivery_target option
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
  | Invalid_external_effect_target detail ->
    Printf.sprintf
      "keeper reply payload carries an invalid external_effect_target: %s"
      detail
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
  let* external_effect_target =
    (* The outcome and the terminal-effect receipt are decided from the same
       [terminal_effect_state] (keeper_agent_run.ml), so an
       External_effect_completed payload carries exactly one receipt proof:
       the surface-post delivery target, or a memory-write revision
       (keeper_turn.ml terminal_effect_fields). The decoder holds both
       directions for each key - present iff that outcome - so [Some] here
       is the proof the External_effect_completed event needs, and [None] on
       that outcome means the completed effect was a memory write. *)
    let completed_external_effect =
      Keeper_turn_outcome.equal turn_outcome
        Keeper_turn_outcome.Terminal_effect_settled
    in
    let values_of key =
      List.filter_map
        (fun (field, value) ->
           if String.equal field key then Some value else None)
        fields
    in
    let* memory_revision =
      match values_of Keeper_tool_execution.memory_revision_wire_key with
      | [] -> Ok None
      | [ value ] ->
        if not completed_external_effect
        then
          Error
            (Invalid_external_effect_target
               (Printf.sprintf
                  "%s present on turn_outcome %s"
                  Keeper_tool_execution.memory_revision_wire_key
                  (Keeper_turn_outcome.to_label turn_outcome)))
        else (
          match value with
          | `Int revision -> Ok (Some revision)
          | _ ->
            Error
              (Invalid_payload_field_type
                 Keeper_tool_execution.memory_revision_wire_key))
      | _ ->
        Error
          (Duplicate_payload_field
             Keeper_tool_execution.memory_revision_wire_key)
    in
    match values_of Keeper_surface_post.delivery_target_wire_key with
    | [] ->
      (match completed_external_effect, memory_revision with
       | false, _ -> Ok None
       | true, Some _ -> Ok None
       | true, None ->
         Error
           (Missing_payload_field Keeper_surface_post.delivery_target_wire_key))
    | [ value ] ->
      if not completed_external_effect
      then
        Error
          (Invalid_external_effect_target
             (Printf.sprintf
                "present on turn_outcome %s"
                (Keeper_turn_outcome.to_label turn_outcome)))
      else if Option.is_some memory_revision
      then
        Error
          (Invalid_external_effect_target
             (Printf.sprintf
                "carries both %s and %s"
                Keeper_surface_post.delivery_target_wire_key
                Keeper_tool_execution.memory_revision_wire_key))
      else (
        match Keeper_surface_post.delivery_target_of_yojson value with
        | Ok target -> Ok (Some target)
        | Error detail -> Error (Invalid_external_effect_target detail))
    | _ ->
      Error
        (Duplicate_payload_field Keeper_surface_post.delivery_target_wire_key)
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
    ; external_effect_target
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
       turn_outcome, String_util.trim_nonempty visible_reply, has_visible_blocks
     with
     | Keeper_turn_outcome.Continuation_checkpoint, _, _ -> None
     | Keeper_turn_outcome.Terminal_effect_settled, _, _ -> None
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
    | Keeper_turn_outcome.Terminal_effect_settled
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
  | Request_stream of keeper_stream_terminal_status

let keeper_stream_terminal_status_to_string = function
  | Stream_done -> "done"
  | Stream_error -> "error"
  | Stream_cancelled -> "cancelled"
  | Stream_rejected -> "rejected"
  | Stream_reconciliation_required -> "acceptance_uncertain"
;;

let keeper_request_terminal_status_to_string = function
  | Request_stream status -> keeper_stream_terminal_status_to_string status
;;

let keeper_request_terminal_status_is_routine = function
  | Request_stream (Stream_done | Stream_cancelled | Stream_reconciliation_required) ->
    true
  | Request_stream (Stream_error | Stream_rejected) -> false
;;

type keeper_stream_worker_event =
  | Stream_runtime_attempt_started of
      Keeper_chat_events.runtime_attempt_scope_disposition
  | Stream_event of int * Agent_core.Types.sse_event
  | Stream_chat_event of Keeper_chat_events.keeper_chat_event
  | Stream_client_disconnected
  | Stream_terminal of
      { status : keeper_stream_terminal_status
      ; body : string
      ; queued_outcome : queued_turn_outcome option
      }

and keeper_stream_completion =
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

type turn_submission =
  | Owner_operation of
      { operation_id : Keeper_owner.Chat_operation.Operation_id.t
      ; admission_token : Keeper_turn_dispatch_authority.token
      ; execution_sw : Eio.Switch.t
      ; surface : Surface_ref.t
      ; speaker : Keeper_chat_store.speaker
      ; conversation_id : string option
      ; external_message_id : string option
      ; workspace_id : string option
      ; extra_mentions : Keeper_identity.Keeper_id.t list
      }

let queued_turn_failure_kind_to_string = function
  | Turn_failed -> "turn_failed"
  | Turn_cancelled -> "turn_cancelled"
  | No_visible_reply -> "no_visible_reply"
  | Missing_turn_ref -> "missing_turn_ref"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Stream_projection_failed -> "stream_projection_failed"

(* Total mapping into the closed operation-ledger vocabulary; the queued kind's
   full name still travels in the failure detail. *)
let chat_operation_failure_kind_of_queued = function
  | Turn_failed -> Keeper_chat_operation.Turn_exception
  | Turn_cancelled -> Keeper_chat_operation.Turn_cancelled
  | No_visible_reply | Missing_turn_ref -> Keeper_chat_operation.Turn_invariant
  | Transcript_persist_failed | Stream_projection_failed ->
    Keeper_chat_operation.Delivery_failed

let queued_delivery_outcome_of_turn_ref = function
  | Some turn_ref ->
      Delivered { outcome_ref = Ids.Turn_ref.to_string turn_ref }
  | None ->
      Failed
        { kind = Missing_turn_ref
        ; detail =
            "queued turn persisted a reply but the reply payload had no valid turn_ref"
        }

let committed_delivery_outcome ~turn_ref = function
  | Error persist_error -> Error persist_error
  | Ok () -> Ok (queued_delivery_outcome_of_turn_ref turn_ref)

let empty_reply_delivery_plan ~has_visible_blocks ~has_tool_calls =
  if has_visible_blocks
  then `Visible_blocks
  else if has_tool_calls
  then `Tool_calls_only
  else `Failure

(* What a turn writes when its outcome is a control boundary or an external
   effect rather than a plain reply. [spoken] is the turn's words, already
   trimmed, and [None] means the model produced none.

   Words are kept on every outcome. They used to be dropped on all three of
   these: the operator who asked a direct question got a status row and an
   empty assistant row, while the raw trace still held the reply. The replay
   decision -- whether these words re-enter model history -- is answered
   separately by the stop reason and never by discarding the string here
   (masc #32727, #32660).

   Only a wordless [External_effect_completed] writes no assistant row: the
   typed tool-call record is the whole of what that turn did. *)
let control_turn_delivery ~turn_outcome ~spoken =
  match (turn_outcome : Keeper_turn_outcome.t), spoken with
  | (Continuation_checkpoint | External_effect_pending), spoken ->
    `Assistant_row (Option.value spoken ~default:"")
  | Terminal_effect_settled, Some words -> `Assistant_row words
  | Terminal_effect_settled, None -> `Tool_calls_only
  | (Visible_reply | No_visible_reply), spoken ->
    (* Reached by their own arms, which carry the same answer for words. *)
    `Assistant_row (Option.value spoken ~default:"")

type keeper_stream_bridge_state = Keeper_chat_agent_core_stream_bridge.state

type translated_keeper_stream_event =
  Keeper_chat_agent_core_stream_bridge.translated_event =
  { bridge_state : keeper_stream_bridge_state
  ; chat_events : Keeper_chat_events.keeper_chat_event list
  }

let empty_keeper_stream_bridge_state () = Keeper_chat_agent_core_stream_bridge.empty_state ()
let translate_agent_core_stream_event = Keeper_chat_agent_core_stream_bridge.translate

(* [user_row_origin] and [submission] are required labelled arguments. Every
   caller presents the typed transcript provenance and execution ownership
   selected at its persistence boundary; this function never infers either
   from a connector label or message content. *)
let process_single_turn ~user_row_origin ~submission
    ~state ~clock ~auth_token ~thread_id ~continuation_channel ~closed
    ~client_disconnects
    ~payload ~run_id ~message_id ~agent_name
    ~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t) =
  let base_path = (Mcp_server.workspace_config state).base_path in
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
    | Stream_terminal { status; body; queued_outcome } ->
        stage_completion
          (Completion_terminal { status; body; queued_outcome })
    | Stream_client_disconnected ->
      Atomic.set client_disconnected true;
      let (_ : bool) = Eio.Promise.try_resolve client_disconnect_resolver () in
      ()
    | (Stream_runtime_attempt_started _ | Stream_event _ | Stream_chat_event _) as event ->
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
                 Eio.Stream.add worker_events event;
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
  in
  let operation_delivery_coordinates =
    match submission with
    | Owner_operation { conversation_id; external_message_id; workspace_id; _ } ->
      conversation_id, external_message_id, workspace_id
  in
  let operation_extra_mentions =
    match submission with
    | Owner_operation { extra_mentions; _ } -> extra_mentions
  in
  let queue_delivery_key () =
    match submission with
    | Owner_operation { operation_id; _ } ->
      Keeper_chat_delivery_identity.Request_id.of_string
        (Keeper_owner.Chat_operation.Operation_id.to_string operation_id)
      |> Result.map (fun operation_id ->
        Keeper_chat_delivery_identity.Operation operation_id)
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
  let publish_tool_stream_protocol_error ?quarantined_occurrence kind detail =
    push_worker_event
      (Stream_chat_event
         (Keeper_chat_events.Agent_core_stream_protocol_error
            { kind
            ; quarantined_occurrence
            ; index = None
            ; tool_call_id = None
            ; event_type = None
            ; reason = Some detail
            ; raw_bytes = None
            }))
  in
  let on_event evt =
    Keeper_stream_tool_accum.on_event worker_tool_accum evt;
    let stream_scope =
      Keeper_stream_tool_accum.current_stream_scope worker_tool_accum
    in
    Keeper_stream_media_accum.on_event ~stream_scope worker_media_accum evt;
    push_worker_event (Stream_event (stream_scope, evt));
    (* The live bridge consumes the same raw event next and is the sole SSE
       protocol-error producer. Drain the durable collector's matching audit
       records without publishing a duplicate assistant diagnostic. *)
    let _drained_protocol_errors =
      Keeper_stream_tool_accum.take_protocol_errors worker_tool_accum
    in
    ()
  in
  let on_tool_stream_observation observation =
    let result =
      match observation with
      | Keeper_hooks_agent_core.Runtime_attempt_started _ ->
        Keeper_stream_media_accum.start_runtime_attempt worker_media_accum;
        let previous_scope =
          Keeper_stream_tool_accum.start_runtime_attempt worker_tool_accum
        in
        push_worker_event (Stream_runtime_attempt_started previous_scope);
        Ok ()
      | Keeper_hooks_agent_core.Turn_collected { turn; tool_source_map } ->
        Keeper_stream_tool_accum.seal_turn worker_tool_accum ~turn
          ~tool_source_map
      | Keeper_hooks_agent_core.Turn_closed_without_sources { turn } ->
        Keeper_stream_tool_accum.close_turn_without_sources worker_tool_accum ~turn
    in
    match result with
    | Ok () -> ()
    | Error detail ->
      Log.Keeper.warn ~keeper_name:payload.name
        "keeper chat tool stream occurrence mapping was rejected: %s"
        detail;
      publish_tool_stream_protocol_error
        Keeper_chat_events.Tool_occurrence_mapping_invalid
        detail;
      (* [Turn_collected] is the final exact pre-execution authority. A bad
         mapping must fail the AfterTurn hook before stage_output can dispatch
         a side effect; warning-only would execute an occurrence the stream
         cannot identify. Official-client [Turn_closed_without_sources] runs
         after its own tool loop, but a contradictory close is still a turn
         protocol failure rather than a state to normalize. *)
      failwith ("tool stream occurrence mapping rejected: " ^ detail)
  in
  let on_tool_result_ready ~tool_call_id ~turn ~planned_index ~execution_id =
    match
      Keeper_stream_tool_accum.record_execution_id worker_tool_accum
        ~tool_call_id ~turn ~planned_index ~execution_id
    with
    | Ok occurrence ->
      let tool_call_id =
        if String.trim tool_call_id = "" then None else Some tool_call_id
      in
      push_worker_event
        (Stream_chat_event
           (Keeper_chat_events.Tool_result_ready
              { occurrence; tool_call_id; execution_id }))
    | Error detail ->
      (* The runtime-aware wrapper invokes this callback only for the exact
         Agent Core candidate attempt whose pre-execution sidecar can satisfy
         the coordinate contract. Official-client attempts remain explicitly
         delivery-only. Once an Agent Core tool log committed, a failed
         occurrence join must abort the turn; publishing a diagnostic and
         returning would let chat persistence claim terminal success without
         its canonical execution. *)
      Log.Keeper.warn ~keeper_name:payload.name
        "keeper chat tool execution identity was not joined: %s"
        detail;
      publish_tool_stream_protocol_error
        Keeper_chat_events.Tool_occurrence_mapping_invalid
        detail;
      failwith ("tool execution occurrence join rejected: " ^ detail)
  in
  (* A gate only for turns an operator started here: this request is open,
     someone is reading it, and the answer has somewhere to come back to. An
     autonomous cycle gets none -- nobody is watching it, so every call it
     made would wait out the timeout and then be denied. *)
  let approval_gate =
    Keeper_tool_approval_gate.create
      ~registry:(Keeper_tool_approval_registry.shared ())
      ~late_approvals:(Keeper_late_approval.shared ())
      ~publish:(fun event -> push_worker_event (Stream_chat_event event))
      ~clock
      ~keeper_name:payload.name
      ~timeout_sec:keeper_tool_approval_timeout_sec
  in
  let accumulated_media_blocks () =
    match
      Keeper_stream_media_accum.to_chat_blocks ~base_dir:base_path
        worker_media_accum
    with
    | [] -> None
    | media_blocks -> Some media_blocks
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
    let tool_calls =
      Keeper_stream_tool_accum.to_tool_calls_for_failure worker_tool_accum
    in
    let persisted =
      append_queued_transport_failure_once ~tool_calls ?blocks ?turn_ref content
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
  let run_turn request_sw =
    let start_time = Time_compat.now () in
        let finish_projection_failure kind detail =
          let persisted = persist_failure_reply detail in
          let queued_outcome =
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
        let admission_token =
          match submission with
          | Owner_operation { admission_token; _ } -> admission_token
        in
        let payload_identity =
          let direct_target =
            Keeper_invocation_contract.direct_message_target_name direct_message
          in
          if String.equal payload.name direct_target && String.trim payload.name <> ""
          then Ok ()
          else Error "Keeper chat payload identity does not match its direct message"
        in
        (* Whether a keeper can take a turn lives in the registry, not on
           disk. [ensure_keeper_exists] downstream reads meta, which an
           unregistered keeper still has, so the user row committed first and
           the turn then failed on the registry miss — and the raw
           [keeper_turn_resources_unavailable] payload was what the person saw
           in their own chat, stored durably beside their message (#25529).
           A missing process-local entry covers both the brief pre-autoboot
           window and a stopped keeper, so the response names only that
           observed fact and offers both retry and start. *)
        let keeper_is_registered =
          if Keeper_registry.is_registered ~base_path payload.name
          then Ok ()
          else
            Error
              (Printf.sprintf
                 "keeper %s is not registered in this server process; retry shortly or start it before sending a message"
                 payload.name)
        in
        let operation_prepare =
          Result.bind keeper_is_registered (fun () ->
            Result.bind payload_identity (fun () ->
              append_queued_user_row_once ()))
        in
        let dispatch_result =
          match operation_prepare with
          | Error _ as error -> error
          | Ok () ->
           (try
            let result =
              execute_keeper_stream_tool_streaming
                ~sw:request_sw
                ~clock
                ?auth_token
                state ~agent_name ~message:direct_message ~on_event
                ~on_tool_stream_observation
                ~on_tool_result_ready
                ~approval_gate
                ~continuation_channel ~on_text_delta:(fun _ -> ())
                ~admission_token
            in
            match result with `Ran result -> Ok (`Ran result)
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
                 [persist_failure_reply] retains sealed call evidence and media
                 already completed, while quarantining the failed unsealed
                 provider scope. *)
              Error (Printexc.to_string exn))
        in
        match dispatch_result with
        | Ok (`Ran ((Tool_result.Completed () | Tool_result.Deferred ()), body)) ->
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
               | Invalid_turn_ref
               | Invalid_external_effect_target _ -> detail
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
                   match persist_failure_reply ?turn_ref err with
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
                   append_queued_assistant_once
                     ~content:assistant_content
                     ~tool_calls
                     ?blocks
                     ?turn_ref
                     ()
                 in
                 let persist_tool_calls_only () =
                   if tool_calls = []
                   then Ok ()
                   else append_queued_tool_calls_once ?turn_ref tool_calls
                 in
                 let delivered_after_persist ?content persisted =
                   match
                     committed_delivery_outcome ~turn_ref persisted
                   with
                   | Ok queued_outcome ->
                       Keeper_chat_broadcast.chat_appended
                         ~keeper_name:payload.name ~source:chat_source ?content ();
                       Ok (Some queued_outcome)
                   | Error _ as error -> error
                 in
                 let turn_outcome = canonical_reply.turn_outcome in
                 let delivery_result =
                   match turn_outcome, String_util.trim_nonempty visible_reply with
                   | ( ( Keeper_turn_outcome.Continuation_checkpoint
                       | Keeper_turn_outcome.External_effect_pending
                       | Keeper_turn_outcome.Terminal_effect_settled ) as
                       control_outcome )
                   , spoken -> (
                       (* [persisted_reply_blocks] always returns [Some _] for
                          [Continuation_checkpoint] (a typed status block), so
                          [has_visible_blocks] is always true for it: a
                          checkpoint turn always persists a delivered assistant
                          row plus the status block — including turns that also
                          produced tool calls and turns carrying a
                          direct-delivery checkpoint. There is no
                          tool-calls-only or user-only continuation path.

                          What the row carries is [control_turn_delivery]'s
                          answer, so the words survive here and in its tests
                          together. *)
                       match
                         control_turn_delivery ~turn_outcome:control_outcome
                           ~spoken
                       with
                       | `Assistant_row assistant_content ->
                           persist_assistant_reply ~assistant_content
                           |> delivered_after_persist ?content:spoken
                       | `Tool_calls_only ->
                           Result.bind
                             (persist_tool_calls_only ())
                             (fun () ->
                                Keeper_chat_broadcast.chat_appended
                                  ~keeper_name:payload.name
                                  ~source:chat_source
                                  ();
                                Ok
                                  (Some
                                     (queued_delivery_outcome_of_turn_ref
                                        turn_ref))))
                   | Keeper_turn_outcome.No_visible_reply, _
                   | Keeper_turn_outcome.Visible_reply, None ->
                       let detail =
                         "no visible reply was produced for this queued message"
                       in
                       (match
                          empty_reply_delivery_plan ~has_visible_blocks
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
                               Ok (Some (queued_delivery_outcome_of_turn_ref turn_ref)))
                        | `Failure ->
                          persist_failure_reply ?turn_ref detail
                          |> Result.map (fun () ->
                                 Some (Failed { kind = No_visible_reply; detail })))
                   | Keeper_turn_outcome.Visible_reply, Some visible_reply ->
                       persist_assistant_reply ~assistant_content:visible_reply
                       |> delivered_after_persist ~content:visible_reply
                 in
                 (match delivery_result with
                  | Error persist_error ->
                      let queued_outcome =
                        Some
                          (Failed
                             { kind = Transcript_persist_failed
                             ; detail = persist_error
                             })
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
        | Ok (`Ran (Tool_result.Failed dispatch_failure_class, err)) ->
            let persisted = persist_failure_reply err in
            let queued_outcome =
              match persisted with
              | Ok () ->
                (* #28810 / #28868 review P0: the dispatch classifies an
                   operator interrupt as [Operator_cancelled]; every other
                   failure class stays a crash-shaped [Turn_failed]. *)
                let kind =
                  match dispatch_failure_class with
                  | Tool_result.Operator_cancelled -> Turn_cancelled
                  | Tool_result.Dependency_unavailable
                  | Tool_result.Policy_rejection
                  | Tool_result.Runtime_failure
                  | Tool_result.Workflow_rejection -> Turn_failed
                in
                Some (Failed { kind; detail = err })
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
              ~failure_class:dispatch_failure_class
              ~tool_name:"masc_keeper_msg"
              ~start_time
              err
        | Error err ->
            let persisted = persist_failure_reply err in
            let queued_outcome =
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
           { status = Stream_error
           ; body = detail
           ; queued_outcome = Some (Failed { kind = Turn_failed; detail })
           })
  in
  let request_id =
    match submission with
    | Owner_operation { execution_sw; operation_id; _ } ->
      (try
         Eio.Fiber.fork ~sw:execution_sw (fun () ->
           (match Eio.Switch.run (fun request_sw -> run_turn request_sw) with
            | _ -> publish_inline_completion ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn when Keeper_registry_types.is_operator_interrupt exn ->
              (* Typed operator cancellation (#28810): the interrupt fails
                 the turn switch and the [Switch.run] boundary re-raises it
                 here — bare or combined ([Multiple]/[Finally_raised],
                 #28868 review). A cancelled turn, not a crash. *)
              let detail = Keeper_registry_types.operator_interrupt_detail in
              push_worker_event
                (Stream_terminal
                   { status = Stream_error
                   ; body = detail
                   ; queued_outcome = Some (Failed { kind = Turn_cancelled; detail })
                   });
              publish_inline_completion ()
            | exception exn ->
              let detail = Printexc.to_string exn in
              push_worker_event
                (Stream_terminal
                   { status = Stream_error
                   ; body = detail
                   ; queued_outcome = Some (Failed { kind = Turn_failed; detail })
                   });
              publish_inline_completion ()));
         Some (Keeper_owner.Chat_operation.Operation_id.to_string operation_id)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         let body = Printexc.to_string exn in
         let queued_outcome =
           match persist_failure_reply body with
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
         None)
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
      ()
  in
  let next_worker_projection () =
    if Atomic.get client_disconnected
    then `Client_disconnected
    else (
      match Eio.Stream.take_nonblocking worker_events with
      | Some event -> `Worker_event event
      | None ->
        Eio.Fiber.first
          ~combine:(fun left right ->
            match left, right with
            | `Worker_event _, _ -> left
            | _, `Worker_event _ -> right
            | `Completion _, _ -> left
            | _, `Completion _ -> right
            | `Client_disconnected, `Client_disconnected -> `Client_disconnected)
          (fun () -> `Worker_event (Eio.Stream.take worker_events))
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
                  | `Worker_event of keeper_stream_worker_event
                  ])))
  in
  let quarantine_failed_stream bridge_state reason =
    if not (Keeper_stream_tool_accum.current_scope_is_sealed worker_tool_accum)
    then (
      let failed =
        Keeper_chat_agent_core_stream_bridge.fail_stream bridge_state
          ~reason:(redact_text reason)
      in
      List.iter (Keeper_chat_events.publish events) failed.chat_events)
  in
  let rec consume_worker_events bridge_state =
    match next_worker_projection () with
    | `Client_disconnected -> None
    | `Worker_event (Stream_event (stream_scope, evt)) ->
        let translated =
          translate_agent_core_stream_event ~redact_text
            ~base_dir:base_path ~stream_scope bridge_state evt
        in
        List.iter (Keeper_chat_events.publish events) translated.chat_events;
        consume_worker_events translated.bridge_state
    | `Worker_event (Stream_runtime_attempt_started previous_scope) ->
        let translated =
          Keeper_chat_agent_core_stream_bridge.start_runtime_attempt
            ~previous_scope bridge_state
        in
        List.iter (Keeper_chat_events.publish events) translated.chat_events;
        consume_worker_events translated.bridge_state
    | `Worker_event (Stream_chat_event event) ->
        Keeper_chat_events.publish events event;
        consume_worker_events bridge_state
    | `Worker_event (Stream_terminal _ | Stream_client_disconnected) ->
        assert false
    | `Completion
        (Completion_terminal
        { status = Stream_cancelled
        ; body = message
        ; queued_outcome
        }) ->
        let message = redact_text message in
        quarantine_failed_stream bridge_state message;
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
        quarantine_failed_stream bridge_state err;
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
            | Keeper_turn_outcome.Terminal_effect_settled
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
          (match canonical_reply.external_effect_target with
           | Some target ->
             Keeper_chat_events.publish events
               (External_effect_completed { target })
           | None -> ());
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
            Some (Failed { kind = Stream_projection_failed; detail = message })
        | exn ->
            let message = redact_text (Printexc.to_string exn) in
            publish_terminal ~status:(Request_stream Stream_error) ~message ();
            Keeper_chat_events.publish events Text_message_end;
            Keeper_chat_events.publish events
              (Event_error { message });
            Some (Failed { kind = Stream_projection_failed; detail = message }))
  in
  match consume_worker_events (empty_keeper_stream_bridge_state ()) with
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
      failed Keeper_chat_operation.Store_unavailable (Keeper_owner.error_to_string error)
    | Ok None ->
      failed
        Keeper_chat_operation.No_queued_operation
        "Owner FIFO head disappeared before claim"
    | Ok (Some operation) ->
      (match operation.input with
       | None ->
         failed
           Keeper_chat_operation.Invalid_input
           "Running Keeper chat operation has no execution input"
       | Some input ->
         (match
            operation_payload_of_json
              ~keeper_name
              ~operation_id:operation.operation_id
              ~source:operation.source
              ~input
          with
          | Error detail -> failed Keeper_chat_operation.Invalid_input detail
          | Ok operation_payload ->
            let payload = operation_payload.payload in
            let operation_id =
              Keeper_owner.Chat_operation.Operation_id.to_string operation.operation_id
            in
            let events = Keeper_chat_events.create () in
            let closed = ref false in
            let delivery, resolve_delivery = Eio.Promise.create () in
            let settle_delivery result =
              (* See terminal delivery race: the first resolver is authoritative. *)
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
                        note_operation_wire_event ~operation_id event;
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
               (match Env_config_discord.bot_token_opt () with
                | Some token ->
                  fork_adapter (fun () ->
                    Keeper_chat_discord.adapter_loop
                      ~clock
                      ~token
                      ~channel_id
                      ~events
                      ~on_send_result:(fun result ->
                        settle_delivery
                          (Result.map_error
                             (fun error ->
                                Format.asprintf "%a" Keeper_chat_discord.pp_error error)
                             result))
                      ())
                | None ->
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
             (* The asker is another Keeper, so the answer goes onto its own
                event queue rather than to a screen. Unlike the connector
                adapters there is nothing to stream: [Reply_details] carries
                the finalized visible reply in one event, so this loop only
                remembers it and commits once the run ends. A failed commit
                settles as a delivery failure, which is what marks the
                operation [Delivery_failed] instead of acknowledging an answer
                the asker never got. *)
             (* Messages.app cannot edit a message once it is sent, so there
                is no partial delivery to project and nothing for a streaming
                adapter to do: the reply goes out once, whole, when the run
                ends. That is the Keeper arm's shape rather than the Discord
                and Slack ones, which is why iMessage has no
                [Keeper_chat_*] adapter module beside theirs. *)
             | Keeper_continuation_channel.Imessage { chat_guid; _ } ->
               (match Channel_gate_imessage_state.reply_target ~chat_guid with
                | Error detail ->
                  settle_delivery (Error detail);
                  fork_adapter drain_events
                | Ok target_chat_guid ->
                  fork_adapter (fun () ->
                    let rec loop reply =
                      match Keeper_chat_events.subscribe events with
                      | Keeper_chat_events.Reply_details details ->
                        loop
                          (match details.turn_outcome with
                           | Keeper_turn_outcome.Visible_reply
                             when String.trim details.reply <> "" ->
                             Some details.reply
                           (* The turn spoke somewhere else or said nothing;
                              either way there is no text to send. *)
                           | Keeper_turn_outcome.Visible_reply
                           | Keeper_turn_outcome.Continuation_checkpoint
                           | Keeper_turn_outcome.Terminal_effect_settled
                           | Keeper_turn_outcome.External_effect_pending
                           | Keeper_turn_outcome.No_visible_reply -> None)
                      | Keeper_chat_events.Run_finished _ ->
                        settle_delivery
                          (match reply with
                           (* A run that produced no visible reply has been
                              delivered in full; sending an empty iMessage
                              would be worse than sending none. *)
                           | None -> Ok ()
                           | Some reply ->
                             Channel_gate_imessage_state.send_message
                               ~chat_guid:target_chat_guid ~content:reply ()
                             |> Result.map_error
                                  Imessage_applescript.error_to_string)
                      | Keeper_chat_events.Event_error { message } ->
                        settle_delivery (Error message)
                      | _ -> loop reply
                    in
                    loop None))
             | Keeper_continuation_channel.Keeper { keeper_name = asked_by } ->
               fork_adapter (fun () ->
                 let commit terminal =
                   settle_delivery
                     (Keeper_delegate_completion_wake.deliver
                        ~base_path:(Mcp_server.workspace_config state).base_path
                        ~asked_by
                        ~operation_id
                        ~delegate:keeper_name
                        ~terminal)
                 in
                 let rec loop reply =
                   match Keeper_chat_events.subscribe events with
                   | Keeper_chat_events.Reply_details details ->
                     loop
                       (match details.turn_outcome with
                        | Keeper_turn_outcome.Visible_reply
                          when String.trim details.reply <> "" ->
                          Some details.reply
                        (* The turn spoke somewhere else or said nothing;
                           either way there is no text to hand back. *)
                        | Keeper_turn_outcome.Visible_reply
                        | Keeper_turn_outcome.Continuation_checkpoint
                        | Keeper_turn_outcome.Terminal_effect_settled
                        | Keeper_turn_outcome.External_effect_pending
                        | Keeper_turn_outcome.No_visible_reply -> None)
                   | Keeper_chat_events.Run_finished _ ->
                     commit
                       (match reply with
                        | Some reply -> Keeper_event_queue.Delegate_replied reply
                        | None -> Keeper_event_queue.Delegate_no_reply)
                   | Keeper_chat_events.Event_error { message } ->
                     commit (Keeper_event_queue.Delegate_failed message)
                   | _ -> loop reply
                 in
                 loop None)
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
                ~events
            in
            let delivery = Eio.Promise.await delivery in
            (match outcome, delivery with
             | Some (Delivered { outcome_ref }), Ok () ->
               Keeper_owner.Operation_succeeded { outcome_ref }
             | Some (Delivered { outcome_ref }), Error detail ->
               failed ~outcome_ref Keeper_chat_operation.Delivery_failed detail
             | Some (Failed { kind; detail }), _ ->
               failed
                 (chat_operation_failure_kind_of_queued kind)
                 (queued_turn_failure_kind_to_string kind ^ ": " ^ detail)
             | None, _ ->
               failed
                 Keeper_chat_operation.Turn_invariant
                 "Owner operation returned no terminal turn outcome")))
  in
  match
    Keeper_turn_dispatch_authority.run execute_admitted
  with
  | execution -> execution
;;

let synthesize_wire_terminal_on_settle ~keeper_name ~operation_id ~execution =
  match take_operation_wire_stream ~operation_id, execution with
  | None, _ ->
    (* No live wire stream ever opened for this operation (connector
       channels, pre-execution failures): nothing to close. *)
    ()
  | Some Wire_terminal_sent, _ -> ()
  | Some Wire_started, Keeper_owner.Operation_failed { kind; detail; _ } ->
    let event =
      Ag_ui.run_error
        ~thread_id:("keeper:" ^ keeper_name)
        ~run_id:("keeper-operation-run-" ^ operation_id)
        ~message:detail
        ~code:(Keeper_chat_operation.failure_kind_to_string kind)
        ()
    in
    note_operation_wire_event ~operation_id event;
    Keeper_chat_broadcast.operation_event ~keeper_name ~operation_id ~event;
    publish_operation_live_event ~operation_id event
  | Some Wire_started, Keeper_owner.Operation_succeeded _ ->
    Log.Misc.warn
      "keeper chat operation %s succeeded without a wire terminal event"
      operation_id

(* The production settle glue between the Owner hook and the wire registry.
   Named (and exposed via For_testing) so a test executes exactly what the
   runner wires: both identifiers become plain strings at this boundary, so
   a swapped argument would typecheck (#28849 review). *)
let on_operation_execution_settled ~keeper_name ~claimed_operation_id ~execution =
  match claimed_operation_id with
  | None -> ()
  | Some operation_id ->
    synthesize_wire_terminal_on_settle
      ~keeper_name
      ~operation_id:(Keeper_owner.Chat_operation.Operation_id.to_string operation_id)
      ~execution
;;

let operation_runner ~state ~clock : Keeper_owner.operation_runner =
  let base_path = (Mcp_server.workspace_config state).base_path in
  { ready =
      (fun ~keeper_name ->
         match Keeper_registry.get_with_health ~base_path keeper_name with
         | Some (_, Keeper_registry.Healthy) -> true
         | Some (_, _)
         | None -> false)
  ; execute = operation_executor ~state ~clock
  ; on_execution_settled = on_operation_execution_settled
  }
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
    (* See stream terminal fan-in: the first terminal notification wins. *)
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
        (* See durable acceptance: a closed SSE stream cannot roll back the operation. *)
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
  let control_turn_delivery = control_turn_delivery
  let surface_context_to_instructions = surface_context_to_instructions
  let keeper_tool_failure_log_details = keeper_tool_failure_log_details
  let keeper_chat_stream_headers = keeper_chat_stream_headers
  let note_operation_wire_event = note_operation_wire_event
  let take_operation_wire_stream = take_operation_wire_stream
  let synthesize_wire_terminal_on_settle = synthesize_wire_terminal_on_settle
  let on_operation_execution_settled = on_operation_execution_settled
  let register_operation_live_sink = register_operation_live_sink
end

(* POST /api/v1/keepers/ask-answer

   The operator answers a Keeper's question from whichever surface they happen
   to be at. Two surfaces can submit for the same ask at once and nothing here
   locks the log: the fold settles on first write, so this responds with what
   actually landed rather than echoing what this caller sent. A second
   submission gets the answer that won, not a bare rejection -- the surface
   showing it has to be able to say what was chosen. *)
let ask_answer_response_of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "chose") -> (
          match List.assoc_opt "choice_ids" fields with
          | Some (`List items) ->
              let rec collect acc = function
                | [] -> Ok (Keeper_ask.Chose { choice_ids = List.rev acc })
                | `String id :: rest -> collect (id :: acc) rest
                | _ -> Error "choice_ids must be an array of strings"
              in
              collect [] items
          | Some _ | None -> Error "chose requires choice_ids")
      | Some (`String "wrote") -> (
          match List.assoc_opt "text" fields with
          | Some (`String text) -> Ok (Keeper_ask.Wrote text)
          | Some _ | None -> Error "wrote requires text")
      | Some (`String "skipped") -> Ok Keeper_ask.Skipped
      | Some (`String other) -> Error (Printf.sprintf "unknown response kind %S" other)
      | Some _ | None -> Error "response requires a kind")
  | _ -> Error "each answer response must be an object"

let ask_answer_submissions_of_json items =
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | (`Assoc fields as item) :: rest -> (
        match List.assoc_opt "question_id" fields with
        | Some (`String question_id) -> (
            match List.assoc_opt "response" fields with
            | Some response_json -> (
                match ask_answer_response_of_json response_json with
                | Ok response -> collect ((question_id, response) :: acc) rest
                | Error message -> Error message)
            | None -> Error "each answer requires a response")
        | Some _ | None ->
            let (_ : Yojson.Safe.t) = item in
            Error "each answer requires a question_id (string)")
    | _ -> Error "answers must be an array of objects"
  in
  collect [] items

let ask_answer_failure_status = function
  | Keeper_ask_store.Ask_not_found _ -> `Not_found
  | Keeper_ask_store.Already_answered _ | Keeper_ask_store.Already_withdrawn _ -> `Conflict
  | Keeper_ask_store.Rejected _ -> `Bad_request
  | Keeper_ask_store.Store_failed _ -> `Internal_server_error

let ask_answer_failure_json failure =
  let detail = Keeper_ask_store.answer_failure_to_string failure in
  match failure with
  | Keeper_ask_store.Already_answered { answers; answered_at; _ } ->
      `Assoc
        [
          ("error", `String detail);
          ("state", `String "answered");
          ("answered_at", `Float answered_at);
          ( "answered_question_ids",
            `List
              (List.map
                 (fun (answer : Keeper_ask.answer) -> `String answer.question_id)
                 answers) );
        ]
  | Keeper_ask_store.Ask_not_found _
  | Keeper_ask_store.Already_withdrawn _
  | Keeper_ask_store.Rejected _
  | Keeper_ask_store.Store_failed _ ->
      `Assoc [ ("error", `String detail) ]

(* The wake that closes the loop between a human answering and the Keeper that
   asked. The stimulus carries the ask_id only; the answer stays in
   [Keeper_ask_store] and the turn reads it there. The continuation the Keeper
   recorded when it asked rides along so a woken Keeper replies where the
   question came from rather than wherever its own state last left it. *)
(* What the route says once an answer is recorded. Recording it and telling the
   Keeper are one act: a 2xx when only the first half happened leaves the
   operator believing a decision landed while the Keeper waits on it forever.
   Split out so the choice can be read and tested on its own. *)
let ask_answer_response ~ask_id ~answer_count ~open_remaining ~delivered =
  let body =
    [
      ("recorded", `Bool true);
      ("ask_id", `String ask_id);
      ("answer_count", `Int answer_count);
      ("delivered", `Bool delivered);
      ("open_remaining", `Int open_remaining);
    ]
  in
  if delivered then (`OK, `Assoc body)
  else
    ( `Internal_server_error,
      `Assoc
        (( "error",
           `String
             "answer recorded but the keeper could not be told; answer again to \
              deliver it" )
        :: body) )

let wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id =
  let channel =
    match
      List.assoc_opt ask_id (Keeper_ask_store.rows ~base_path ~keeper_name)
    with
    | Some (ask, _) -> ask.Keeper_ask.continuation
    | None ->
        Keeper_continuation_channel.unrouted
          "answered ask is no longer in the store"
  in
  let payload = { Keeper_event_queue.ask_id; channel } in
  let stimulus =
    { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload
      (* A human addressed this Keeper directly, the same as a mention. *)
    ; urgency = Keeper_event_queue.Normal
      (* NDT-OK: stimulus receipt time, used only for ordering/age *)
    ; arrived_at = Unix.gettimeofday ()
    ; payload = Keeper_event_queue.Ask_answered payload
    }
  in
  match
    Keeper_registry_event_queue.enqueue_stimulus_durable_result ~base_path keeper_name
      stimulus
  with
  | Keeper_registry_event_queue.Stimulus_storage_error detail ->
      Log.Server.error "ask answer wake could not be stored (keeper=%s ask_id=%s): %s"
        keeper_name ask_id detail;
      false
  | Keeper_registry_event_queue.Stimulus_enqueued
  | Keeper_registry_event_queue.Stimulus_already_present -> (
      match
        Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal ~base_path
          keeper_name
      with
      | Keeper_registry.Signaled -> true
      | Keeper_registry.Deferred_not_running _
      | Keeper_registry.Deferred_lifecycle _
      | Keeper_registry.Deferred_unregistered ->
          (* Delivered all the same: the stimulus is stored and the Keeper
             reads it when it next runs. Only the storage failure above leaves
             an answer nobody will ever be told about. *)
          Log.Server.info
            "ask answer wake stored for a keeper that is not running (keeper=%s ask_id=%s)"
            keeper_name ask_id;
          true)

let handle_keeper_ask_answer state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      let parsed =
        try
          match Yojson.Safe.from_string body_str with
          | `Assoc fields ->
              let string_field name =
                match List.assoc_opt name fields with
                | Some (`String value) -> Ok (String.trim value)
                | Some _ | None -> Error (Printf.sprintf "%s (string) is required" name)
              in
              let ( let* ) = Result.bind in
              let* keeper_name = string_field "name" in
              let* ask_id = string_field "ask_id" in
              let* submissions =
                match List.assoc_opt "answers" fields with
                | Some (`List items) -> ask_answer_submissions_of_json items
                | Some _ | None -> Error "answers (array) is required"
              in
              let actor_id =
                match List.assoc_opt "actor_id" fields with
                | Some (`String value) -> Some (String.trim value)
                | Some _ | None -> None
              in
              let session_id =
                match List.assoc_opt "session_id" fields with
                | Some (`String value) -> Some (String.trim value)
                | Some _ | None -> None
              in
              Ok (keeper_name, ask_id, submissions, actor_id, session_id)
          | _ -> Error "JSON object body required"
        with Yojson.Json_error message -> Error ("invalid json: " ^ message)
      in
      match parsed with
      | Error message ->
          respond_json_value_with_cors ~status:`Bad_request request reqd
            (keeper_chat_stream_error_json message)
      | Ok (keeper_name, ask_id, submissions, actor_id, session_id) ->
          if not (Keeper_registry.is_registered ~base_path keeper_name) then
            respond_json_value_with_cors ~status:`Not_found request reqd
              (keeper_chat_stream_error_json "keeper not registered")
          else
            let responder =
              {
                Keeper_ask.surface = Surface_ref.Dashboard { session_id };
                actor_id;
                display_name = None;
              }
            in
            let now = Time_compat.now () in
            match
              Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id ~submissions ~responder
                ~now
            with
            | Error failure ->
                (* An answer recorded but never delivered leaves the Keeper
                   waiting on a decision that already exists. Answering again
                   is how an operator retries, so the retry finishes the
                   delivery instead of only being told it lost the race. The
                   wake is keyed by ask_id, so re-enqueueing a delivered one
                   is a no-op. *)
                (match failure with
                 | Keeper_ask_store.Already_answered _ ->
                     ignore
                       (wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id
                         : bool)
                 | Keeper_ask_store.Ask_not_found _
                 | Keeper_ask_store.Already_withdrawn _
                 | Keeper_ask_store.Rejected _
                 | Keeper_ask_store.Store_failed _ -> ());
                Log.Keeper.info "keeper_ask_answer: keeper=%s ask_id=%s refused=%s" keeper_name
                  ask_id
                  (Keeper_ask_store.answer_failure_to_string failure);
                respond_json_value_with_cors ~status:(ask_answer_failure_status failure) request
                  reqd (ask_answer_failure_json failure)
            | Ok answers ->
                Log.Keeper.info "keeper_ask_answer: keeper=%s ask_id=%s answers=%d" keeper_name
                  ask_id (List.length answers);
                (* The answer is durable now; the Keeper that asked still has
                   no idea. Without this wake it is written down where only a
                   screen reads it and the asker has to remember to go and
                   look, which is why no Keeper had ever asked. *)
                let delivered =
                  wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id
                in
                Log.Keeper.info
                  "keeper_ask_answer: keeper=%s ask_id=%s answers=%d delivered=%b"
                  keeper_name ask_id (List.length answers) delivered;
                let status, body =
                  ask_answer_response ~ask_id ~answer_count:(List.length answers)
                    ~open_remaining:
                      (Keeper_ask_store.open_ask_count ~base_path ~keeper_name)
                    ~delivered
                in
                respond_json_value_with_cors ~status request reqd body)

(* GET /api/v1/keepers/asks?name=<keeper>&include_resolved=<bool>

   What one Keeper is waiting on a human for. A surface renders these rows and
   answers through POST /api/v1/keepers/ask-answer; the choice ids it sends
   back come from the rows it was given, so no surface ever matches on label
   text and rewording a choice cannot orphan an answer. *)
let ask_choice_json (choice : Keeper_ask.choice) =
  `Assoc
    [
      ("choice_id", `String choice.choice_id);
      ("label", `String choice.label);
      ( "description",
        match choice.description with None -> `Null | Some text -> `String text );
    ]

let ask_question_json (question : Keeper_ask.question) =
  `Assoc
    [
      ("question_id", `String question.question_id);
      ("header", `String question.header);
      ("prompt", `String question.prompt);
      ( "mode",
        `String (match question.mode with Keeper_ask.Single -> "single" | Keeper_ask.Multi -> "multi") );
      ( "free_text",
        match question.free_text with
        | Keeper_ask.Choices_only -> `Assoc [ ("allowed", `Bool false) ]
        | Keeper_ask.Free_text_allowed { hint } ->
            `Assoc
              [
                ("allowed", `Bool true);
                ("hint", match hint with None -> `Null | Some text -> `String text);
              ] );
      ("choices", `List (List.map ask_choice_json question.choices));
    ]

let ask_resolution_json = function
  | Keeper_ask.Open -> `Assoc [ ("state", `String "open") ]
  | Keeper_ask.Answered_by { answers; answered_at; _ } ->
      `Assoc
        [
          ("state", `String "answered");
          ("answered_at", `Float answered_at);
          ( "answered_question_ids",
            `List
              (List.map
                 (fun (answer : Keeper_ask.answer) -> `String answer.question_id)
                 answers) );
        ]
  | Keeper_ask.Withdrawn_because { reason; withdrawn_at } ->
      `Assoc
        [
          ("state", `String "withdrawn");
          ("reason", `String reason);
          ("withdrawn_at", `Float withdrawn_at);
        ]

let ask_row_is_open = function
  | Keeper_ask.Open -> true
  | Keeper_ask.Answered_by _ | Keeper_ask.Withdrawn_because _ -> false

let ask_row_json ~keeper_name (ask_id, ((a : Keeper_ask.ask), resolution)) =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("ask_id", `String ask_id);
      ("asked_at", `Float a.asked_at);
      ("context", match a.context with None -> `Null | Some text -> `String text);
      ("questions", `List (List.map ask_question_json a.questions));
      ("resolution", ask_resolution_json resolution);
    ]

let handle_keeper_asks_list state request reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let include_resolved =
    Server_utils.bool_query_param request "include_resolved" ~default:false
  in
  let rows_for keeper_name =
    Keeper_ask_store.rows ~base_path ~keeper_name
    |> List.filter (fun (_, (_, resolution)) ->
           include_resolved || ask_row_is_open resolution)
    |> List.map (ask_row_json ~keeper_name)
  in
  match Server_utils.query_param request "name" with
  | Some keeper_name ->
      if not (Keeper_registry.is_registered ~base_path keeper_name) then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (keeper_chat_stream_error_json "keeper not registered")
      else
        let rows = rows_for keeper_name in
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
            [
              ("scope", `String "keeper");
              ("keeper", `String keeper_name);
              ("open_count", `Int (Keeper_ask_store.open_ask_count ~base_path ~keeper_name));
              ("returned", `Int (List.length rows));
              ("asks", `List rows);
            ])
  | None ->
      (* Fleet-wide. A surface showing questions shows them for everyone at
         once: an operator does not know which Keeper is stuck before looking,
         and asking them to pick a name first is asking them to guess. *)
      let keepers =
        List.map
          (fun (entry : Keeper_registry_types.registry_entry) -> entry.name)
          (Keeper_registry.all ~base_path ())
      in
      let rows = List.concat_map rows_for keepers in
      let open_total =
        List.fold_left
          (fun total keeper_name ->
            total + Keeper_ask_store.open_ask_count ~base_path ~keeper_name)
          0 keepers
      in
      respond_json_value_with_cors ~status:`OK request reqd
        (`Assoc
          [
            ("scope", `String "fleet");
            ("keeper", `Null);
            ("keeper_count", `Int (List.length keepers));
            ("open_count", `Int open_total);
            ("returned", `Int (List.length rows));
            ("asks", `List rows);
          ])
