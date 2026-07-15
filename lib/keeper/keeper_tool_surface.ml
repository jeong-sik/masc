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
        let names =
          registry_names @ keeper_names config
          |> List.map String.trim
          |> List.filter (fun name -> not (String.equal name ""))
          |> List.sort_uniq String.compare
          |> take limit
        in
        let rows =
          names
          |> List.filter_map (fun name ->
               keeper_list_row_json ~runtime_class:"keeper" config name)
        in
        let json =
          if not detailed then
            `Assoc
              [
                ("count", `Int (List.length names));
                ("keepers", `List (List.map (fun name -> `String name) names));
                ("items", `List rows);
              ]
          else
            `Assoc
              [
                ("count", `Int (List.length rows));
                ("keepers", `List rows);
              ]
        in
        json)
  in
  tool_result_ok_data data

let handle_keeper_list ctx args : tool_result =
  keeper_list_body ~config:ctx.config args

let dedupe_sorted_strings = Persona_audit.dedupe_sorted_strings

let handle_keeper_persona_audit ctx args =
  Persona_audit.handle ~config:ctx.config args

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

let compaction_dispatch_error_data ~stage ~checkpoint_applied error =
  let detail = Keeper_context_runtime.lifecycle_dispatch_error_to_string error in
  error_assoc
    [ "error_code", `String (error_code_to_string Conflict)
    ; "message", `String (Printf.sprintf "compaction lifecycle dispatch failed: %s" detail)
    ; "lifecycle_stage", `String stage
    ; "checkpoint_applied", `Bool checkpoint_applied
    ; "dispatch_error", `String detail
    ]

let compaction_recovery_error_data ?dispatch_error error =
  let tag = Keeper_post_turn.compaction_recovery_error_to_tag error in
  let detail = Keeper_post_turn.compaction_recovery_error_to_string error in
  let recovery_code =
    match error with
    | Keeper_post_turn.Checkpoint_load_failed
        Keeper_checkpoint_store.Not_found -> Not_found
    | Compaction_rejected Retired_deterministic_mode
    | Compaction_rejected Runtime_identity_unavailable
    | Compaction_rejected Structurally_unchanged
    | Compaction_rejected Checkpoint_not_reduced ->
      Precondition_failed
    | Compaction_rejected Summarizer_unavailable
    | Compaction_rejected Plan_unavailable_or_invalid
    | Compaction_evidence_missing
    | Unexpected_compaction_decision _ -> Internal_error
    | Checkpoint_superseded _ -> Conflict
    | Checkpoint_load_failed _
    | Checkpoint_save_failed _ -> Internal_error
  in
  let code =
    match dispatch_error with
    | None -> recovery_code
    | Some _ -> Conflict
  in
  error_assoc
    ([ "error_code", `String (error_code_to_string code)
     ; "message", `String detail
     ; "compaction_error", `String tag
     ; "checkpoint_applied", `Bool false
     ]
     @
     match dispatch_error with
     | None -> []
     | Some error ->
       [ "recovery_error_code", `String (error_code_to_string recovery_code)
       ; ( "lifecycle_dispatch_error"
         , `String
             (Keeper_context_runtime.lifecycle_dispatch_error_to_string error) ) ])

let keeper_sandbox_status_fleet_names ctx =
  let registry_names =
    Keeper_registry.all ~base_path:ctx.config.base_path ()
    |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
  in
  registry_names @ configured_keeper_names ctx.config @ keeper_names ctx.config
  |> dedupe_sorted_strings

type sandbox_status_fleet_item =
  | Sandbox_status_meta of keeper_meta
  | Sandbox_status_error of { name : string; error : string }

let keeper_sandbox_status_error_item_json config ~name ~error =
  let persisted_meta =
    match read_meta config name with
    | Ok (Some meta) -> Some meta
    | Ok None | Error _ -> None
  in
  let keepalive_running =
    match persisted_meta with
    | Some meta -> Keeper_status_bridge.runtime_keepalive_running config meta
    | None -> false
  in
  let persisted_fields =
    match persisted_meta with
    | Some meta ->
        [
          ("persisted_meta", keeper_brief_meta_json meta);
          ("agent_name", `String meta.agent_name);
          ( "persisted_sandbox_profile",
            `String (sandbox_profile_to_string meta.sandbox_profile) );
          ( "persisted_network_mode",
            `String (network_mode_to_string meta.network_mode) );
        ]
    | None ->
        [
          ("persisted_meta", `Null);
          ("agent_name", `Null);
          ("persisted_sandbox_profile", `Null);
          ("persisted_network_mode", `Null);
        ]
  in
  error_assoc
    ([
       ("keeper", `String name);
       ("sandbox_profile", `Null);
       ("configured_network_mode", `Null);
       ("effective_mode", `String "unknown");
       ("managed_container_kind", `String Keeper_sandbox_control.managed_kind);
       ("container_count", `Int 0);
       ("containers", `List []);
       ("preflight", `Null);
       ("container_error", `Null);
       ("why_no_container", `String "effective_meta_read_failed");
       ( "recommendation",
         `String "Fix keeper TOML/persona profile and retry sandbox status." );
       ("keepalive_running", `Bool keepalive_running);
       ("effective_meta_error", keeper_list_effective_meta_error_json name error);
     ]
     @ persisted_fields)

let handle_keeper_sandbox_status ctx args : tool_result =
  let verbose = get_bool args "verbose" false in
  let include_preflight = get_bool args "include_preflight" true in
  let timeout_sec = Stdlib.Float.min 20.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 5.0)) in
  match String.trim (get_string args "name" "") with
  | "" ->
      let configured_names = configured_keeper_names ctx.config in
      let candidate_names = keeper_sandbox_status_fleet_names ctx in
      let resolved =
        candidate_names
        |> List.filter_map (fun name ->
             match read_effective_meta ctx.config name with
             | Ok (Some meta) -> Some (Sandbox_status_meta meta)
             | Ok None when List.mem name configured_names -> (
                 match load_or_materialize_boot_meta ctx name with
                 | Ok { meta; _ } -> (
                     match
                       Keeper_meta_contract.effective_meta_result
                         ~base_path:ctx.config.base_path
                         meta
                     with
                     | Ok effective_meta -> Some (Sandbox_status_meta effective_meta)
                     | Error msg ->
                         Log.Keeper.warn
                           "keeper_sandbox_status fleet: failed to overlay effective meta for materialized keeper %s: %s"
                           name msg;
                         Some (Sandbox_status_error { name; error = msg }))
                 | Error msg ->
                     Log.Keeper.warn
                       "keeper_sandbox_status fleet: failed to materialize configured keeper %s: %s"
                       name msg;
                     Some (Sandbox_status_error { name; error = msg }))
             | Ok None -> None
             | Error msg ->
                 Log.Keeper.warn
                   "keeper_sandbox_status fleet: failed to read effective meta for %s: %s"
                   name msg;
                 Some (Sandbox_status_error { name; error = msg }))
      in
      let seen = Hashtbl.create 16 in
      let unique_items =
        List.filter_map
          (fun item ->
            let name =
              match item with
              | Sandbox_status_meta meta -> meta.name
              | Sandbox_status_error { name; _ } -> name
            in
            if Hashtbl.mem seen name then None
            else (
              Hashtbl.add seen name ();
              Some item))
          resolved
      in
      let any_docker =
        List.exists
          (function
            | Sandbox_status_meta (m : keeper_meta) -> m.sandbox_profile = Docker
            | Sandbox_status_error _ -> false)
          unique_items
      in
      let cached_preflight =
        if include_preflight && any_docker then
          Keeper_sandbox_control.preflight_status_json ~timeout_sec
        else
          None
      in
      let render_item (meta : keeper_meta) =
        let preflight_override =
          if meta.sandbox_profile = Docker then Some cached_preflight
          else None
        in
        Keeper_sandbox_control.live_status_json
          ~include_preflight ?preflight_override
          ~config:ctx.config ~meta ~timeout_sec ~verbose ()
      in
      let items =
        List.map
          (function
            | Sandbox_status_meta meta -> render_item meta
            | Sandbox_status_error { name; error } ->
                keeper_sandbox_status_error_item_json ctx.config ~name ~error)
          unique_items
      in
      tool_result_ok_data
        (`Assoc
           [
             ("count", `Int (List.length items));
             ("items", `List items);
           ])
  | _ ->
      (match prepare_passive_keeper_identity ctx args with
       | Error err -> tool_result_error err
       | Ok (prepared_args, identity_reseed) -> (
           match resolve_keeper_meta ctx prepared_args with
           | Error err -> tool_result_error err
           | Ok meta ->
               let json =
                 `Assoc
                   [
                     ("keeper", `String meta.name);
                     ( "sandbox",
                       Keeper_sandbox_control.live_status_json
                         ~include_preflight ~config:ctx.config ~meta
                         ~timeout_sec ~verbose () );
                 ]
                 |> attach_identity_reseed ?identity_reseed
               in
               tool_result_ok_data json))

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_sandbox_start_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_meta_config ~config args with
  | Error err -> tool_result_error err
  | Ok meta ->
      let timeout_sec = get_float args "timeout_sec" nan in
      let ttl_sec = Option.value ~default:0.0 (get_float_opt args "ttl_sec") in
      if (not (Float.is_finite timeout_sec)) || timeout_sec <= 0.0
      then tool_result_error "timeout_sec must be a positive finite number"
      else if (not (Float.is_finite ttl_sec)) || ttl_sec < 0.0
      then tool_result_error "ttl_sec must be a non-negative finite number"
      else
      let network_mode_raw =
        String.trim
          (get_string args "network_mode"
             (network_mode_to_string meta.network_mode))
      in
      (match parse_network_mode_or_error network_mode_raw with
       | Error err -> tool_result_error err
       | Ok network_mode -> (
           match
             Keeper_sandbox_control.start_managed_container
               ~config ~meta ~network_mode ~ttl_sec ~timeout_sec ()
           with
           | Error err -> tool_result_error err
           | Ok result ->
               invalidate_status_cache meta.name;
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
  then tool_result_error "timeout_sec must be a positive finite number"
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
  | Error err -> tool_result_error_data (validation_error_data err)
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
      (match keeper_name with
       | Some name -> invalidate_status_cache name
       | None -> Keeper_status_detail.invalidate_status_cache_all ());
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

(* Recurring loop tools (#3190) removed: zero callers. *)

let should_bootstrap_existing_keepalives name args =
  match name with
  | "masc_keeper_msg" ->
      not (String.equal (String.trim (get_string args "message" "")) "")
  | _ -> false

let maybe_bootstrap_existing_keepalives ctx ~name ~args =
  if should_bootstrap_existing_keepalives name args
  then
    (try start_existing_keepalives ctx
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "start_existing_keepalives failed: %s"
         (Stdlib.Printexc.to_string exn))

(** Keeper tools are scoped to the caller's current base_path.
    Do not retarget requests across other base_path registries. *)
let resolve_ctx ctx ~name:_ _args = ctx

(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_reset_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_meta_config ~config args with
  | Error err -> tool_result_error err
  | Ok meta ->
    let reset_meta = Keeper_meta_contract.reset_runtime_state meta in
    (match Keeper_meta_store.write_meta config reset_meta with
     | Ok () ->
       tool_result_ok
         (Printf.sprintf
            "Reset runtime state for %s: usage counters zeroed, last_model_used cleared."
            meta.name)
     | Error err ->
       tool_result_error
         (Printf.sprintf "Failed to write reset meta for %s: %s" meta.name err))

let handle_keeper_reset ctx args : tool_result =
  keeper_reset_body ~config:ctx.config args

(** Resolve the primary model max context for a keeper.

    Returns the resolved primary provider/runtime context window, separate from
    any requested [max_context_override].
    Returns [min_keeper_context_tokens] when meta is unavailable. *)
let resolve_primary_max_context (meta : Keeper_meta_contract.keeper_meta option) : int =
  let min_ctx = Keeper_config.min_keeper_context_tokens in
  match meta with
  | None -> min_ctx
  | Some meta ->
    let resolution =
      Keeper_context_runtime.resolve_max_context_resolution_of_meta meta
    in
    max min_ctx resolution.effective_budget

let manual_compaction_wakeup_observation ~base_path keeper_name =
  match
    Keeper_registry.wakeup
      ~intent:Keeper_registry.Compaction_signal
      ~base_path
      keeper_name
  with
  | Keeper_registry.Signaled -> `Assoc [ "outcome", `String "signaled" ]
  | Keeper_registry.Deferred_unregistered ->
    Log.Keeper.info
      "%s: manual compaction request queued without a registered wake target"
      keeper_name;
    `Assoc [ "outcome", `String "deferred_unregistered" ]
  | Keeper_registry.Deferred_not_running phase ->
    let phase = Keeper_state_machine.phase_to_string phase in
    Log.Keeper.info
      "%s: manual compaction request wake deferred in phase=%s"
      keeper_name
      phase;
    `Assoc
      [ "outcome", `String "deferred_not_running"; "phase", `String phase ]
  | Keeper_registry.Deferred_lifecycle denial ->
    let reason = Keeper_lifecycle_admission.autonomous_denial_to_wire denial in
    Log.Keeper.info
      "%s: manual compaction request wake deferred by lifecycle reason=%s"
      keeper_name
      reason;
    `Assoc
      [ "outcome", `String "deferred_lifecycle"; "reason", `String reason ]
;;

(** Queue an operator compaction for the target Keeper's owning lane. *)
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_compact_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_name_config ~config args with
  | Error err -> tool_result_error err
  | Ok name ->
    match Keeper_registry.get ~base_path:config.base_path name with
    | None ->
      Otel_metric_store.inc_counter Keeper_metrics.(to_string OperatorCompact)
        ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label Not_found))] ();
      tool_result_error_data
        (validation_error_data
           (Printf.sprintf "keeper %s is not in the registry" name))
    | Some entry ->
    if Keeper_state_machine.is_terminal entry.phase then begin
      Otel_metric_store.inc_counter Keeper_metrics.(to_string OperatorCompact)
        ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label Precondition))] ();
      tool_result_error_data
        (validation_error_data
           (Printf.sprintf "keeper %s is explicitly stopped" name))
    end
    else
      let stimulus : Keeper_event_queue.stimulus =
        { post_id = Keeper_event_queue.manual_compaction_post_id
        ; urgency = Immediate
        ; arrived_at = Time_compat.now ()
        ; payload = Manual_compaction_requested
        }
      in
      let queued queue_outcome =
        tool_result_ok_data
          (`Assoc
            [ "name", `String name
            ; "queued", `Bool true
            ; "queue_outcome", `String queue_outcome
            ; "stimulus", `String (Keeper_event_queue.payload_kind_label stimulus.payload)
            ; ( "wake"
              , manual_compaction_wakeup_observation
                  ~base_path:config.base_path
                  name )
            ])
      in
      (match
         Keeper_registry_event_queue.enqueue_stimulus_durable_result
           ~base_path:config.base_path
           name
           stimulus
       with
       | Stimulus_storage_error detail ->
         Log.Keeper.error
           ~keeper_name:name
           "manual compaction request enqueue failed: %s"
           detail;
         tool_result_error
           (Printf.sprintf "keeper %s: compaction request enqueue failed: %s" name detail)
       | Stimulus_enqueued -> queued "enqueued"
       | Stimulus_already_present -> queued "already_present")

let handle_keeper_compact ctx args : tool_result =
  keeper_compact_body ~config:ctx.config args

(** Last-resort context clear.

    Drops all conversation messages from the keeper's checkpoint file,
    optionally preserving the system prompt.  Dispatches
    [Operator_clear_requested] to reset overflow-related FSM conditions. *)
(* RFC-0182 §3.1 — ctx-free body for keeper_dispatch_ref path. *)
let keeper_clear_body ~(config : Workspace.config) args : tool_result =
  match resolve_keeper_name_config ~config args with
  | Error err -> tool_result_error err
  | Ok name ->
    let reason = String.trim (get_string args "reason" "") in
    if String.equal reason "" then
      tool_result_error_data
        (validation_error_data
           "reason is required for masc_keeper_clear (audit trail)")
    else
    (* Same registry race guard as [handle_keeper_compact]: if the keeper
       disappeared between [resolve_keeper_name] and [get], abort cleanly
       rather than silently proceed with a half-applied clear. *)
    match Keeper_registry.get ~base_path:config.base_path name with
    | None ->
      tool_result_error_data
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
      let max_tokens = resolve_primary_max_context meta_for_trace in
      let session, ctx_opt =
        Keeper_context_runtime.load_context_from_checkpoint
          ~trace_id
          ~primary_model_max_tokens:max_tokens
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
                (fun (m : Agent_sdk.Types.message) ->
                   (=) m.role Llm_provider.Types.System)
                existing_messages
            else
              []
          in
          let cleared_ctx =
            {
              wctx with
              checkpoint =
                {
                  (Keeper_context_runtime.checkpoint_of_context wctx) with
                  messages = cleared_messages;
                };
            }
          in
          (* Increment generation from meta to signal a new context epoch.
             Using a hardcoded value would violate generation monotonicity
             — the keeper_unified_turn retry loop uses meta.runtime.generation
             to detect stale contexts. *)
          let current_gen =
            match meta_for_trace with
            | Some meta -> meta.runtime.generation
            | None -> 0
          in
          (match meta_for_trace with
           | Some meta ->
               (match
                  Keeper_context_runtime.save_oas_checkpoint
                    ~multimodal_policy:meta.multimodal_policy
                    ~keeper_name:meta.name
                    ~session
                    ~agent_name:meta.agent_name
                    ~ctx:cleared_ctx
                    ~generation:(current_gen + 1)
                with
                | Ok _ -> ()
                | Error err ->
                    Log.Keeper.warn
                      "%s: failed to save cleared OAS checkpoint: %s"
                      name err)
           | None -> ());
          msg_count - List.length cleared_messages
      in
      (* Dispatch FSM event to clear overflow conditions *)
      Keeper_context_runtime.dispatch_keeper_phase_event
        ~config ~keeper_name:name
        (Keeper_state_machine.Operator_clear_requested { preserve_system; reason });
      (* Clear registry failure state *)
      Keeper_registry.set_failure_reason ~base_path:config.base_path name None;
      Keeper_registry.reset_turn_failures ~base_path:config.base_path name;
      invalidate_status_cache name;
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

let dispatch ?continuation_channel ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_persona_list" -> Some (tool_result_with_tool_name ~tool_name:name (Persona.handle_persona_list ctx args))
  | "masc_persona_create" -> Some (tool_result_with_tool_name ~tool_name:name (Keeper_tool_persona_crud.handle_persona_create ctx args))
  | "masc_persona_update" -> Some (tool_result_with_tool_name ~tool_name:name (Keeper_tool_persona_crud.handle_persona_update ctx args))
  | "masc_persona_delete" -> Some (tool_result_with_tool_name ~tool_name:name (Keeper_tool_persona_crud.handle_persona_delete ctx args))
  | "masc_keeper_create_from_persona" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_create_from_persona ctx args))
  | "masc_keeper_up" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_up ctx args))
  | "masc_keeper_status" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_status ctx args))
  | "masc_keeper_msg" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_msg
              ?continuation_channel
              ~submitted_by:ctx.agent_name
              ctx
              args))
  | "masc_keeper_msg_result" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_msg_result ctx args))
  | "masc_keeper_msg_cancel" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_msg_cancel ctx args))
  | "masc_keeper_msg_queue" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_msg_queue ctx args))
  | "masc_keeper_down" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_down ctx args))
  | "masc_keeper_list" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_list ctx args))
  | "masc_keeper_persona_audit" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_persona_audit ctx args))
  | "masc_keeper_sandbox_status" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_sandbox_status ctx args))
  | "masc_keeper_reset" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_reset ctx args))
  | "masc_keeper_compact" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_compact ctx args))
  | "masc_keeper_clear" -> Some (tool_result_with_tool_name ~tool_name:name (handle_keeper_clear ctx args))
  | _ -> None

let dispatch_keeper_msg ~submitted_by ?continuation_channel ctx ~args : tool_result =
  let name = "masc_keeper_msg" in
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  tool_result_with_tool_name
    ~tool_name:name
    (handle_keeper_msg ?continuation_channel ~submitted_by ctx args)
;;

(** Streaming dispatch: only handles keeper_msg with text delta forwarding.
    Returns None for all other tool names.
    Called from server_routes_http_keeper_stream. *)
let dispatch_stream
      ?on_text_delta
      ?on_event
      ?continuation_channel
      ?on_admission_rejected
      ?on_admitted
      ctx
      ~name
      ~args
  : tool_result option
  =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_keeper_msg" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (handle_keeper_msg_stream
              ?on_text_delta
              ?on_event
              ?continuation_channel
              ?on_admission_rejected
              ?on_admitted
              ctx
              args))
  | _ -> None

let dispatch_stream_if_free
      ?on_text_delta
      ?on_event
      ?continuation_channel
      ctx
      ~name
      ~args
  =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_keeper_msg" ->
      (match
         handle_keeper_msg_stream_if_free
           ?on_text_delta
           ?on_event
           ?continuation_channel
           ctx
           args
       with
       | `Busy rejection -> `Busy rejection
       | `Ran result ->
         `Ran
           (Some
              (tool_result_with_tool_name ~tool_name:name result)))
  | _ -> `Ran None

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
       ?canonical_name:metadata.canonical_name
       ?replacement:metadata.replacement
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
   invoked from a path that lacks ?sw / ?clock (e.g. OAS handler).
   Production keeper dispatch from [Mcp_server_eio_execute] always
   provides them via PR-A.2 plumbing. *)
let eio_context_missing tool_name =
  Some
    (tool_result_error_data
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
    match name with
    | "masc_keeper_list" ->
      Some (tool_result_with_tool_name ~tool_name:name (keeper_list_body ~config args))
    | "masc_keeper_msg_result" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_msg_result_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_msg_cancel" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_msg_cancel_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_msg_queue" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_msg_queue_body
              ~config
              ~caller:agent_name
              args))
    | "masc_keeper_compact" ->
      Some (tool_result_with_tool_name ~tool_name:name (keeper_compact_body ~config args))
    | "masc_keeper_clear" ->
      run_external_effect (fun () ->
        Some (tool_result_with_tool_name ~tool_name:name (keeper_clear_body ~config args)))
    | "masc_keeper_reset" ->
      Some (tool_result_with_tool_name ~tool_name:name (keeper_reset_body ~config args))
    | "masc_keeper_persona_audit" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_persona_audit.handle ~config args))
    | "masc_keeper_status" ->
      Some
        (tool_result_with_tool_name
           ~tool_name:name
           (Keeper_tool_surface_ops.keeper_status_body ~config ~agent_name args))
    | "masc_keeper_sandbox_status" ->
      (match sw, clock with
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
         Some
           (tool_result_with_tool_name
              ~tool_name:name
              (handle_keeper_sandbox_status ctx args))
       | _ -> eio_context_missing name)
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
      (match sw, clock with
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
         run_external_effect (fun () ->
           Keeper_tool_surface_ops.invalidate_keeper_list_cache ();
           Keeper_tool_surface_ops.invalidate_status_cache
             (Tool_args.get_string args "name" "");
           Some
             (tool_result_with_tool_name
                ~tool_name:name
                (Keeper_turn_lifecycle.handle_keeper_down ctx args)))
       | _ -> eio_context_missing name)
    (* RFC-0182 Phase 5 PR-B: Eio-bound keeper tools.  Require both
       sw and clock from caller; gracefully fail when invoked from a
       path without Eio context. *)
    | "masc_keeper_msg" ->
      (match sw, clock with
       | Some sw, Some clock ->
         Some
           (Keeper_tool_surface_ops.keeper_msg_body
              ~config
              ~agent_name
              ~sw
              ~clock
              ~publication_recovery_provider
              ?proc_mgr
              ?net
              args)
       | _ -> eio_context_missing "masc_keeper_msg")
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
