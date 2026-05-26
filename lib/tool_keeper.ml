(* Keeper tool dispatch — ops + cache + start/stop + repair extracted to
   [Tool_keeper_ops] (godfile decomp). *)

open Tool_args
open Keeper_types
open Keeper_runtime

include Tool_keeper_ops

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let cache_key =
    Printf.sprintf "%s:%d:%b" ctx.config.base_path limit detailed
  in
  let body =
    cached_text_by_key keeper_list_cache ~key:cache_key
      ~ttl_s:(keeper_list_cache_ttl_s ()) (fun () ->
        let registry_names =
          Keeper_registry.all ~base_path:ctx.config.base_path ()
          |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
        in
        let names =
          registry_names @ keeper_names ctx.config
          |> List.map String.trim
          |> List.filter (fun name -> not (String.equal name ""))
          |> List.sort_uniq String.compare
          |> take limit
        in
        let rows =
          names
          |> List.filter_map (fun name ->
               keeper_list_row_json ~runtime_class:"keeper" ctx.config name)
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
        Yojson.Safe.pretty_to_string json)
  in
  (true, body)

let dedupe_sorted_strings = Persona_audit.dedupe_sorted_strings
let handle_keeper_persona_audit = Persona_audit.handle

let parse_network_mode_or_error raw =
  match network_mode_of_string raw with
  | Some mode -> Ok mode
  | None ->
      Error
        (Printf.sprintf "invalid network_mode %S (allowed: %s)" raw
           (String.concat ", " valid_network_mode_strings))

let keeper_sandbox_status_fleet_names ctx =
  let registry_names =
    Keeper_registry.all ~base_path:ctx.config.base_path ()
    |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
  in
  registry_names @ configured_keeper_names ctx.config @ keeper_names ctx.config
  |> dedupe_sorted_strings

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
             match read_meta ctx.config name with
             | Ok (Some meta) -> Some meta
             | Ok None when List.mem name configured_names -> (
                 match load_or_materialize_boot_meta ctx name with
                 | Ok { meta; _ } -> Some meta
                 | Error msg ->
                     Log.Keeper.warn
                       "keeper_sandbox_status fleet: failed to materialize configured keeper %s: %s"
                       name msg;
                     None)
             | Ok None | Error _ -> None)
      in
      let seen = Hashtbl.create 16 in
      let unique_metas =
        List.filter_map
          (fun (meta : keeper_meta) ->
            if Hashtbl.mem seen meta.name then None
            else begin
              Hashtbl.add seen meta.name ();
              Some meta
            end)
          resolved
      in
      let any_docker =
        List.exists
          (fun (m : keeper_meta) -> m.sandbox_profile = Docker)
          unique_metas
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
      let items = List.map render_item unique_metas in
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
             [
               ("count", `Int (List.length items));
               ("items", `List items);
             ]) )
  | _ ->
      (match prepare_passive_keeper_identity ctx args with
       | Error err -> (false, err)
       | Ok (prepared_args, identity_reseed) -> (
           match resolve_keeper_meta ctx prepared_args with
           | Error err -> (false, err)
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
               (true, Yojson.Safe.pretty_to_string json)))

let handle_keeper_sandbox_start ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta ->
      let timeout_sec = Stdlib.Float.min 30.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 10.0)) in
      let ttl_sec = Stdlib.Float.min 86_400.0 (Stdlib.Float.max 1.0 (get_float args "ttl_sec" 1800.0)) in
      let network_mode_raw =
        String.trim
          (get_string args "network_mode"
             (network_mode_to_string meta.network_mode))
      in
      (match parse_network_mode_or_error network_mode_raw with
       | Error err -> (false, err)
       | Ok network_mode -> (
           match
             Keeper_sandbox_control.start_managed_container
               ~config:ctx.config ~meta ~network_mode ~ttl_sec ~timeout_sec ()
           with
           | Error err -> (false, err)
           | Ok result ->
               invalidate_status_cache meta.name;
               ( true,
                 Yojson.Safe.pretty_to_string
                   (`Assoc
                      [
                        ("keeper", `String meta.name);
                        ("action", `String "start");
                        ("sandbox", result);
                      ]) )))

let handle_keeper_sandbox_stop ctx args : tool_result =
  let timeout_sec = Stdlib.Float.min 30.0 (Stdlib.Float.max 1.0 (get_float args "timeout_sec" 10.0)) in
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
  | Error err -> (false, error_response_typed ~code:Validation_error err)
  | Ok scope ->
      let stop_result =
        Keeper_sandbox_control.stop_containers
          ?keeper_name ~scope ~config:ctx.config ~timeout_sec ()
      in
      let stale_cleanup =
        if prune_stale then
          Some
            (Keeper_sandbox_control.cleanup_stale ~config:ctx.config
               ~timeout_sec:(Stdlib.Float.min timeout_sec 5.0) ())
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
                ("errors",
                 `List (List.map (fun err -> `String err) cleanup.errors));
              ]
      in
      ( true,
        Yojson.Safe.pretty_to_string
          (`Assoc
             [
               ("action", `String "stop");
               ("keeper", Json_util.string_opt_to_json keeper_name);
               ("container_kind", `String (Keeper_sandbox_control.stop_scope_to_string scope));
               ("stop_result", stop_json);
               ("stale_cleanup", stale_json);
             ]) )

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
  if should_bootstrap_existing_keepalives name args then
    (try start_existing_keepalives ctx
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "start_existing_keepalives failed: %s"
         (Stdlib.Printexc.to_string exn))

(** Keeper tools are scoped to the caller's current base_path.
    Do not retarget requests across other base_path registries. *)
let resolve_ctx ctx ~name:_ _args = ctx

let handle_keeper_reset ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> (false, err)
  | Ok meta ->
    let reset_meta = Keeper_types.reset_runtime_state meta in
    (match Keeper_types.write_meta ctx.config reset_meta with
     | Ok () ->
       (true, Printf.sprintf
         "Reset runtime state for %s: usage counters zeroed, last_model_used cleared."
         meta.name)
     | Error err ->
       (false, Printf.sprintf "Failed to write reset meta for %s: %s" meta.name err))

(** Resolve the primary model max context for a keeper.

    Returns the resolved primary provider/cascade budget, separate from any
    requested [max_context_override] turn-budget widening.
    Returns [min_keeper_context_tokens] when meta is unavailable. *)
let resolve_primary_max_context (meta : Keeper_types.keeper_meta option) : int =
  let min_ctx = Keeper_config.min_keeper_context_tokens in
  match meta with
  | None -> min_ctx
  | Some meta ->
    let resolution =
      Keeper_exec_context.resolve_max_context_resolution_of_meta meta
    in
    max min_ctx resolution.effective_budget

(** Operator-initiated context compaction.

    Dispatches [Operator_compact_requested] to the FSM, then compacts the
    keeper's latest checkpoint via OAS checkpoint recovery.  Returns
    before/after token counts on success. *)
let handle_keeper_compact ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
    let force = get_bool args "force" false in
    (* Registry race: [resolve_keeper_name] succeeded but the registry entry
       can still disappear if another fiber unregistered the keeper.  Treat
       this as a distinct "not found" error rather than an opaque
       "phase=unknown" precondition failure. *)
    match Keeper_registry.get ~base_path:ctx.config.base_path name with
    | None ->
      Prometheus.inc_counter Keeper_metrics.(to_string OperatorCompact)
        ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label Not_found))] ();
      (false, error_response_typed ~code:Validation_error
        (Printf.sprintf "keeper %s is not in the registry" name))
    | Some entry ->
    let phase_before = Keeper_state_machine.phase_to_string entry.phase in
    (* Phase precondition: Overflowed, Paused, or (Running/Failing with force).
       Match on the variant directly so the compiler warns when new phases
       are added — the catch-all wildcard would silently default to [false]. *)
    let allowed =
      match entry.phase with
      | Overflowed | Paused | Compacting -> true
      | Running | Failing -> force
      | Offline | Stopped | Dead | Zombie | Crashed | Restarting | HandingOff | Draining -> false
    in
    if not allowed then begin
      Prometheus.inc_counter Keeper_metrics.(to_string OperatorCompact)
        ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label Precondition))] ();
      (false, error_response_typed ~code:Validation_error
        (Printf.sprintf
           "keeper %s is in phase %s; compaction requires Overflowed, Paused, or force=true"
           name phase_before))
    end
    else begin
      (* Dispatch FSM event *)
      Keeper_exec_context.dispatch_keeper_phase_event
        ~config:ctx.config ~keeper_name:name
        Keeper_state_machine.Operator_compact_requested;
      (* Read meta for checkpoint access *)
      match read_meta_resolved ctx.config name with
      | Ok None | Error _ ->
        (false, Printf.sprintf "keeper %s: meta unavailable for compaction" name)
      | Ok (Some (_resolved, meta)) ->
        let base_dir = Keeper_types.session_base_dir ctx.config in
        let model = Keeper_exec_context.checkpoint_model_of_meta meta in
        let max_tokens = resolve_primary_max_context (Some meta) in
        Keeper_exec_context.dispatch_keeper_phase_event
          ~config:ctx.config ~keeper_name:name
          ~origin:Keeper_registry.Operator_compact
          Keeper_state_machine.Compaction_started;
        match
          Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
            ~base_dir ~meta ~model ~primary_model_max_tokens:max_tokens
        with
        | Some recovery ->
          Keeper_exec_context.dispatch_compaction_completed
            ~config:ctx.config ~keeper_name:name
            ~origin:Keeper_registry.Operator_compact
            ~before_tokens:recovery.compaction.before_tokens
            ~after_tokens:recovery.compaction.after_tokens;
          invalidate_status_cache name;
          Prometheus.inc_counter Keeper_metrics.(to_string OperatorCompact)
            ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label Ok))] ();
          (true,
           Yojson.Safe.to_string
             (`Assoc [
               ("name", `String name);
               ("phase_before", `String phase_before);
               ("phase_after", `String
                  (match Keeper_registry.get ~base_path:ctx.config.base_path name with
                   | Some entry -> Keeper_state_machine.phase_to_string entry.phase
                   | None -> "unknown"));
               ("before_tokens", `Int recovery.compaction.before_tokens);
               ("after_tokens", `Int recovery.compaction.after_tokens);
             ]))
        | None ->
          (* Compaction infrastructure unavailable — emit [Compaction_failed]
             so [context_overflow] stays set and [derive_phase] re-projects
             to Overflowed.  A subsequent [Compact_retry_exhausted] dispatch
             (owned by the retry-loop caller) will latch the keeper to Paused.
             Emitting [Compaction_completed] here would be a false success
             signal. *)
          Keeper_exec_context.dispatch_keeper_phase_event
            ~config:ctx.config ~keeper_name:name
            ~origin:Keeper_registry.Operator_compact
            (Keeper_state_machine.Compaction_failed {
               reason = "no_valid_checkpoint";
            });
          Prometheus.inc_counter Keeper_metrics.(to_string OperatorCompact)
            ~labels:[("keeper", name); ("result", Keeper_operator_compact_result.(to_label No_checkpoint))] ();
          (false,
           Printf.sprintf
             "keeper %s: checkpoint compaction unavailable (no valid checkpoint found)"
             name)
    end

(** Last-resort context clear.

    Drops all conversation messages from the keeper's checkpoint file,
    optionally preserving the system prompt.  Dispatches
    [Operator_clear_requested] to reset overflow-related FSM conditions. *)
let handle_keeper_clear ctx args : tool_result =
  match resolve_keeper_name ctx args with
  | Error err -> (false, err)
  | Ok name ->
    let reason = String.trim (get_string args "reason" "") in
    if String.equal reason "" then
      (false, error_response_typed ~code:Validation_error
        "reason is required for masc_keeper_clear (audit trail)")
    else
    (* Same registry race guard as [handle_keeper_compact]: if the keeper
       disappeared between [resolve_keeper_name] and [get], abort cleanly
       rather than silently proceed with a half-applied clear. *)
    match Keeper_registry.get ~base_path:ctx.config.base_path name with
    | None ->
      (false, error_response_typed ~code:Validation_error
        (Printf.sprintf "keeper %s is not in the registry" name))
    | Some entry ->
      let preserve_system = get_bool args "preserve_system_prompt" true in
      let phase_before = Keeper_state_machine.phase_to_string entry.phase in
      let base_dir = Keeper_types.session_base_dir ctx.config in
      (* Must use the keeper's OWN trace_id to locate its checkpoint file.
         Using generate_trace_id () would create a fresh session dir and
         always report 0 cleared messages, because the existing checkpoint
         lives under meta.runtime.trace_id. *)
      let meta_for_trace =
        match read_meta_resolved ctx.config name with
        | Ok (Some (_, meta)) -> Some meta
        | _ -> None
      in
      let preserve_paused_state =
        (match entry.phase with
         | Keeper_state_machine.Paused -> true
         | _ -> false)
        || Atomic.get entry.fiber_stop
      in
      let trace_id =
        match meta_for_trace with
        | Some meta -> Keeper_id.Trace_id.to_string meta.runtime.trace_id
        | None -> Keeper_exec_context.generate_trace_id ()
      in
      let max_tokens = resolve_primary_max_context meta_for_trace in
      let max_checkpoint_messages =
        match meta_for_trace with
        | Some meta -> meta.compaction.max_checkpoint_messages
        | None -> 100
      in
      let session, ctx_opt =
        Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages
          ~trace_id
          ~primary_model_max_tokens:max_tokens
          ~base_dir
      in
      let checkpoint_found = Option.is_some ctx_opt in
      let cleared_count =
        match ctx_opt with
        | None -> 0
        | Some wctx ->
          let existing_messages = Keeper_exec_context.messages_of_context wctx in
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
                  (Keeper_exec_context.checkpoint_of_context wctx) with
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
               let model = Keeper_exec_context.checkpoint_model_of_meta meta in
               (match
                  Keeper_exec_context.save_oas_checkpoint
                    ~max_checkpoint_messages
                    ~session
                    ~agent_name:meta.agent_name
                    ~model
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
      let continuity_cleared =
        match meta_for_trace with
        | Some meta ->
            let updated_meta =
              {
                meta with
                continuity_summary = "";
                paused = meta.paused || preserve_paused_state;
                updated_at = Keeper_types.now_iso ();
                runtime =
                  {
                    meta.runtime with
                    last_continuity_update_ts = 0.0;
                  };
              }
            in
            (match Keeper_types.write_meta ~force:true ctx.config updated_meta with
             | Ok () -> true
             | Error err ->
                 Log.Keeper.warn
                   "%s: failed to clear continuity meta during operator clear: %s"
                   name err;
                 false)
        | None -> false
      in
      (* Dispatch FSM event to clear overflow conditions *)
      Keeper_exec_context.dispatch_keeper_phase_event
        ~config:ctx.config ~keeper_name:name
        (Keeper_state_machine.Operator_clear_requested { preserve_system; reason });
      (* Clear registry failure state *)
      Keeper_registry.set_failure_reason ~base_path:ctx.config.base_path name None;
      Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path name;
      invalidate_status_cache name;
      Log.Keeper.warn
        "%s: context cleared by operator (reason=%s, preserve_system=%b, cleared=%d msgs)"
        name reason preserve_system cleared_count;
      Prometheus.inc_counter Keeper_metrics.(to_string OperatorClear)
        ~labels:[("keeper", name);
                 ("preserve_system", Bool.to_string preserve_system)] ();
      (true,
       Yojson.Safe.to_string
         (`Assoc [
           ("name", `String name);
           ("phase_before", `String phase_before);
           ("phase_after", `String
              (match Keeper_registry.get ~base_path:ctx.config.base_path name with
               | Some entry -> Keeper_state_machine.phase_to_string entry.phase
               | None -> "unknown"));
           ("cleared_message_count", `Int cleared_count);
           ("checkpoint_found", `Bool checkpoint_found);
           ("continuity_cleared", `Bool continuity_cleared);
           ("preserve_system_prompt", `Bool preserve_system);
           ("reason", `String reason);
         ]))

let dispatch ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_persona_list" -> Some (Persona.handle_persona_list ctx args)
  | "masc_persona_schema" -> Some (Persona.handle_persona_schema ctx args)
  | "masc_persona_generate" -> Some (Persona.handle_persona_generate ctx args)
  | "masc_persona_save" -> Some (Persona.handle_persona_save ctx args)
  | "masc_keeper_create_from_persona" -> Some (handle_keeper_create_from_persona ctx args)
  | "masc_keeper_up" -> Some (handle_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_keeper_msg ctx args)
  | "masc_keeper_msg_result" -> Some (handle_keeper_msg_result ctx args)
  | "masc_keeper_repair" -> Some (handle_keeper_repair ctx args)
  | "masc_keeper_down" -> Some (handle_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_keeper_list ctx args)
  | "masc_keeper_persona_audit" -> Some (handle_keeper_persona_audit ctx args)
  | "masc_keeper_sandbox_status" -> Some (handle_keeper_sandbox_status ctx args)
  | "masc_keeper_sandbox_start" -> Some (handle_keeper_sandbox_start ctx args)
  | "masc_keeper_sandbox_stop" -> Some (handle_keeper_sandbox_stop ctx args)
  | "masc_keeper_reset" -> Some (handle_keeper_reset ctx args)
  | "masc_keeper_compact" -> Some (handle_keeper_compact ctx args)
  | "masc_keeper_clear" -> Some (handle_keeper_clear ctx args)
  | _ -> None

(** Streaming dispatch: only handles keeper_msg with text delta forwarding.
    Returns None for all other tool names.
    Called from server_routes_http_keeper_stream. *)
let dispatch_stream ~on_text_delta ctx ~name ~args : tool_result option =
  maybe_bootstrap_existing_keepalives ctx ~name ~args;
  let ctx = resolve_ctx ctx ~name args in
  match name with
  | "masc_keeper_msg" ->
      Some (handle_keeper_msg_stream ~on_text_delta ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only =
  [ "masc_persona_list"; "masc_persona_schema"; "masc_keeper_list";
    "masc_keeper_status"; "masc_keeper_persona_audit";
    "masc_keeper_sandbox_status" ]

let tool_required_permission = function
  | "masc_persona_list" | "masc_persona_schema" | "masc_keeper_list"
  | "masc_keeper_status" | "masc_keeper_persona_audit"
  | "masc_keeper_sandbox_status" ->
      Some Masc_domain.CanReadState
  | "masc_persona_generate" | "masc_persona_save"
  | "masc_keeper_create_from_persona" | "masc_keeper_up"
  | "masc_keeper_msg" | "masc_keeper_msg_result"
  | "masc_keeper_repair"
  | "masc_keeper_sandbox_start" | "masc_keeper_sandbox_stop"
  | "masc_keeper_down" | "masc_keeper_reset"
  | "masc_keeper_compact" | "masc_keeper_clear" ->
      Some Masc_domain.CanBroadcast
  | _ -> None

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_keeper
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name tool_spec_read_only)
           ~is_idempotent:(List.mem s.name tool_spec_read_only)
           ~is_destructive:(String.equal s.name "masc_keeper_clear")
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
