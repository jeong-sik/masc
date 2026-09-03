open Masc_domain
open Tool_args

type tool_result = Tool_result.result

type 'a context = 'a Tool_operator.context

module Operator_remote_name = Tool_name.Operator_remote_name
module Operator_name = Tool_name.Operator_name

let operator_remote_tool_name name = Operator_remote_name.to_string name

let operator_tool_name name =
  operator_remote_tool_name (Operator_remote_name.Operator_tool name)
;;

let board_attention_quarantine_requeue_tool_name =
  operator_tool_name Operator_name.Operator_board_attention_quarantine_requeue
;;

let task_recovery_tool_name =
  operator_tool_name Operator_name.Operator_task_recovery_resolve
;;

(* RFC-0189 PR-1b.11 — typed result.

   [result_of_json] projects [Operator_control.*_json :
   ... -> (Yojson.Safe.t, string) result] into the typed surface.

   Success: [json] is the operator response envelope as
   [Yojson.Safe.t]; passing it as [~data:json] keeps the structured
   payload first-class.

   Failure: wrapped in a typed [Tool_args.error_assoc] envelope. Class is
   [Workflow_rejection] — the
   operator surface rejects caller-side input (unknown
   action, target not found, schema violation). When
   [Operator_control] later distinguishes runtime / transient
   failures via a typed Error variant, the construction site here
   gets the appropriate class at that time. *)

let result_of_json ~tool_name ~start_time = function
  | Ok json ->
      (match Json_util.assoc_string_opt "status" json with
       | Some "deferred" ->
         Tool_result.make_deferred ~tool_name ~start_time ~data:json ()
       | Some "error" ->
         Tool_result.make_err
           ~tool_name
           ~class_:Tool_result.Workflow_rejection
           ~start_time
           ~data:json
           "Workspace message persisted, but Keeper delivery was rejected; do not resend"
       | Some _ | None ->
         Tool_result.make_ok ~tool_name ~start_time ~data:json ())
  | Error message ->
      let data = Tool_args.error_assoc [ "message", `String message ] in
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        ~data
        (Yojson.Safe.to_string data)

let json_ok = Tool_agent.json_ok

let snapshot_schemas = Operator_tool_toml.snapshot
let digest_schemas = Operator_tool_toml.digest
let board_attention_quarantine_requeue_schema = Operator_tool_toml.quarantine_requeue
let task_recovery_schema = Operator_tool_toml.task_recovery_resolve
let action_schemas = Operator_tool_toml.action
let confirm_schema = Operator_tool_toml.confirm

let board_attention_quarantine_failure_class = function
  | Keeper_board_attention_quarantine_command.Candidate_state_conflict _
  | Keeper_board_attention_quarantine_command.Partition_state_conflict _ ->
    Tool_result.Workflow_rejection
  | Keeper_board_attention_quarantine_command.Durability_unconfirmed _
  | Keeper_board_attention_quarantine_command.Wake_request_failed _ ->
    Tool_result.Runtime_failure
;;

let board_attention_quarantine_requeue_result
      ~tool_name
      ~start_time
      (ctx : _ context)
      args
  =
  let module Command = Keeper_board_attention_quarantine_command in
  match Command.parse_tool_command args with
  | Error error ->
    let data = Command.input_error_to_json error in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
  | Ok command ->
    let result =
      Command.execute
        ~now:(Time_compat.now ())
        ~base_path:ctx.config.Workspace.base_path
        command
    in
    let audit =
      Command.audit
        ctx.config
        ~actor:ctx.agent_name
        command
        ~outcome:
          (match result with
           | Ok _ -> Audit_log.Success
           | Error error ->
             Audit_log.Failure (Command.execution_error_label error))
      |> Command.audit_json
    in
    (match result with
     | Ok report ->
       Operator_control.invalidate_snapshot_cache ();
       Dashboard_projection_cache.invalidate_snapshot_json ~config:ctx.config;
       Tool_result.make_ok
         ~tool_name
         ~start_time
         ~data:(Command.success_json ~audit command report)
         ()
     | Error error ->
       let data = Command.failure_json ~audit error in
       Tool_result.make_err
         ~tool_name
         ~class_:(board_attention_quarantine_failure_class error)
         ~start_time
         ~data
         (Yojson.Safe.to_string data))
;;

let task_recovery_failure_class = function
  | Masc_domain.Task _ | Masc_domain.Agent _ -> Tool_result.Workflow_rejection
  | Masc_domain.Auth _ -> Tool_result.Policy_rejection
  | Masc_domain.System (Masc_domain.System_error.LockContention _)
  | Masc_domain.RateLimitExceeded _ ->
    Tool_result.Dependency_unavailable
  | Masc_domain.System _ | Masc_domain.CacheError _ -> Tool_result.Runtime_failure
;;

let task_recovery_result ~tool_name ~start_time (ctx : _ context) args =
  match Operator_task_recovery_command.parse_tool_command args with
  | Error error ->
    let data = Operator_task_recovery_command.input_error_to_json error in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
  | Ok command ->
    let result =
      Operator_task_recovery_command.execute
        ctx.config
        ~actor:ctx.agent_name
        command
    in
    let audit =
      Operator_task_recovery_command.audit
        ctx.config
        ~actor:ctx.agent_name
        command
        ~outcome:
          (match result with
           | Ok _ -> Audit_log.Success
           | Error error ->
             Audit_log.Failure (Masc_domain.masc_error_to_string error))
      |> Operator_task_recovery_command.audit_json
    in
    (match result with
     | Ok report ->
       let observe_cache_invalidation label f =
         try
           f ();
           None
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           let detail = Printf.sprintf "%s: %s" label (Printexc.to_string exn) in
           Log.Misc.error
             "operator task recovery cache invalidation failed task=%s detail=%s"
             report.task_id
             detail;
           Some detail
       in
       let cache_errors =
         [ observe_cache_invalidation "operator_snapshot_cache" (fun () ->
             Operator_control.invalidate_snapshot_cache ())
         ; observe_cache_invalidation "dashboard_projection_cache" (fun () ->
             Dashboard_projection_cache.invalidate_snapshot_json ~config:ctx.config)
         ]
         |> List.filter_map Fun.id
       in
       let report =
         { report with
           post_commit_errors = report.post_commit_errors @ cache_errors
         }
       in
       Tool_result.make_ok
         ~tool_name
         ~start_time
         ~data:(Operator_task_recovery_command.success_json ~audit command report)
         ()
     | Error error ->
       let data =
         Operator_task_recovery_command.mutation_error_json ~audit error
       in
       Tool_result.make_err
         ~tool_name
         ~class_:(task_recovery_failure_class error)
         ~start_time
         ~data
         (Yojson.Safe.to_string data))
;;

let judgment_write_schema = Operator_tool_toml.judgment_write

let dispatch (ctx : 'a context) ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  Log.Misc.debug "operator_dispatch: tool=%s agent=%s" name ctx.agent_name;
  let control_ctx : 'a Operator_control.context =
    {
      config = ctx.config;
      agent_name = ctx.agent_name;
      sw = ctx.sw;
      clock = ctx.clock;
      proc_mgr = ctx.proc_mgr;
      net = ctx.net;
      delegated_dispatch = ctx.delegated_dispatch;
      mcp_session_id = ctx.mcp_session_id;
    }
  in
  match name with
  | "masc_operator_snapshot" ->
      (* The tool is the observation half of operator CAS commands. Dashboard
         refreshes may use the cache, but an explicit operator observation must
         not return a stale assignee/backlog version. *)
      Operator_control.invalidate_snapshot_cache ();
      let actor = get_string_opt args "actor" in
      let view = get_string_opt args "view" in
      let include_messages = get_bool args "include_messages" true in
      let include_keepers = get_bool args "include_keepers" true in
      Some
        (json_ok ~tool_name:name ~start_time:start
           (Operator_control.snapshot_json ?actor ?view ~include_messages
              ~include_keepers control_ctx))
  | "masc_operator_digest" ->
      let actor = get_string_opt args "actor" in
      let target_type = get_string_opt args "target_type" in
      let target_id = get_string_opt args "target_id" in
      let include_workers = get_bool args "include_workers" true in
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.digest_json ?actor ?target_type ?target_id
              ~include_workers control_ctx))
  | "masc_operator_action" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.action_json control_ctx args))
  | tool_name
    when String.equal tool_name board_attention_quarantine_requeue_tool_name ->
      Some
        (board_attention_quarantine_requeue_result
           ~tool_name
           ~start_time:start
           ctx
           args)
  | tool_name when String.equal tool_name task_recovery_tool_name ->
      Some (task_recovery_result ~tool_name ~start_time:start ctx args)
  | "masc_operator_confirm" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.confirm_json control_ctx args))
  | "masc_operator_judgment_write" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.judgment_write_json control_ctx args))
  | _ ->
      Log.Misc.warn "operator_dispatch_unknown: tool=%s agent=%s" name ctx.agent_name;
      None

let schemas : tool_schema list =
  [ snapshot_schemas.local
  ; digest_schemas.local
  ; action_schemas.local
  ; board_attention_quarantine_requeue_schema
  ; task_recovery_schema
  ; confirm_schema
  ; judgment_write_schema
  ]
;;

let remote_schemas : tool_schema list =
  [ snapshot_schemas.remote
  ; digest_schemas.remote
  ; action_schemas.remote
  ; board_attention_quarantine_requeue_schema
  ; task_recovery_schema
  ; confirm_schema
  ]
;;

let remote_tool_names : string list = Operator_remote_name.all_strings

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only =
  [
    operator_tool_name Operator_name.Operator_snapshot;
    operator_tool_name Operator_name.Operator_digest;
  ]

(* Tools with explicit catalog metadata that must be preserved. *)
let operator_profile_only_tools =
  [ board_attention_quarantine_requeue_tool_name
  ; task_recovery_tool_name
  ]
;;

let tool_spec_hidden =
  "masc_operator_judgment_write" :: operator_profile_only_tools
;;

let tool_spec_hidden_actions = [ operator_tool_name Operator_name.Operator_action ]

let () =
  List.iter
    (fun (s : tool_schema) ->
      let is_hidden = List.mem s.name tool_spec_hidden || List.mem s.name tool_spec_hidden_actions in
      let existing = Tool_catalog.metadata s.name in
      let direct_call_when_hidden =
        is_hidden && not (List.mem s.name operator_profile_only_tools)
      in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_operator
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name tool_spec_read_only)
           ~visibility:(if is_hidden then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:direct_call_when_hidden
           ?reason:existing.reason
           ()))
    schemas

let () =
  Tool_operator.register_operator_tools ~dispatch ~schemas ~remote_schemas;
  Dashboard_projection_cache.register_operator_snapshot_json { Dashboard_projection_cache.snapshot = Operator_control.snapshot_json };
  Dashboard_projection_cache.register_operator_digest_json { Dashboard_projection_cache.digest = Operator_control.digest_json };
  Atomic.set
    Workspace_hooks.operator_pending_confirm_trace_id_fn
    Operator_pending_confirm.trace_id;
  Atomic.set
    Workspace_hooks.operator_pending_confirm_upsert_fn
    (fun config (entry : Workspace_hooks.operator_pending_confirm_request) ->
      Operator_pending_confirm.upsert_pending_confirm config entry);
  Atomic.set
    Workspace_hooks.operator_pending_confirm_read_result_fn
    (fun config ->
      Operator_pending_confirm.read_pending_confirms_result config);
  Atomic.set
    Workspace_hooks.operator_pending_confirm_remove_fn
    Operator_pending_confirm.remove_pending_confirm;
  Operator_pending_confirm.register_target_gate
    (fun config target ->
      match target.Operator_pending_confirm.target_type, target.target_id with
      | Operator_action_constants.Keeper, Some keeper_name ->
        let admission =
          Keeper_owner_registry.shutdown_operation_id
            ~base_path:config.Workspace.base_path
            ~keeper_name
        in
        (match admission with
         | Error error -> Error (Keeper_owner_registry.lookup_error_to_string error)
         | Ok None -> Ok ()
         | Ok (Some operation_id) ->
           Error
             (Printf.sprintf
                "Keeper %s is shutting down under operation %s"
                keeper_name
                (Keeper_shutdown_types.Operation_id.to_string operation_id)))
      | Operator_action_constants.Keeper, None ->
        Error "Keeper pending-confirm target requires target_id"
      | (Operator_action_constants.Workspace | Operator_action_constants.Goal), _ -> Ok ());
  Keeper_turn_lifecycle.register_remove_pending_confirms_by_target
    (fun config ~target_type ~target_id ->
      Operator_pending_confirm.remove_pending_confirms_by_typed_target
        config
        { Operator_pending_confirm.target_type = target_type; target_id })
;;

let force_link = ()
