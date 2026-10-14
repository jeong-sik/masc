open Tool_args
open Result.Syntax

include Operator_control_action

let json_of_dispatch_output body =
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body

let dispatch_keeper_json (ctx : 'a context) ~tool_name ~args =
  match ctx.delegated_dispatch with
  | None -> Error (Printf.sprintf "%s dispatch unavailable in this context" tool_name)
  | Some dispatch ->
    (match dispatch ~name:tool_name ~args with
     | Some result when Tool_result.is_success result ->
       Ok (json_of_dispatch_output (Tool_result.message result))
     | Some result -> Error (Tool_result.message result)
     | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name))

let resolve_keeper_meta_for_name (ctx : 'a context) ~(name : string) =
  match Keeper_meta_store.read_effective_meta_resolved ctx.config name with
  | Error err -> Error err
  | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
  | Ok (Some (resolved_name, meta)) -> Ok (resolved_name, meta)

let keeper_diagnostic_for_name (ctx : 'a context) ~(name : string) =
  match resolve_keeper_meta_for_name ctx ~name with
  | Error err -> Error err
  | Ok (_resolved_name, meta) ->
      let phase = Keeper_status_bridge.runtime_phase ctx.config meta in
      let now_ts = Time_compat.now () in
      Ok
        (Keeper_status_runtime.keeper_diagnostic_json
           ~meta
           ~phase
           ~history_items:[]
           ~now_ts)

let keeper_diagnostic_health_state json =
  Json_util.get_string json "health_state" |> Option.map String.lowercase_ascii

let keeper_diagnostic_recoverable json =
  Json_util.get_bool json "recoverable" |> Option.value ~default:false

let keeper_recovery_outcome after_diagnostic =
  match keeper_diagnostic_health_state after_diagnostic with
  | Some ("healthy" | "idle") when not (keeper_diagnostic_recoverable after_diagnostic) ->
      (true, None)
  | Some state ->
      ( false,
        Some
          (Printf.sprintf
             "keeper remained %s after recovery attempt"
             state) )
  | None -> (false, Some "keeper recovery did not return a health_state")

(** {1 Domain-specific action handlers} *)

(* A handler returns what its action produced. [execute_action] adds the
   reported [tool_name] from [delegated_tool_name]. The tools a handler
   dispatches are its own business and are named where they are called. *)

let execute_broadcast (ctx : 'a context) (request : action_request) =
  let* message =
    require_payload_field request.payload "message"
      "payload.message is required"
  in
  let* result =
    match
      (* The operator addressing the workspace is speech. *)
      Workspace.broadcast
        ~audience:Workspace_broadcast.Fleet_conversation
        ctx.config ~from_agent:request.actor ~content:message
    with
    | Ok result -> Ok result
    | Error error -> Error (Workspace.broadcast_error_to_string error)
  in
  let result_status =
    match result.mention_delivery with
    | Workspace_broadcast.Passive
    | Workspace_broadcast.Accepted
    | Workspace_broadcast.Already_accepted -> ActionOk
    | Workspace_broadcast.Pending
    | Workspace_broadcast.Deferred _ -> ActionDeferred
    | Workspace_broadcast.Rejected _ -> ActionError
  in
  Ok (Workspace_broadcast.broadcast_delivery_to_yojson result, result_status)

let execute_namespace_pause (ctx : 'a context) (request : action_request) =
  let reason =
    get_string request.payload "reason" "Paused by operator action"
  in
  Workspace.pause ctx.config ~by:request.actor ~reason;
  `Assoc [ ("paused", `Bool true); ("reason", `String reason) ]

let execute_namespace_resume (ctx : 'a context) (request : action_request) =
  let status =
    match Workspace.resume ctx.config ~by:request.actor with
    | `Resumed -> "resumed"
    | `Already_running -> "already_running"
  in
  `Assoc [ ("status", `String status) ]

let execute_task_inject (ctx : 'a context) (request : action_request) =
  let* title =
    require_payload_field request.payload "title"
      "payload.title is required"
  in
  let priority = get_int request.payload "priority" 2 in
  let description =
    get_string request.payload "description" "Injected by operator action"
  in
  Ok (`String (Workspace.add_task ctx.config ~title ~priority ~description))

let execute_keeper_probe (ctx : 'a context) (request : action_request) =
  let* name = require_target_id request in
  let status_args =
    `Assoc
      [
        ("name", `String name);
        ("fast", `Bool false);
        ("include_context", `Bool false);
        ("include_metrics_overview", `Bool true);
        ("include_history_tail", `Bool false);
      ]
  in
  let* status_json =
    dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
  in
  let* diagnostic = keeper_diagnostic_for_name ctx ~name in
  Ok (`Assoc [ ("status", status_json); ("diagnostic", diagnostic) ])

let execute_keeper_recover (ctx : 'a context) (request : action_request) =
  let* name = require_target_id request in
  let* (resolved_name, _meta) =
    resolve_keeper_meta_for_name ctx ~name
  in
  let* before_diagnostic = keeper_diagnostic_for_name ctx ~name:resolved_name in
  let recoverable =
    Json_util.get_bool before_diagnostic "recoverable" |> Option.value ~default:false
  in
  if not recoverable then
    Ok
      (`Assoc
        [
          ("recovered", `Bool false);
          ("skipped_reason", `String "keeper is already healthy enough; recovery not required");
          ("before", before_diagnostic);
        ])
  else
    let* down_result =
      dispatch_keeper_json ctx ~tool_name:"masc_keeper_down"
        ~args:(`Assoc [ ("name", `String resolved_name) ])
    in
    let* up_result =
      dispatch_keeper_json ctx ~tool_name:"masc_keeper_up"
        ~args:(`Assoc [ ("name", `String resolved_name) ])
    in
    let* after_diagnostic = keeper_diagnostic_for_name ctx ~name:resolved_name in
    let recovered, skipped_reason =
      keeper_recovery_outcome after_diagnostic
    in
    Ok
      (`Assoc
        [
          ("recovered", `Bool recovered);
          ( "skipped_reason", Json_util.string_opt_to_json skipped_reason );
          ("before", before_diagnostic);
          ("after", after_diagnostic);
          ("down", down_result);
          ("up", up_result);
        ])

let execute_keeper_message (ctx : 'a context) (request : action_request) =
  let* name = require_target_id request in
  let* message =
    require_payload_field request.payload "message"
      "payload.message is required"
  in
  let args =
    `Assoc
      [ ( "target"
        , `Assoc [ "kind", `String "keeper"; "name", `String name ] )
      ; "capability", `String "invoke_turn"
      ; "prompt", `String message
      ]
  in
  dispatch_keeper_json ctx ~tool_name:Keeper_tool_name.(to_string Keeper_delegate) ~args

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t * action_result_status, string) result =
  let completed result = Ok (result, ActionOk) in
  let* result, result_status =
    match request.action with
    | Operator_action_catalog.Broadcast -> execute_broadcast ctx request
    | Operator_action_catalog.Namespace_pause ->
      completed (execute_namespace_pause ctx request)
    | Operator_action_catalog.Namespace_resume ->
      completed (execute_namespace_resume ctx request)
    | Operator_action_catalog.Task_inject ->
      Result.bind (execute_task_inject ctx request) completed
    | Operator_action_catalog.Keeper_message ->
      Result.bind (execute_keeper_message ctx request) completed
    | Operator_action_catalog.Keeper_probe ->
      Result.bind (execute_keeper_probe ctx request) completed
    | Operator_action_catalog.Keeper_recover ->
      Result.bind (execute_keeper_recover ctx request) completed
  in
  Ok
    ( `Assoc
        [ ("tool_name", `String (delegated_tool_name request.action))
        ; ("result", result)
        ]
    , result_status )

let invalidate_operator_snapshot_views config =
  invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config

(* Every action is staged for confirmation and runs from [confirm_json]. *)
let action_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let* request = action_request_of_args ?actor_hint ctx args in
  let action_type = Operator_action_catalog.to_string request.action in
  let target_type = Operator_action_catalog.target_type_string request.action in
  let delegated_tool = delegated_tool_name request.action in
  let trace_id = trace_id "ops" in
  let expires_at = Masc_domain.iso8601_of_unix_seconds (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
  let* token = generate_confirm_token ~clock:ctx.clock ctx.config in
  let preview = preview_of_action request in
  let entry =
    {
      confirm_token = token;
      trace_id;
      actor = request.actor;
      action_type;
      target_type;
      target_id = request.target_id;
      payload = request.payload;
      delegated_tool;
      created_at = Masc_domain.now_iso ();
      expires_at = Some expires_at;
    }
  in
  let* () = upsert_pending_confirm ctx.config entry in
  let () = invalidate_operator_snapshot_views ctx.config in
  append_action_log ctx.config
    {
      trace_id;
      actor = request.actor;
      remote_session_id = ctx.mcp_session_id;
      remote_client_type = remote_client_type_of_context ctx;
      action_type;
      target_type;
      target_id = request.target_id;
      delegated_tool;
      confirmation_state = Preview;
      result_status = ActionOk;
      latency_ms = 0;
      created_at = Masc_domain.now_iso ();
    };
  Ok
    (Tool_args.ok_assoc
       [
         ("trace_id", `String trace_id);
         ("confirm_required", `Bool true);
         ("confirm_token", `String entry.confirm_token);
         ("preview", preview);
         ("tool_name", `String delegated_tool);
         ("expires_at", `String expires_at);
       ])

(** The closed decision type of the operator confirm gate. Parsing an
    incoming "decision" field yields exactly one of these; unknown values
    are rejected at the parse site instead of falling through to a string
    comparison downstream (#27512). *)
type confirm_decision =
  | Confirm
  | Deny

let confirm_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let actor = resolved_actor ?actor_hint ctx in
  let* decision =
    match get_string_opt args "decision" with
    | None -> Ok Confirm
    | Some raw -> (
        let normalized = String.lowercase_ascii (String.trim raw) in
        match normalized with
        | "" | "confirm" -> Ok Confirm
        | "deny" -> Ok Deny
        | _ ->
            Error
              (Printf.sprintf
                 "decision must be \"confirm\" or \"deny\" (got: %S)" raw))
  in
  match get_string_opt args "confirm_token" with
  | None -> Error "confirm_token is required"
  | Some confirm_token -> (
      match
        raw_pending_confirms ctx.config
        |> List.find_opt (fun entry ->
               String.equal entry.confirm_token confirm_token)
      with
      | None -> Error "pending confirmation not found"
      | Some entry when pending_confirm_expired entry ->
          let* () = remove_pending_confirm ctx.config confirm_token in
          let () = invalidate_operator_snapshot_views ctx.config in
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = Expired;
              result_status = ActionError;
              latency_ms = 0;
              created_at = Masc_domain.now_iso ();
            };
          Audit_log.log_gate_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:Audit_log.Gate_expired ~action_type:entry.action_type
            ~confirmation_state:(confirmation_state_to_string Expired) ();
          Error "pending confirmation expired"
      | Some entry when not (String.equal actor entry.actor) ->
          append_action_log ctx.config
            {
              trace_id = entry.trace_id;
              actor;
              remote_session_id = ctx.mcp_session_id;
              remote_client_type = remote_client_type_of_context ctx;
              action_type = entry.action_type;
              target_type = entry.target_type;
              target_id = entry.target_id;
              delegated_tool = entry.delegated_tool;
              confirmation_state = Denied;
              result_status = ActionError;
              latency_ms = 0;
              created_at = Masc_domain.now_iso ();
            };
          Audit_log.log_gate_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:Audit_log.Gate_unauthorized ~action_type:entry.action_type
            ~confirmation_state:(confirmation_state_to_string Denied) ();
          Error "actor is not allowed to confirm this action"
      | Some entry -> (
          match decision with
          | Deny -> (
            let* () = remove_pending_confirm ctx.config confirm_token in
            let () = invalidate_operator_snapshot_views ctx.config in
            append_action_log ctx.config
              {
                trace_id = entry.trace_id;
                actor;
                remote_session_id = ctx.mcp_session_id;
                remote_client_type = remote_client_type_of_context ctx;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                delegated_tool = entry.delegated_tool;
                confirmation_state = Denied;
                result_status = ActionOk;
                latency_ms = 0;
                created_at = Masc_domain.now_iso ();
              };
            Audit_log.log_gate_decision ctx.config
              ~agent_id:actor ~trace_id:entry.trace_id
              ~decision:Audit_log.Gate_deny ~action_type:entry.action_type
              ~confirmation_state:(confirmation_state_to_string Denied) ();
            Ok
              (Tool_args.ok_assoc
                 [ "trace_id", `String entry.trace_id
                 ; "decision", `String "deny"
                 ; "tool_name", `String entry.delegated_tool
                 ; "result_status", `String "not_executed"
                 ; "executed_action", pending_confirm_to_yojson entry
                 ]))
          | Confirm ->
            let started_at = Unix.gettimeofday () in
            let* request = action_request_of_pending_confirm entry in
            let* () = remove_pending_confirm ctx.config confirm_token in
            let () = invalidate_operator_snapshot_views ctx.config in
            let* executed, result_status = execute_action ctx request in
            let () = invalidate_operator_snapshot_views ctx.config in
            let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
            append_action_log ctx.config
              {
                trace_id = entry.trace_id;
                actor = entry.actor;
                remote_session_id = ctx.mcp_session_id;
                remote_client_type = remote_client_type_of_context ctx;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                delegated_tool = entry.delegated_tool;
                confirmation_state = Confirmed;
                result_status;
                latency_ms;
                created_at = Masc_domain.now_iso ();
              };
            Audit_log.log_gate_decision ctx.config
              ~agent_id:entry.actor ~trace_id:entry.trace_id
              ~decision:Audit_log.Gate_confirm ~action_type:entry.action_type
              ~confirmation_state:(confirmation_state_to_string Confirmed) ();
            let fields =
              [ ("trace_id", `String entry.trace_id)
              ; ("decision", `String "confirm")
              ; ("tool_name", `String entry.delegated_tool)
              ; ("result", executed)
              ; ("executed_action", pending_confirm_to_yojson entry)
              ]
            in
            Ok
              (match result_status with
               | ActionOk -> Tool_args.ok_assoc fields
               | ActionDeferred -> `Assoc (("status", `String "deferred") :: fields)
               | ActionError -> Tool_args.error_assoc fields)))
