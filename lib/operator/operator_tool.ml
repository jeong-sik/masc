open Masc_domain
open Tool_args

type tool_result = Tool_result.result

type 'a context = 'a Tool_operator.context

module Operator_name = Tool_name.Operator_name

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
           (Tool_guidance.to_string Tool_guidance.Workspace_message_delivery_rejected)
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
  let module O = Tool_name.Operator_name in
  (* Routing is decided on the closed Operator vocabulary; the string arms below
     are reached only for names outside it. A constructor added to
     Tool_name.Operator_name is a compile error in [operator_name_arm]. *)
  let operator_name_arm = function
    | O.Operator_snapshot -> `Snapshot
    | O.Operator_digest -> `Digest
    | O.Operator_action -> `Action
    | O.Operator_board_attention_quarantine_requeue -> `Quarantine_requeue
    | O.Operator_task_recovery_resolve -> `Task_recovery
    | O.Operator_confirm -> `Confirm
    | O.Operator_judgment_write -> `Judgment_write
  in
  match Option.map operator_name_arm (O.of_string name) with
  | Some `Snapshot ->
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
  | Some `Digest ->
      let actor = get_string_opt args "actor" in
      let target_type = get_string_opt args "target_type" in
      let target_id = get_string_opt args "target_id" in
      let include_workers = get_bool args "include_workers" true in
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.digest_json ?actor ?target_type ?target_id
              ~include_workers control_ctx))
  | Some `Action ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.action_json control_ctx args))
  | Some `Quarantine_requeue ->
      Some
        (board_attention_quarantine_requeue_result
           ~tool_name:name
           ~start_time:start
           ctx
           args)
  | Some `Task_recovery ->
      Some (task_recovery_result ~tool_name:name ~start_time:start ctx args)
  | Some `Confirm ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.confirm_json control_ctx args))
  | Some `Judgment_write ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.judgment_write_json control_ctx args))
  | None ->
      Log.Misc.warn "operator_dispatch_unknown: tool=%s agent=%s" name ctx.agent_name;
      None

(* Both surfaces are derived from Tool_name.Operator_name, so a constructor
   added there cannot be advertised locally without a schema, nor slip into the
   Operator_remote profile by omission: [remote_schema] must say [None] out
   loud. The two functions are exhaustive, so that decision is a compile error
   rather than a default. *)
let local_schema : Operator_name.t -> tool_schema = function
  | Operator_name.Operator_snapshot -> snapshot_schemas.local
  | Operator_name.Operator_digest -> digest_schemas.local
  | Operator_name.Operator_action -> action_schemas.local
  | Operator_name.Operator_board_attention_quarantine_requeue ->
    board_attention_quarantine_requeue_schema
  | Operator_name.Operator_task_recovery_resolve -> task_recovery_schema
  | Operator_name.Operator_confirm -> confirm_schema
  | Operator_name.Operator_judgment_write -> judgment_write_schema
;;

(* [None] means the tool is local-only: the Operator_remote profile gates on
   these names (Mcp_server_eio_tool_profile), so widening the set is a
   deliberate edit here. *)
let remote_schema : Operator_name.t -> tool_schema option = function
  | Operator_name.Operator_snapshot -> Some snapshot_schemas.remote
  | Operator_name.Operator_digest -> Some digest_schemas.remote
  | Operator_name.Operator_action -> Some action_schemas.remote
  | Operator_name.Operator_board_attention_quarantine_requeue ->
    Some board_attention_quarantine_requeue_schema
  | Operator_name.Operator_task_recovery_resolve -> Some task_recovery_schema
  | Operator_name.Operator_confirm -> Some confirm_schema
  | Operator_name.Operator_judgment_write -> None
;;

let schemas : tool_schema list = List.map local_schema Operator_name.all

let remote_schemas : tool_schema list =
  List.filter_map remote_schema Operator_name.all
;;

let remote_tool_names : string list =
  List.map (fun (s : tool_schema) -> s.name) remote_schemas
;;


(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

type registration_policy =
  { read_only : bool
  ; hidden : bool
  ; allow_direct_call_when_hidden : bool
      (** A hidden tool the operator profile still reaches directly. False for
          the two that must go through the profile and nothing else. *)
  }

(* One row per Operator_name constructor. This used to be four string lists
   consulted with List.mem, so a tool got its policy by being absent from them:
   a new one was silently not read-only, visible, and not directly callable.
   Now the three answers are stated per constructor and the match is exhaustive,
   so adding one is a compile error until they are given. *)
let registration_policy : Operator_name.t -> registration_policy = function
  | Operator_name.Operator_snapshot ->
    { read_only = true; hidden = false; allow_direct_call_when_hidden = false }
  | Operator_name.Operator_digest ->
    { read_only = true; hidden = false; allow_direct_call_when_hidden = false }
  | Operator_name.Operator_confirm ->
    { read_only = false; hidden = false; allow_direct_call_when_hidden = false }
  | Operator_name.Operator_action ->
    { read_only = false; hidden = true; allow_direct_call_when_hidden = true }
  | Operator_name.Operator_judgment_write ->
    { read_only = false; hidden = true; allow_direct_call_when_hidden = true }
  | Operator_name.Operator_board_attention_quarantine_requeue ->
    { read_only = false; hidden = true; allow_direct_call_when_hidden = false }
  | Operator_name.Operator_task_recovery_resolve ->
    { read_only = false; hidden = true; allow_direct_call_when_hidden = false }
;;

(* Registration walks the vocabulary, not the schema list, so every constructor
   is registered with the schema and policy that belong to it. *)
let () =
  List.iter
    (fun name ->
      let (s : tool_schema) = local_schema name in
      let policy = registration_policy name in
      let existing = Tool_catalog.metadata s.name in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_operator
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:policy.read_only
           ~visibility:
             (if policy.hidden then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:policy.allow_direct_call_when_hidden
           ?reason:existing.reason
           ()))
    Operator_name.all

let () =
  Tool_operator.register_operator_tools ~dispatch ~remote_schemas;
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
