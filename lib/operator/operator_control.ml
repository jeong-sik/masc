open Tool_args
open Result_syntax

include Operator_control_action

let json_of_dispatch_output body =
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body

let tool_keeper_ctx (ctx : 'a context) : _ Tool_keeper.context =
  {
    config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
    net = ctx.net;
  }

let dispatch_keeper_json (ctx : 'a context) ~tool_name ~args =
  match Tool_keeper.dispatch (tool_keeper_ctx ctx) ~name:tool_name ~args with
  | Some (true, body) -> Ok (json_of_dispatch_output body)
  | Some (false, err) -> Error err
  | None -> Error (Printf.sprintf "%s dispatch unavailable" tool_name)

let resolve_keeper_meta_for_name (ctx : 'a context) ~(name : string) =
  match Keeper_types.read_meta_resolved ctx.config name with
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
        Keeper_exec_status.parse_agent_status ctx.config ~agent_name:meta.agent_name
      in
      let now_ts = Time_compat.now () in
      Ok
        (Keeper_exec_status.keeper_diagnostic_json
           ~meta
           ~agent_status
           ~keepalive_running
           ~history_items:[]
           ~now_ts
        |> Keeper_exec_status.augment_keeper_diagnostic_json
             ~meta
             ~keepalive_running
             ~keepalive_started_at:
               (Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta)
             ~now_ts)

let keeper_diagnostic_health_state json =
  match U.member "health_state" json with
  | `String value -> Some (String.lowercase_ascii value)
  | _ -> None

let keeper_diagnostic_recoverable json =
  match U.member "recoverable" json with
  | `Bool value -> value
  | _ -> false

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

let room_action_result request result =
  Ok (`Assoc [
    ("tool_name", `String (delegated_tool_for request.action_type));
    ("result", result);
  ])

let execute_room_action (ctx : 'a context) (request : action_request) =
  match request.action_type with
  | "broadcast" ->
      let* () = validate_target_type "namespace" request in
      let* message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let result = Room.broadcast ctx.config ~from_agent:request.actor ~content:message in
      room_action_result request (`String result)
  | "namespace_pause" ->
      let* () = validate_target_type "namespace" request in
      let reason =
        get_string request.payload "reason" "Paused by operator control plane"
      in
      Room.pause ctx.config ~by:request.actor ~reason;
      room_action_result request
        (`Assoc [ ("paused", `Bool true); ("reason", `String reason) ])
  | "namespace_resume" ->
      let* () = validate_target_type "namespace" request in
      let status =
        match Room.resume ctx.config ~by:request.actor with
        | `Resumed -> "resumed"
        | `Already_running -> "already_running"
      in
      room_action_result request (`Assoc [ ("status", `String status) ])
  | "social_sweep" ->
      room_action_result request
        (`Assoc [("status", `String "removed");
                 ("reason", `String "Social runtime removed. Keepers discover board events via proactive turns.")])
  | "task_inject" ->
      let* () = validate_target_type "namespace" request in
      let* title =
        match get_string_opt request.payload "title" with
        | Some value -> Ok value
        | None -> Error "payload.title is required"
      in
      let priority = get_int request.payload "priority" 2 in
      let description =
        get_string request.payload "description" "Injected by operator control plane"
      in
      let result = Room.add_task ctx.config ~title ~priority ~description in
      room_action_result request (`String result)
  | _ -> Error (Printf.sprintf "not a namespace action: %s" request.action_type)

let execute_team_action (_ctx : 'a context) (request : action_request) =
  (* Team session actions removed — all return error *)
  Error (Printf.sprintf "team session actions removed: action=%s target_type=%s target_id=%s"
    request.action_type
    request.target_type
    (Option.value ~default:"?" request.target_id))

let execute_keeper_action (ctx : 'a context) (request : action_request) =
  match request.action_type with
  | "keeper_probe" ->
      let* () = validate_target_type "keeper" request in
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
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let* (resolved_name, _meta) =
        resolve_keeper_meta_for_name ctx ~name
      in
      let* before_diagnostic = keeper_diagnostic_for_name ctx ~name:resolved_name in
      let recoverable =
        match U.member "recoverable" before_diagnostic with
        | `Bool value -> value
        | _ -> false
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
                    ( "skipped_reason",
                      match skipped_reason with
                      | Some reason -> `String reason
                      | None -> `Null );
                    ("before", before_diagnostic);
                    ("after", after_diagnostic);
                    ("down", down_result);
                    ("up", up_result);
                  ] );
            ])
  | "keeper_message" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let* message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let* () =
        match request.payload |> U.member "models" with
        | `Null -> Ok ()
        | _ ->
            Error
              "legacy keeper model args removed for masc_keeper_msg: models. Keepers now use cascade_name and last_model_used only."
      in
      let direct_reply =
        match request.payload |> U.member "direct_reply" with
        | `Bool value -> value
        | _ -> false
      in
      let timeout_sec =
        match request.payload |> U.member "timeout_sec" with
        | `Int value when value > 0 -> Some value
        | `Float value when value > 0.0 -> Some (int_of_float (Float.ceil value))
        | _ -> None
      in
      let args =
        `Assoc
          (([
              ("name", `String name);
              ("message", `String message);
            ]
            @ if direct_reply then [ ("direct_reply", `Bool true) ] else [])
           @
           match timeout_sec with
           | Some value -> [ ("timeout_sec", `Int value) ]
           | None -> [])
      in
      let keeper_ctx : _ Tool_keeper.context =
        {
          config = ctx.config;
          agent_name = ctx.agent_name;
          sw = ctx.sw;
          clock = ctx.clock;
          proc_mgr = ctx.proc_mgr;
          net = ctx.net;
        }
      in
      let* ok, body =
        match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
        | Some (true, body) -> Ok (true, body)
        | Some (false, err) -> Error err
        | None -> Error "masc_keeper_msg dispatch unavailable"
      in
      let _ = ok in
      Ok
        (`Assoc
          [
            ("tool_name", `String "masc_keeper_msg");
            ("result", json_of_dispatch_output body);
          ])
  | _ -> Error (Printf.sprintf "not a keeper action: %s" request.action_type)

let execute_review_action (ctx : 'a context) (request : action_request) =
  let* () = validate_target_type "review_item" request in
  let* item_id =
    require_payload_field request.payload "item_id"
      "payload.item_id is required"
  in
  let* fingerprint =
    require_payload_field request.payload "fingerprint"
      "payload.fingerprint is required"
  in
  let* item_target_type =
    require_payload_field request.payload "item_target_type"
      "payload.item_target_type is required"
  in
  let reason =
    get_string request.payload "reason" "" |> String.trim
  in
  if reason = "" then Error "payload.reason is required"
  else
    let decision =
      if String.equal request.action_type "review_resolve"
      then "resolved"
      else "deferred"
    in
    let entry : Operator_review_state.review_decision =
      {
        item_id;
        fingerprint;
        decision;
        actor = request.actor;
        reason;
        at = Types.now_iso ();
        target_type = item_target_type;
        target_id = get_string_opt request.payload "item_target_id";
        recommended_action_type =
          get_string_opt request.payload "recommended_action_type";
      }
    in
    Operator_review_state.upsert_review_decision ctx.config entry;
    Ok
      (`Assoc
        [
          ("tool_name", `String "review_state");
          ( "result",
            `Assoc
              [
                ("item_id", `String item_id);
                ("fingerprint", `String fingerprint);
                ("decision", `String decision);
                ("actor", `String request.actor);
                ("reason", `String reason);
              ] );
        ])

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t, string) result =
  (* Canonicalize legacy action_type aliases before dispatch. *)
  let request =
    match request.action_type with
    | "autonomy_tick" -> { request with action_type = "social_sweep" }
    | _ -> request
  in
  match request.action_type with
  | "broadcast" | "namespace_pause" | "namespace_resume" | "social_sweep" | "task_inject" ->
      execute_room_action ctx request
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject"
  | "team_worker_spawn_batch" | "team_stop" ->
      execute_team_action ctx request
  | "keeper_probe" | "keeper_recover" | "keeper_message" ->
      execute_keeper_action ctx request
  | "review_resolve" | "review_defer" ->
      execute_review_action ctx request
  | "" -> Error "action_type is required"
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

(** All known action_types: available_actions plus legacy/unlisted ones. *)
let known_action_types =
  let from_registry =
    List.map
      (fun (a : Operator_pending_confirm.available_action) -> a.action_type)
      Operator_pending_confirm.available_actions
  in
  (* autonomy_tick excluded: canonical_action_type maps it to social_sweep
     before validate_request runs, so it never reaches here as-is. *)
  from_registry @ [ "social_sweep"; "team_turn";
                    "review_resolve"; "review_defer" ]

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
    let expires_at = iso_of_unix (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
    let* token = generate_confirm_token ~clock:ctx.clock ctx.config in
    let preview =
      match request.action_type with
      | _ -> preview_of_action request
    in
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
        created_at = Types.now_iso ();
        expires_at = Some expires_at;
      }
    in
    upsert_pending_confirm ctx.config entry;
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
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
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
        created_at = Types.now_iso ();
      };
    Ok
      (json_ok
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
          remove_pending_confirm ctx.config confirm_token;
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
              created_at = Types.now_iso ();
            };
          Audit_log.log_governance_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:"expired" ~action_type:entry.action_type
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
              created_at = Types.now_iso ();
            };
          Audit_log.log_governance_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:"unauthorized" ~action_type:entry.action_type
            ~confirmation_state:(confirmation_state_to_string Denied) ();
          Error "actor is not allowed to confirm this action"
      | Some entry ->
          if String.equal decision "deny" then (
            remove_pending_confirm ctx.config confirm_token;
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
                created_at = Types.now_iso ();
              };
            Audit_log.log_governance_decision ctx.config
              ~agent_id:actor ~trace_id:entry.trace_id
              ~decision:"deny" ~action_type:entry.action_type
              ~confirmation_state:(confirmation_state_to_string Denied) ();
            Ok
              (json_ok
                 [
                   ("trace_id", `String entry.trace_id);
                   ("decision", `String "deny");
                   ("tool_name", `String entry.delegated_tool);
                   ("executed_action", pending_confirm_to_yojson entry);
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
            let* executed = execute_action ctx request in
            remove_pending_confirm ctx.config confirm_token;
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
                created_at = Types.now_iso ();
              };
            Audit_log.log_governance_decision ctx.config
              ~agent_id:entry.actor ~trace_id:entry.trace_id
              ~decision:"confirm" ~action_type:entry.action_type
              ~confirmation_state:(confirmation_state_to_string Confirmed) ();
            Ok
              (json_ok
                 [
                   ("trace_id", `String entry.trace_id);
                   ("decision", `String "confirm");
                   ("tool_name", `String entry.delegated_tool);
                   ("result", executed);
                   ("executed_action", pending_confirm_to_yojson entry);
                   (* backward compat — remove after dashboard migration *)
                   ("delegated_tool_result", executed);
                 ]))
