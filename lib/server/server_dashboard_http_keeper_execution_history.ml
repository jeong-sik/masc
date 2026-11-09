module History = Keeper_native_execution_history
module P = History.Projection
module Public_error = Server_keeper_chat_public_error
open Result.Syntax

type route =
  | Calls of {keeper_name:string; operation_id:string}
  | Events of {keeper_name:string; operation_id:string; call_id:string}

let route path =
  match String.split_on_char '/' path |> List.map Uri.pct_decode with
  | [""; "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"; operation_id; "native-calls"] ->
    Some (Calls {keeper_name; operation_id})
  | [""; "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"; operation_id; "native-calls"; call_id; "events"] ->
    Some (Events {keeper_name; operation_id; call_id})
  | _ -> None

let permission = Masc_domain.CanAdmin
let optional string = function None -> `Null | Some value -> `String (string value)
let block_kind = function
  | P.Text_block -> "text" | Thinking_block -> "thinking"
  | Reasoning_details_block -> "reasoning_details" | Redacted_thinking_block -> "redacted_thinking"
  | Image_block -> "image" | Document_block -> "document" | Audio_block -> "audio"

let map_display_field key project = function
  | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
      name, if String.equal name key then project value else value) fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as value -> value

let binding_target_json ~redact_json target =
  (* The opaque Core snapshot's canonical codec owns these schema keys and
     enum values. Only its display leaves enter content redaction; transport,
     registration, provider kind, auth scheme and the diagnostic fingerprint
     remain the snapshot's typed facts. *)
  Agent_core.Binding_identity.Redacted_snapshot.to_yojson target
  |> map_display_field "provider" (map_display_field "id" redact_json)
  |> map_display_field "model" redact_json
  |> map_display_field "endpoint" redact_json
  |> map_display_field "request_path" redact_json
  |> map_display_field "credential_scope" redact_json

let node_kind ~redact_text ~redact_json = function
  | P.Agent_run {agent_name} -> `Assoc ["kind", `String "agent_run"; "agent_name", `String (redact_text agent_name)]
  | Agent_turn {ordinal} -> `Assoc ["kind", `String "agent_turn"; "ordinal", `Int ordinal]
  | Provider_attempt {ordinal; target} -> `Assoc ["kind", `String "provider_attempt"; "ordinal", `Int ordinal;
      "target", binding_target_json ~redact_json target]
  | Output_block {ordinal; block_kind=kind} -> `Assoc ["kind", `String "output_block";
      "ordinal", `Int ordinal; "block_kind", `String (block_kind kind)]
  | Tool_invocation {provider_tool_use_id; tool_name; schedule; completion} ->
    `Assoc ["kind", `String "tool_invocation"; "tool_name", `String (redact_text tool_name);
      "provider_tool_use_id", optional Fun.id provider_tool_use_id;
      "schedule", `Assoc ["planned_index", `Int schedule.planned_index;
        "batch_index", `Int schedule.batch_index; "batch_size", `Int schedule.batch_size;
        "execution_mode", Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode];
      "completion", Agent_core.Tool_contract.completion_to_yojson completion]
  | Tool_attempt -> `Assoc ["kind", `String "tool_attempt"]

let redact_media_source ~redact_text = function
  | Llm_provider.Types.Base64 value -> Llm_provider.Types.Base64 (redact_text value)
  | Url value -> Url (redact_text value)
  | File_id value -> File_id (redact_text value)

let rec redact_block ~redact_text ~redact_json : Llm_provider.Types.content_block -> Llm_provider.Types.content_block = function
  | Text value -> Text (redact_text value)
  | Thinking value -> Thinking {content=redact_text value.content;
      signature=Option.map redact_text value.signature}
  | ReasoningDetails value -> ReasoningDetails {
      reasoning_content=Option.map redact_text value.reasoning_content;
      details=List.map (fun (detail : Llm_provider.Types.reasoning_detail) ->
        {Llm_provider.Types.raw=redact_json detail.raw; text=Option.map redact_text detail.text}) value.details}
  | RedactedThinking value -> RedactedThinking (redact_text value)
  | ToolUse value -> ToolUse {value with name=redact_text value.name; input=redact_json value.input}
  | ToolResult value -> ToolResult {value with content=redact_text value.content;
      json=Option.map redact_json value.json;
      content_blocks=Option.map (List.map (redact_block ~redact_text ~redact_json)) value.content_blocks}
  | Image value -> Image {value with source=redact_media_source ~redact_text value.source}
  | Document value -> Document {value with source=redact_media_source ~redact_text value.source}
  | Audio value -> Audio {value with source=redact_media_source ~redact_text value.source}

let update_json ~redact_text ~redact_json update =
  let content_json block =
    redact_block ~redact_text ~redact_json block |> Llm_provider.Api_common.content_block_to_json in
  match update with
  | P.Turn_ready _ -> "turn_ready", None
  | Checkpoint_snapshot _ -> "checkpoint_snapshot", None
  | Provider_event _ -> "provider_event", None
  | Provider_request_snapshot _ -> "provider_request_snapshot", None
  | Provider_response_snapshot _ -> "provider_response_snapshot", None
  | Output_delta value -> "output_delta", Some (redact_json value)
  | Output_snapshot value -> "output_snapshot", Some (content_json value)
  | Tool_input_delta value -> "tool_input_delta", Some (redact_json value)
  | Tool_input_snapshot value -> "tool_input_snapshot", Some (content_json value)
  | Tool_progress value -> "tool_progress", Some (redact_json value)
  | Tool_result value -> "tool_result", Some (content_json value)

let failure_kind = function
  | P.Provider_failure -> "provider_failure" | Tool_failure -> "tool_failure"
  | Hook_failure -> "hook_failure" | Observer_failure -> "observer_failure"
  | Persistence_failure -> "persistence_failure" | Protocol_failure -> "protocol_failure"
  | Internal_failure -> "internal_failure"

let terminal_json ~redact_text ~redact_json = function
  | P.Succeeded -> `Assoc ["kind", `String "succeeded"]
  | Failed failure -> `Assoc ["kind", `String "failed";
      "failure_kind", `String (failure_kind failure.kind); "detail", `String (redact_text failure.detail);
      "data", (match failure.data with None -> `Null | Some value -> redact_json value)]
  | Cancelled {reason; data} -> `Assoc ["kind", `String "cancelled";
      "reason", optional redact_text reason; "data", (match data with None -> `Null | Some value -> redact_json value)]

let event_json ~redact_text ~redact_json (event : P.event) =
  let payload = match event.payload with
    | P.Node_opened node -> `Assoc ["kind", `String "node_opened";
        "node_id", `String (P.Node_id.to_string node.node_id);
        "run_id", `String (P.Run_id.to_string node.run_id);
        "parent_node_id", optional P.Node_id.to_string node.parent_node_id;
        "node", node_kind ~redact_text ~redact_json node.kind]
    | Node_updated {node_id; update} ->
      let kind, data = update_json ~redact_text ~redact_json update in
      `Assoc ["kind", `String "node_updated"; "node_id", `String (P.Node_id.to_string node_id);
        "update_kind", `String kind; "data", (match data with None -> `Null | Some data -> data)]
    | Node_closed {node_id; terminal} -> `Assoc ["kind", `String "node_closed";
        "node_id", `String (P.Node_id.to_string node_id); "terminal", terminal_json ~redact_text ~redact_json terminal] in
  let cause_json = function
    | P.Internal_event event_id -> `Assoc ["kind", `String "internal"; "event_id", `String (P.Event_id.to_string event_id)]
    | External_event {source; event_id} -> `Assoc ["kind", `String "external";
        "source", `String (P.External_source.to_string source); "event_id", `String event_id] in
  `Assoc ["event_id", `String (P.Event_id.to_string event.event_id);
    "run_id", `String (P.Run_id.to_string event.run_id);
    "correlation_id", `String (P.Correlation_id.to_string event.correlation_id);
    "seq", `Int event.seq; "parent_event_id", optional P.Event_id.to_string event.parent_event_id;
    "causes", `List (List.map cause_json event.causes); "payload", payload;
    "event_time", `Float event.event_time; "observed_at", `Float event.observed_at;
    "source_clock", `String (Agent_core.Event_envelope.source_clock_to_string event.source_clock)]

let public_error kind detail =
  let error = Public_error.make ~incident_id:(Random_id.uuid_v7 ()) kind in
  Log.Dashboard.warn "native_history incident_id=%s code=%s detail=%s"
    error.incident_id error.code detail;
  error

let history_error error =
  let kind = match error with
    | History.Invalid_keeper_name _ | Invalid_limit _ | Unknown_after_call _ -> Public_error.Invalid_input
    | Missing_operation_store | Unknown_call _ -> Journal_missing
    | Operation_store (Unknown_operation _) -> Unknown_operation
    | Operation_store (Invalid_input _ | Not_queued _ | Not_running _ | Idempotency_conflict _
        | Store_unavailable _ | Integrity_error _ | Native_call_unsettled)
    | Runtime_unavailable | Filesystem_unavailable -> Store_unavailable
    | Projection_failed (P.Invalid_limit _ | Cursor_scope_mismatch | Cursor_ahead _) -> Invalid_input
    | Projection_failed (Locator_not_found _ | Locator_not_top_level _) -> Journal_missing
    | Projection_failed (Semantic_failure _) -> Journal_corrupt
    | Projection_failed (Storage_failure _) -> Journal_unreadable in
  public_error kind (History.error_to_string error)

let parameter request key =
  match List.assoc_opt key (Uri.query (Uri.of_string request.Httpun.Request.target)) with
  | None -> Ok None
  | Some [value] -> Ok (Some value)
  | Some (_ :: _ :: _ | []) -> Error (public_error Public_error.Invalid_input ("duplicate query field: " ^ key))

let limit request ~default ~maximum =
  let* raw = parameter request "limit" in
  match raw with
  | None -> Ok default
  | Some raw -> (match int_of_string_opt raw with
    | Some value when value > 0 && value <= maximum -> Ok value
    | Some _ | None -> Error (public_error Public_error.Invalid_input "invalid history page limit"))

let cursor request key =
  let* raw = parameter request key in
  match raw with
  | None -> Ok None
  | Some raw ->
    let* json = try Ok (Yojson.Safe.from_string raw) with Yojson.Json_error detail ->
      Error (public_error Public_error.Invalid_input detail) in
    P.cursor_of_yojson json |> Result.map Option.some
    |> Result.map_error (fun error -> public_error Public_error.Invalid_input (P.cursor_decode_error_to_string error))

let handle_get state request reqd route =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let keeper_name, raw_id = match route with
    | Calls {keeper_name; operation_id} | Events {keeper_name; operation_id; call_id=_} -> keeper_name, operation_id in
  let result = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let* operation_id = History.Operation_id.of_string raw_id
      |> Result.map_error (public_error Public_error.Invalid_input) in
    match route with
    | Calls _ ->
      let* after_call_id = parameter request "after_call_id" in
      let* limit = limit request ~default:50 ~maximum:History.max_calls_per_page in
      let* page = History.list_calls ~base_path ~keeper_name ~operation_id ~after_call_id ~limit
        |> Result.map_error history_error in
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let calls = List.map (fun (call : Keeper_native_call.history_ref) -> `Assoc [
        "call_id", `String call.call_id;
        "runtime_id", `String (Keeper_secret_redaction.redact_text redaction call.runtime_id);
        "trace_id", `String (Keeper_id.Trace_id.to_string call.trace_id)]) page.calls in
      Ok (`Assoc ["schema", `String "masc.native_execution_calls.v1";
        "operation_id", `String raw_id; "execution_operation_id", `String (History.Operation_id.to_string page.execution_operation_id);
        "calls", `List calls; "next_after_call_id", optional Fun.id page.next_after_call_id])
    | Events {call_id; _} ->
      let* after = cursor request "after" in
      let* through = cursor request "through" in
      let* limit = limit request ~default:200 ~maximum:Keeper_chat_event_log.page_max_limit in
      let* result = History.read_page ~base_path ~keeper_name ~operation_id ~call_id ~after ~through ~limit
        |> Result.map_error history_error in
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let page = result.page in
      Ok (`Assoc ["schema", `String "masc.native_execution_events.v1";
        "operation_id", `String raw_id; "execution_operation_id", `String (History.Operation_id.to_string result.execution_operation_id);
        "call_id", `String result.call.call_id;
        "events", `List (List.map (event_json
          ~redact_text:(Keeper_secret_redaction.redact_text redaction)
          ~redact_json:(Keeper_secret_redaction.redact_json redaction)) page.events);
        "next_cursor", P.cursor_to_yojson page.next_cursor;
        "high_watermark", P.cursor_to_yojson page.high_watermark; "has_more", `Bool page.has_more])) in
  match result with
  | Ok json -> Server_auth.respond_json_value_with_cors ~status:`OK request reqd json
  | Error error -> Server_auth.respond_json_value_with_cors ~status:error.status request reqd (Public_error.to_json error)
