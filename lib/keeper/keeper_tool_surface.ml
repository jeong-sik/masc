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
  (* Read before consulting the projection cache: a previously readable
     roster cannot certify a directory that has since become unreadable.
     The census also raises when the roster path cannot even be ensured
     (e.g. occupied by a file); that failure is typed here, like the
     fleet-health projections do, instead of escaping the tool. *)
  let persisted_names_result =
    try keeper_names_result config with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  match persisted_names_result with
  | Error detail -> tool_result_error ~class_:Tool_result.Runtime_failure detail
  | Ok persisted_names ->
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
          registry_names
          @ persisted_names
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
  (* Equipment bypasses the metadata TTL; one immutable ledger read serves
     all rows, including failures, for this response. *)
  let equipment = Candle_equipment.reader ~now:Time_compat.now ~base_path:config.base_path () in
  let row = function
    | `Assoc fields as json ->
      let portrait = match Json_util.assoc_string_opt "name" json with
        | Some keeper -> (match equipment ~keeper with
            | Ok value -> Keeper_portrait_equipment.Ready value
            | Error reason -> Keeper_portrait_equipment.Unavailable reason)
        | None -> Keeper_portrait_equipment.Unavailable "Keeper name unavailable" in
      `Assoc (("portrait", Keeper_portrait_equipment.reading_to_json portrait)
        :: List.remove_assoc "candle_account_revision"
          (List.remove_assoc "candle_balance_milli" (List.remove_assoc "portrait" fields)))
    | json -> json in
  let data = match data with
    | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        if key = (if detailed then "keepers" else "items") then
          match value with `List rows -> key, `List (List.map row rows) | value -> key, value
        else key, value) fields)
    | json -> json in
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
      let stop_json =
        `Assoc
          [
            ("matched", `Int stop_result.matched);
            ("removed", `Int stop_result.removed);
            ("errors", `List (List.map (fun err -> `String err) stop_result.errors));
          ]
      in
      tool_result_ok_data
        (`Assoc
           [
             ("action", `String "stop");
             ("keeper", Json_util.string_opt_to_json keeper_name);
             ("container_kind", `String (Keeper_sandbox_control.stop_scope_to_string scope));
             ("stop_result", stop_json);
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

(* A clear the store did not report as saved. [effect_disposition] says what is
   known of the checkpoint on disk: untouched, or not known. *)
let keeper_clear_failure
      ~class_
      ~effect_disposition
      ~(code : Tool_args.error_code)
      ~message
      fields
  : tool_result
  =
  tool_result_error_data
    ~class_
    ~effect_disposition
    (error_assoc
       (("error_code", `String (error_code_to_string code))
        :: ("message", `String message)
        :: fields))
;;

(** Explicit operator clear. The original maintenance child owns preparation,
    official-session reset, retained/canonical installation and input publication.
    The two stores commit separately; no partial effect is reported as success. *)
let keeper_clear_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_name_config ~config args with
  | Error err -> tool_result_error ~class_:Tool_result.Workflow_rejection err
  | Ok name ->
    let reason = String.trim (get_string args "reason" "") in
    if String.equal reason "" then
      tool_result_error_data ~class_:Tool_result.Policy_rejection
        (validation_error_data "reason is required for masc_keeper_clear (audit trail)")
    else
    let preserve_system = get_bool args "preserve_system_prompt" true in
    let failure ~class_ ~effect_disposition ~code ~message fields =
      keeper_clear_failure ~class_ ~effect_disposition ~code ~message (("name",`String name)::fields) in
    let before_effect ?(class_=Tool_result.Workflow_rejection) ?(code=Tool_args.Precondition_failed) detail fields =
      failure ~class_ ~effect_disposition:Tool_result.Proven_pre_effect
        ~code ~message:("history not cleared: " ^ detail) fields in
    let after_effect detail =
      failure ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Effect_outcome_unknown
        ~code:Tool_args.Internal_error
        ~message:("the official-client session was cleared, but history/input publication was not confirmed: "
          ^ detail ^ ". Preserve the evidence and run a fresh explicit masc_keeper_clear to reconcile.")
        ["official_client_session_cleared",`Bool true] in
    let clear_idle () =
      match Keeper_registry.get ~base_path:config.base_path name with
      | None -> before_effect "the Keeper disappeared from the registry" []
      | Some entry ->
        let phase_before = Keeper_state_machine.phase_to_string entry.phase in
        match read_meta_resolved config name with
        | Error detail -> before_effect ~class_:Tool_result.Runtime_failure ~code:Tool_args.Internal_error
            ("Keeper metadata could not be read: " ^ detail) []
        | Ok None -> before_effect "Keeper metadata disappeared after name resolution" []
        | Ok (Some (_,meta)) ->
          match Keeper_owner_registry.begin_history_clear ~base_path:config.base_path ~keeper_name:name with
          | Error error -> before_effect (Keeper_owner_registry.command_error_to_string error) []
          | Ok writer ->
            let authority = Keeper_owner.history_clear_authority writer in
            if not (Keeper_id.Trace_id.equal meta.runtime.trace_id (Keeper_history_clear.trace_id authority)) then
              before_effect "Keeper trace changed before clear admission" []
            else
            let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
            let session = Keeper_context_runtime.create_session ~session_id:trace_id
              ~base_dir:(Keeper_types_profile.session_base_dir config) in
            let path = Keeper_checkpoint_store.agent_core_checkpoint_path
              ~session_dir:session.session_dir ~session_id:trace_id in
            match Keeper_history_clear.prepare ~authority ~session_dir:session.session_dir ~preserve_system with
            | Error error ->
              let fields = match error with
                | Keeper_history_clear.Canonical_unreadable
                    (Keeper_checkpoint_store.Ref_read_failed (Keeper_checkpoint_store.Newer_version {expected;got})) ->
                  ["checkpoint_version",`Int got;"readable_version",`Int expected]
                | Canonical_unreadable (Keeper_checkpoint_store.Ref_read_failed
                    (Keeper_checkpoint_store.Read_failed {cause;_})) ->
                  ["read_failure",`String (match cause with
                    | Keeper_checkpoint_store.Os_error errno -> "os_error: " ^ Unix.error_message errno
                    | Changed_while_read -> "changed_while_read" | Read_raised -> "read_raised")]
                | Canonical_unreadable (Keeper_checkpoint_store.Ref_not_found
                    | Ref_identity_invalid _ | Ref_session_mismatch _ | Ref_lock_failed _
                    | Ref_read_failed (Not_found | Store_error _ | Parse_error _
                      | Superseded_version _ | Io_error _ | Agent_core_error _))
                | Invalid_clear _ | Retained_unavailable _
                | Installation_unconfirmed _ | Removal_unconfirmed _ -> [] in
              let class_,code = match error with
                | Keeper_history_clear.Invalid_clear _
                | Canonical_unreadable (Keeper_checkpoint_store.Ref_read_failed (Newer_version _)) ->
                  Tool_result.Workflow_rejection,Tool_args.Precondition_failed
                | Canonical_unreadable (Keeper_checkpoint_store.Ref_not_found
                    | Ref_identity_invalid _ | Ref_session_mismatch _ | Ref_lock_failed _
                    | Ref_read_failed (Not_found | Store_error _ | Parse_error _ | Read_failed _
                      | Superseded_version _ | Io_error _ | Agent_core_error _))
                | Retained_unavailable _ | Installation_unconfirmed _ | Removal_unconfirmed _ ->
                  Tool_result.Runtime_failure,Tool_args.Internal_error in
              before_effect ~class_ ~code (Keeper_history_clear.error_to_string error) (("checkpoint_path",`String path)::fields)
            | Ok plan ->
              (* No official-session mutation occurs until both owned input and
                 canonical state have been checked by this immutable plan. *)
              match Keeper_official_client_session_store.clear_then ~base_path:config.base_path ~keeper_name:name (fun () ->
                match Keeper_history_clear.execute plan with
                | Error error -> after_effect (Keeper_history_clear.error_to_string error)
                | Ok receipt ->
                  match Keeper_owner_registry.commit_history_clear ~base_path:config.base_path ~keeper_name:name ~writer ~receipt with
                  | Error error -> after_effect (Keeper_owner_registry.command_error_to_string error)
                  | Ok () ->
                    let marker = Keeper_history_clear.append_marker receipt
                      ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name:name in
                    let marker_fields = match marker with
                      | Ok () -> []
                      | Error detail ->
                        Log.Keeper.error "%s: confirmed history/input clear has no restart marker: %s" name detail;
                        Otel_metric_store.inc_counter Keeper_metrics.(to_string TurnBoundaryFailures)
                          ~labels:["keeper",name;"site","clear"] ();
                        ["history_restart_line_error",`String detail] in
                    Keeper_context_runtime.dispatch_keeper_phase_event ~config ~keeper_name:name
                      (Keeper_state_machine.Operator_clear_requested {preserve_system;reason});
                    ignore (Keeper_turn_failure_streak.reset ~base_path:config.base_path ~keeper_name:name);
                    let history_fields = match Keeper_history_clear.history receipt with
                      | Emptied {cleared_message_count;checkpoint_found} ->
                        ["cleared_message_count",`Int cleared_message_count;
                         "checkpoint_found",`Bool checkpoint_found;"preserve_system_prompt",`Bool preserve_system]
                      | Removed {checkpoint_path;undecodable} ->
                        ["checkpoint_found",`Bool true;
                         "undecodable_checkpoint_removed",`Assoc ["checkpoint_path",`String checkpoint_path;
                           "decode_error",`String (Keeper_checkpoint_store.checkpoint_load_error_to_string undecodable)]] in
                    Log.Keeper.warn "%s: operator confirmed history and input clear (reason=%s)" name reason;
                    tool_result_ok_data (`Assoc (history_fields @ marker_fields @
                      ["name",`String name;"phase_before",`String phase_before;
                       "phase_after",`String (match Keeper_registry.get ~base_path:config.base_path name with
                         | Some entry -> Keeper_state_machine.phase_to_string entry.phase | None -> "unknown");
                       "official_client_session_cleared",`Bool true;"reason",`String reason]))) with
              | Ok result -> result
              | Error detail ->
                failure ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Effect_outcome_unknown
                  ~code:Tool_args.Internal_error
                  ~message:("history was left untouched, but the official-client session reset was not confirmed: " ^ detail)
                  ["official_client_session_clear",`String "unknown"]
    in
    let result = match Keeper_owner_registry.run_maintenance_if_idle
      ~base_path:config.base_path ~keeper_name:name clear_idle with
    | Ok (`Ran result) -> result
    | Ok (`Busy block) ->
      failure ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect
        ~code:Tool_args.Conflict
        ~message:("history not cleared: " ^ Keeper_owner.autonomous_block_to_string block
          ^ ". Wait for or stop the current turn, then retry the clear.") []
    | Error error ->
      let effect_disposition = match error with
        | Keeper_owner_registry.Command_lookup_failed _ | Command_lifecycle_reserved _ -> Tool_result.Proven_pre_effect
        | Command_rejected _ -> Tool_result.Effect_outcome_unknown in
      failure ~class_:Tool_result.Dependency_unavailable ~effect_disposition ~code:Tool_args.Precondition_failed
        ~message:("history clear was not confirmed: " ^ Keeper_owner_registry.command_error_to_string error) [] in
    Otel_metric_store.inc_counter Keeper_metrics.(to_string OperatorClear)
      ~labels:["keeper",name;"preserve_system",Bool.to_string preserve_system] ();
    result

let handle_keeper_clear ctx args : tool_result =
  keeper_clear_body ~config:ctx.config args

let dispatch ?invocation_ref ctx ~name ~args : tool_result option =
  let ctx = resolve_ctx ctx ~name in
  (* Routing reads Tool_name.Keeper_name, so a constructor added there is a
     compile error here rather than a tool that is advertised and answers
     nothing. Unknown names keep returning None. *)
  match Keeper_tool_name.of_string name with
  | None -> None
  | Some keeper_name ->
    (match keeper_name with
    | Keeper_tool_name.Keeper_up -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_up ctx args))
    | Keeper_tool_name.Keeper_status -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_status ctx args))
    | Keeper_tool_name.Keeper_delegate ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.handle_keeper_delegate
                ?invocation_ref
                ~submitted_by:ctx.agent_name
                ctx
                args))
    | Keeper_tool_name.Keeper_msg ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.handle_keeper_msg_from_args
                ~submitted_by:ctx.agent_name
                ctx
                args))
    | Keeper_tool_name.Keeper_delegate_status ->
        Some
          (tool_result_with_tool_name ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_status_body
                ~config:ctx.config ~caller:ctx.agent_name args))
    | Keeper_tool_name.Keeper_delegate_cancel ->
        Some
          (tool_result_with_tool_name ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_cancel_body
                ~config:ctx.config ~caller:ctx.agent_name args))
    | Keeper_tool_name.Keeper_delegate_list ->
        Some
          (tool_result_with_tool_name ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_list_body
                ~config:ctx.config ~caller:ctx.agent_name args))
    | Keeper_tool_name.Keeper_down -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_down ctx args))
    | Keeper_tool_name.Keeper_list -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_list ctx args))
    | Keeper_tool_name.Keeper_audit ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_audit ctx args))
    | Keeper_tool_name.Keeper_reset -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_reset ctx args))
    | Keeper_tool_name.Keeper_clear -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_clear ctx args))
    | Keeper_tool_name.Keeper_sandbox_start ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_sandbox_start ctx args))
    | Keeper_tool_name.Keeper_sandbox_stop ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_sandbox_stop ctx args))
    )

let dispatch_keeper_msg ~submitted_by ?continuation_channel ctx ~message : tool_result =
  let name = Keeper_tool_name.(to_string Keeper_msg) in
  let ctx = resolve_ctx ctx ~name in
  tool_result_with_tool_name
    ~tool_name:name
    (handle_keeper_msg ?continuation_channel ~submitted_by ctx message)
;;

let submit_keeper_msg ~submitted_by ?continuation_channel ctx ~message =
  let name = Keeper_tool_name.(to_string Keeper_msg) in
  let ctx = resolve_ctx ctx ~name in
  Keeper_tool_surface_ops.submit_keeper_msg
    ?continuation_channel ~submitted_by ctx message
  |> Result.map_error (fun error ->
         tool_result_of_handler_error error
         |> tool_result_with_tool_name ~tool_name:name)
;;

let dispatch_keeper_msg_stream_admitted
      ~operation_id
      ~admission_token
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?continuation_channel
      ctx
      ~message
      ~input_speaker
  =
  let name = Keeper_tool_name.(to_string Keeper_msg) in
  let ctx = resolve_ctx ctx ~name in
  let dispatch =
    handle_keeper_msg_stream_admitted
      ~operation_id
      ~admission_token
      ~input_speaker
      ?on_text_delta
      ?on_event
      ?on_tool_stream_observation
      ?on_tool_result_ready
      ?approval_gate
      ?continuation_channel
      ctx
      message
  in
  Some
    (match dispatch with
     | Keeper_turn.Turn_settled result ->
       Keeper_turn.Turn_settled (tool_result_with_tool_name ~tool_name:name result)
     | Keeper_turn.Turn_failed { result; failure } ->
       Keeper_turn.Turn_failed
         { result = tool_result_with_tool_name ~tool_name:name result; failure })

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
    (* Same vocabulary as [dispatch]; this path is the one that has the Eio
       context. Both read Tool_name.Keeper_name, so a constructor cannot be
       handled on one path and silently dropped on the other. *)
    match Keeper_tool_name.of_string name with
    | None -> None
    | Some keeper_name ->
      (match keeper_name with
      | Keeper_tool_name.Keeper_list ->
        Some (tool_result_with_tool_name ~tool_name:name (keeper_list_body ~config args))
      | Keeper_tool_name.Keeper_delegate_status ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_status_body
                ~config
                ~caller:agent_name
                args))
      | Keeper_tool_name.Keeper_delegate_cancel ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_cancel_body
                ~config
                ~caller:agent_name
                args))
      | Keeper_tool_name.Keeper_delegate_list ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.keeper_delegate_list_body
                ~config
                ~caller:agent_name
                args))
      | Keeper_tool_name.Keeper_clear ->
        run_external_effect (fun () ->
          Some (tool_result_with_tool_name ~tool_name:name (keeper_clear_body ~config args)))
      | Keeper_tool_name.Keeper_reset ->
        Some (tool_result_with_tool_name ~tool_name:name (keeper_reset_body ~config args))
      | Keeper_tool_name.Keeper_audit ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_keeper_audit.handle ~config args))
      | Keeper_tool_name.Keeper_status ->
        Some
          (tool_result_with_tool_name
             ~tool_name:name
             (Keeper_tool_surface_ops.keeper_status_body ~config ~agent_name args))
      | Keeper_tool_name.Keeper_sandbox_start ->
        run_external_effect (fun () ->
          Some
            (tool_result_with_tool_name
               ~tool_name:name
               (keeper_sandbox_start_body ~config args)))
      | Keeper_tool_name.Keeper_sandbox_stop ->
        run_external_effect (fun () ->
          Some
            (tool_result_with_tool_name
               ~tool_name:name
               (keeper_sandbox_stop_body ~config args)))
      | Keeper_tool_name.Keeper_down ->
        with_eio_context (fun ctx ->
           run_external_effect (fun () ->
             Keeper_tool_surface_ops.invalidate_keeper_list_cache ();
             Some
               (tool_result_with_tool_name
                  ~tool_name:name
                  (Keeper_turn_lifecycle.handle_keeper_down ctx args))))
      | Keeper_tool_name.Keeper_delegate ->
        with_eio_context (fun ctx ->
          Some
            (Keeper_tool_surface_ops.handle_keeper_delegate
               ~submitted_by:agent_name
               ctx
               args))
      | Keeper_tool_name.Keeper_msg ->
        with_eio_context (fun ctx ->
          Some
            (tool_result_with_tool_name
               ~tool_name:name
               (Keeper_tool_surface_ops.handle_keeper_msg_from_args
                  ~submitted_by:agent_name
                  ctx
                  args)))
      | Keeper_tool_name.Keeper_up ->
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
         | _ -> eio_context_missing Keeper_tool_name.(to_string Keeper_up))
      )
;;
