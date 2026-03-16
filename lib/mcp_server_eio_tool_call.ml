(** Mcp_server_eio_tool_call — Tool call handler, resource subscriptions, result envelope

    Extracted from mcp_server_eio.ml.
    Handles tools/call JSON-RPC method: timeout, retry, result envelope,
    telemetry, audit logging, and resource subscription management.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Role_filtered of Mode.mode

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn

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

(** {1 Resource Subscriptions} *)

let resource_subscription_mutex = Eio.Mutex.create ()

let with_resource_subscription_lock f =
  try Eio.Mutex.use_rw ~protect:true resource_subscription_mutex f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let resource_subscriptions : (string, (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 64

let resource_is_dynamic uri =
  let lower = String.lowercase_ascii uri in
  not
    (String.contains lower '{'
     || String.starts_with ~prefix:"masc://schema" lower
     || String.starts_with ~prefix:"masc://institution" lower
     || String.starts_with ~prefix:"masc://tool-help" lower)

let subscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
      let uris =
        match Hashtbl.find_opt resource_subscriptions session_id with
        | Some uris -> uris
        | None ->
            let uris = Hashtbl.create 8 in
            Hashtbl.replace resource_subscriptions session_id uris;
            uris
      in
      Hashtbl.replace uris uri ())

let unsubscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
      match Hashtbl.find_opt resource_subscriptions session_id with
      | Some uris ->
          Hashtbl.remove uris uri;
          if Hashtbl.length uris = 0 then
            Hashtbl.remove resource_subscriptions session_id
      | None -> ())

let clear_resource_subscriptions_for_session session_id =
  with_resource_subscription_lock (fun () ->
      Hashtbl.remove resource_subscriptions session_id)

let jsonrpc_notification ?params method_name =
  let base =
    [
      ("jsonrpc", `String "2.0");
      ("method", `String method_name);
    ]
  in
  `Assoc
    (base
    @
    match params with
    | Some params -> [ ("params", params) ]
    | None -> [])

let send_resource_updated_notification ~session_id ~uri =
  Sse.send_to session_id
    (jsonrpc_notification "notifications/resources/updated"
       ~params:(`Assoc [ ("uri", `String uri) ]))

let broadcast_tools_list_changed () =
  Agent_card.invalidate_cache ();
  Sse.broadcast (jsonrpc_notification "notifications/tools/list_changed")

let dedup_strings items =
  items |> List.sort_uniq String.compare

let core_status_resource_ids =
  [ "status"; "status.json"; "events"; "events.json" ]

let task_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "tasks"; "tasks.json" ])

let agent_resource_ids =
  dedup_strings
    (core_status_resource_ids
    @ [ "who"; "who.json"; "agents"; "agents.json" ])

let message_resource_ids =
  dedup_strings
    (core_status_resource_ids @ [ "messages"; "messages.json" ])

let worktree_resource_ids =
  dedup_strings
    (core_status_resource_ids @ [ "worktrees"; "worktrees.json" ])

let resource_id_of_uri uri =
  let resource_id, _uri = Mcp_server.parse_masc_resource_uri uri in
  resource_id

let affected_resource_ids_for_tool = function
  | "masc_add_task"
  | "masc_claim_next"
  | "masc_transition"
  | "masc_update_priority"
  | "masc_plan_set_task"
  | "masc_plan_clear_task" ->
      task_resource_ids
  | "masc_init"
  | "masc_join"
  | "masc_leave"
  | "masc_register_capabilities"
  | "masc_heartbeat"
  | "masc_suspend" ->
      agent_resource_ids
  | "masc_broadcast"
  | "masc_portal_open"
  | "masc_portal_send"
  | "masc_portal_close" ->
      message_resource_ids
  | "masc_worktree_create"
  | "masc_worktree_remove" ->
      worktree_resource_ids
  | _ -> core_status_resource_ids

let maybe_emit_resource_notifications ~success ~tool_name =
  if success && not (Tool_dispatch.is_read_only tool_name) then
    let affected_ids = affected_resource_ids_for_tool tool_name in
    with_resource_subscription_lock (fun () ->
        Hashtbl.iter
          (fun session_id uris ->
            Hashtbl.iter
              (fun uri () ->
                if
                  resource_is_dynamic uri
                  && List.mem (resource_id_of_uri uri) affected_ids
                then
                  send_resource_updated_notification ~session_id ~uri)
              uris)
          resource_subscriptions)

(** {1 Tool Call Handler} *)

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
let handle_call_tool_eio ~execute_tool_eio
    ~sw ~clock ?(profile = Full) ?mcp_session_id
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
                ~tool_name:name ~success ~duration_ms ()
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
