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
      let keepalive_running =
        Keeper_status_bridge.runtime_keepalive_running ctx.config meta
      in
      let agent_status =
        Keeper_status_runtime.parse_agent_status ctx.config ~agent_name:meta.agent_name
      in
      let now_ts = Time_compat.now () in
      Ok
        (Keeper_status_runtime.keeper_diagnostic_json
           ~meta
           ~agent_status
           ~keepalive_running
           ~history_items:[]
           ~now_ts
        |> Keeper_status_runtime.augment_keeper_diagnostic_json
             ~meta
             ~keepalive_running
             ~keepalive_started_at:
               (Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta)
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

(* resolve_team_turn_actor and execute_team_turn removed — team session cleanup *)

(** {1 Domain-specific action handlers} *)

let workspace_action_result request result =
  Ok (`Assoc [
    ("tool_name", `String (delegated_tool_for request.action_type));
    ("result", result);
  ])

let execute_workspace_action (ctx : 'a context) (request : action_request) =
  match request.action_type with
  | "broadcast" ->
      let* () = validate_target_type Operator_action_constants.Workspace request in
      let* message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let result = Workspace.broadcast ctx.config ~from_agent:request.actor ~content:message in
      workspace_action_result request (`String result)
  | "namespace_pause" ->
      let* () = validate_target_type Operator_action_constants.Workspace request in
      let reason =
        get_string request.payload "reason" "Paused by operator control plane"
      in
      Workspace.pause ctx.config ~by:request.actor ~reason;
      workspace_action_result request
        (`Assoc [ ("paused", `Bool true); ("reason", `String reason) ])
  | "namespace_resume" ->
      let* () = validate_target_type Operator_action_constants.Workspace request in
      let status =
        match Workspace.resume ctx.config ~by:request.actor with
        | `Resumed -> "resumed"
        | `Already_running -> "already_running"
      in
      workspace_action_result request (`Assoc [ ("status", `String status) ])
  | "social_sweep" ->
      workspace_action_result request
        (`Assoc [("status", `String "removed");
                 ("reason", `String "Social runtime removed. Keepers discover board events via proactive turns.")])
  | "task_inject" ->
      let* () = validate_target_type Operator_action_constants.Workspace request in
      let* title =
        match get_string_opt request.payload "title" with
        | Some value -> Ok value
        | None -> Error "payload.title is required"
      in
      let priority = get_int request.payload "priority" 2 in
      let description =
        get_string request.payload "description" "Injected by operator control plane"
      in
      let result =
        Workspace.add_task ctx.config ~title ~priority ~description
      in
      workspace_action_result request (`String result)
  | _ -> Error (Printf.sprintf "not a namespace action: %s" request.action_type)

let execute_keeper_action (ctx : 'a context) (request : action_request) =
  match request.action_type with
  | "keeper_probe" ->
      let* () = validate_target_type Operator_action_constants.Keeper request in
      let* name = require_target_id request in
      let status_args =
        `Assoc
          [
            ("name", `String name);
            ("fast", `Bool false);
            ("include_context", `Bool false);
            ("include_metrics_overview", `Bool true);
            ("include_memory_bank", `Bool false);
            ("include_history_tail", `Bool false);
            ("include_compaction_history", `Bool false);
          ]
      in
      let* status_json =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_status" ~args:status_args
      in
      let* diagnostic = keeper_diagnostic_for_name ctx ~name in
      Ok
        (`Assoc
          [
            ("tool_name", `String "masc_keeper_status");
            ( "result",
              `Assoc
                [
                  ("status", status_json);
                  ("diagnostic", diagnostic);
                ] );
          ])
  | "keeper_recover" ->
      let* () = validate_target_type Operator_action_constants.Keeper request in
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
              ("tool_name", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool false);
                    ("skipped_reason", `String "keeper is already healthy enough; recovery not required");
                    ("before", before_diagnostic);
                  ] );
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
              ("tool_name", `String "masc_keeper_recover");
              ( "result",
                `Assoc
                  [
                    ("recovered", `Bool recovered);
                    ( "skipped_reason", Json_util.string_opt_to_json skipped_reason );
                    ("before", before_diagnostic);
                    ("after", after_diagnostic);
                    ("down", down_result);
                    ("up", up_result);
                  ] );
            ])
  | "keeper_message" ->
      let* () = validate_target_type Operator_action_constants.Keeper request in
      let* name = require_target_id request in
      let* message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* () =
        Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_delegate"
          request.payload
      in
      let args =
        `Assoc
          [ ( "target"
            , `Assoc [ "kind", `String "keeper"; "name", `String name ] )
          ; "capability", `String "invoke_turn"
          ; "prompt", `String message
          ]
      in
      let* result =
        dispatch_keeper_json ctx ~tool_name:"masc_keeper_delegate" ~args
      in
      Ok
        (`Assoc
          [
            ("tool_name", `String "masc_keeper_delegate");
            ("result", result);
          ])
  | _ -> Error (Printf.sprintf "not a keeper action: %s" request.action_type)

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t, string) result =
  match request.action_type with
  | "broadcast" | "namespace_pause" | "namespace_resume" | "social_sweep"
  | "task_inject" ->
      execute_workspace_action ctx request
  | "keeper_probe" | "keeper_recover" | "keeper_message" ->
      execute_keeper_action ctx request
  | "" -> Error "action_type is required"
  (* Issue #8394: team_* actions retired — fall through to the standard
     "unsupported action_type" path. Previously routed to a stub that
     returned "team session actions removed: ..." which masked the
     legitimate validation failure as a runtime stub error. *)
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

(** All known action_types: available_actions plus hidden canonical actions. *)
let known_action_types =
  let from_registry =
    List.map
      (fun (a : Operator_pending_confirm.available_action) -> a.action_type)
      Operator_pending_confirm.available_actions
  in
  (* Issue #8394: removed [team_turn] — team session execution surface is
     retired. *)
  from_registry @ [ "social_sweep" ]

let validate_request request =
  if request.action_type = "" then Error "action_type is required"
  else if List.mem request.action_type known_action_types then Ok ()
  else Error (Printf.sprintf "unsupported action_type: %s" request.action_type)

let action_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let* request = action_request_of_args ?actor_hint ctx args in
  let* () = validate_request request in
  let* request = normalize_request_target_type request in
  let delegated_tool = delegated_tool_for request.action_type in
  let trace_id = trace_id "ops" in
  let started_at = Unix.gettimeofday () in
  if confirm_required request.action_type then (
    let expires_at = Masc_domain.iso8601_of_unix_seconds (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
    let* token = generate_confirm_token ~clock:ctx.clock ctx.config in
    let preview = preview_of_action request in
    let entry =
      {
        token;
        trace_id;
        actor = request.actor;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        payload = request.payload;
        delegated_tool;
        created_at = Masc_domain.now_iso ();
        expires_at = Some expires_at;
      }
    in
    let* () = upsert_pending_confirm ctx.config entry in
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
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
           ("confirm_token", `String entry.token);
           ("preview", preview);
           ("tool_name", `String delegated_tool);
           ("expires_at", `String expires_at);
         ]))
  else
    let* executed = execute_action ctx request in
    let latency_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
    append_action_log ctx.config
      {
        trace_id;
        actor = request.actor;
        remote_session_id = ctx.mcp_session_id;
        remote_client_type = remote_client_type_of_context ctx;
        action_type = request.action_type;
        target_type = request.target_type;
        target_id = request.target_id;
        delegated_tool;
        confirmation_state = Immediate;
        result_status = ActionOk;
        latency_ms;
        created_at = Masc_domain.now_iso ();
      };
    Ok
      (Tool_args.ok_assoc
         [
           ("trace_id", `String trace_id);
           ("confirm_required", `Bool false);
           ("tool_name", `String delegated_tool);
           ("result", executed);
         ])

let confirm_json ?actor_hint (ctx : _ context) args :
    (Yojson.Safe.t, string) result =
  let* actor = resolved_actor_for_args ?actor_hint ctx args in
  let decision =
    match get_string_opt args "decision" with
    | Some raw ->
        let normalized = String.lowercase_ascii (String.trim raw) in
        if normalized = "" then "confirm" else normalized
    | None -> "confirm"
  in
  match get_string_opt args "confirm_token" with
  | None -> Error "confirm_token is required"
  | Some confirm_token -> (
      match
        raw_pending_confirms ctx.config
        |> List.find_opt (fun entry -> String.equal entry.token confirm_token)
      with
      | None -> Error "pending confirmation not found"
      | Some entry when pending_confirm_expired entry ->
          let* () = remove_pending_confirm ctx.config confirm_token in
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
      | Some entry ->
          if String.equal decision "deny" then (
            let* () = remove_pending_confirm ctx.config confirm_token in
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
          else
            let started_at = Unix.gettimeofday () in
            let request =
              {
                actor = entry.actor;
                action_type = entry.action_type;
                target_type = entry.target_type;
                target_id = entry.target_id;
                payload = entry.payload;
              }
            in
            let* () = remove_pending_confirm ctx.config confirm_token in
            let* executed = execute_action ctx request in
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
                result_status = ActionOk;
                latency_ms;
                created_at = Masc_domain.now_iso ();
              };
            Audit_log.log_gate_decision ctx.config
              ~agent_id:entry.actor ~trace_id:entry.trace_id
              ~decision:Audit_log.Gate_confirm ~action_type:entry.action_type
              ~confirmation_state:(confirmation_state_to_string Confirmed) ();
            Ok
              (Tool_args.ok_assoc
                 [
                   ("trace_id", `String entry.trace_id);
                   ("decision", `String "confirm");
                   ("tool_name", `String entry.delegated_tool);
                   ("result", executed);
                   ("executed_action", pending_confirm_to_yojson entry);
                 ]))
