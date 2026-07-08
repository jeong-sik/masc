(** Keeper_turn -- keeper lifecycle and message-turn handlers.

    Orchestrates keeper turns by building domain-specific system prompt
    configuration and delegating to {!Keeper_agent_run.run_turn} which
    owns the full OAS-backed context lifecycle (checkpoint, prompt state,
    Agent.run).

    Sub-modules:
    - Keeper_turn_up: start/reconfigure
    - Keeper_turn_setup: ensure_keeper_exists
    - Keeper_turn_lifecycle: shutdown *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_alerting
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_setup
open Otel_spans

type tool_result = Keeper_types_profile.tool_result

let handle_keeper_up = Keeper_turn_up.handle_keeper_up
let handle_keeper_down = Keeper_turn_lifecycle.handle_keeper_down

let turn_cost_for_result (result : Keeper_agent_run.run_result) : float =
  (* cost_usd is accounted independently of token-count trust (token⊥cost). The
     provider's authoritative cost field is used directly; missing/non-positive
     cost remains 0.0. *)
  Keeper_unified_metrics.estimate_usage_cost_usd result.usage

let update_direct_turn_meta (meta : keeper_meta) ~(latency_ms : int)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let turn_cost = turn_cost_for_result result in
  let usage_trust =
    Keeper_unified_metrics.classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~context_max:0
  in
  let usage_trusted =
    Keeper_unified_metrics.usage_trust_is_trusted usage_trust
  in
  let trusted_input_tokens =
    if usage_trusted then result.usage.input_tokens else 0
  in
  let trusted_output_tokens =
    if usage_trusted then result.usage.output_tokens else 0
  in
  let trusted_total_tokens =
    if usage_trusted then Keeper_context_runtime.total_tokens result.usage else 0
  in
  let updated_meta = {
    meta with
    updated_at = now_iso ();
    runtime =
      {
        meta.runtime with
        usage =
          {
            total_turns = meta.runtime.usage.total_turns + 1;
            total_input_tokens =
              meta.runtime.usage.total_input_tokens + trusted_input_tokens;
            total_output_tokens =
              meta.runtime.usage.total_output_tokens + trusted_output_tokens;
            total_tokens =
              meta.runtime.usage.total_tokens + trusted_total_tokens;
            total_cost_usd = meta.runtime.usage.total_cost_usd +. turn_cost;
            last_turn_ts = now_ts;
            last_input_tokens = trusted_input_tokens;
            last_output_tokens = trusted_output_tokens;
            last_total_tokens = trusted_total_tokens;
            last_latency_ms = latency_ms;
          };
      };
  } in
  Keeper_unified_metrics.record_keeper_total_cost_usd
    ~keeper_name:updated_meta.name
    ~total_cost_usd:updated_meta.runtime.usage.total_cost_usd;
  updated_meta

let has_no_progress_loop_blocker (meta : keeper_meta) =
  match meta.runtime.last_blocker with
  | Some { klass = No_progress_loop; _ } -> true
  | Some
      { klass =
          ( Runtime_exhausted _
          | Capacity_backpressure
          | Ambiguous_post_commit_timeout
          | Ambiguous_post_commit_failure
          | Admission_queue_wait_timeout
          | Turn_timeout_after_queue_wait
          | Turn_timeout
          | Turn_livelock_blocked
          | Completion_contract_violation
          | Fiber_unresolved
          | Stale_turn_timeout
          | Stale_fleet_batch
          | Oas_agent_execution_timeout
          | Sdk_max_turns_exceeded
          | Sdk_token_budget_exceeded
          | Sdk_cost_budget_exceeded
          | Sdk_unrecognized_stop_reason
          | Sdk_idle_detected
          | Sdk_guardrail_violation
          | Sdk_tripwire_violation
          | Sdk_exit_condition_met
          | Sdk_input_required )
      ; _
      } ->
    false
  | None -> false

let is_no_progress_failure_reason = function
  | Some (Keeper_registry.Provider_runtime_error { code; _ }) ->
    String.equal code Keeper_unified_turn_no_progress.failure_reason_code
  | Some
      ( Keeper_registry.Heartbeat_consecutive_failures _
      | Keeper_registry.Turn_consecutive_failures _
      | Keeper_registry.Stale_turn_timeout _
      | Keeper_registry.Stale_termination_storm _
      | Keeper_registry.Stale_fleet_batch _
      | Keeper_registry.Provider_timeout_loop _
      | Keeper_registry.Completion_contract_violation _
      | Keeper_registry.Ambiguous_partial_commit _
      | Keeper_registry.Fiber_unresolved _
      | Keeper_registry.Exception _
      | Keeper_registry.Turn_overflow_pause
      | Keeper_registry.Turn_livelock_pause ) ->
    false
  | None -> false

let has_no_progress_failure_reason ~base_path keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some { Keeper_registry.last_failure_reason; _ } ->
    is_no_progress_failure_reason last_failure_reason
  | None -> false

let has_direct_success_no_progress_pause ~(config : Workspace.config)
    (meta : keeper_meta) =
  (* RFC-0303 Phase 3: the no-progress loop detector is retired; a residual
     no-progress pause is now recognised only from persisted meta blocker or
     registry failure_reason (no live detector latch). *)
  meta.paused
  && (has_no_progress_loop_blocker meta
      || has_no_progress_failure_reason ~base_path:config.base_path meta.name)

let clear_no_progress_meta_blocker (meta : keeper_meta) =
  match meta.runtime.last_blocker with
  | Some { Keeper_meta_contract.klass = Keeper_meta_contract.No_progress_loop; _ } ->
    Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  | _ -> meta

let persist_direct_success_no_progress_resume ~base_path (resumed_meta : keeper_meta) =
  match
    Keeper_registry.update_entry
      ~base_path
      resumed_meta.name
      (fun entry ->
        let last_failure_reason =
          if is_no_progress_failure_reason entry.last_failure_reason
          then None
          else entry.last_failure_reason
        in
        { entry with
          meta = resumed_meta
        ; last_failure_reason
        ; turn_consecutive_failures = 0
        })
  with
  | Ok () -> Ok ()
  | Error err ->
    Log.Keeper.warn
      "%s: direct keeper_msg success could not persist no_progress resume state: %s"
      resumed_meta.name
      (Keeper_registry.registry_entry_validation_error_to_string err);
    Error err

let direct_success_disposition_allows_no_progress_resume
      (result : Keeper_agent_run.run_result)
  : bool
  =
  match result.operator_disposition with
  | Some
      { disposition = Keeper_execution_receipt.Disp_pass
      ; reason = Keeper_execution_receipt.Reason_healthy
      } -> true
  | Some _ | None -> false

let direct_success_tool_call_has_progress
      (detail : Keeper_agent_run.tool_call_detail)
  : bool
  =
  match detail.typed_outcome with
  | Some Keeper_tool_outcome.Progress -> (
    match Keeper_tool_progress.classify_tool_progress detail.tool_name with
    | Keeper_tool_progress.Passive_status -> false
    | Keeper_tool_progress.Claim_context
    | Keeper_tool_progress.Execution
    | Keeper_tool_progress.Completion -> true)
  | Some (Keeper_tool_outcome.No_progress _ | Keeper_tool_outcome.Error _)
  | None -> false

let direct_success_has_progress_evidence (result : Keeper_agent_run.run_result) :
    bool
  =
  List.exists direct_success_tool_call_has_progress result.tool_calls
  || Option.is_some (Keeper_unified_metrics_support.visible_run_validation result)

let direct_success_may_clear_no_progress_pause
      (result : Keeper_agent_run.run_result)
  : bool
  =
  direct_success_disposition_allows_no_progress_resume result
  && direct_success_has_progress_evidence result

let clear_direct_success_no_progress_pause
      ~(config : Workspace.config)
      ~(pre_turn_meta : keeper_meta)
      ~(result : Keeper_agent_run.run_result)
      (meta : keeper_meta)
  : keeper_meta
  =
  if not (has_direct_success_no_progress_pause ~config pre_turn_meta)
  then meta
  else if not (direct_success_may_clear_no_progress_pause result)
  then (
    Log.Keeper.info
      "%s: direct keeper_msg success kept no_progress pause/blocker because \
       result lacked healthy operator disposition or typed resume evidence"
      meta.name;
    meta)
  else
    let cleared_meta = clear_no_progress_meta_blocker meta in
    let resumed_meta =
      { cleared_meta with
        paused = false
      ; auto_resume_after_sec = None
      ; latched_reason = None
      ; updated_at = now_iso ()
      }
    in
    match
      persist_direct_success_no_progress_resume
        ~base_path:config.base_path
        resumed_meta
    with
    | Error _ -> meta
    | Ok () ->
      (match
         Keeper_registry.dispatch_event_and_log
           ~base_path:config.base_path
           meta.name
           Keeper_state_machine.Operator_resume
       with
       | Error err ->
         Log.Keeper.warn
           "%s: direct keeper_msg success could not dispatch Operator_resume after persisted no_progress recovery: %s"
           meta.name
           (Keeper_state_machine.transition_error_to_string err)
       | Ok _ -> ());
      Keeper_turn_livelock.reset_keeper_livelock
        ~base_path:config.base_path
        ~keeper:resumed_meta.name;
      Keeper_livelock_state.reset_for_keeper ~keeper:resumed_meta.name;
      Log.Keeper.info
        "%s: direct keeper_msg success cleared no_progress pause/blocker"
        resumed_meta.name;
      resumed_meta

let direct_turn_observation ~(config : Workspace.config) (meta : keeper_meta) :
    Keeper_world_observation.world_observation =
  Keeper_world_observation.observe_direct_keeper_msg
    ~config
    ~meta

let direct_owner_conversation_context
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(direct_reply : bool)
      ~(channel_session_key : string option)
      ~(channel : string)
  : string
  =
  if (not direct_reply) || Option.is_some channel_session_key || String.trim channel <> ""
  then ""
  else
    Keeper_world_observation_message_scope.collect_recent_direct_conversation
      ~limit:8 ~config ~meta ()
    |> Keeper_world_observation_message_scope.render_recent_direct_conversation_context

(* Flatten newlines/tabs to spaces and trim, so a co-view value never breaks
   the line-oriented instruction block. *)
let normalized_surface_context_value value =
  value
  |> String.to_seq
  |> Seq.map (function '\n' | '\r' | '\t' -> ' ' | ch -> ch)
  |> String.of_seq
  |> String.trim

let surface_context_field_value = function
  | `String s -> normalized_surface_context_value s
  | json -> Yojson.Safe.to_string json

(* Accept fields as BOTH the dashboard wire shape [`List of {k,v} objects] and a
   plain [`Assoc] map. The earlier keeper_turn copy matched only `Assoc and
   silently dropped the dashboard's list shape on the MCP tool path. *)
let surface_context_fields fields_json =
  let lines =
    match fields_json with
    | `List items ->
        List.filter_map
          (function
            | `Assoc fields -> (
                match
                  (List.assoc_opt "k" fields, List.assoc_opt "v" fields)
                with
                | Some (`String k), Some v ->
                    let k = normalized_surface_context_value k in
                    if k = "" then None
                    else
                      Some
                        (Printf.sprintf "  - %s: %s" k
                           (surface_context_field_value v))
                | _ -> None)
            | _ -> None)
          items
    | `Assoc pairs ->
        List.filter_map
          (fun (k, v) ->
            let k = normalized_surface_context_value k in
            if k = "" then None
            else
              Some
                (Printf.sprintf "  - %s: %s" k (surface_context_field_value v)))
          pairs
    | _ -> []
  in
  if lines = [] then None else Some (String.concat "\n" lines)

(* Single SSOT formatter for dashboard co-view context
   ({label,route,scene,fields}). Shared by the HTTP copilot route
   ([Server_routes_http_keeper_stream]) and the masc_keeper_msg MCP tool path,
   so the two surfaces cannot drift. *)
let surface_context_to_instructions (ctx : Yojson.Safe.t) : string option =
  match ctx with
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) ->
            let s = normalized_surface_context_value s in
            if s = "" then None else Some s
        | _ -> None
      in
      let fields_block =
        match List.assoc_opt "fields" fields with
        | Some fields_json -> surface_context_fields fields_json
        | None -> None
      in
      let lines =
        List.filter_map
          (fun (name, value_opt) ->
            Option.map (fun v -> Printf.sprintf "%s: %s" name v) value_opt)
          [
            ("Surface label", get_string "label");
            ("Route", get_string "route");
            ("Scene", get_string "scene");
          ]
      in
      let lines =
        match fields_block with
        | Some block -> lines @ [ "Fields:"; block ]
        | None -> lines
      in
      if lines = [] then None
      else Some (String.concat "\n" ("[Co-view context]" :: lines))
  | json ->
      Some
        (Printf.sprintf "[Co-view context]\n%s"
           (Yojson.Safe.pretty_to_string json))

module For_testing = struct
  let direct_owner_conversation_context = direct_owner_conversation_context
  let surface_context_to_instructions = surface_context_to_instructions
  let direct_success_may_clear_no_progress_pause =
    direct_success_may_clear_no_progress_pause
  let clear_direct_success_no_progress_pause =
    clear_direct_success_no_progress_pause
  let direct_no_progress_retry_reason =
    Keeper_turn_runtime_budget.direct_no_progress_retry_reason
  let direct_no_progress_retry_decision =
    Keeper_turn_runtime_budget.direct_no_progress_retry_decision
  let run_direct_no_progress_retry_loop =
    Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
end

let resolve_turn_runtime_id (meta : keeper_meta) =
  let runtime_id = String.trim (Keeper_meta_contract.runtime_id_of_meta meta) in
  if runtime_id = "" then
    Error (Printf.sprintf "invalid runtime_id for keeper %s: empty" meta.name)
  else
    Ok runtime_id

let keeper_msg_timeout_override args =
  match get_float_opt args "timeout_sec" with
  | None -> Ok None
  | Some timeout_sec
    when Float.is_finite timeout_sec && timeout_sec > 0.0 ->
      Ok (Some timeout_sec)
  | Some _ -> Error "timeout_sec must be a positive finite number"

let user_oas_blocks_of_args args =
  match Keeper_multimodal_input.parse_user_blocks args with
  | Error err -> Error err
  | Ok [] -> Ok None
  | Ok user_blocks ->
      let attachments = Keeper_multimodal_input.parse_attachments args in
      match Keeper_multimodal_input.to_oas_blocks ~attachments user_blocks with
      | Error err -> Error err
      | Ok [] -> Ok None
      | Ok blocks -> Ok (Some blocks)

let preflight_keeper_msg ctx args : (unit, string) result =
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    Error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         name)
  else if message = "" then
    Error "message is required"
  else
    let direct_reply = get_bool args "direct_reply" false in
    match keeper_msg_timeout_override args with
    | Error e -> Error e
    | Ok _ ->
    (match Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_msg" args with
    | Error e -> Error e
    | Ok () ->
    (match reject_removed_keeper_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> Error e
    | Ok () ->
    (match reject_removed_keeper_msg_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> Error e
    | Ok () ->
    (match user_oas_blocks_of_args args with
    | Error e -> Error e
    | Ok _ ->
    match ensure_keeper_exists ~ctx ~name with
    | Error e -> Error e
    | Ok meta ->
      match resolve_turn_runtime_id meta with
      | Error e -> Error e
      | Ok turn_runtime_id ->
        let effective_models =
          if direct_reply then
            Provider_runtime_projection.default_execution_model_strings
              (                 (turn_runtime_id))
          else
            effective_model_labels_for_turn meta
        in
        match Keeper_types_support.ensure_api_keys_for_labels effective_models with
        | Error e -> Error e
        | Ok () ->
          Keeper_turn_helpers.ensure_local_discovery_ready effective_models))))

(* -- Direct-message turn FSM wrapper ---------------------------------------- *)

(** Run a direct [masc_keeper_msg] turn with the same typed FSM transitions
    emitted by the autonomous [Keeper_unified_turn.run_keeper_cycle] path.

    Direct turns historically called [Keeper_agent_run.run_turn] directly,
    which left them invisible to [Keeper_turn_fsm] telemetry and violated
    the SSOT contract audited in
    [docs/audit/2026-06-13-masc-fsm-drift-audit.md] (finding #3).  This
    wrapper emits the canonical start sequence
    [Idle -> Phase_gating -> Runtime_routing -> Awaiting_provider -> Streaming]
    before invoking [f], then records the matching terminal state
    ([Done], [Failed], or [Cancelled]) from the result or exception.

    The wrapper is intentionally thin: it does not duplicate metrics,
    receipt, or meta writes — those remain in
    [run_keeper_msg_turn_admitted].  It only restores FSM observability so
    direct and autonomous turns share the same state-machine read model. *)
let run_direct_turn_with_fsm ~(keeper_name : string) ~(turn_id : int) f =
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Phase_gating
    Keeper_turn_fsm.Runtime_routing;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Runtime_routing
    Keeper_turn_fsm.Awaiting_provider;
  Keeper_turn_fsm.emit_transition
    ~keeper_name
    ~turn_id
    ~prev:Keeper_turn_fsm.Awaiting_provider
    Keeper_turn_fsm.Streaming;
  try
    let result = f () in
    (match result with
     | Ok _ ->
       Keeper_turn_fsm.emit_transition
         ~keeper_name
         ~turn_id
         ~prev:Keeper_turn_fsm.Streaming
         Keeper_turn_fsm.Completing;
       Keeper_turn_fsm.emit_transition
         ~keeper_name
         ~turn_id
         ~prev:Keeper_turn_fsm.Completing
         Keeper_turn_fsm.Done
     | Error err ->
       let reason =
         Keeper_turn_fsm.Failure_provider_error
           { kind = Keeper_agent_error.sdk_error_kind err
           ; detail = Agent_sdk.Error.to_string err
           }
       in
       Keeper_turn_fsm.emit_transition
         ~keeper_name
         ~turn_id
         ~prev:Keeper_turn_fsm.Streaming
         (Keeper_turn_fsm.Failed reason));
    result
  with
  | Eio.Cancel.Cancelled _ as e ->
    (* Cooperative cancellation must be preserved and reflected as a
       terminal [Cancelled] state, not swallowed as a successful completion.
       See [KeeperTurnFSM.tla] [HonorStopSignal] and the audit finding #5. *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name
      ~turn_id
      ~prev:Keeper_turn_fsm.Streaming
      (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop);
    raise e
  | exn ->
    Keeper_turn_fsm.emit_transition
      ~keeper_name
      ~turn_id
      ~prev:Keeper_turn_fsm.Streaming
      (Keeper_turn_fsm.Failed
         (Keeper_turn_fsm.Failure_unexpected_exception
            { exn = Printexc.to_string exn; backtrace = None }));
    raise exn

(* -- handle_keeper_msg: orchestrator ---------------------------------------- *)

(* Body of [handle_keeper_msg], runnable only while holding the keeper's
   turn slot ([Keeper_turn_admission]). Covers [Keeper_agent_run.run_turn]
   AND the post-turn meta/lifecycle writes — both must stay inside the slot
   or a concurrent turn can clobber the checkpoint and regress
   [total_turns] (2026-06-10 RCA, RFC-0225 §1).

   Precondition: the caller holds the keeper's turn slot, OR the call
   returns before any keeper-state read/write (the invalid-name path in
   [handle_keeper_msg] calls this directly because the validation guard
   below exits first). Do not add keeper-state mutation ahead of the
   validation guards without moving it behind the slot. *)
let run_keeper_msg_turn_admitted ?on_text_delta ?on_event ?event_bus ctx args : tool_result =
  with_span
    ~name:"keeper_turn"
    ~attrs:[
      "keeper.name", `String (get_string args "name" "");
      "masc.turn_type", `String "direct";
    ]
    (fun _trace_id ->
  let on_event =
    match on_event with
    | Some cb -> Some cb
    | None ->
        (match on_text_delta with
         | None -> None
         | Some cb -> Some (fun (evt : Agent_sdk.Types.sse_event) ->
             match evt with
             | Agent_sdk.Types.ContentBlockDelta { delta = TextDelta text; _ } -> cb text
             | _ -> ()))
  in
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         name)
  else if message = "" then
    tool_result_error "message is required"
  else
    let turn_instructions =
      match get_string_opt args "turn_instructions" with
      | Some _ as ti -> ti
      | None -> (
          match args with
          | `Assoc fields -> (
              match List.assoc_opt "surface_context" fields with
              | Some ctx -> surface_context_to_instructions ctx
              | None -> None)
          | _ -> None)
    in
    let no_skill_route = get_bool args "no_skill_route" false in
    let no_state_block = get_bool args "no_state_block" false in
    let direct_reply = get_bool args "direct_reply" false in
    let channel_session_key = get_string_opt args "channel_session_key" in
    let channel = get_string args "channel" "" in
    (* RFC-0320 W2b: recover the typed continuation channel serialized into the
       tool args at dispatch (Keeper_continuation_channel codec). A missing or
       unparseable value is fail-closed to [None] (downstream [Unrouted]); the
       flat [channel] string above cannot be reconstructed into the typed
       variant without a lossy string classifier, so provenance rides its own
       lossless field instead. *)
    let continuation_channel =
      match Json_util.assoc_member_opt "continuation_channel" args with
      | Some json ->
        (match Keeper_continuation_channel.of_yojson json with
         | Ok c -> Some c
         | Error _ -> None)
      | None -> None
    in
    (match keeper_msg_timeout_override args with
    | Error e -> tool_result_error e
    | Ok keeper_msg_oas_timeout_s ->
    (match Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_msg" args with
    | Error e -> tool_result_error ("" ^ e)
    | Ok () ->
    (match reject_removed_keeper_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> tool_result_error ("" ^ e)
    | Ok () ->
    (match reject_removed_keeper_msg_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> tool_result_error ("" ^ e)
    | Ok () ->
    (match user_oas_blocks_of_args args with
    | Error e -> tool_result_error ("" ^ e)
    | Ok user_blocks ->
    match ensure_keeper_exists
      ~ctx ~name
    with
    | Error e -> tool_result_error ("" ^ e)
    | Ok meta0 ->
      (* RFC vision-delegation §2.3 site 1 (fresh input). For a Delegate keeper,
         evict each image to the artifact store + an eager analyze_image reading
         BEFORE it enters the turn, so the main history stays text-only and
         RFC-0265 never recomputes required=['image'] from it. No-op for
         Inherit/Reroute keepers (safe-by-default). *)
      let user_blocks =
        Option.map
          (Keeper_vision_ingest.evict_blocks
             ~mode:Keeper_vision_ingest.Eager
             ~policy:meta0.multimodal_policy
             ~keeper_name:meta0.name)
          user_blocks
      in
      let turn_task_id = Printf.sprintf "keeper_turn_%s_%d"
        name (int_of_float (Time_compat.now () *. 1000.0)) in
      let keeper_turn_id = meta0.runtime.usage.total_turns + 1 in
      (* RFC-0233 §7: mint the turn's join key ONCE from the pre-turn meta0 —
         the same (trace_id, total_turns + 1) snapshot the Turn_record writer
         stamps (keeper_agent_run.ml:250-251 receives this very meta via the
         run_turn call below). Threaded into reply_json; never re-derived at
         the reply seam from updated_meta, whose trace_id is post-lifecycle and
         is rotated on handoff turns (keeper_rollover) — re-derivation would
         yield a different join key than the Turn_record for the same turn
         (RFC §7.2 mint-once, thread down). *)
      let turn_ref =
        Ids.Turn_ref.make
          ~trace_id:(Keeper_id.Trace_id.to_string meta0.runtime.trace_id)
          ~absolute_turn:keeper_turn_id
      in
      let turn_tracker = Progress.start_tracking ~task_id:turn_task_id ~total_steps:5 () in
      Progress.Tracker.step turn_tracker ~message:"Preparing keeper turn configuration" ();
      let meta = meta0 in
      match resolve_turn_runtime_id meta with
      | Error e ->
        Progress.stop_tracking turn_task_id;
        tool_result_error ("" ^ e)
      | Ok turn_runtime_id ->
      (* start_keepalive is deferred AFTER run_turn completes.
         Starting it here causes the heartbeat fiber to immediately grab LLM
         slots, starving the synchronous run_turn call (Issue #2610). *)
      (* auto execution session interception removed in #2908 *)
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Workspace.masc_root_dir ctx.config in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~generation:meta.runtime.generation ()
      in
      let effective_models =
        if direct_reply then
          Provider_runtime_projection.default_execution_model_strings
            turn_runtime_id
        else
          effective_model_labels_for_turn meta
      in
      Progress.Tracker.step turn_tracker ~message:"Validating API keys" ();
      (match Keeper_types_support.ensure_api_keys_for_labels effective_models with
       | Error e ->
         Progress.stop_tracking turn_task_id;
         tool_result_error ("" ^ e)
       | Ok () ->
         Progress.Tracker.step turn_tracker ~message:"Building turn prompt" ();
         (match Keeper_turn_helpers.ensure_local_discovery_ready effective_models with
          | Error e ->
            Progress.stop_tracking turn_task_id;
            tool_result_error ("" ^ e)
	      | Ok () ->
	            let max_runtime_context =
	              let resolution =
	                Keeper_context_runtime.resolve_max_context_resolution
	                  ~requested_override:meta.max_context_override effective_models
              in
            (match resolution.requested_override with
            | Some requested ->
              Log.Keeper.debug
                "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d (manual turn)"
                meta.name requested resolution.turn_budget resolution.primary_budget
                resolution.effective_budget
	            | None -> ());
	              resolution.effective_budget
	            in
		            let profile_defaults =
		              Keeper_types_profile.load_keeper_profile_defaults meta.name
		            in
            let base_dir =
              let root = session_base_dir ctx.config in
              match channel_session_key with
              | Some key when direct_reply ->
                let d = Filename.concat (Filename.concat root "channels") key in
                let (_ : string) = Keeper_fs.ensure_dir d in
                d
              | _ -> root
            in
            let effective_no_skill_route = no_skill_route || direct_reply in
            let effective_no_state_block = no_state_block || direct_reply in
            let fallback_skill_route =
              route_keeper_skill  ~message
            in
            let live_worktree_change = None in
            let build_turn_prompt ~base_system_prompt ~messages
                : Keeper_agent_run.turn_prompt =
              (* === SOFT CONTEXT (injected via extra_system_context) === *)
              (* 1. Recovery + tiered memory context *)
              let continuity_snapshot = latest_state_snapshot_from_messages messages in
              let progress_cache =
                Keeper_memory_policy.read_progress_snapshot_cache
                  ~config:ctx.config ~name:meta.name
              in
              let recovery_snapshot, recovery_generation, recovery_source =
                match
                  progress_cache
                with
                | Some cache ->
                    (Some cache.snapshot, cache.generation, "progress_log")
                | None ->
                    (match continuity_snapshot with
                     | Some snapshot -> (Some snapshot, Some meta.runtime.generation, "checkpoint")
                     | None ->
                         (match
                            Keeper_memory_policy.state_snapshot_of_summary_text
                              meta.continuity_summary
                          with
                          | Some snapshot ->
                              (Some snapshot, None, "meta_summary")
                          | None -> (None, None, "none")))
              in
              let continuity_text =
                let recovery_sections =
                  match recovery_snapshot with
                  | None -> []
                  | Some snapshot ->
                      Keeper_memory_policy.prompt_memory_sections_of_snapshot
                        ~current_generation:meta.runtime.generation
                        ?source_generation:recovery_generation
                        snapshot
                in
                (* RFC-0149 §3.1 — route through typed Result resolver
                   so a memory bank IO fault is rendered as an explicit
                   [unavailable] marker in the prompt context instead of
                   collapsing into an empty block indistinguishable from
                   "no long-term notes recorded". *)
                let durable_text =
                  (* RFC keeper-memory-consolidation Stage 1: memory_bank long-term
                     inject를 kill-switch 뒤로 둔다. off 시 Memory OS facts
                     (keeper_run_tools_hooks.render_if_enabled, default-ON) 단독
                     주입이 되어 durable 기억의 double-coverage를 제거한다.
                     continuity 복구는 .memory.jsonl이 아니라 snapshot cache
                     (read_progress_snapshot_cache, :533-553) 경유라 무영향. *)
                  if not (Keeper_memory_bank_env.bank_longterm_inject_enabled ())
                  then ""
                  else
                  match
                    read_recent_memory_texts_result ctx.config
                      ~name:meta.name
                      ~horizon:Keeper_memory_policy.long_term_horizon
                      ~max_bytes:(128 * 1024)
                      ~max_lines:200
                      ~limit:3
                  with
                  | Ok [] -> ""
                  | Ok items ->
                      let safe_items =
                        List.filter_map
                          (fun s ->
                             match
                               Keeper_run_prompt.safe_memory_fragment
                                 (String.trim s)
                             with
                             | Some frag -> Some frag
                             | None ->
                                 Log.Keeper.warn
                                   "dropped long-term memory fragment containing \
                                    prompt-injection pattern";
                                 None)
                          items
                      in
                      if safe_items = []
                      then ""
                      else
                        "Long-term memory:\n- " ^ String.concat "\n- " safe_items
                  | Error exn_class ->
                      Printf.sprintf
                        "Long-term memory: [unavailable: %s]"
                        (Keeper_memory_recall_exn_class.to_label exn_class)
                in
                let recovery_fallback =
                  if recovery_sections <> [] then []
                  else
                    let summary =
                      match continuity_snapshot with
                      | Some s -> keeper_state_snapshot_to_summary_text s
                      | None ->
                          continuity_fallback_summary_text
                            ~continuity_summary:meta.continuity_summary
                            ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
                    in
                    if summary = "" || summary = "No continuity snapshot available."
                    then []
                    else [ summary ]
                in
                let blocks =
                  (if recovery_sections = [] then recovery_fallback else recovery_sections)
                  @ (if String.trim durable_text = "" then [] else [ durable_text ])
                in
                match blocks with
                | [] -> ""
                | _ ->
                    Printf.sprintf
                      "Recent continuity snapshot (%s):\n%s"
                      recovery_source
                      (String.concat "\n\n" blocks)
              in
              let recent_direct_conversation_text =
                direct_owner_conversation_context
                  ~config:ctx.config ~meta ~direct_reply ~channel_session_key
                  ~channel
              in
              (* 2. Skill route *)
              let skill_route_text =
                if effective_no_skill_route then ""
                else
                  skill_route_context_text
                    ~fallback_route:fallback_skill_route
                    
              in
              (* 3. Worktree changes *)
              let worktree_text =
                match live_worktree_change with
                | Some summary when String.trim summary <> "" -> summary
                | _ -> ""
              in
              (* 4. Turn instructions *)
              let turn_instructions_text =
                match turn_instructions with
                | None -> ""
                | Some ti ->
                  "--- Turn-specific instructions ---\n" ^ ti
              in
              let telemetry_feedback_text =
                match meta.telemetry_feedback_enabled with
                | Some true ->
                  let window_hours =
                    match meta.telemetry_feedback_window_hours with
                    | Some n when n > 0 -> min n 168
                    | _ -> 24
                  in
                  let window_minutes = window_hours * 60 in
                  (* compute reads JSONL via Eio (Fs_compat.fold_jsonl_lines),
                     a cancellation point, so a bare catch-all here would
                     swallow [Eio.Cancel.Cancelled] and let a cancelled turn
                     keep building its prompt. Route through the RFC-0106 SSOT
                     combinator, which re-raises Cancelled and recovers others
                     (matches the trajectory-finalize handlers below). *)
                  Cancel_safe.protect
                    ~on_exn:(fun exn ->
                      Log.Keeper.warn
                        "%s: telemetry feedback render failed: %s"
                        meta.name (Printexc.to_string exn);
                      "")
                    (fun () ->
                      Model_inference_metrics.compute
                        ~base_path:ctx.config.base_path
                        ~window_minutes
                      |> Model_inference_metrics.render_keeper_prompt_feedback)
                | Some false | None -> ""
              in
              let soft_parts = List.filter
                (fun s -> String.trim s <> "")
                [ continuity_text;
                  recent_direct_conversation_text;
                  skill_route_text;
                  worktree_text;
                  telemetry_feedback_text;
                  turn_instructions_text ]
              in
              let dynamic_context = String.concat "\n\n" soft_parts in
              (* === HARD CONSTRAINTS (stay in system_prompt) === *)
              (* 1. Direct reply mode *)
              let prompt =
                if direct_reply then
                  Keeper_prompt.append_direct_reply_mode_prompt
                    ~base_prompt:base_system_prompt
                else
                  base_system_prompt
              in
              (* 2. Policy guards + tool-use guidance *)
              let prompt =
                let policy_guards = [
                  (effective_no_skill_route,
                   "Output guard: NEVER output lines starting with SKILL: or SKILL_REASON:.");
                  (effective_no_state_block,
                   Keeper_prompt.state_block_output_guard_text);
                ] in
                let policy_lines =
                  List.filter_map
                    (fun (active, line) -> if active then Some line else None)
                    policy_guards
                in
                let tool_use_lines = [
                  "Tool-use guidance:";
                  "- If the user asks you to speak, use voice, make sound, or output TTS, prefer keeper_voice_session_start and keeper_voice_speak.";
                  "- Voice sessions are turn-based: operator speech arrives as transcribed text through normal keeper turns; do not wait for a live duplex audio stream.";
                  "- Do not simulate spoken audio with plain text roleplay when a voice tool can handle the request.";
                  "- If voice execution fails, say that voice output is unavailable and continue in text.";
                ] in
                match policy_lines @ tool_use_lines with
                | [] -> prompt
                | _ ->
                    Printf.sprintf "%s\n\n%s"
                      prompt
                      (String.concat "\n" (policy_lines @ tool_use_lines))
              in
              { system_prompt = prompt; dynamic_context }
            in
            Progress.Tracker.step turn_tracker
              ~message:(Printf.sprintf "Executing Agent.run for %s" name) ();
            let world_observation = direct_turn_observation ~config:ctx.config meta in
            let turn_affordances =
              Keeper_unified_metrics.observed_affordances_of_observation
                ~meta
                world_observation
            in
            (* RFC-0225 §3.3: per-run carrier for the chat lane. *)
	            let turn_ctx_cell = Keeper_tool_call_log.create_turn_ctx_cell () in
	            let direct_history_messages =
	              let (_session, ctx_opt) =
	                Keeper_context_runtime.load_context_from_checkpoint
	                  ~max_checkpoint_messages:
	                    meta.compaction.max_checkpoint_messages
	                  ~trace_id:
	                    (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
	                  ~primary_model_max_tokens:max_runtime_context
	                  ~base_dir
	              in
	              match ctx_opt with
	              | None -> []
	              | Some ctx ->
	                Keeper_context_runtime.messages_of_context ctx
	                |> Keeper_context_core.repair_broken_tool_call_pairs
	            in
	            let direct_base_system_prompt =
	              Keeper_run_context.build_base_system_prompt
	                ~config:ctx.config
	                ~profile_defaults
	                ~meta
	            in
	            let direct_prompt_for_estimate =
	              build_turn_prompt
	                ~base_system_prompt:direct_base_system_prompt
	                ~messages:direct_history_messages
	            in
	            let direct_dynamic_context =
	              Keeper_run_prompt.dynamic_context_with_recent_failures
	                ~keeper_name:meta.name
	                direct_prompt_for_estimate.dynamic_context
	            in
	            let direct_user_message_for_estimate =
	              Keeper_run_prompt.sanitize_user_message message
	            in
	            let direct_prompt_metrics =
	              Keeper_agent_run.build_prompt_metrics
	                ~system_prompt:direct_prompt_for_estimate.system_prompt
	                ~dynamic_context:direct_dynamic_context
	                ~user_message:direct_user_message_for_estimate
	            in
	            let direct_prompt_estimated_input_tokens =
	              Keeper_run_prompt.estimate_input_tokens
	                ~prompt_metrics:direct_prompt_metrics
	                ~system_prompt:direct_prompt_for_estimate.system_prompt
	                ~dynamic_context:direct_dynamic_context
	                ~memory_context:""
	                ~temporal_context:""
	                ~user_message:direct_user_message_for_estimate
	                ~history_messages:direct_history_messages
	            in
	            let run_result, latency_ms =
	              Keeper_context_runtime.timed (fun () ->
	                  match Eio_context.get_clock () with
	                  | Error msg -> Error (Agent_sdk.Error.Internal msg)
	                  | Ok clock ->
	                  let { Keeper_unified_turn_retry_setup.timeout_sec
	                      ; remaining_turn_budget_s
	                      ; current_turn_phase_elapsed_ms
	                      ; max_idle_turns
	                      ; _
	                      }
	                    =
	                    Keeper_unified_turn_retry_setup.build
	                      ~now:(fun () -> Eio.Time.now clock)
	                      ~keeper_name:meta.name
	                      ~channel:Keeper_world_observation.Reactive
	                      ~turn_affordances
	                  in
	                  let publish_direct_cascade_resolution
	                      ~runtime_id
	                      ~decision
	                      ~reason
	                      ~next_runtime
	                      ~attempt
	                      err =
	                    Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
	                      ~keeper_name:meta.name
	                      ~runtime_id
	                      ~decision
	                      ~reason
	                      ~next_runtime
	                      ~attempt
	                      ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
	                      ~error_message:(Some (Agent_sdk.Error.to_string err))
	                  in
	                  let setup_direct_retry_runtime runtime_id =
	                    Keeper_unified_turn_pre_dispatch.build_runtime_execution
	                      ~meta
	                      ~profile_defaults
	                      ~runtime_id
	                  in

		                  run_direct_turn_with_fsm
		                    ~keeper_name:meta.name
		                    ~turn_id:keeper_turn_id
		                    (fun () ->
		                       Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
		                         ~keeper_name:meta.name
		                         ~base_runtime:turn_runtime_id
		                         ~initial_runtime:turn_runtime_id
		                         ~initial_max_context:max_runtime_context
		                         ~estimated_input_tokens:
		                           direct_prompt_estimated_input_tokens
		                         ~timeout_sec
		                         ~remaining_turn_budget_s
		                         ~current_turn_phase_elapsed_ms
		                         ~now_s:(fun () -> Eio.Time.now clock)
		                         ~setup_retry_runtime:setup_direct_retry_runtime
		                         ~publish_cascade_resolution:
		                           publish_direct_cascade_resolution
		                         ~emit_runtime_selected:
		                           (fun ~runtime_id ~fallback_reason ->
		                              Keeper_metrics.emit_runtime_selected
		                                ~keeper_name:meta.name
		                                ~runtime_id
		                                ~fallback_reason)
		                         ~emit_runtime_rotation:
		                           (fun ~from_runtime ~to_runtime ~reason ->
		                              Keeper_metrics.emit_runtime_rotation
		                                ~keeper_name:meta.name
		                                ~from_runtime
		                                ~to_runtime
		                                ~reason)
		                         ~record_retry_setup_failure:
		                           (fun ~from_runtime ~retry ~rotation_attempt
		                                ~fail_open_err ->
		                              let reason =
		                                Keeper_error_classify
		                                .degraded_retry_reason_to_string
		                                  retry.fallback_reason
		                              in
		                              Log.Keeper.warn
		                                "%s: direct keeper_msg no-progress response \
		                                 from runtime=%s suggested retry to %s \
		                                 (reason=%s), but retry setup failed: %s"
		                                meta.name
		                                from_runtime
		                                retry.next_runtime
		                                reason
		                                (short_preview
		                                   (Agent_sdk.Error.to_string
		                                      fail_open_err));
		                              Keeper_turn_helpers.record_pre_dispatch_terminal_observation
		                                ~config:ctx.config
		                                ~meta
		                                ~generation:meta.runtime.generation
		                                ~runtime_id:retry.next_runtime
		                                ~outcome:`Error
		                                ~terminal_reason_code:
		                                  (Printf.sprintf
		                                     "direct_retry_setup_%s"
		                                     (Keeper_agent_error
		                                      .terminal_reason_code_of_sdk_error
		                                        fail_open_err))
		                                ~activity_kind:
		                                  "direct_no_progress_retry_setup"
		                                ~trajectory_outcome:
		                                  (Trajectory.Failed
		                                     (Agent_sdk.Error.to_string
		                                        fail_open_err))
		                                ~error_kind:
		                                  (Keeper_agent_error
		                                   .sdk_error_kind_for_receipt
		                                     fail_open_err)
		                                ~error_message:
		                                  (Agent_sdk.Error.to_string fail_open_err)
		                                ~degraded_retry_applied:true
		                                ~degraded_retry_runtime:retry.next_runtime
		                                ~fallback_reason:retry.fallback_reason
		                                ~runtime_rotation_attempts:
		                                  [ rotation_attempt ]
		                                ~keeper_turn_id
		                                ())
		                         ~before_retry:
		                           Keeper_turn_runtime_budget
		                           .yield_before_direct_no_progress_retry
		                         ~run_once:
		                           (fun ~runtime_id ~max_context ~is_retry
		                                ~degraded_retry_runtime ~fallback_reason
		                                ~runtime_rotation_attempts ->
		                              Keeper_agent_run.run_turn
		                                ~config:ctx.config
		                                ~meta
		                                ~turn_ctx_cell
		                                ~base_dir
		                                ~max_context
		                                ~build_turn_prompt
		                                ~user_message:message
		                                ?user_blocks
		                                ~runtime_id
		                                ~world_observation
		                                ~turn_affordances
		                                ?continuation_channel
		                                (* A kmsg turn is user-triggered, i.e.
		                                   reactive: it must use the reactive
		                                   idle budget so the graduated idle hook
		                                   (nudge -> final warning -> graceful
		                                   Skip) can run its course before the
		                                   OAS loop guard aborts the run. *)
		                                ~max_idle_turns
		                                ?oas_timeout_s:keeper_msg_oas_timeout_s
		                                ~generation:meta.runtime.generation
		                                ?on_event
		                                ~trajectory_acc
		                                ?degraded_retry_runtime
		                                ?fallback_reason
		                                ~runtime_rotation_attempts
		                                ~is_retry
		                                ?event_bus
		                                ())
		                         ()))
		            in
		            match run_result with
            | Error err ->
              let e_str = Agent_sdk.Error.to_string err in
              let user_message = Keeper_agent_error.user_message_of_sdk_error err in
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   (Trajectory.Failed e_str) in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              start_keepalive ctx meta;
              Progress.stop_tracking turn_task_id;
              tool_result_error user_message
	            | Ok (result, final_max_runtime_context) ->
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   Trajectory.Completed in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
              let resilience_handles =
                Keeper_turn_runtime_budget.post_turn_resilience_handles
                  ~config:ctx.config ~meta
              in
              let lifecycle =
                Keeper_context_runtime.apply_post_turn_lifecycle_with_resilience_handles
                  ~resilience_audit_store:
                    resilience_handles.resilience_audit_store
                  ~resilience_strategy_executor:
                    resilience_handles.resilience_strategy_executor
                  ~base_dir
                  ~on_compaction_started:(fun () ->
                    Keeper_context_runtime.dispatch_keeper_phase_event
                      ~config:ctx.config
                      ~origin:Keeper_registry.Post_turn_lifecycle
                      ~keeper_name:meta.name
                      Keeper_state_machine.Compaction_started)
                  ~on_handoff_started:(fun () ->
                    Keeper_context_runtime.dispatch_keeper_phase_event
                      ~config:ctx.config
                      ~origin:Keeper_registry.Post_turn_lifecycle
                      ~keeper_name:meta.name
                      Keeper_state_machine.Handoff_started)
	                  ~meta
	                  ~model:result.model_used
	                  ~primary_model_max_tokens:final_max_runtime_context
                  ~current_turn_blocker_info:None
                  ~checkpoint:result.checkpoint
                |> resilience_handles.sync_lifecycle_meta
              in
              Keeper_context_runtime.dispatch_post_turn_lifecycle_events
                ~config:ctx.config
                ~keeper_name:meta.name
                lifecycle;
              let lifecycle_updated_meta =
                clear_direct_success_no_progress_pause
                  ~config:ctx.config
                  ~pre_turn_meta:meta
                  ~result
                  lifecycle.updated_meta
              in
              let updated_meta =
                update_direct_turn_meta lifecycle_updated_meta ~latency_ms result
              in
              (* #9733: keeper_msg turn-completion is the same race shape
                 as the unified-turn failure path — heartbeat updates
                 [last_seen] in parallel and bumps
                 [meta_version], so a bare [write_meta] loses the CAS
                 race and silently drops the turn payload (usage tokens,
                 trace_history, generation).  Use the same merged-CAS
                 retry as [keeper_unified_turn.ml:1683] so the cycle
                 payload wins at the cycle-owned fields and heartbeat-
                 owned fields are taken from disk. *)
              (match
                 write_meta_with_merge
                   ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                   ctx.config updated_meta
               with
               | Ok () -> ()
               | Error msg ->
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string WriteMetaFailures)
                     ~labels:
                       [ ("keeper", updated_meta.name);
                         ("phase",
                          if is_version_conflict_error msg
                          then "keeper_msg_turn_cas_race"
                          else "keeper_msg_turn")
                       ]
                     ();
                   if is_version_conflict_error msg then
                     Log.Keeper.warn
                       "write_meta lost CAS race after retries (keeper_msg turn): %s"
                       msg
                   else
                     Log.Keeper.error
                       "write_meta failed after keeper_msg turn: %s" msg);
              (try
                 Keeper_unified_metrics.append_metrics_snapshot
                   ~config:ctx.config
                   ~meta:updated_meta
                   ~observation:(direct_turn_observation ~config:ctx.config updated_meta)
                   ~result
                   ~latency_ms
                   ~turn_cost:(turn_cost_for_result result)
                   ~turn_generation:lifecycle.turn_generation
                   ~channel:Keeper_world_observation.Reactive
                   ~snapshot_source:"keeper_turn_msg"
                   ~context_ratio:lifecycle.context_ratio
                   ~context_tokens:lifecycle.context_tokens
                   ~context_max:lifecycle.context_max
                   ~message_count:lifecycle.message_count
                   ~compaction:lifecycle.compaction
                   ~handoff_json:lifecycle.handoff_json
                   ()
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                   (* #10047: surface the drop as a Otel_metric_store counter so
                      dashboards can alert when state advances without a
                      matching metric record. The log alone was too easy
                      to miss and operators trusted metric jsonl as
                      ground truth. *)
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string MetricEmitDropped)
                     ~labels:[
                       ("keeper", updated_meta.name);
                       ("channel", "turn");
                       ("site", "keeper_turn_msg");
                     ] ();
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string TurnMetricsSnapshotFailures)
                     ~labels:[("keeper", updated_meta.name); ("site", "turn")]
                     ();
                   Log.Keeper.error
                     "write metrics snapshot failed after keeper_msg turn: %s"
                     (Printexc.to_string exn));
              Keeper_unified_metrics.broadcast_lifecycle_events
                ~name:updated_meta.name
                ~turn_generation:lifecycle.turn_generation
                ~compaction:lifecycle.compaction
                ~handoff_json:lifecycle.handoff_json;
              start_keepalive ctx updated_meta;
              Progress.Tracker.complete turn_tracker
                ~message:(Printf.sprintf "Turn completed: %d tool calls" (Keeper_agent_result.tool_call_count result)) ();
              let reply_json =
                let surface_model_used = Keeper_agent_run.runtime_lane_label in
                let u = result.usage in
                let cost_field = match u.cost_usd with
                  | Some c -> `Float c
                  | None -> `Null
                in
                let cache_miss_input_tokens =
                  Keeper_hooks_oas.cache_miss_input_tokens
                    ~input_tokens:u.input_tokens
                    ~cache_creation_input_tokens:u.cache_creation_input_tokens
                    ~cache_read_input_tokens:u.cache_read_input_tokens
                in
                let tool_call_evidence =
                  result.tool_calls
                  |> List.filter_map (fun detail ->
                         match detail.Keeper_agent_run.route_evidence with
                         | Some _ ->
                             Some
                               (Keeper_agent_run.tool_call_detail_to_json
                                  detail)
                         | None -> None)
                in
                `Assoc [
                  ("reply", `String result.response_text);
                  ( Keeper_turn_outcome.wire_key,
                    `String
                      (Keeper_turn_outcome.to_label
                         (Keeper_turn_outcome.of_result_surface
                            ~response_text:result.response_text
                            result.stop_reason)) );
                  ("model", `String surface_model_used);
                  ("model_used_raw", `String surface_model_used);
                  ("turns", `Int result.turn_count);
                  ( "tool_call_evidence",
                    `List tool_call_evidence );
                  ("usage", `Assoc [
                    ("input_tokens", `Int u.input_tokens);
                    ("output_tokens", `Int u.output_tokens);
                    ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
                    ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
                    ("cache_miss_input_tokens", `Int cache_miss_input_tokens);
                    ("cost_usd", cost_field);
                  ]);
                  (* RFC-0233 §7: the turn's join key, minted once from the
                     pre-turn snapshot above. The server persists it on the
                     chat row via append_turn ?turn_ref. *)
                  ( Keeper_turn_outcome.turn_ref_wire_key,
                    Ids.Turn_ref.to_yojson turn_ref );
                ]
              in
              tool_result_ok (Yojson.Safe.to_string reply_json)

))))))))

let handle_keeper_msg ?on_text_delta ?on_event ?event_bus ctx args : tool_result =
  let event_bus =
    match event_bus with
    | Some _ -> event_bus
    | None -> Keeper_event_bus.get ()
  in
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (* Invalid input cannot reach run_turn; let the admitted body produce
       its precise validation error without holding the slot. *)
    run_keeper_msg_turn_admitted ?on_text_delta ?on_event ?event_bus ctx args
  else
    match
      Keeper_turn_admission.run_serialized
        ~base_path:ctx.config.base_path
        ~keeper_name:name
        (fun () ->
          run_keeper_msg_turn_admitted ?on_text_delta ?on_event ?event_bus ctx args)
    with
    | `Ran result -> result
    | `Rejected { Keeper_turn_admission.waiting; in_flight } ->
        let in_flight_text =
          match in_flight with
          | None -> ""
          | Some { Keeper_turn_admission.lane; started_at } ->
              (* NDT-OK: gettimeofday renders the in-flight turn age for the error text only *)
              Printf.sprintf
                "; in-flight %s turn running for %.0fs"
                (Keeper_turn_admission.lane_to_string lane)
                (Unix.gettimeofday () -. started_at)
        in
        tool_result_error
          (Printf.sprintf
             "keeper %s turn queue is full (%d chat requests waiting%s); retry later"
             name
             waiting
             in_flight_text)

let handle_keeper_msg_if_free ?on_text_delta ?on_event ?event_bus ctx args =
  let event_bus =
    match event_bus with
    | Some _ -> event_bus
    | None -> Keeper_event_bus.get ()
  in
  let name = get_string args "name" "" in
  if not (validate_name name) then
    `Ran (run_keeper_msg_turn_admitted ?on_text_delta ?on_event ?event_bus ctx args)
  else
    Keeper_turn_admission.run_chat_if_free
      ~base_path:ctx.config.base_path
      ~keeper_name:name
      (fun () ->
        run_keeper_msg_turn_admitted ?on_text_delta ?on_event ?event_bus ctx args)
