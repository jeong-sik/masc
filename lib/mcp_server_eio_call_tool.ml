(** Mcp_server_eio_call_tool — Tool call handler and result envelope

    Extracted from mcp_server_eio.ml.
    Handles tools/call JSON-RPC method: timeout, retry, result envelope,
    telemetry, and audit logging.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

let log_mcp_exn ~label exn =
  let tag = match exn with
    | Sys_error _ | Failure _ | Not_found | End_of_file
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | _ -> "[UNEXPECTED] "
  in
  Log.Mcp.info "%s%s: %s" tag label (Printexc.to_string exn)

(** Parse bounded int from environment variable. *)
let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let parsed =
        Option.value ~default:default (int_of_string_opt (String.trim raw))
      in
      max min_v (min max_v parsed)

let contains_casefold haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  Re.execp (Re.str needle |> Re.compile) haystack

let parse_status_from_message ~success ~message =
  if not success then
    if
      contains_casefold message "input required"
      || contains_casefold message "ask agent"
      || contains_casefold message "ask agent question"
    then
      ("ask_agent_question", Some "ask_agent_question")
    else if
      contains_casefold message "auth required"
      || contains_casefold message "authentication required"
      || contains_casefold message "unauthorized"
    then
      ("ask_for_auth", Some "ask_for_auth")
    else
      ("error", None)
  else
    ("ok", None)

let quality_issue severity code message attempts =
  `Assoc [
    ("severity", `String severity);
    ("code", `String code);
    ("message", `String message);
    ("retry_attempts", `Int attempts);
  ]

let quality_from_result ~success ~message ~attempts =
  if success then
    `Assoc [
      ("passed", `Bool true);
      ("issues", `List []);
    ]
  else
    let issue =
      if contains_casefold message "timeout" || contains_casefold message "timed out" then
        quality_issue "error" "tool_timeout" message attempts
      else
        quality_issue "error" "tool_failure" message attempts
    in
    `Assoc [
      ("passed", `Bool false);
      ("issues", `List [issue]);
    ]

let read_only_retry_limit () =
  Env_config.Tools.readonly_retry_limit

let is_retryable_message message =
  (* Tool-level timeouts must not be retried — retrying a 30s timeout
     causes 60-90s total wait time, amplifying the original issue. *)
  if contains_casefold message "Tool timed out" then false
  else
  contains_casefold message "timeout" ||
  contains_casefold message "temporary" ||
  contains_casefold message "temporarily" ||
  contains_casefold message "econn" ||
  contains_casefold message "connection" ||
  contains_casefold message "unavailable" ||
  contains_casefold message "rate limit" ||
  contains_casefold message "502" ||
  contains_casefold message "503"

let read_only_retry_wait ~attempt =
  let attempt = float_of_int attempt in
  min 1.5 (0.2 *. attempt)

let call_tool_with_readonly_retry
    ~clock
    ~run_tool
    ~is_read_only
    () =
  let max_attempts = read_only_retry_limit () in
  let rec loop attempt =
    let (success, message) =
      run_tool ()
    in
    if
      success
      || attempt >= max_attempts
      || not is_read_only
      || not (is_retryable_message message)
    then
      (success, message, attempt)
    else (
      Eio.Time.sleep clock (read_only_retry_wait ~attempt);
      loop (attempt + 1))
  in
  loop 1

let coerce_tool_timeout_sec (raw_timeout_sec : float option) : float option =
  match raw_timeout_sec with
  | None -> None
  | Some raw when raw <= 0.0 -> None
  | Some raw ->
      let raw_sec = int_of_float (Float.ceil raw) in
      Some (float_of_int (max 5 (min 300 raw_sec)))

(** Optional per-tool timeout to prevent long calls from starving the request loop. *)
let tool_timeout_sec_opt ~(tool_name : string) ~(arguments : Yojson.Safe.t) : float option =
  ignore arguments;
  match tool_name with
  | "masc_keeper_msg" ->
      (* No fixed timeout for keeper_msg. Keeper has its own internal limits
         (max_turns, max_cost_usd, max_tokens) that control call duration.
         A fixed external timeout conflicts with multi-turn tool-use loops. *)
      None
  | "masc_transition" ->
      (* Transition can trigger anti-rationalization review on completion
         paths. A fixed timeout can report a false error while the state
         mutation continues in the background, leaving caller-visible status
         out of sync with persisted task state. *)
      None
  | _ ->
      let global_default_sec =
        float_of_int
          (int_of_env_default
             "MASC_TOOL_TIMEOUT_DEFAULT_SEC"
             ~default:60
             ~min_v:5
             ~max_v:300)
      in
      Some global_default_sec

(** Resolve managed agent tool call to canonical operation *)
let resolve_managed_agent_call ?mcp_session_id params =
  let module U = Yojson.Safe.Util in
  let requested_name = params |> U.member "name" |> U.to_string in
  let arguments = params |> U.member "arguments" in
  let identity =
    Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments
  in
  Sdk_tool_contract.resolve_requested_tool_call
    ~agent_name:identity.Agent_identity.agent_name
    ~requested_name ~arguments

(** Handle tools/call JSON-RPC method *)
let handle_call_tool_eio ~execute_tool_eio ~maybe_emit_resource_notifications
    ~broadcast_tools_list_changed ~sw ~clock ?(profile = Full) ?mcp_session_id
    ?auth_token state id params =
  let module U = Yojson.Safe.Util in
  let make_response = Mcp_transport_protocol.make_response in
  let (name, arguments) =
    match profile with
    | Managed_agent -> (
        match resolve_managed_agent_call ?mcp_session_id params with
        | Ok resolved -> resolved
        | Error msg ->
            raise
              (Invalid_argument
                 ("managed agent tool translation failed: " ^ msg)))
    | Full | Operator_remote ->
        (params |> U.member "name" |> U.to_string, params |> U.member "arguments")
  in
  let is_read_only = Tool_dispatch.is_read_only name in

  (* Measure execution time for telemetry *)
  let start_time = Eio.Time.now clock in
  let timeout_hit = ref false in
  let execute_with_timeout () =
    let local_timeout_hit = ref false in
    let result =
      try
        match tool_timeout_sec_opt ~tool_name:name ~arguments with
        | None ->
            execute_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state ~name ~arguments
        | Some timeout_sec ->
            (try
               Eio.Time.with_timeout_exn
                 clock
                 timeout_sec
                 (fun () ->
                   execute_tool_eio
                     ~sw
                     ~clock
                     ?mcp_session_id
                     ?auth_token
                     state
                     ~name
                     ~arguments)
             with Eio.Time.Timeout ->
               local_timeout_hit := true;
               Log.Mcp.error "tools/call timeout: %s after %.0fs" name timeout_sec;
               (false,
                Printf.sprintf
                  "Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_DEFAULT_SEC)"
                  timeout_sec
                  name))
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       (* Never let a tool exception crash the MCP server. *)
       let err = Printexc.to_string exn in
       let trace = Printexc.get_backtrace () in
       let err_detail = if String.length trace > 0 then err ^ "\n" ^ trace else err in
       if contains_casefold err "Invalid_argument(\"MASC not initialized" then
         (false, Types.masc_error_to_string Types.NotInitialized)
       else
         (Log.Mcp.error "tools/call crashed: %s" err_detail;
          false, Printf.sprintf "Internal error: %s" err_detail)
    in
    if !local_timeout_hit then timeout_hit := true;
    result
  in
  let (success, message, attempts) =
    if is_read_only then
      call_tool_with_readonly_retry
        ~clock
        ~run_tool:execute_with_timeout
        ~is_read_only
        ()
    else
      let (success, message) = execute_with_timeout () in
      (success, message, 1)
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in

  (* Resolve agent_name: session identity > arguments > fallback *)
  let agent_name =
    let from_args = Safe_ops.json_string ~default:"" "agent_name" arguments in
    if from_args <> "" then from_args
    else
      let identity =
        Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments
      in
      let resolved = identity.Agent_identity.agent_name in
      if resolved <> "" then resolved else "unknown"
  in
  let error_detail =
    if success then None
    else
      let truncated =
        let error_preview_max = 200 in
        String_util.utf8_safe ~max_bytes:(error_preview_max + 3) ~suffix:"..." message |> String_util.to_string
      in
      Some (Printf.sprintf "timeout=%d|duration_ms=%d|detail=%s"
              (if !timeout_hit then 1 else 0) duration_ms truncated)
  in
  let otel_trace_id = Otel_spans.current_trace_id () in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:name ~success ~error_msg:error_detail
    ?trace_id:otel_trace_id ();
  if not success then
    Log.emit Log.Error ~module_name:"MCP"
      ~details:
        (`Assoc
          [
            ("event_family", `String "tool_call_failure");
            ("tool_name", `String name);
            ("agent_name", `String agent_name);
            ("duration_ms", `Int duration_ms);
            ("timeout_hit", `Bool !timeout_hit);
            ("attempts", `Int attempts);
            ("error_detail", `String (Option.value ~default:"" error_detail));
          ])
      (Printf.sprintf "tool call failed: %s — %s" name
         (Option.value ~default:"(no detail)" error_detail));

  (* Track tool call in telemetry (controlled by MASC_TELEMETRY_ENABLED) *)
  let telemetry_enabled = Env_config_core.telemetry_enabled () in
  if telemetry_enabled then
    (match state.Mcp_server.fs with
     | Some fs ->
         (try Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
                ~tool_name:name ~agent_id:agent_name ~success ~duration_ms
                ~source:(Tool_registry.string_of_source External_mcp) ()
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            log_mcp_exn ~label:"telemetry tracking failed" exn)
     | None -> ());

  (* Prometheus: record errors for failed tool calls *)
  if not success then
    Prometheus.record_error ~error_type:name ();

  (* Track in-memory call counter for all declared tool names (including hidden). *)
  Tool_registry.record_call_if_known ~source:External_mcp ~tool_name:name ~success ~duration_ms ();

  let tool_args_preview =
    Observability_redact.redact_tool_input ~tool_name:name arguments
  in
  let activity_string_field key =
    match Safe_ops.json_string_opt key arguments with
    | Some value when String.trim value <> "" ->
        Some (key, `String (Observability_redact.redact_preview value))
    | _ -> None
  in
  let activity_int_field key =
    match Safe_ops.json_int_opt key arguments with
    | Some value -> Some (key, `Int value)
    | None -> None
  in
  let activity_payload =
    `Assoc
      ([
         ("tool_name", `String name);
         ("success", `Bool success);
         ("duration_ms", `Int duration_ms);
         ("source", `String (Tool_registry.string_of_source External_mcp));
         ("error", match error_detail with Some e -> `String e | None -> `Null);
         ( "tool_args_preview",
           match tool_args_preview with
           | Some preview -> `String preview
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
  in

  (* Emit activity graph event for tool call — enables real-time dashboard tracking *)
  (try
    ignore (Activity_graph.emit state.Mcp_server.room_config
      ~actor:(Activity_graph.entity ~kind:"agent" agent_name)
      ~subject:(Activity_graph.entity ~kind:"tool" name)
      ~kind:"tool.called"
      ~payload:activity_payload
      ~tags:(if success then ["tool"; "success"] else ["tool"; "failure"])
      ())
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    log_mcp_exn ~label:"activity graph emit failed" exn);

  let jsonrpc_id_str =
    match id with
    | `String s -> s
    | `Int i -> string_of_int i
    | `Intlit s -> s
    | `Float f -> Printf.sprintf "%0.0f" f
    | _ -> "unknown"
  in
  let trace_id =
    match otel_trace_id with
    | Some tid -> tid
    | None -> jsonrpc_id_str
  in
  (* Append recovery hint on failure *)
  let message =
    if success then message
    else
      let hint = Masc_error_recovery.recovery_hint message in
      match hint with
      | None -> message
      | Some h -> message ^ "\n\n💡 Recovery: " ^ h
  in
  let (status, required_follow_up) = parse_status_from_message ~success ~message in
  let quality = quality_from_result ~success ~message ~attempts in
  let workflow_guidance =
    Workflow_guide.guidance_to_json
      (Workflow_guide.next_steps_for_call ~tool_name:name ~args:arguments ~success)
  in
  let envelope =
    `Assoc [
      ("kind", `String "tool_call");
      ("summary", `String message);
      ("status", `String status);
      ("tool", `String name);
      ("required_follow_up",
       (match required_follow_up with
        | None -> `Null
        | Some value -> `String value));
      ("trace_id", `String trace_id);
      ("quality", quality);
      ("workflow_guidance", workflow_guidance);
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
  let structured_content = Tool_result.structured_payload_of_message message in
  let meta_fields =
    [
      ("trace_id", `String trace_id);
      ("agent_id", `String agent_name);
      ("tool", `String name);
      ("duration_ms", `Int duration_ms);
      ("attempts", `Int attempts);
      ("timestamp", `String (Types.now_iso ()));
    ]
    @ (if !timeout_hit then [ ("timeout_hit", `Bool true) ] else [])
  in
  let result_fields =
    [
      ("resultEnvelope", envelope);
      ("content", `List content_items);
      ("isError", `Bool (not success));
      ("_meta", `Assoc meta_fields);
    ]
    @
    match structured_content with
    | Some value -> [ ("structuredContent", value) ]
    | None -> []
  in
  let result = make_response ~id (`Assoc result_fields) in

  maybe_emit_resource_notifications ~success ~tool_name:name;
  if success
     && List.mem name [ "masc_tool_admin_update" ]
  then
    broadcast_tools_list_changed ();

  (* Log result *)
  let preview =
    String_util.utf8_safe ~max_bytes:83 ~suffix:"..." message |> String_util.to_string
  in
  let preview = String.map (function '\n' -> ' ' | c -> c) preview in
  Log.Mcp.info "%s -> %s" name preview;

  result
