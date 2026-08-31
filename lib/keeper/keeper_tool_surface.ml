(* Keeper tool dispatch — ops + cache + start/stop + repair extracted to
   [Keeper_tool_surface_ops] (godfile decomp). *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_runtime

include Keeper_tool_surface_ops

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path.  Uses
   [Workspace.config] only (no Eio fields), letting Keeper_tool_surface register
   masc_keeper_list with [Keeper_dispatch_ref] at module load. *)
let keeper_list_body ~(config : Workspace.config) args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let cache_key =
    Printf.sprintf "%s:%d:%b" config.base_path limit detailed
  in
  let data =
    cached_json_by_key keeper_list_cache ~key:cache_key
      ~ttl_s:(keeper_list_cache_ttl_s ()) (fun () ->
        let registry_names =
          Keeper_registry.all ~base_path:config.base_path ()
          |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
        in
        let all_names =
          registry_names @ keeper_names config
          |> List.map String.trim
          |> List.filter (fun name -> not (String.equal name ""))
          |> List.sort_uniq String.compare
        in
        (* [total] is measured before [limit] is applied, so a caller can tell
           a short answer from a complete one. Without it [count] reports the
           post-truncation size and reads as "that is all of them" — the shape
           behind masc#29077, where a 129-keeper workspace answered 50 and the
           operational keepers, sorting after ~90 benchmark ones, all fell off
           the end. *)
        let total = List.length all_names in
        let names = take limit all_names in
        let truncated = List.length names < total in
        let rows =
          names
          |> List.filter_map (fun name ->
               keeper_list_row_json ~runtime_class:"keeper" config name)
        in
        (* [truncated] answers "did [limit] drop names", nothing else. [count]
           can still be below [min total limit] in the detailed shape when a
           listed name has no readable metadata and [keeper_list_row_json]
           yields no row. *)
        let listing =
          [
            ("total", `Int total);
            ("limit", `Int limit);
            ("truncated", `Bool truncated);
          ]
        in
        let json =
          if not detailed then
            `Assoc
              ([
                 ("count", `Int (List.length names));
                 ("keepers", `List (List.map (fun name -> `String name) names));
                 ("items", `List rows);
               ]
              @ listing)
          else
            `Assoc
              ([
                 ("count", `Int (List.length rows));
                 ("keepers", `List rows);
               ]
              @ listing)
        in
        json)
  in
  tool_result_ok_data data

let handle_keeper_list ctx args : tool_result =
  keeper_list_body ~config:ctx.config args

let handle_keeper_audit ctx args =
  Keeper_tool_keeper_audit.handle ~config:ctx.config args

let parse_network_mode_or_error raw =
  match network_mode_of_string raw with
  | Some mode -> Ok mode
  | None ->
      Error
        (Printf.sprintf "invalid network_mode %S (allowed: %s)" raw
           (String.concat ", " valid_network_mode_strings))

let validation_error_data message =
  error_assoc
    [ "error_code", `String (error_code_to_string Validation_error)
    ; "message", `String message
    ]

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_sandbox_start_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_meta_config ~config args with
  | Error err -> tool_result_error ~class_:Tool_result.Workflow_rejection err
  | Ok meta ->
      let timeout_sec = get_float args "timeout_sec" nan in
      let ttl_sec = Option.value ~default:0.0 (get_float_opt args "ttl_sec") in
      if (not (Float.is_finite timeout_sec)) || timeout_sec <= 0.0
      then tool_result_error ~class_:Tool_result.Policy_rejection "timeout_sec must be a positive finite number"
      else if (not (Float.is_finite ttl_sec)) || ttl_sec < 0.0
      then tool_result_error ~class_:Tool_result.Policy_rejection "ttl_sec must be a non-negative finite number"
      else
      let network_mode_raw =
        String.trim
          (get_string args "network_mode"
             (network_mode_to_string meta.network_mode))
      in
      (match parse_network_mode_or_error network_mode_raw with
       | Error err -> tool_result_error ~class_:Tool_result.Policy_rejection err
       | Ok network_mode -> (
           match
             Keeper_sandbox_control.start_managed_container
               ~config ~meta ~network_mode ~ttl_sec ~timeout_sec ()
           with
           | Error err -> tool_result_error ~class_:Tool_result.Dependency_unavailable err
           | Ok result ->
               tool_result_ok_data
                 (`Assoc
                    [
                      ("keeper", `String meta.name);
                      ("action", `String "start");
                      ("sandbox", result);
                    ])))

let handle_keeper_sandbox_start ctx args : tool_result =
  keeper_sandbox_start_body ~config:ctx.config args

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_sandbox_stop_body ~(config : Workspace.config) args : tool_result =
  let timeout_sec = get_float args "timeout_sec" nan in
  if (not (Float.is_finite timeout_sec)) || timeout_sec <= 0.0
  then tool_result_error ~class_:Tool_result.Policy_rejection "timeout_sec must be a positive finite number"
  else
  let prune_stale = get_bool args "prune_stale" false in
  let container_kind_raw =
    get_string args "container_kind" Keeper_sandbox_control.managed_kind
  in
  let keeper_name =
    match String.trim (get_string args "name" "") with
    | "" -> None
    | name -> Some name
  in
  match Keeper_sandbox_control.parse_stop_scope container_kind_raw with
  | Error err -> tool_result_error_data ~class_:Tool_result.Policy_rejection (validation_error_data err)
  | Ok scope ->
      let stop_result =
        Keeper_sandbox_control.stop_containers
          ?keeper_name ~scope ~config ~timeout_sec ()
      in
      let stale_cleanup =
        if prune_stale then
          Some
            (Keeper_sandbox_control.cleanup_stale ~config
               ~timeout_sec ())
        else
          None
      in
      let stop_json =
        `Assoc
          [
            ("matched", `Int stop_result.matched);
            ("removed", `Int stop_result.removed);
            ("errors", `List (List.map (fun err -> `String err) stop_result.errors));
          ]
      in
      let stale_json =
        match stale_cleanup with
        | None -> `Null
        | Some cleanup ->
            `Assoc
              [
                ("scanned", `Int cleanup.scanned);
                ("removed", `Int cleanup.removed);
                ("already_absent", `Int cleanup.already_absent);
                ("errors",
                 `List (List.map (fun err -> `String err) cleanup.errors));
              ]
      in
      tool_result_ok_data
        (`Assoc
           [
             ("action", `String "stop");
             ("keeper", Json_util.string_opt_to_json keeper_name);
             ("container_kind", `String (Keeper_sandbox_control.stop_scope_to_string scope));
             ("stop_result", stop_json);
             ("stale_cleanup", stale_json);
           ])

let handle_keeper_sandbox_stop ctx args : tool_result =
  keeper_sandbox_stop_body ~config:ctx.config args

(* masc_keeper_reconcile tool removed along with the manual_reconcile
   blocker mechanism. Failed turns record evidence via Keeper_registry;
   recovery is autonomous (next turn's observation) or operator-driven
   (keeper_chat/board), not blocker-driven. *)

(** Keeper tools are scoped to the caller's current base_path.
    Do not retarget requests across other base_path registries. *)
let resolve_ctx ctx ~name:_ = ctx

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_reset_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_meta_config ~config args with
  | Error err -> tool_result_error ~class_:Tool_result.Workflow_rejection err
  | Ok meta ->
    (match
       Keeper_owner_registry.apply_meta
         ~base_path:config.base_path
         ~keeper_name:meta.name
         (Keeper_owner_reducer.Reset_latch
            { updated_at = Keeper_meta_contract.now_iso () })
     with
     | Ok (Some _) ->
       tool_result_ok
         (Printf.sprintf
            "Reset lifecycle latch for %s: pause and blocker state cleared."
            meta.name)
     | Ok None ->
       tool_result_error ~class_:Tool_result.Runtime_failure
         (Printf.sprintf "Failed to reset %s: owner metadata missing" meta.name)
     | Error error ->
       tool_result_error ~class_:Tool_result.Runtime_failure
         (Printf.sprintf
            "Failed to reset %s: %s"
            meta.name
            (Keeper_owner_registry.command_error_to_string error)))

let handle_keeper_reset ctx args : tool_result =
  keeper_reset_body ~config:ctx.config args

(** Last-resort context clear.

    Drops all conversation messages from the keeper's checkpoint file,
    optionally preserving the system prompt.  Dispatches
    [Operator_clear_requested] to reset overflow-related FSM conditions. *)
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_clear_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_name_config ~config args with
  | Error err -> tool_result_error ~class_:Tool_result.Workflow_rejection err
  | Ok name ->
    let reason = String.trim (get_string args "reason" "") in
    if String.equal reason "" then
      tool_result_error_data ~class_:Tool_result.Policy_rejection
        (validation_error_data
           "reason is required for masc_keeper_clear (audit trail)")
    else
    (* Same registry race guard as [handle_keeper_compact]: if the keeper
       disappeared between [resolve_keeper_name] and [get], abort cleanly
       rather than silently proceed with a half-applied clear. *)
    match Keeper_registry.get ~base_path:config.base_path name with
    | None ->
      tool_result_error_data ~class_:Tool_result.Workflow_rejection
        (validation_error_data
           (Printf.sprintf "keeper %s is not in the registry" name))
    | Some entry ->
      let preserve_system = get_bool args "preserve_system_prompt" true in
      let phase_before = Keeper_state_machine.phase_to_string entry.phase in
      let base_dir = Keeper_types_profile.session_base_dir config in
      (* Must use the keeper's OWN trace_id to locate its checkpoint file.
         Using generate_trace_id () would create a fresh session dir and
         always report 0 cleared messages, because the existing checkpoint
         lives under meta.runtime.trace_id. *)
      let meta_for_trace =
        match read_meta_resolved config name with
        | Ok (Some (_, meta)) -> Some meta
        | _ -> None
      in
      let trace_id =
        match meta_for_trace with
        | Some meta -> Keeper_id.Trace_id.to_string meta.runtime.trace_id
        | None -> Keeper_context_runtime.generate_trace_id ()
      in
      let session, ctx_opt =
        Keeper_context_runtime.load_context_from_checkpoint
          ~trace_id
          ~base_dir
      in
      let checkpoint_found = Option.is_some ctx_opt in
      let cleared_count =
        match ctx_opt with
        | None -> 0
        | Some wctx ->
          let existing_messages = Keeper_context_runtime.messages_of_context wctx in
          let msg_count = List.length existing_messages in
          let cleared_messages =
            if preserve_system then
              (* Keep only system-role messages *)
              List.filter
                (fun (m : Agent_core.Types.message) ->
                   (=) m.role Llm_provider.Types.System)
                existing_messages
            else
              []
          in
          let checkpoint =
            { (Keeper_context_runtime.checkpoint_of_context wctx) with
              messages = cleared_messages
            }
          in
          let cleared_ctx = { checkpoint } in
          (match meta_for_trace with
           | Some meta ->
               (match
                  Keeper_context_runtime.save_agent_core_checkpoint
                    ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta)
                    ~keeper_name:meta.name
                    ~session
                    ~agent_name:meta.name
                    ~ctx:cleared_ctx
                with
                | Ok _ -> ()
                | Error err ->
                    let detail =
                      Keeper_context_core.checkpoint_write_error_to_string
                        ~persistence_error_to_string:Fun.id
                        err
                    in
                    Log.Keeper.warn
                      "%s: failed to save cleared AGENT_CORE checkpoint: %s"
                      name detail)
           | None -> ());
          msg_count - List.length cleared_messages
      in
      (* Dispatch FSM event to clear overflow conditions *)
      Keeper_context_runtime.dispatch_keeper_phase_event
        ~config ~keeper_name:name
        (Keeper_state_machine.Operator_clear_requested { preserve_system; reason });
      (* Clear registry failure state *)
      ignore
        (Keeper_turn_failure_streak.reset
           ~base_path:config.base_path
           ~keeper_name:name);
      Keeper_unified_turn_failure.reset_invalid_request_failures ~keeper_name:name;
      Keeper_unified_turn_failure.note_turn_success name;
      Log.Keeper.warn
        "%s: context cleared by operator (reason=%s, preserve_system=%b, cleared=%d msgs)"
        name reason preserve_system cleared_count;
      Otel_metric_store.inc_counter Keeper_metrics.(to_string OperatorClear)
        ~labels:[("keeper", name);
                 ("preserve_system", Bool.to_string preserve_system)] ();
      tool_result_ok_data
        (`Assoc
          [
               ("name", `String name);
               ("phase_before", `String phase_before);
               ( "phase_after"
               , `String
                   (match Keeper_registry.get ~base_path:config.base_path name with
                    | Some entry -> Keeper_state_machine.phase_to_string entry.phase
                    | None -> "unknown") );
               ("cleared_message_count", `Int cleared_count);
               ("checkpoint_found", `Bool checkpoint_found);
               ("preserve_system_prompt", `Bool preserve_system);
            ("reason", `String reason);
          ])

let handle_keeper_clear ctx args : tool_result =
  keeper_clear_body ~config:ctx.config args

let dispatch ?invocation_ref ctx ~name ~args : tool_result option =
  let ctx = resolve_ctx ctx ~name in
  match name with
  | "masc_keeper_up" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_up ctx args))
  | "masc_keeper_status" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_status ctx args))
  | "masc_keeper_delegate" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.handle_keeper_delegate
              ?invocation_ref
              ~submitted_by:ctx.agent_name
              ctx
              args))
  | "masc_keeper_msg" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.handle_keeper_msg_from_args
              ~submitted_by:ctx.agent_name
              ctx
              args))
  | "masc_keeper_delegate_status" ->
      Some
        (tool_result_with_tool_name ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_status_body
              ~config:ctx.config ~caller:ctx.agent_name args))
  | "masc_keeper_delegate_cancel" ->
      Some
        (tool_result_with_tool_name ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_cancel_body
              ~config:ctx.config ~caller:ctx.agent_name args))
  | "masc_keeper_delegate_list" ->
      Some
        (tool_result_with_tool_name ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_list_body
              ~config:ctx.config ~caller:ctx.agent_name args))
  | "masc_keeper_down" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_down ctx args))
  | "masc_keeper_list" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_list ctx args))
  | "masc_keeper_audit" ->
    Some
      (tool_result_with_tool_name
         ~tool_name:name
         (handle_keeper_audit ctx args))
  | "masc_keeper_reset" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_reset ctx args))
  | "masc_keeper_clear" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_clear ctx args))
  | "masc_keeper_sandbox_start" ->
    Some
      (tool_result_with_tool_name
         ~tool_name:name
         (handle_keeper_sandbox_start ctx args))
  | "masc_keeper_sandbox_stop" ->
    Some
      (tool_result_with_tool_name
         ~tool_name:name
         (handle_keeper_sandbox_stop ctx args))
  | _ -> None

let dispatch_keeper_msg ~submitted_by ?continuation_channel ctx ~message : tool_result =
  let name = "masc_keeper_msg" in
  let ctx = resolve_ctx ctx ~name in
  tool_result_with_tool_name
    ~tool_name:name
    (handle_keeper_msg ?continuation_channel ~submitted_by ctx message)
;;

let dispatch_keeper_msg_stream_admitted
      ~admission_token
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?continuation_channel
      ctx
      ~message
  =
  let name = "masc_keeper_msg" in
  let ctx = resolve_ctx ctx ~name in
  Some
    (tool_result_with_tool_name
       ~tool_name:name
       (handle_keeper_msg_stream_admitted
          ~admission_token
          ?on_text_delta
          ?on_event
          ?on_tool_stream_observation
          ?on_tool_result_ready
      ?approval_gate
          ?continuation_channel
          ctx
          message))

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

exception Keeper_surface_registration_error of Tool_catalog.execution_policy_error

let () =
  Printexc.register_printer (function
    | Keeper_surface_registration_error error ->
      Some (Tool_catalog.execution_policy_error_to_string error)
    | _ -> None)
;;

let register_keeper_surface_schema (s : Masc_domain.tool_schema) =
  let metadata = Tool_catalog.metadata s.name in
  let policy =
    match Tool_catalog.execution_policy_of_metadata ~tool_name:s.name metadata with
    | Ok policy -> policy
    | Error error -> raise (Keeper_surface_registration_error error)
  in
  Tool_spec.register
    (Tool_spec.create
       ~name:s.name
       ~description:s.description
       ~module_tag:Tool_dispatch.Mod_external
       ~input_schema:s.input_schema
       ~handler_binding:Tag_dispatch
       ~is_read_only:policy.is_read_only
       ~mcp_context_required:policy.mcp_context_required
       ~is_idempotent:policy.is_idempotent
       ~visibility:metadata.visibility
       ~implementation_status:metadata.implementation_status
       ?reason:metadata.reason
       ~allow_direct_call_when_hidden:metadata.allow_direct_call_when_hidden
       ())
let () =
  List.iter register_keeper_surface_schema schemas

(* RFC-0182 §3.1 — register ctx-free keeper handlers with
   [Keeper_dispatch_ref].  Only [masc_keeper_list] today; the
   remaining keeper tools (status, msg, clear, compact,
   sandbox lifecycle) use the keeper Eio context and are gated on
   Phase 5 Eio plumbing scope. *)
(* RFC-0182 Phase 5 PR-B: [eio_context_missing] returns a typed "Eio context
   required" failure when masc_keeper_msg / masc_keeper_up etc. are
   invoked from a path that lacks ?sw / ?clock (e.g. AGENT_CORE handler).
   Production keeper dispatch from [Mcp_server_eio_execute] always
   provides them via PR-A.2 plumbing. *)
let eio_context_missing tool_name =
  Some
    (tool_result_error_data ~class_:Tool_result.Dependency_unavailable
       ~tool_name
       (`Assoc
          [ ( "error"
            , `String
                (Printf.sprintf
                   "%s requires Eio context (sw + clock); call via Mcp_server_eio_execute"
                   tool_name) ) ]))
;;

let () =
  Keeper_dispatch_ref.dispatch
  := fun ~config ~agent_name ~publication_recovery_provider ?sw ?clock ?proc_mgr ?net ?mcp_session_id:_ ?authorize_external_effect ~name ~args () ->
    let run_external_effect continue =
      match authorize_external_effect with
      | None -> continue ()
      | Some authorize -> authorize ~operation:name ~input:args ~continue
    in
    let with_eio_context continue =
      match sw, clock with
      | Some sw, Some clock ->
        let ctx : _ Keeper_types_profile.context =
          { config
          ; agent_name
          ; sw
          ; clock
          ; proc_mgr
          ; net
          ; publication_recovery_provider
          }
        in
        continue ctx
      | _ -> eio_context_missing name
    in
    match name with
    | "masc_keeper_list" ->
      Some (tool_result_with_tool_name ~tool_name:name (keeper_list_body ~config args))
    | "masc_keeper_delegate_status" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_status_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_delegate_cancel" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_cancel_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_delegate_list" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_delegate_list_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_clear" ->
      run_external_effect (fun () ->
        Some (tool_result_with_tool_name ~tool_name:name (keeper_clear_body ~config args)))
    | "masc_keeper_reset" ->
      Some (tool_result_with_tool_name ~tool_name:name (keeper_reset_body ~config args))
    | "masc_keeper_audit" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_keeper_audit.handle ~config args))
    | "masc_keeper_status" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_status_body ~config ~agent_name args))
    | "masc_keeper_sandbox_start" ->
      run_external_effect (fun () ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (keeper_sandbox_start_body ~config args)))
    | "masc_keeper_sandbox_stop" ->
      run_external_effect (fun () ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (keeper_sandbox_stop_body ~config args)))
    | "masc_keeper_down" ->
      with_eio_context (fun ctx ->
         run_external_effect (fun () ->
           Keeper_tool_surface_ops.invalidate_keeper_list_cache ();
           Some
             (tool_result_with_tool_name
                ~tool_name:name
                (Keeper_turn_lifecycle.handle_keeper_down ctx args))))
    | "masc_keeper_delegate" ->
      with_eio_context (fun ctx ->
        Some
          (Keeper_tool_surface_ops.handle_keeper_delegate
             ~submitted_by:agent_name
             ctx
             args))
    | "masc_keeper_msg" ->
      with_eio_context (fun ctx ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.handle_keeper_msg_from_args
                ~submitted_by:agent_name
                ctx
                args)))
    | "masc_keeper_up" ->
      (match sw, clock with
       | Some sw, Some clock ->
         Some
           (Keeper_tool_surface_ops.keeper_up_body
              ~config
              ~agent_name
              ~sw
              ~clock
              ~publication_recovery_provider
              ?proc_mgr
              ?net
              args)
       | _ -> eio_context_missing "masc_keeper_up")
    | _ -> None
;;
