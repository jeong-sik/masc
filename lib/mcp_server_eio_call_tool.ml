(** Mcp_server_eio_call_tool — Tool call handler and result envelope

    Extracted from mcp_server_eio.ml.
    Handles tools/call JSON-RPC method: single dispatch, result envelope,
    telemetry, and audit logging. Per-tool timeout was
    removed (2026-06-08 fleet-wide cleanup); the tool itself is
    responsible for any hang protection. *)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

(* Delegate to the single canonical definition rather than re-declaring the
   exception→severity match (it previously drifted as a verbatim copy in two
   modules; [Mcp_server_eio_execute] already delegates the same way). The
   severity is derived from the exception class — see
   [Mcp_server_eio_helpers.mcp_exn_level_and_tag]. *)
let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn

let status_of_result : Tool_result.result -> string = function
  | Tool_result.Completed _ -> "ok"
  | (Tool_result.Deferred _ as result) -> Tool_result.string_of_disposition result
  | Tool_result.Failed _ -> "error"
;;

let structured_content_of_result : Tool_result.result -> Yojson.Safe.t option =
  function
  | Tool_result.Completed { data = (`Assoc _ as data); _ }
  | Tool_result.Deferred { data = (`Assoc _ as data); _ }
  | Tool_result.Failed { data = (`Assoc _ as data); _ } -> Some data
  | Tool_result.Completed
      { data = (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
      ; _
      }
  | Tool_result.Deferred
      { data = (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
      ; _
      }
  | Tool_result.Failed
      { data = (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
      ; _
      } -> None
;;

let activity_preview_string value =
  value
  |> Safe_ops.sanitize_text_utf8
  |> Observability_redact.redact_preview
  |> Safe_ops.sanitize_text_utf8

let activity_plain_string value = Safe_ops.sanitize_text_utf8 value

let activity_tool_called_payload ~tool_name ~success ~duration_ms ~source
    ?error_detail ?tool_args_preview arguments =
  let activity_string_field key =
    match Safe_ops.json_string_opt key arguments with
    | Some value ->
        let preview = activity_preview_string value in
        if String.trim preview <> "" then Some (key, `String preview) else None
    | None -> None
  in
  let activity_int_field key =
    match Safe_ops.json_int_opt key arguments with
    | Some value -> Some (key, `Int value)
    | None -> None
  in
  `Assoc
    ([
       ("tool_name", `String (activity_plain_string tool_name));
       ("success", `Bool success);
       ("duration_ms", `Int duration_ms);
       ("source", `String (activity_plain_string source));
       ( "error",
         match error_detail with
         | Some e -> `String (activity_plain_string e)
         | None -> `Null );
       ( "tool_args_preview",
         match tool_args_preview with
         | Some preview -> `String (activity_plain_string preview)
         | None -> `Null );
     ]
     @ List.filter_map activity_string_field
         [
           "cmd";
           "task_id";
           "repo";
           "path";
           "message";
           "branch";
           "branch_name";
           "title";
           "session_id";
           "operation_id";
           "verification_id";
         ]
     @ List.filter_map activity_int_field [ "pr_number"; "issue_number" ])
  |> Safe_ops.sanitize_json_utf8

let option_label key = function
  | Some value when String.trim value <> "" -> [ key, value ]
  | Some _ | None -> []
;;

let mcp_server_operation_duration_labels ~tool_name ~success context =
  let transport =
    match context.Otel_dispatch_hook.transport with
    | None -> []
    | Some transport ->
      option_label
        Otel_genai.Mcp_attr_key.network_protocol_name
        transport.network_protocol_name
      @ option_label
          Otel_genai.Mcp_attr_key.network_protocol_version
          transport.network_protocol_version
      @ option_label
          Otel_genai.Mcp_attr_key.network_transport
          transport.network_transport
  in
  [ Otel_genai.Mcp_attr_key.mcp_method_name, Otel_genai.Mcp_value.tools_call_method
  ; Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool"
  ]
  @ option_label Otel_genai.Attr_key.gen_ai_tool_name (Some tool_name)
  @ option_label
      Otel_genai.Mcp_attr_key.mcp_protocol_version
      context.mcp_protocol_version
  @ transport
  @
  if success
  then []
  else
    [ Otel_genai.Mcp_attr_key.error_type, Otel_genai.Mcp_value.tool_error_type ]
;;

let record_mcp_server_operation_duration_sample ~tool_name ~success ~duration_seconds =
  match Otel_dispatch_hook.current_request_context () with
  | None -> ()
  | Some context ->
    Otel_metric_store.observe_histogram
      Otel_genai.Mcp_metric_name.server_operation_duration
      ~labels:(mcp_server_operation_duration_labels ~tool_name ~success context)
      duration_seconds
;;

let record_mcp_server_operation_duration result ~duration_ms =
  record_mcp_server_operation_duration_sample
    ~tool_name:(Tool_result.tool_name result)
    ~success:(not (Tool_result.is_failed result))
    ~duration_seconds:(float_of_int duration_ms /. 1000.0)
;;

let failure_observation ~duration_ms
    : Tool_result.result -> (Tool_result.tool_failure_class * string) option
  = function
  | Tool_result.Failed { class_; message; _ } ->
    let truncated =
      let error_preview_max = 200 in
      String_util.utf8_safe ~max_bytes:(error_preview_max + 3) ~suffix:"..." message
      |> String_util.to_string
    in
    Some (class_, Printf.sprintf "duration_ms=%d|detail=%s" duration_ms truncated)
  | Tool_result.Completed _ | Tool_result.Deferred _ -> None
;;

module For_testing = struct
  let activity_tool_called_payload = activity_tool_called_payload
  let failure_observation = failure_observation
  let record_mcp_server_operation_duration = record_mcp_server_operation_duration
  let record_mcp_server_operation_duration_sample =
    record_mcp_server_operation_duration_sample
end

let nonempty_string_opt = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

type keeper_runtime_mcp_log_context = {
  keeper_name : string;
  agent_name : string option;
  model : string;
  trace_id : string option;
  session_id : string option;
  turn : int option;
  keeper_turn_id : int option;
  task_id : string option;
  sandbox_profile : string option;
  sandbox_root : string option;
  sandbox_roots : string list option;
  network_mode : string option;
  runtime_profile : string option;
}

let runtime_mcp_keeper_log_context_of_entry
    ?mcp_session_id
    (entry : Keeper_registry.registry_entry)
    ~(arguments : Yojson.Safe.t) : keeper_runtime_mcp_log_context =
  let trace_id =
    Keeper_id.Trace_id.to_string entry.meta.runtime.trace_id
  in
  let model = "runtime" in
  let session_id =
    match Json_util.get_string_nonempty arguments "session_id" with
    | Some _ as session_id -> session_id
    | None ->
        (match nonempty_string_opt mcp_session_id with
         | Some _ as session_id -> session_id
         | None -> Some trace_id)
  in
  let turn =
    match entry.current_turn_observation with
    | Some obs -> Some obs.turn_id
    | None -> None
  in
  let config = Workspace.default_config entry.base_path in
  {
    keeper_name = entry.name;
    agent_name = Some entry.name;
    model;
    trace_id = Some trace_id;
    session_id;
    turn;
    keeper_turn_id = turn;
    task_id = Option.map Keeper_id.Task_id.to_string entry.meta.current_task_id;
    sandbox_profile =
      Some (Keeper_types_profile_sandbox.sandbox_profile_to_string entry.meta.sandbox_profile);
    sandbox_root =
      Some (Keeper_sandbox.host_root_abs_of_meta ~config entry.meta);
    sandbox_roots =
      Some (Keeper_alerting_path.sandbox_roots ~meta:entry.meta);
    network_mode =
      Some (Keeper_types_profile_sandbox.network_mode_to_string entry.meta.network_mode);
    runtime_profile =
      (try Some (Keeper_meta_contract.runtime_id_of_meta entry.meta)
       with Failure _ -> None);
  }

let runtime_mcp_keeper_error_preview message =
  let max_chars = 400 in
  let s = String.trim message in
  String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"..." s
  |> String_util.to_string

let runtime_mcp_keeper_tool_call_sse_payload
    ~(keeper_name : string)
    ~(tool_name : string)
    ~(duration_ms : int)
    ~(disposition : ('completed, 'deferred, 'failed) Tool_result.disposition)
    ~(arguments : Yojson.Safe.t)
    ~(message : string) : Yojson.Safe.t =
  let base_fields =
    [
      ("type", `String "keeper_tool_call");
      ("name", `String keeper_name);
      ("tool_name", `String tool_name);
      ("duration_ms", `Int duration_ms);
      ("disposition", `String (Tool_result.string_of_disposition disposition));
      ("ts_unix", `Float (Time_compat.now ()));
    ]
  in
  let error_fields =
    match disposition with
    | Tool_result.Completed _ | Tool_result.Deferred _ -> []
    | Tool_result.Failed _ ->
      [ ("error_text", `String (runtime_mcp_keeper_error_preview message)) ]
  in
  let io_fields =
    Keeper_tools_agent_core_handler_telemetry.tool_io_preview_fields
      ~tool_name
      ~input:arguments
      ~output:message
      ()
  in
  `Assoc (base_fields @ error_fields @ io_fields)

let runtime_mcp_masc_root ~base_path =
  match Keeper_tool_call_log.configured_masc_root () with
  | Some masc_root -> masc_root
  | None ->
      let config = Workspace.default_config base_path in
      Workspace.masc_root_dir config

let record_runtime_mcp_trajectory_coverage_gap
    ~(masc_root : string)
    ~(keeper_name : string)
    ~(trace_id : string)
    ~(stale_reason : string)
    (exn : exn) : unit =
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"trajectory_tool_call"
      ~producer:"mcp_server_eio_call_tool.runtime_mcp"
      ~durable_store:(Trajectory.trajectory_path masc_root keeper_name trace_id)
      ~dashboard_surface:"/api/v1/keepers/:name/tool-stats"
      ~stale_reason
      ~keeper_name
      ~trace_id
      ~exn
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | gap_exn ->
      log_mcp_exn
        ~label:"runtime MCP trajectory coverage gap append failed"
        gap_exn

let record_runtime_mcp_keeper_trajectory
    (ctx : keeper_runtime_mcp_log_context)
    ~(base_path : string)
    ~(tool_name : string)
    ~(arguments : Yojson.Safe.t)
    ~(message : string)
    ~(success : bool)
    ~(duration_ms : int)
    ~(execution_id : Ids.Execution_id.t) : unit =
  let trace_id = Option.value ~default:"runtime-mcp" ctx.trace_id in
  let masc_root = runtime_mcp_masc_root ~base_path in
  let safe_input = Observability_redact.redact_json_value arguments in
  let safe_output =
    Observability_redact.redact_preview ~max_len:4000 message
  in
  let turn = Option.value ~default:0 ctx.turn in
  let round =
    Trajectory.next_round
      ~masc_root
      ~keeper_name:ctx.keeper_name
      ~trace_id
      ~turn
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:ctx.keeper_name
      ?trace_id:ctx.trace_id
      ?session_id:ctx.session_id
      ?keeper_turn_id:ctx.keeper_turn_id
      ?task_id:ctx.task_id
      ?sandbox_profile:ctx.sandbox_profile
      ?sandbox_root:ctx.sandbox_root
      ?sandbox_roots:ctx.sandbox_roots
      ?network_mode:ctx.network_mode
      ?runtime_profile:ctx.runtime_profile
      ()
  in
  let error = if success then None else Some safe_output in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name
      ~input:safe_input
      ~success
      ~duration_ms:(float_of_int duration_ms)
      ?error
      ?sandbox_target:ctx.sandbox_profile
      ()
  in
  let now = Time_compat.now () in
  let entry : Trajectory.tool_call_entry =
    {
      ts = now;
      ts_iso = Masc_domain.iso8601_of_unix_seconds now;
      turn;
      round;
      tool_name;
      args_json = Yojson.Safe.to_string safe_input;
      gate_decision = Trajectory.Pass;
      result = Some safe_output;
      duration_ms;
      error;
      execution_id = Some (Ids.Execution_id.to_string execution_id);
    }
  in
  try
    Trajectory.append_entry
      ~runtime_contract
      ~action_radius
      ~masc_root
      ~keeper_name:ctx.keeper_name
      ~trace_id
      entry
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      record_runtime_mcp_trajectory_coverage_gap
        ~masc_root
        ~keeper_name:ctx.keeper_name
        ~trace_id
        ~stale_reason:"runtime_mcp_trajectory_append_failed"
        exn

let record_runtime_mcp_keeper_tool_trace
    ?mcp_session_id
    (entry : Keeper_registry.registry_entry)
    ~(tool_name : string)
    ~(arguments : Yojson.Safe.t)
    ~(message : string)
    ~(disposition : ('completed, 'deferred, 'failed) Tool_result.disposition)
    ~(execution_id : Ids.Execution_id.t)
    ~(duration_ms : int) : unit =
  let ctx =
    runtime_mcp_keeper_log_context_of_entry
      ?mcp_session_id
      entry
      ~arguments
  in
  let success =
    match disposition with
    | Tool_result.Completed _ | Tool_result.Deferred _ -> true
    | Tool_result.Failed _ -> false
  in
  Keeper_tool_call_log.log_call
    ~keeper_name:ctx.keeper_name
    ~tool_name
    ~input:arguments
    ~output_text:message
    ~success
    ~duration_ms:(float_of_int duration_ms)
    ~model:ctx.model
    ~lane:"runtime_mcp"
    ?agent_name:ctx.agent_name
    ~execution_id
    ?trace_id:ctx.trace_id
    ?session_id:ctx.session_id
    ?turn:ctx.turn
    ?keeper_turn_id:ctx.keeper_turn_id
    ?task_id:ctx.task_id
    ?sandbox_profile:ctx.sandbox_profile
    ?sandbox_root:ctx.sandbox_root
      ?sandbox_roots:ctx.sandbox_roots
      ?network_mode:ctx.network_mode
      ?runtime_profile:ctx.runtime_profile
    ~result_bytes:(String.length message)
    ();
  record_runtime_mcp_keeper_trajectory
    ctx
    ~base_path:entry.base_path
    ~tool_name
    ~arguments
    ~message
    ~success
    ~duration_ms
    ~execution_id;
  Sse.broadcast
    (runtime_mcp_keeper_tool_call_sse_payload
       ~keeper_name:ctx.keeper_name
       ~tool_name
       ~duration_ms
       ~disposition
       ~arguments
       ~message)

(** Resolve managed agent tool call to canonical operation *)
(* The protocol layer answers this with Invalid_params rather than a generic
   failure. It used to tell the two apart by prefix-matching the message of an
   [Invalid_argument] -- the sentinel text was the whole contract, written once
   at the raise and once at the catch, and a reword on either side would have
   quietly downgraded the answer with nothing going red. *)
exception Managed_agent_translation_failed of string

let resolve_managed_agent_call ?mcp_session_id request =
  let requested_name = Mcp_server_eio_call_request.requested_name request in
  let arguments = Mcp_server_eio_call_request.arguments request in
  let identity =
    Client_registry_eio.get_or_create_identity ?mcp_session_id arguments
  in
  Agent_core_tool_contract.resolve_requested_tool_call
    ~agent_name:identity.Client_identity.agent_name
    ~requested_name ~arguments

(** Handle tools/call JSON-RPC method *)
let handle_call_tool_eio ~execute_tool_eio ~maybe_emit_resource_notifications
    ~broadcast_tools_list_changed ~sw ~clock ?(profile = Full) ?mcp_session_id
    ?auth_token ?(internal_keeper_runtime = false) state id request =
  (* The active workspace is an admission fact for this call.  In particular,
     [masc_start] may publish a new current scope while executing, but the
     initiating call and every post-execution observation remain attributed to
     this source scope. *)
  let workspace_scope : Mcp_server.workspace_scope =
    Mcp_server.workspace_scope state
  in
  let config = workspace_scope.config in
  let make_response = Mcp_transport_protocol.make_response in
  let request_id =
    match Mcp_transport_protocol.request_id_of_yojson id with
    | Ok request_id -> request_id
    | Error error ->
      invalid_arg
        ("handle_call_tool_eio admitted an invalid MCP request id: "
         ^ Mcp_transport_protocol.request_id_error_to_string error)
  in
  let invocation_ref =
    match mcp_session_id with
    | None -> None
    | Some session_id ->
      (match Tool_invocation_ref.external_mcp ~request_id ~session_id with
       | Ok invocation_ref -> Some invocation_ref
       | Error error ->
         invalid_arg
           ("handle_call_tool_eio admitted an invalid MCP invocation scope: "
            ^ Tool_invocation_ref.error_to_string error))
  in
  let requested_name = Mcp_server_eio_call_request.requested_name request in
  let admitted_arguments = Mcp_server_eio_call_request.arguments request in
  let name, arguments =
    match profile with
    | Managed_agent -> (
        match resolve_managed_agent_call ?mcp_session_id request with
        | Ok resolved -> resolved
        | Error msg ->
            raise (Managed_agent_translation_failed msg))
    | Full | Operator_remote -> requested_name, admitted_arguments
  in
  (* Measure execution time for telemetry *)
  let start_time = Eio.Time.now clock in
  let execute () =
    try
      execute_tool_eio
        ~sw
        ~clock
        ~workspace_scope
        ?profile:(Some profile)
        ?mcp_session_id
        ?invocation_ref
        ?auth_token
        ?internal_keeper_runtime:(Some internal_keeper_runtime)
        state
        ~name
        ~arguments
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Auth.Auth_config_error _ ->
      Tool_result.error
        ~failure_class:Tool_result.Runtime_failure
        ~tool_name:name
        ~start_time
        "Authentication configuration unavailable"
    | Workspace.Not_initialized ->
      (* RFC-0189: server bootstrap incomplete — Masc_domain
         System NotInitialized.  [Runtime_failure] (caller
         cannot fix; the operator must initialise MASC). *)
      Tool_result.error
        ~failure_class:Tool_result.Runtime_failure
        ~tool_name:name ~start_time
        (Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized))
    | exn when Keeper_registry_types.is_operator_interrupt exn ->
      (* #28810: operator-requested turn interrupt is a typed cancellation,
         not a crash. The guard covers every Eio delivery shape
         (#28868 review). *)
      Log.Mcp.info "tools/call interrupted by operator: %s" name;
      Tool_result.error
        ~failure_class:Tool_result.Operator_cancelled
        ~tool_name:name
        ~start_time
        Keeper_registry_types.operator_interrupt_detail
    | exn ->
      (* Never let a tool exception crash the MCP server. *)
      let err = Printexc.to_string exn in
      let trace = Printexc.get_backtrace () in
      let err_detail = if String.length trace > 0 then err ^ "\n" ^ trace else err in
      (Log.Mcp.error "tools/call crashed: %s" err_detail;
         (* RFC-0189: catch-all for unexpected exceptions —
            [Runtime_failure].  Could become more specific via
            [of_exn] once the exception variants are typed; for
            now blanket Runtime preserves operator-visible
            severity (the existing log line stays ERROR). *)
         Tool_result.error
           ~failure_class:Tool_result.Runtime_failure
           ~tool_name:name ~start_time
           (Printf.sprintf "Internal error: %s" err_detail))
  in
  let result = execute () in
  let attempts = 1 in
  let success = not (Tool_result.is_failed result)
  and message = Tool_result.message result
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let request_id_json =
    Mcp_transport_protocol.request_id_to_yojson request_id
  in
  let request_id_trace_fallback = Yojson.Safe.to_string request_id_json in
  let mcp_session_detail = Json_util.string_opt_to_json mcp_session_id in

  (* Resolve caller identity for telemetry.  HTTP auth injects [_agent_name];
     tool-domain [agent_name] is not a caller identity. *)
  let agent_name =
    let from_transport =
      Safe_ops.json_string ~default:"" "_agent_name" arguments
    in
    if from_transport <> "" then from_transport
    else
      let identity =
        Client_registry_eio.get_or_create_identity ?mcp_session_id arguments
      in
      let resolved = identity.Client_identity.agent_name in
      if resolved <> "" then resolved else "unknown"
  in
  let telemetry_session_id =
    match Json_util.get_string_nonempty arguments "session_id" with
    | Some _ as session_id -> session_id
    | None -> nonempty_string_opt mcp_session_id
  in
  let telemetry_operation_id = Json_util.get_string_nonempty arguments "operation_id" in
  let telemetry_worker_run_id = Json_util.get_string_nonempty arguments "worker_run_id" in
  let failure_observation = failure_observation ~duration_ms result in
  let error_detail =
    Option.map (fun (_failure_class, detail) -> detail) failure_observation
  in
  let otel_trace_id = Otel_spans.current_trace_id () in
  Audit_log.log_tool_call config
    ~agent_id:agent_name ~tool_name:name ~success ~error_msg:error_detail
    ?trace_id:otel_trace_id ();
  (match failure_observation with
   | None -> ()
   | Some (failure_class, error_detail) ->
    Log.Mcp.emit (Tool_result.log_level_of_failure_class failure_class)
      ~details:
        (`Assoc
          [
            ("event_family", `String "tool_call_failure");
            ( "failure_class",
              `String (Tool_result.tool_failure_class_to_string failure_class) );
            ("tool_name", `String name);
            ("phase", `String "failure");
            ("request_id", request_id_json);
            ("session_id", mcp_session_detail);
            ("outcome", `String "error");
            ("agent_name", `String agent_name);
            ("duration_ms", `Int duration_ms);
            ("attempts", `Int attempts);
            ("error_detail", `String error_detail);
          ])
      (Printf.sprintf "tool call failed: %s — %s" name
         error_detail));

  (* Classify call source: Keeper_internal only when the resolved agent_name
     matches a keeper in the admission workspace.  A process-global lookup
     could select an identically named keeper from the newly current scope
     after [masc_start], tearing tool-usage persistence from this call's
     observation generation.  Missing identity falls through to External_mcp.
     Issue #8915. *)
  let keeper_entry =
    if String.length agent_name = 0 then None
    else
      Keeper_registry.all ~base_path:config.base_path ()
      |> List.find_opt (fun (entry : Keeper_registry.registry_entry) ->
        String.equal entry.name agent_name)
  in
  (* RFC-0233 PR-1: one mint per execution at this dispatch boundary. The
     tool_calls row, the trajectory row and the [Tool_called] telemetry event
     all carry this value, so a reader of two streams can tell one physical
     call reported twice from two calls. Minted only when a keeper owns the
     call, because that is when a tool_calls row is written. *)
  let execution_id =
    Option.map (fun _ -> Ids.Execution_id.generate ()) keeper_entry
  in
  let source : Tool_registry.call_source =
    match keeper_entry with
    | Some _ -> Agent_internal
    | None -> External_mcp
  in
  (match keeper_entry with
   | Some entry ->
       Keeper_registry.record_tool_use
         ~base_path:entry.base_path entry.name ~tool_name:name ~disposition:result;
       Keeper_registry_tool_usage_persistence.mark_dirty ~base_path:entry.base_path entry.name
   | None -> ());

  (* #10358: classify failure mode at the dispatch boundary so
     telemetry carries the diagnostic.  Mirrors the vocabulary
     [Tool_assignment_telemetry.emit_completed] uses below; hoisted
     here so [track_tool_called] can fan out a paired
     [Error_occurred] event for the previously-dead ADT variant. *)
  let telemetry_error_kind =
    match failure_observation with
    | Some _ -> Some (Telemetry_eio.error_kind_of_string "tool_failure")
    | None -> None
  in
  let telemetry_failure_class =
    Option.map (fun (failure_class, _detail) -> failure_class) failure_observation
  in
  (* Track tool call in telemetry (controlled by MASC_TELEMETRY_ENABLED) *)
  let telemetry_enabled = Env_config_core.telemetry_enabled () in
  if telemetry_enabled then
    (match state.Mcp_server.fs with
     | Some fs ->
         (try Telemetry_eio.track_tool_called ~fs config
                ~tool_name:name ~agent_id:agent_name ~success ~duration_ms
                ~source:(Tool_registry.string_of_source source)
                ?session_id:telemetry_session_id
                ?operation_id:telemetry_operation_id
                ?worker_run_id:telemetry_worker_run_id
                ?execution_id:(Option.map Ids.Execution_id.to_string execution_id)
                ?failure_class:telemetry_failure_class
                ?error_kind:telemetry_error_kind
                ?error_message:error_detail
                ()
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            log_mcp_exn ~label:"telemetry tracking failed" exn)
     | None -> ());

  (* Otel_metric_store: record errors for failed tool calls *)
  if not success then
    Otel_metric_store.record_error ~error_type:name ();
  record_mcp_server_operation_duration result ~duration_ms;

  (* Track in-memory call counter for all declared tool names (including hidden). *)
  (* Tool assignment telemetry: Called → Completed causal chain.
     Lookup latest assignment for this agent, emit Called at start
     and Completed after result is known. *)
  let assignment_id_opt =
    Tool_assignment_telemetry.find_latest_assignment_id ~agent_id:agent_name
  in
  let called_assignment_id_opt =
    match assignment_id_opt with
    | Some aid ->
        let args_hash =
          Digestif.SHA256.(digest_string (Yojson.Safe.to_string arguments) |> to_hex)
        in
        Tool_assignment_telemetry.emit_called
          ~agent_id:agent_name
          ~tool_name:name
          ~arguments_hash:args_hash
          ~source:(Tool_registry.string_of_source source)
          ()
    | None -> None
  in
  (match called_assignment_id_opt with
   | Some aid ->
       let error_kind =
         if not success then
           Some (Tool_assignment_telemetry.error_kind_of_string "tool_failure")
         else None
       in
       Tool_assignment_telemetry.emit_completed
         ~assignment_id:aid
         ~tool_name:name
         ~success
         ~duration_ms:(float_of_int duration_ms)
         ?error_kind
         ()
   | None -> ());

  (* Track in-memory call counter for all declared tool names (including hidden). *)
  Tool_registry.record_call_if_known ~source ?assignment_id:called_assignment_id_opt
    ~tool_name:name ~disposition:result ~duration_ms ();

  let activity_payload =
    let tool_args_preview =
      Observability_redact.redact_tool_input ~tool_name:name arguments
    in
    activity_tool_called_payload
      ~tool_name:name
      ~success
      ~duration_ms
      ~source:(Tool_registry.string_of_source source)
      ?error_detail
      ?tool_args_preview
      arguments
  in

  (* Emit activity graph event for tool call — enables real-time dashboard tracking *)
  (try
    (* fire-and-forget: activity graph emission must not change the tool-call result. *)
    ignore (Activity_graph.emit config
      ~actor:(Activity_graph.entity ~kind:"agent" agent_name)
      ~subject:(Activity_graph.entity ~kind:"tool" name)
      ~kind:
        (Activity_graph.tool_execution_event_kind_to_string
           Activity_graph.External_tool_called)
      ~payload:activity_payload
      ~tags:(if success then ["tool"; "success"] else ["tool"; "failure"])
      ())
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    log_mcp_exn ~label:"activity graph emit failed" exn);

  let trace_id =
    match otel_trace_id with
    | Some tid -> tid
    | None -> request_id_trace_fallback
  in
  (match keeper_entry, execution_id with
   | Some entry, Some execution_id ->
       (try
          record_runtime_mcp_keeper_tool_trace
            ?mcp_session_id
            entry
            ~tool_name:name
            ~arguments
            ~message
            ~disposition:result
            ~execution_id
            ~duration_ms
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          log_mcp_exn ~label:"runtime MCP keeper tool trace failed" exn)
   | Some _, None | None, _ -> ());
  let status = status_of_result result in
  let envelope =
    `Assoc [
      ("kind", `String "tool_call");
      ("summary", `String message);
      ("status", `String status);
      ("tool", `String name);
    ]
  in
  let content_items =
    [
      `Assoc
        [
          ("type", `String "text");
          ("text", `String message);
        ]
    ]
  in
  let structured_content = structured_content_of_result result in
  let meta_fields =
    [
      ("trace_id", `String trace_id);
      ("agent_id", `String agent_name);
      ("tool", `String name);
      ("duration_ms", `Int duration_ms);
      ("attempts", `Int attempts);
      ("timestamp", `String (Masc_domain.now_iso ()));
    ]
    @
    match Tool_result.failure_class result with
    | Some failure_class ->
      [ ( "failure_class"
        , `String (Tool_result.tool_failure_class_to_string failure_class) ) ]
    | None -> []
  in
  (* [CallToolResult] defines [content], [structuredContent], [isError] and
     [_meta] and nothing else, so the envelope and the call trace go under this
     server's own [_meta] key rather than beside them. The envelope is what the
     TUI renders a call as; the rest is timing and failure classification. *)
  let call_meta =
    Mcp_server.(
      meta_field ~key:tool_call_meta_key (("envelope", envelope) :: meta_fields))
  in
  let result_fields =
    [
      ("content", `List content_items);
      ("isError", `Bool (not success));
      ("_meta", `Assoc call_meta);
    ]
    @
    match structured_content with
    | Some value -> [ ("structuredContent", value) ]
    | None -> []
  in
  let result = make_response ~id (`Assoc result_fields) in

  maybe_emit_resource_notifications ~success ~tool_name:name;

  (* Log result *)
  let preview =
    String_util.utf8_safe ~max_bytes:83 ~suffix:"..." message |> String_util.to_string
  in
  let preview = String.map (function '\n' -> ' ' | c -> c) preview in
  let outcome = if success then Tool_result.Ok else Tool_result.Error in
  Log.Mcp.emit (Tool_result.log_level_of_tool_call_outcome outcome)
    ~details:
      (`Assoc
        [
          ("event_family", `String "tool_call");
          ("tool_name", `String name);
          ("phase", `String "result");
          ("request_id", request_id_json);
          ("session_id", mcp_session_detail);
          ("agent_name", `String agent_name);
          ("outcome", `String (Tool_result.string_of_tool_call_outcome outcome));
          ("success", `Bool success);
          ("duration_ms", `Int duration_ms);
          ("attempts", `Int attempts);
        ])
    (Printf.sprintf "%s -> %s" name preview);

  result
