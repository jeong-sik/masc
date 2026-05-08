open Tool_args
open Result.Syntax

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

let resolve_keeper_name_for_action (ctx : 'a context) ~(name : string) =
  match resolve_keeper_meta_for_name ctx ~name with
  | Ok (resolved_name, _meta) -> Ok resolved_name
  | Error _ ->
      let requested_name = String.trim name in
      if requested_name = "" then Error "target_id is required"
      else
        let configured = Keeper_types.configured_keeper_names ctx.config in
        if List.mem requested_name configured then
          Ok requested_name
        else
          match Keeper_types.keeper_name_from_agent_name requested_name with
          | Some alias_name when List.mem alias_name configured -> Ok alias_name
          | _ -> Error (Printf.sprintf "keeper not found: %s" name)

type keeper_github_identity_target = {
  requested_name : string;
  resolved_name : string;
  github_identity : string;
  credential_scope : string;
  git_identity_mode : string;
  bundle_root : string;
  gh_config_dir : string;
}

type github_identity_target = {
  requested_identity : string;
  github_identity : string;
  bundle_root : string;
  gh_config_dir : string;
}

let github_identity_target (ctx : 'a context) ~(identity : string) =
  let identity = String.trim identity in
  if identity = "" then Error "target_id identity is required"
  else if not (Keeper_config.validate_name identity) then
    Error (Printf.sprintf "invalid github_identity '%s'" identity)
  else
    let bundle_root = Keeper_gh_env.bundle_root ctx.config ~github_identity:identity in
    let gh_config_dir = Keeper_gh_env.gh_config_dir_of_bundle bundle_root in
    Ok { requested_identity = identity; github_identity = identity; bundle_root; gh_config_dir }

let keeper_github_identity_target (ctx : 'a context) ~(name : string) =
  let* resolved_name = resolve_keeper_name_for_action ctx ~name in
  let defaults = Keeper_types_profile.load_keeper_profile_defaults resolved_name in
  let git_identity_mode =
    Option.value ~default:"keeper_alias" defaults.git_identity_mode
  in
  let github_identity, credential_scope =
    match defaults.github_identity with
    | Some value -> value, "keeper_identity"
    | None -> Keeper_gh_env.root_github_identity, "root_fallback"
  in
  let bundle_root = Keeper_gh_env.bundle_root ctx.config ~github_identity in
  let gh_config_dir = Keeper_gh_env.gh_config_dir_of_bundle bundle_root in
  Ok
    {
      requested_name = name;
      resolved_name;
      github_identity;
      credential_scope;
      git_identity_mode;
      bundle_root;
      gh_config_dir;
    }

let keeper_github_identity_preview_json target =
  `Assoc
    [
      ("target_id", `String target.requested_name);
      ("keeper", `String target.resolved_name);
      ("github_identity", `String target.github_identity);
      ("credential_scope", `String target.credential_scope);
      ("git_identity_mode", `String target.git_identity_mode);
      ("bundle_root", `String target.bundle_root);
      ("gh_config_dir", `String target.gh_config_dir);
      ("hostname", `String "github.com");
      ("git_protocol", `String "https");
    ]

let github_identity_preview_json target =
  `Assoc
    [
      ("target_id", `String target.requested_identity);
      ("github_identity", `String target.github_identity);
      ("bundle_root", `String target.bundle_root);
      ("gh_config_dir", `String target.gh_config_dir);
      ("hostname", `String "github.com");
      ("git_protocol", `String "https");
    ]

let gh_process_env_for_config_dir gh_config_dir =
  Keeper_gh_env.compose_base_with_gh_config ~dir:gh_config_dir

let run_gh_auth_status ~gh_config_dir =
  try
    let env = gh_process_env_for_config_dir gh_config_dir in
    Ok
      (Process_eio.run_argv_with_status ~env
         [ "gh"; "auth"; "status"; "--hostname"; "github.com" ])
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error "gh executable not found in PATH"
  | exn -> Error (Printexc.to_string exn)

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
      let* () = validate_target_type "root" request in
      let* message =
        match get_string_opt request.payload "message" with
        | Some value -> Ok value
        | None -> Error "payload.message is required"
      in
      let result = Coord.broadcast ctx.config ~from_agent:request.actor ~content:message in
      room_action_result request (`String result)
  | "namespace_pause" ->
      let* () = validate_target_type "root" request in
      let reason =
        get_string request.payload "reason" "Paused by operator control plane"
      in
      Coord.pause ctx.config ~by:request.actor ~reason;
      room_action_result request
        (`Assoc [ ("paused", `Bool true); ("reason", `String reason) ])
  | "namespace_resume" ->
      let* () = validate_target_type "root" request in
      let status =
        match Coord.resume ctx.config ~by:request.actor with
        | `Resumed -> "resumed"
        | `Already_running -> "already_running"
      in
      room_action_result request (`Assoc [ ("status", `String status) ])
  | "social_sweep" ->
      room_action_result request
        (`Assoc [("status", `String "removed");
                 ("reason", `String "Social runtime removed. Keepers discover board events via proactive turns.")])
  | "task_inject" ->
      let* () = validate_target_type "root" request in
      let* title =
        match get_string_opt request.payload "title" with
        | Some value -> Ok value
        | None -> Error "payload.title is required"
      in
      let priority = get_int request.payload "priority" 2 in
      let description =
        get_string request.payload "description" "Injected by operator control plane"
      in
      (* RFC-0034.v2: per-goal cap guard. operator [task_inject] payload
         has no [goal_id] today; guard is a no-op for orphan tasks but
         wired so a future goal-aware payload inherits the cap. *)
      let result =
        Coord.add_task
          ~reject_if:(Coord_task_capacity.rejection_for_add_task ?goal_id:None)
          ctx.config ~title ~priority ~description
      in
      room_action_result request (`String result)
  | "github_identity_login_prepare" ->
      let* () = validate_target_type "root" request in
      let* identity = require_target_id request in
      let* target = github_identity_target ctx ~identity in
      Fs_compat.mkdir_p target.bundle_root;
      Fs_compat.mkdir_p target.gh_config_dir;
      let login_command =
        Printf.sprintf
          "GH_CONFIG_DIR=%s gh auth login --hostname github.com --git-protocol https --web"
          (Filename.quote target.gh_config_dir)
      in
      room_action_result request
        (`Assoc
           [
             ("github_identity", `String target.github_identity);
             ("bundle_root", `String target.bundle_root);
             ("gh_config_dir", `String target.gh_config_dir);
             ("hostname", `String "github.com");
             ("git_protocol", `String "https");
             ("login_command", `String login_command);
           ])
  | "github_identity_status" ->
      let* () = validate_target_type "root" request in
      let* identity = require_target_id request in
      let* target = github_identity_target ctx ~identity in
      let gh_config_dir_exists =
        Sys.file_exists target.gh_config_dir && Sys.is_directory target.gh_config_dir
      in
      let auth_result =
        if gh_config_dir_exists then
          Some (run_gh_auth_status ~gh_config_dir:target.gh_config_dir)
        else None
      in
      let authenticated =
        match auth_result with
        | Some (Ok (Unix.WEXITED 0, _output)) -> true
        | _ -> false
      in
      let auth_status_json =
        match auth_result with
        | Some (Ok (status, output)) ->
            `Assoc
              [
                ("status", Keeper_alerting_path.process_status_to_json status);
                ("output", `String output);
              ]
        | Some (Error err) -> `Assoc [ ("error", `String err) ]
        | None -> `Null
      in
      room_action_result request
        (`Assoc
           [
             ("github_identity", `String target.github_identity);
             ("bundle_root", `String target.bundle_root);
             ("gh_config_dir", `String target.gh_config_dir);
             ("gh_config_dir_exists", `Bool gh_config_dir_exists);
             ("operator_fallback_allowed", `Bool false);
             ("authenticated", `Bool authenticated);
             ("auth_status", auth_status_json);
           ])
  | _ -> Error (Printf.sprintf "not a namespace action: %s" request.action_type)

(* Issue #8394: removed [execute_team_action] — team session execution
   surface was retired but the dispatch arm + this stub remained,
   silently turning any team_* operator action into a misleading
   "team session actions removed: ..." error instead of the cleaner
   "unsupported action_type" path. *)

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
  | "keeper_github_identity_login_prepare" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let* target = keeper_github_identity_target ctx ~name in
      Fs_compat.mkdir_p target.bundle_root;
      Fs_compat.mkdir_p target.gh_config_dir;
      let login_command =
        Printf.sprintf
          "GH_CONFIG_DIR=%s gh auth login --hostname github.com --git-protocol https --web"
          (Filename.quote target.gh_config_dir)
      in
      Ok
        (`Assoc
          [
            ("tool_name", `String "masc_keeper_github_identity_login_prepare");
            ( "result",
              `Assoc
                [
                  ("keeper", `String target.resolved_name);
                  ("github_identity", `String target.github_identity);
                  ("credential_scope", `String target.credential_scope);
                  ("git_identity_mode", `String target.git_identity_mode);
                  ("bundle_root", `String target.bundle_root);
                  ("gh_config_dir", `String target.gh_config_dir);
                  ("hostname", `String "github.com");
                  ("git_protocol", `String "https");
                  ("login_command", `String login_command);
                ] );
          ])
  | "keeper_github_identity_status" ->
      let* () = validate_target_type "keeper" request in
      let* name = require_target_id request in
      let* resolved_name = resolve_keeper_name_for_action ctx ~name in
      let defaults = Keeper_types_profile.load_keeper_profile_defaults resolved_name in
      let git_identity_mode =
        Option.value ~default:"keeper_alias" defaults.git_identity_mode
      in
      let binding_result = Keeper_gh_env.keeper_binding ctx.config ~keeper_name:resolved_name in
      let configured_github_identity = defaults.github_identity in
      let effective_github_identity, credential_scope, bundle_root, gh_config_dir, binding_error =
        match binding_result with
        | Ok binding ->
            ( binding.effective_github_identity
            , Keeper_gh_env.credential_scope_to_string binding.credential_scope
            , binding.bundle_root
            , binding.gh_config_dir
            , None )
        | Error err ->
            let fallback_identity =
              Option.value ~default:Keeper_gh_env.root_github_identity
                configured_github_identity
            in
            let bundle_root =
              Keeper_gh_env.bundle_root ctx.config
                ~github_identity:fallback_identity
            in
            ( fallback_identity
            , (match configured_github_identity with
               | Some _ -> "keeper_identity"
               | None -> "root_fallback")
            , bundle_root
            , Keeper_gh_env.gh_config_dir_of_bundle bundle_root
            , Some err )
      in
      let hard_mode = Env_config_keeper.KeeperSandbox.hard_mode () in
      let gh_config_dir_exists =
        Sys.file_exists gh_config_dir && Sys.is_directory gh_config_dir
      in
      let auth_result =
        if gh_config_dir_exists then
          Some (run_gh_auth_status ~gh_config_dir)
        else None
      in
      let authenticated =
        match auth_result with
        | Some (Ok (Unix.WEXITED 0, _output)) -> true
        | _ -> false
      in
      let auth_status_json =
        match auth_result with
        | Some (Ok (status, output)) ->
            `Assoc
              [
                ("status", Keeper_alerting_path.process_status_to_json status);
                ("output", `String output);
              ]
        | Some (Error err) -> `Assoc [ ("error", `String err) ]
        | None -> `Null
      in
      Ok
        (`Assoc
          [
            ("tool_name", `String "masc_keeper_github_identity_status");
            ( "result",
              `Assoc
                [
                  ("keeper", `String resolved_name);
                  ("configured_github_identity",
                    (match configured_github_identity with
                     | Some value -> `String value
                     | None -> `Null));
                  ("effective_github_identity", `String effective_github_identity);
                  ("credential_scope", `String credential_scope);
                  ("git_identity_mode", `String git_identity_mode);
                  ("bundle_root", `String bundle_root);
                  ("gh_config_dir", `String gh_config_dir);
                  ("gh_config_dir_exists", `Bool gh_config_dir_exists);
                  ("root_fallback_available",
                    `Bool (Keeper_gh_env.root_gh_config_dir_exists ctx.config));
                  ("operator_fallback_allowed", `Bool false);
                  ("hard_mode", `Bool hard_mode);
                  ("binding_error",
                    (match binding_error with Some err -> `String err | None -> `Null));
                  ("authenticated", `Bool authenticated);
                  ("auth_status", auth_status_json);
                ] );
          ])
  | _ -> Error (Printf.sprintf "not a keeper action: %s" request.action_type)

let execute_action (ctx : 'a context) (request : action_request) :
    (Yojson.Safe.t, string) result =
  (* Canonicalize legacy action_type aliases before dispatch. *)
  let request =
    match request.action_type with
    | "autonomy_tick" -> { request with action_type = "social_sweep" }
    | _ -> request
  in
  match request.action_type with
  | "broadcast" | "namespace_pause" | "namespace_resume" | "social_sweep"
  | "task_inject" | "github_identity_login_prepare" | "github_identity_status" ->
      execute_room_action ctx request
  | "keeper_probe" | "keeper_recover" | "keeper_message"
  | "keeper_github_identity_login_prepare"
  | "keeper_github_identity_status" ->
      execute_keeper_action ctx request
  | "" -> Error "action_type is required"
  (* Issue #8394: team_* actions retired — fall through to the standard
     "unsupported action_type" path. Previously routed to a stub that
     returned "team session actions removed: ..." which masked the
     legitimate validation failure as a runtime stub error. *)
  | other -> Error (Printf.sprintf "unsupported action_type: %s" other)

(** All known action_types: available_actions plus legacy/unlisted ones. *)
let known_action_types =
  let from_registry =
    List.map
      (fun (a : Operator_pending_confirm.available_action) -> a.action_type)
      Operator_pending_confirm.available_actions
  in
  (* autonomy_tick excluded: canonical_action_type maps it to social_sweep
     before validate_request runs, so it never reaches here as-is.
     Issue #8394: removed [team_turn] — team session execution surface is
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
    let expires_at = iso_of_unix (Unix.gettimeofday () +. remote_confirm_ttl_seconds) in
    let* token = generate_confirm_token ~clock:ctx.clock ctx.config in
    let* preview =
      match request.action_type with
      | "github_identity_login_prepare" ->
          let* identity = require_target_id request in
          let* target = github_identity_target ctx ~identity in
          Ok (github_identity_preview_json target)
      | "keeper_github_identity_login_prepare" ->
          let* name = require_target_id request in
          let* target = keeper_github_identity_target ctx ~name in
          Ok (keeper_github_identity_preview_json target)
      | _ -> Ok (preview_of_action request)
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
        created_at = Masc_domain.now_iso ();
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
        created_at = Masc_domain.now_iso ();
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
        created_at = Masc_domain.now_iso ();
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
              created_at = Masc_domain.now_iso ();
            };
          Audit_log.log_governance_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:Audit_log.Governance_expired ~action_type:entry.action_type
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
          Audit_log.log_governance_decision ctx.config
            ~agent_id:actor ~trace_id:entry.trace_id
            ~decision:Audit_log.Governance_unauthorized ~action_type:entry.action_type
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
                created_at = Masc_domain.now_iso ();
              };
            Audit_log.log_governance_decision ctx.config
              ~agent_id:actor ~trace_id:entry.trace_id
              ~decision:Audit_log.Governance_deny ~action_type:entry.action_type
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
                created_at = Masc_domain.now_iso ();
              };
            Audit_log.log_governance_decision ctx.config
              ~agent_id:entry.actor ~trace_id:entry.trace_id
              ~decision:Audit_log.Governance_confirm ~action_type:entry.action_type
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
