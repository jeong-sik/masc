(** Mcp_server_eio_call_tool — Tool call handler and result envelope

    Extracted from mcp_server_eio.ml.
    Handles tools/call JSON-RPC method: timeout, retry, result envelope,
    telemetry, and audit logging.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Role_filtered of Mode.mode

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
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v parsed)

let contains_casefold haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

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
      if contains_casefold message "timeout" then
        quality_issue "warning" "tool_timeout" message attempts
      else
        quality_issue "error" "tool_failure" message attempts
    in
    `Assoc [
      ("passed", `Bool false);
      ("issues", `List [issue]);
    ]

let read_only_retry_limit () =
  match Sys.getenv_opt "MASC_TOOL_READONLY_RETRY_LIMIT" with
  | Some raw ->
      (try
         let parsed = int_of_string (String.trim raw) in
         max 1 (min 5 parsed)
       with Failure _ -> 2)
  | None -> 2

let is_retryable_message message =
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
  let default_timeout_sec =
    float_of_int
      (int_of_env_default
         "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
         ~default:45
         ~min_v:10
         ~max_v:300)
  in
  match tool_name with
  | "masc_keeper_msg" ->
      let requested_timeout_sec = coerce_tool_timeout_sec (Safe_ops.json_float_opt "timeout_sec" arguments) in
      Some (Option.value requested_timeout_sec ~default:default_timeout_sec)
  | _ -> None

(** Resolve managed agent tool call to canonical operation *)
let resolve_managed_agent_call ?mcp_session_id params =
  let module U = Yojson.Safe.Util in
  let requested_name = params |> U.member "name" |> U.to_string in
  let arguments = params |> U.member "arguments" in
  match Agent_swarm_contract.sdk_binding_by_name requested_name with
  | None -> Ok (requested_name, arguments)
  | Some binding ->
      let identity =
        Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments
      in
      (match
         Agent_swarm_contract.build_operation_arguments
           ~agent_name:identity.Agent_identity.agent_name binding arguments
       with
      | Ok translated_arguments ->
          Ok
            ( binding.Agent_swarm_contract.canonical_operation,
              translated_arguments )
      | Error msg -> Error msg)

(** Handle tools/call JSON-RPC method *)
let handle_call_tool_eio ~execute_tool_eio ~maybe_emit_resource_notifications
    ~broadcast_tools_list_changed ~sw ~clock ?(profile = Full) ?mcp_session_id
    ?auth_token state id params =
  let module U = Yojson.Safe.Util in
  let make_response = Mcp_server.make_response in
  let (name, arguments) =
    match profile with
    | Managed_agent -> (
        match resolve_managed_agent_call ?mcp_session_id params with
        | Ok resolved -> resolved
        | Error msg ->
            raise
              (Invalid_argument
                 ("managed agent tool translation failed: " ^ msg)))
    | Full | Operator_remote | Role_filtered _ ->
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
                  "Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC)"
                  timeout_sec
                  name))
     with exn ->
       (* Never let a tool exception crash the MCP server. *)
       let err = Printexc.to_string exn in
       if contains_casefold err "Invalid_argument(\"MASC not initialized" then
         (false, Types.masc_error_to_string Types.NotInitialized)
       else
         (Log.Mcp.error "tools/call crashed: %s" err;
          false, Printf.sprintf "Internal error: %s" err)
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

  (* Audit log (tool_call) if enabled *)
  let agent_name =
    Safe_ops.json_string ~default:"unknown" "agent_name" arguments
  in
  let error_msg = if success then None else Some (Printf.sprintf "timeout=%d|duration_ms=%d" (if !timeout_hit then 1 else 0) duration_ms) in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:name ~success ~error_msg ();

  (* Track tool call in telemetry (controlled by MASC_TELEMETRY_ENABLED) *)
  let telemetry_enabled =
    match Sys.getenv_opt "MASC_TELEMETRY_ENABLED" with
    | Some "false" | Some "0" -> false
    | _ -> true  (* Default: enabled *)
  in
  if telemetry_enabled then
    (match state.Mcp_server.fs with
     | Some fs ->
         (try Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
                ~tool_name:name ~agent_id:agent_name ~success ~duration_ms ()
          with exn ->
            log_mcp_exn ~label:"telemetry tracking failed" exn)
     | None -> ());

  (* Prometheus: record errors for failed tool calls *)
  if not success then
    Prometheus.record_error ~error_type:name ();

  (* Track in-memory call counter only for declared tool names. *)
  Tool_registry.record_call_if_known ~tool_name:name ~success ~duration_ms;

  let trace_id =
    match id with
    | `String s -> s
    | `Int i -> string_of_int i
    | `Intlit s -> s
    | `Float f -> Printf.sprintf "%0.0f" f
    | _ -> "unknown"
  in
  let (status, required_follow_up) = parse_status_from_message ~success ~message in
  let quality = quality_from_result ~success ~message ~attempts in
  let workflow_guidance =
    Workflow_guide.guidance_to_json
      (Workflow_guide.next_steps ~tool_name:name ~success)
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
  let structured_content =
    match name with
    | "masc_swarm_live_run"
    | "masc_team_session_status"
    | "masc_operator_digest" -> (
        try Some (Yojson.Safe.from_string message) with _ -> None)
    | _ -> None
  in
  let result_fields =
    [
      ("resultEnvelope", envelope);
      ("content", `List content_items);
      ("isError", `Bool (not success));
    ]
    @
    match structured_content with
    | Some value -> [ ("structuredContent", value) ]
    | None -> []
  in
  let result = make_response ~id (`Assoc result_fields) in

  maybe_emit_resource_notifications ~success ~tool_name:name;
  if success
     && List.mem name [ "masc_switch_mode"; "masc_tool_admin_update" ]
  then
    broadcast_tools_list_changed ();

  (* Log result *)
  let preview =
    if String.length message > 80
    then String.sub message 0 80 ^ "..."
    else message
  in
  let preview = String.map (function '\n' -> ' ' | c -> c) preview in
  Log.Mcp.info "%s -> %s" name preview;

  result
