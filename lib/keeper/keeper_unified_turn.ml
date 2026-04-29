(** Keeper_unified_turn — Single entry point for keeper cycles via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

(* Interval (seconds) for the per-turn background fiber that drains the
   `keeper_turn` subscription on the OAS event bus.  See
   [start_background_turn_event_bus_drain] for context.

   Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_KEEPER_TURN_DRAIN_INTERVAL_SEC]: hyperparameters belong in
   code, not in [Sys.getenv_opt].  Calibrated values move via PR with
   measurement evidence, not as silent operator overrides. *)
let default_turn_event_bus_drain_interval_sec = 0.05

let turn_event_bus_drain_interval_sec () =
  default_turn_event_bus_drain_interval_sec

let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  let rec loop offset =
    if offset = needle_len then true
    else if haystack.[start_idx + offset] <> needle.[offset] then false
    else loop (offset + 1)
  in
  loop 0

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec loop i =
      if i + needle_len > hay_len then false
      else if substring_matches_at ~needle haystack i then true
      else loop (i + 1)
    in
    loop 0

let string_contains_substring_ci ~(needle : string) (haystack : string) : bool =
  string_contains_substring
      ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let report_keeper_cycle_side_effect_issue
    ~(config : Coord.config)
    ~(keeper_name : string)
    ~(side_effect : string)
    ?(severity = `Warn)
    (detail : string) : unit =
  let message =
    Printf.sprintf "keeper cycle %s failed: %s" side_effect detail
  in
  Keeper_registry.record_error ~base_path:config.base_path keeper_name message;
  match severity with
  | `Warn -> Log.Keeper.warn "%s: %s" keeper_name message
  | `Error -> Log.Keeper.error "%s: %s" keeper_name message

let dispatch_keeper_phase_event_checked
    ~(config : Coord.config)
    ~(keeper_name : string)
    ~(side_effect : string)
    (event : Keeper_state_machine.event) : unit =
  match
    Keeper_registry.dispatch_event ~base_path:config.base_path keeper_name event
  with
  | Ok _ -> ()
  | Error err ->
      report_keeper_cycle_side_effect_issue
        ~config ~keeper_name ~side_effect
        (Printf.sprintf "phase dispatch %s failed: %s"
           (Keeper_state_machine.event_to_string event)
           (Keeper_state_machine.transition_error_to_string err))

let finalize_trajectory_acc
    ~(config : Coord.config)
    ~(keeper_name : string)
    (trajectory_acc : Trajectory.accumulator)
    (outcome : Trajectory.trajectory_outcome) : unit =
  try
    let trajectory = Trajectory.finalize trajectory_acc outcome in
    Log.Keeper.debug
      "%s: trajectory finalized outcome=%s total_tool_calls=%d"
      keeper_name
      (Trajectory.outcome_to_string trajectory.outcome)
      trajectory.total_tool_calls
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      report_keeper_cycle_side_effect_issue
        ~config ~keeper_name ~side_effect:"trajectory finalize"
        ~severity:`Error
        (Printexc.to_string exn)

let record_execution_receipt_gap
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(stale_reason : string)
    ~(error : string)
    () : unit =
  try
    let masc_root = Coord.masc_root_dir config in
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"execution_receipt"
      ~producer:"keeper_unified_turn.pre_dispatch"
      ~durable_store:
        (Filename.concat
           (Filename.concat (Filename.concat masc_root "keepers") meta.name)
           "execution-receipts")
      ~dashboard_surface:"/api/v1/dashboard/execution-trust"
      ~stale_reason
      ~keeper_name:meta.name
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~error
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Keeper.warn
        "keeper:%s pre-dispatch execution_receipt coverage gap append failed: %s"
        meta.name
        (Printexc.to_string exn)

(* ── KeeperTaskAcquisition.tla spec-action runtime guards (Cycle 44) ──

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperTaskAcquisition.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit] so an [Assert_failure] from a
   PPX-injected guard becomes a Prometheus counter increment by default
   (counter mode) and a re-raise when [MASC_FSM_GUARD_ASSERT=1]
   (assert mode for tests / CI). Bug-action [TaskRejected] is NOT
   instrumented — it is the failure mode these guards are designed to
   detect.

   This pattern follows PR #11696 (Cycle 43, KeeperHeartbeat closeout)
   which introduced [Keeper_fsm_guard_runtime] and the counter-default
   policy. *)

(* AssignTask: the channel decision picks "turn" when at least one of
   [pending_mentions], [pending_board_events], or
   [pending_scope_messages] is non-empty. The post-action guard pins
   the structural invariant that drove the decision. *)
let post_assign_task ~(any_pending : bool) ~(channel : string) =
  ignore any_pending; ignore channel
  [@@fsm_guard "any_pending = true && channel = \"turn\""]

(* EmptyQueueSleep: complementary branch — every pending list is empty
   and the cycle exits without claiming. *)
let post_empty_queue_sleep ~(any_pending : bool) ~(channel : string) =
  ignore any_pending; ignore channel
  [@@fsm_guard "any_pending = false && channel = \"scheduled_autonomous\""]

(* TurnComplete (KeeperTaskAcquisition.tla, Cycle 45 follow-up to
   PR #11716): the [run_keeper_cycle] body has produced an [Ok meta]
   for this cycle. The post-action invariant pins that the
   [cycle_completed] ref was actually toggled before the result is
   returned — catches a regression where a future refactor splits
   the bottom of [run_keeper_cycle] into branches that forget to
   record completion. The ref is single-fiber by construction: each
   [run_keeper_cycle] invocation runs in its own fiber, and the ref
   is allocated fresh inside the function. *)
let post_turn_complete_task ~(cycle_completed : bool ref) =
  ignore cycle_completed
  [@@fsm_guard "!cycle_completed = true"]

let pre_dispatch_tool_surface : Keeper_execution_receipt.tool_surface =
  {
    turn_lane = "pre_dispatch";
    tool_surface_class = "none";
    tool_requirement = "none";
    visible_tool_count = 0;
    tool_gate_enabled = false;
    tool_surface_fallback_used = false;
    required_tools = [];
    missing_required_tools = [];
  }

let record_pre_dispatch_terminal_observation
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(generation : int)
    ~(cascade_name : string)
    ~(outcome : string)
    ~(terminal_reason_code : string)
    ~(activity_kind : string)
    ~(trajectory_outcome : Trajectory.trajectory_outcome)
    ?error_kind
    ?error_message
    ?keeper_turn_id
    () : unit =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let started_at = now_iso () in
  let masc_root = Coord.masc_root_dir config in
  let trajectory_acc =
    Trajectory.create_accumulator
      ~masc_root
      ~keeper_name:meta.name
      ~trace_id
      ~generation
  in
  finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc
    trajectory_outcome;
  let ended_at = now_iso () in
  let receipt : Keeper_execution_receipt.t =
    {
      keeper_name = meta.name;
      agent_name = meta.agent_name;
      trace_id;
      generation;
      turn_count =
        (match keeper_turn_id with
         | Some _ -> keeper_turn_id
         | None -> Some meta.runtime.usage.total_turns);
      current_task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id;
      goal_ids = meta.active_goal_ids;
      outcome;
      terminal_reason_code;
      response_text_present = false;
      model_used = None;
      requested_tools = [];
      reported_tools = [];
      observed_tools = [];
      canonical_tools = [];
      unexpected_tools = [];
      tools_used = [];
      tool_contract_result = "not_dispatched";
      tool_surface = pre_dispatch_tool_surface;
      sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta;
      sandbox_root = Some (Keeper_sandbox.host_root_abs_of_meta ~config meta);
      network_mode = Keeper_types.network_mode_to_string meta.network_mode;
      approval_profile = None;
      approval_profile_derived = false;
      cascade_name;
      cascade_selected_model = None;
      cascade_attempt_count = 0;
      cascade_fallback_applied = false;
      cascade_outcome = "not_dispatched";
      degraded_retry_applied = false;
      degraded_retry_cascade = None;
      fallback_reason = None;
      cascade_rotation_attempts = [];
      stop_reason = None;
      error_kind;
      error_message;
      started_at;
      ended_at;
    }
  in
  (try
     Keeper_execution_receipt.append config receipt
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
      let error = Printexc.to_string exn in
      Log.Keeper.warn
        "keeper:%s pre-dispatch execution_receipt append failed: %s"
        meta.name error;
      record_execution_receipt_gap ~config ~meta
        ~stale_reason:"pre_dispatch_execution_receipt_append_failed"
        ~error
        ());
  (try
     let event =
       Activity_graph.emit config
         ~actor:{ kind = "agent"; id = meta.agent_name }
         ~kind:activity_kind
         ~payload:
           (`Assoc
              [
                ("keeper_name", `String meta.name);
                ("trace_id", `String trace_id);
                ("outcome", `String outcome);
                ("terminal_reason_code", `String terminal_reason_code);
                ("cascade_name", `String cascade_name);
              ])
         ()
     in
     Log.Keeper.debug "%s: activity graph %s emitted seq=%d" meta.name
       activity_kind event.seq
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
      report_keeper_cycle_side_effect_issue
        ~config
        ~keeper_name:meta.name
        ~side_effect:(activity_kind ^ " emit")
        (Printexc.to_string exn))

let ensure_local_discovery_ready
    ?refresh
    (labels : string list) : (unit, string) result =
  let refresh =
    match refresh with
    | Some f -> f
    | None -> fun labels ->
        Cascade_runtime.refresh_local_discovery_if_possible labels
  in
  if not (Cascade_runtime.labels_require_local_discovery labels)
  then Ok ()
  else
    try
      if refresh labels
      then Ok ()
      else
        Error
          (Printf.sprintf
             "local discovery refresh required for labels [%s] but refresh failed"
             (String.concat ", " labels))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Error
          (Printf.sprintf
             "local discovery refresh raised for labels [%s]: %s"
             (String.concat ", " labels)
             (Printexc.to_string exn))

type local_only_liveness_decision =
  | Keep_effective_cascade of string
  | Probe_local_only_urls of {
      effective_cascade : string;
      fallback_cascade : string;
      ollama_base_urls : string list;
    }

let decide_local_only_liveness
    ?resolve_label
    ~(base_cascade : string)
    ~(effective_cascade : string)
    (labels : string list) : local_only_liveness_decision =
  let resolve_label =
    match resolve_label with
    | Some resolve_label -> resolve_label
    | None -> fun label -> Cascade_config.parse_model_string label
  in
  let normalized_base =
    Keeper_cascade_profile.normalize_declared_name base_cascade
  in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  if not (String.equal normalized_effective Keeper_config.local_only_cascade_name)
     || String.equal normalized_base Keeper_config.local_only_cascade_name
  then Keep_effective_cascade normalized_effective
  else
    let ollama_urls =
      labels
      |> List.filter_map resolve_label
      |> List.filter_map (fun (cfg : Llm_provider.Provider_config.t) ->
             if Cascade_ollama_probe.is_ollama_url cfg.base_url then
               Some cfg.base_url
             else None)
      |> dedupe_keep_order
    in
    match ollama_urls with
    | [] -> Keep_effective_cascade normalized_effective
    | ollama_base_urls ->
        Probe_local_only_urls
          {
            effective_cascade = normalized_effective;
            fallback_cascade = normalized_base;
            ollama_base_urls;
          }

let fail_open_local_only_when_unavailable
    ?resolve_label
    ?probe_ollama_base_url
    ~(base_cascade : string)
    ~(effective_cascade : string)
    (labels : string list) : string =
  match
    decide_local_only_liveness ?resolve_label ~base_cascade ~effective_cascade
      labels
  with
  | Keep_effective_cascade cascade -> cascade
  | Probe_local_only_urls
      { effective_cascade; fallback_cascade; ollama_base_urls } ->
      let probe_ollama_base_url =
        match probe_ollama_base_url with
        | Some probe -> Some probe
        | None ->
          (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
           | Some sw, Some net ->
             Some (fun base_url ->
               Option.is_some (Cascade_ollama_probe.try_probe ~sw ~net base_url))
           | _ -> None)
      in
      (match probe_ollama_base_url with
       | None -> effective_cascade
       | Some probe ->
         if List.exists probe ollama_base_urls then effective_cascade
         else fallback_cascade)

(** PR-B: ollama saturation pre-skip support.

    When every label in the resolved cascade points at the same
    ollama [base_url] (single-provider profile), we can pre-check the
    [Cascade_ollama_probe] cache before paying an [Agent.run] dispatch.
    If the probe reports [process_available <= 0] the request would
    queue on a busy slot and very likely blow the keeper turn budget,
    causing a cascading FAILED cycle.  Skipping the turn here keeps
    the keeper alive without burning the budget. *)

(** [resolve_ollama_only_base_url ?resolve_label labels] returns
    [Some url] when [labels] is non-empty AND every label parses to
    an ollama provider config sharing the same [base_url].  Returns
    [None] when the cascade has zero candidates, when any candidate
    is non-ollama, when ollama candidates point at different hosts,
    or when any label fails to parse.

    Pure: [resolve_label] is the only injected dependency for tests. *)
let resolve_ollama_only_base_url
    ?resolve_label
    (labels : string list) : string option =
  let resolve_label =
    match resolve_label with
    | Some f -> f
    | None -> fun label -> Cascade_config.parse_model_string label
  in
  match labels with
  | [] -> None
  | first :: rest ->
      let is_ollama_cfg (cfg : Llm_provider.Provider_config.t) =
        match cfg.kind with
        | Llm_provider.Provider_config.Ollama -> true
        | _ -> false
      in
      (match resolve_label first with
       | Some cfg when is_ollama_cfg cfg ->
           let base_url = cfg.base_url in
           let same_ollama_host label =
             match resolve_label label with
             | Some other when is_ollama_cfg other ->
                 String.equal other.base_url base_url
             | _ -> false
           in
           if List.for_all same_ollama_host rest then Some base_url
           else None
       | _ -> None)

(** [is_ollama_saturated ?capacity_lookup base_url] returns [true]
    only when the cache has a fresh entry whose
    [process_available <= 0] AND there is at least one queued or
    active request.  [None] (no cache entry / probe never ran) and
    failed probes are deliberately treated as "not saturated" so a
    flaky probe never starves the keeper.  Mirrors the conservative
    fail-open policy in [Cascade_ollama_probe.try_probe]. *)
let is_ollama_saturated
    ?capacity_lookup
    (base_url : string) : bool =
  let capacity_lookup =
    match capacity_lookup with
    | Some f -> f
    | None -> fun url -> Cascade_ollama_probe.cached_capacity url
  in
  match capacity_lookup base_url with
  | None -> false
  | Some (info : Cascade_throttle.capacity_info) ->
      info.process_available <= 0
      && (info.process_active > 0 || info.process_queue_length > 0)

(** Backoff sleep applied after a saturation skip so the keeper does
    not hot-spin against a busy ollama instance. Short by design:
    the heartbeat loop already has its own pacing (see
    [keeper_keepalive.ml]); this only covers the case where multiple
    keepers race the probe cache. *)
let saturation_skip_backoff_sec = 5.0

let saturation_skip_jitter_factor = 0.4

let saturation_skip_sleep_duration () =
  let jitter =
    saturation_skip_backoff_sec
    *. saturation_skip_jitter_factor
    *. Random.float 1.0
  in
  saturation_skip_backoff_sec +. jitter

let turn_livelock_max_attempts () =
  Int.max 1
    (Env_config_core.get_int ~default:3
       "MASC_KEEPER_TURN_LIVELOCK_MAX_ATTEMPTS")

let turn_livelock_stuck_after_sec () =
  Float.max 1.0
    (Env_config_core.get_float ~default:1800.0
       "MASC_KEEPER_TURN_LIVELOCK_STUCK_AFTER_SEC")

(* Extracted to Keeper_error_classify — see keeper_error_classify.ml *)

module EC = Keeper_error_classify

type cascade_execution = {
  cascade_name : string;
  max_context_resolution : Keeper_exec_context.max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int;
}

let fail_open_rotation_cascades_from_catalog
    ~(catalog_names : string list)
    ~(keeper_assignable : string list) =
  if catalog_names = [] then None
  else
    let is_reserved_recovery name =
      String.equal name Keeper_config.default_cascade_name
      || String.equal name Keeper_config.local_recovery_cascade_name
    in
    let is_keeper_assignable name =
      List.exists (String.equal name) keeper_assignable
    in
    match
      catalog_names
      |> List.filter (fun name ->
             is_reserved_recovery name || is_keeper_assignable name)
      |> dedupe_keep_order
    with
    | [] -> None
    | candidates -> Some candidates

let active_fail_open_rotation_cascades () =
  fail_open_rotation_cascades_from_catalog
    ~catalog_names:(Keeper_cascade_profile.catalog_names ())
    ~keeper_assignable:(Keeper_cascade_profile.keeper_catalog_names ())

let next_fail_open_cascade_for_turn
    ?rotation_cascades
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : string)
    ~(attempted_cascades : string list)
    (err : Oas.Error.sdk_error) : EC.degraded_retry option =
  let fallback_hint =
    Keeper_cascade_profile.fallback_cascade_for effective_cascade
  in
  EC.degraded_rotation_after_recoverable_error
    ?rotation_cascades
    ?fallback_hint
    ~base_cascade ~effective_cascade ~tool_requirement
    ~attempted_cascades err

let sdk_error_kind = function
  | Oas.Error.Api _ -> "api"
  | Oas.Error.Agent _ -> "agent"
  | Oas.Error.Mcp _ -> "mcp"
  | Oas.Error.Config _ -> "config"
  | Oas.Error.Serialization _ -> "serialization"
  | Oas.Error.Io _ -> "io"
  | Oas.Error.Orchestration _ -> "orchestration"
  | Oas.Error.A2a _ -> "a2a"
  | Oas.Error.Internal _ -> "internal"

let record_turn_failure_stress
    ~(meta : keeper_meta)
    ~(is_auto_recoverable : bool)
    ~(consecutive : int)
    ~(threshold : int)
    ~(err : Oas.Error.sdk_error)
  : unit =
  let room_id =
    match meta.joined_room_ids with
    | room_id :: _ -> room_id
    | [] -> ""
  in
  Agent_stress.record {
    agent_name = meta.name;
    room_id;
    kind =
      Turn_failure {
        consecutive;
        threshold;
        counted_toward_crash = not is_auto_recoverable;
        recoverable = is_auto_recoverable;
        error_kind = Some (sdk_error_kind err);
      };
    timestamp = Unix.gettimeofday ();
  }

(* Retry guard floor: relaxed 30→15 (2026-04-27).
   Original 60s threshold (guard 30 + min 30) caused keeper cycle FAILED when
   remaining turn budget fell into the 30-60s band, increasing noop count and
   eventually fleet auto-pause. Field evidence (post v0.18.4): keepers hung on
   cohttp-eio bulk read for ~600s and arrived at the retry branch with <60s
   remaining → guarded out → cycle terminal.

   New threshold (15+15=30s) accommodates small-tail retries:
   - cohttp connect 1s + first-token 2-5s = ~6s baseline
   - 30s leaves ~9-12s headroom for actual response

   Root cause is OAS HTTP body lacking timeout (`http_client.ml take_all`);
   this is a band-aid until that lands. *)
let oas_timeout_guard_sec = 15.0

let min_oas_timeout_budget_sec = 15.0

type oas_timeout_budget_resolution = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  max_turns : int;
  source : string;
}

let oas_timeout_budget_resolution_to_yojson
    (budget : oas_timeout_budget_resolution) : Yojson.Safe.t =
  `Assoc
    [
      ("oas_timeout_sec", `Float budget.effective_timeout_sec);
      ("adaptive_timeout_sec", `Float budget.adaptive_timeout_sec);
      ("keeper_turn_timeout_sec", `Float budget.keeper_turn_timeout_sec);
      ("remaining_turn_budget_sec", `Float budget.remaining_turn_budget_sec);
      ("estimated_input_tokens", `Int budget.estimated_input_tokens);
      ("max_turns", `Int budget.max_turns);
      ("source", `String budget.source);
    ]

let resolve_bounded_oas_timeout_budget_with_turn_budget
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : oas_timeout_budget_resolution option =
  let usable_budget = remaining_turn_budget_s -. oas_timeout_guard_sec in
  if usable_budget < min_oas_timeout_budget_sec
  then None
  else
    let runtime = Keeper_runtime_resolved.current () in
    let adaptive_timeout_sec =
      Keeper_runtime_resolved
      .oas_timeout_for_estimated_input_tokens_with_turn_budget
        ~estimated_input_tokens ~max_turns
    in
    let effective_timeout_sec =
      Float.min adaptive_timeout_sec usable_budget
    in
    let source =
      match runtime.oas_timeout_override_sec.value with
      | Some _ when effective_timeout_sec < adaptive_timeout_sec ->
          "override_capped_by_turn_budget"
      | Some _ -> "override"
      | None when effective_timeout_sec < adaptive_timeout_sec ->
          "adaptive_estimated_input_tokens_capped_by_turn_budget"
      | None -> "adaptive_estimated_input_tokens"
    in
    Some
      {
        effective_timeout_sec;
        adaptive_timeout_sec;
        keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
        remaining_turn_budget_sec = usable_budget;
        estimated_input_tokens = max 0 estimated_input_tokens;
        max_turns;
        source;
      }

let bounded_oas_timeout_for_turn_budget_with_turn_budget
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : float option =
  Option.map
    (fun (budget : oas_timeout_budget_resolution) -> budget.effective_timeout_sec)
    (resolve_bounded_oas_timeout_budget_with_turn_budget
       ~estimated_input_tokens ~max_turns ~remaining_turn_budget_s)

let bounded_oas_timeout_for_turn_budget ~(estimated_input_tokens : int)
    ~(remaining_turn_budget_s : float) : float option =
  bounded_oas_timeout_for_turn_budget_with_turn_budget ~estimated_input_tokens
    ~max_turns:(Keeper_runtime_resolved.reactive_max_turns_per_call ())
    ~remaining_turn_budget_s

let oas_retry_budget_available_for_turn ~(estimated_input_tokens : int)
    ~(max_turns : int) ~(remaining_turn_budget_s : float) : bool =
  Option.is_some
    (resolve_bounded_oas_timeout_budget_with_turn_budget
       ~estimated_input_tokens ~max_turns ~remaining_turn_budget_s)

let reclassify_oas_timeout_for_attempt
    ~(timeout_budget : oas_timeout_budget_resolution option)
    (err : Oas.Error.sdk_error) : Oas.Error.sdk_error =
  match err, timeout_budget with
  | Oas.Error.Api (Timeout { message }), Some timeout_budget
    when EC.is_structural_oas_timeout_message message ->
      Oas_worker_named.sdk_error_of_masc_internal_error
        (Oas_worker_named.Oas_timeout_budget
           {
             budget_sec = timeout_budget.effective_timeout_sec;
             keeper_turn_timeout_sec =
               timeout_budget.keeper_turn_timeout_sec;
             estimated_input_tokens = timeout_budget.estimated_input_tokens;
             source = timeout_budget.source;
           })
  | _ -> err

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_budget_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

let next_fail_open_cascade_for_turn_with_budget
    ?rotation_cascades
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : string)
    ~(attempted_cascades : string list)
    ~(estimated_input_tokens : int)
    ~(max_turns : int)
    ~(remaining_turn_budget_s : float)
    (err : Oas.Error.sdk_error) : degraded_retry_budget_decision =
  match
    next_fail_open_cascade_for_turn
      ?rotation_cascades
      ~base_cascade ~effective_cascade ~tool_requirement
      ~attempted_cascades err
  with
  | None -> No_degraded_retry
  | Some retry ->
      if
        oas_retry_budget_available_for_turn
          ~estimated_input_tokens ~max_turns ~remaining_turn_budget_s
      then Degraded_retry_allowed retry
      else Degraded_retry_budget_exhausted retry

type overflow_retry_plan = {
  retry_max_context : int;
  retry_generation : int;
  compaction : compaction_event;
}

type turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_summary = {
  correlation_id : string option;
  overflow_imminent : turn_event_bus_overflow option;
}

let empty_turn_event_bus_summary =
  {
    correlation_id = None;
    overflow_imminent = None;
  }

let merge_turn_event_bus_summary
    (left : turn_event_bus_summary)
    (right : turn_event_bus_summary) : turn_event_bus_summary =
  {
    correlation_id =
      (match left.correlation_id with
       | Some _ -> left.correlation_id
       | None -> right.correlation_id);
    overflow_imminent =
      (match right.overflow_imminent with
       | Some _ -> right.overflow_imminent
       | None -> left.overflow_imminent);
  }

(** Recover from context overflow by compacting and reducing max_context.

    Extracts the token limit directly from the structured [ContextOverflow]
    error instead of re-parsing stringified error messages.
    No local token-budget math — OAS owns context budgeting.
    MASC only decides whether to compact and retry.

    @boundary-contract
    - MASC owns: "compact & retry?" decision (at most once per turn),
      extracting the limit from OAS structured errors, generation tracking.
    - OAS owns: context overflow detection, ContextOverflow/TokenBudgetExceeded
      error emission, checkpoint compaction algorithm, token budget enforcement.
    - Neither may: MASC must not invent token limits or run its own budget
      math; OAS must not auto-retry on overflow (MASC needs to decide). *)
let recover_context_overflow_retry
    ~(meta : keeper_meta)
    ~(base_dir : string)
    ~(max_cascade_context : int)
    ~(error : Oas.Error.sdk_error) : overflow_retry_plan option =
  let actual_limit =
    match error with
    | Oas.Error.Api (ContextOverflow { limit = Some limit; _ }) -> limit
    | Oas.Error.Agent (TokenBudgetExceeded { limit; _ }) -> limit
    | _ ->
      (* Overflow detected but limit not available — use 80% of cascade max
         as a conservative fallback. *)
      max 4096 (max_cascade_context * 4 / 5)
  in
  let retry_max_context =
    if max_cascade_context <= 0 then actual_limit
    else min max_cascade_context actual_limit
  in
  let model = Keeper_exec_context.checkpoint_model_of_meta meta in
  match
    Keeper_exec_context.recover_latest_checkpoint_for_overflow_retry
      ~base_dir ~meta ~model
      ~primary_model_max_tokens:retry_max_context
  with
  | Some recovery ->
      Log.Keeper.warn
        "%s: context overflow retry — compacted checkpoint (%d->%d tokens, max_context=%d, generation=%d)"
        meta.name recovery.compaction.before_tokens
        recovery.compaction.after_tokens
        retry_max_context recovery.turn_generation;
      Some
        {
          retry_max_context;
          retry_generation = recovery.turn_generation;
          compaction = recovery.compaction;
        }
  | None ->
      Log.Keeper.warn
        "%s: context overflow detected but checkpoint recovery unavailable: %s"
        meta.name (short_preview (Oas.Error.to_string error));
      None

let summarize_turn_event_bus
    (events : Oas.Event_bus.event list) : turn_event_bus_summary =
  List.fold_left
    (fun acc (evt : Oas.Event_bus.event) ->
      let correlation_id =
        match acc.correlation_id with
        | Some _ -> acc.correlation_id
        | None -> Some evt.meta.correlation_id
      in
      match evt.payload with
      | Oas.Event_bus.ContextOverflowImminent
          { estimated_tokens; limit_tokens; _ } ->
          {
            correlation_id;
            overflow_imminent =
              Some { estimated_tokens; limit_tokens };
          }
      | _ -> { acc with correlation_id })
    empty_turn_event_bus_summary
    events

let context_overflow_event_of_error
    ~(fallback_tokens : int)
    ?(turn_event_bus : turn_event_bus_summary =
      { correlation_id = None; overflow_imminent = None })
    (err : Oas.Error.sdk_error) : Keeper_state_machine.event =
  match turn_event_bus.overflow_imminent with
  | Some { estimated_tokens; limit_tokens } ->
      Keeper_state_machine.Context_overflow_detected
        {
          source = `Oas_signal;
          token_count = max 0 estimated_tokens;
          limit_tokens = Some limit_tokens;
        }
  | None ->
      match err with
      | Oas.Error.Agent (TokenBudgetExceeded { kind = "Input"; used; limit }) ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Oas_signal;
              token_count = used;
              limit_tokens = Some limit;
            }
      | Oas.Error.Api (ContextOverflow { limit; _ }) ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Prompt_rejected;
              token_count = Option.value ~default:(max 0 fallback_tokens) limit;
              limit_tokens = limit;
            }
      | _ ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Oas_signal;
              token_count = max 0 fallback_tokens;
              limit_tokens = None;
            }

let pause_keeper_for_overflow
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(reason : string) : keeper_meta =
  let paused_meta =
    {
      meta with
      paused = true;
      updated_at = now_iso ();
    }
  in
  (* #9733: [paused = true] is cycle-owned (the overflow-recovery
     fiber decided the keeper must pause); heartbeat-owned fields
     (joined_room_ids, last_seen_seq_by_room) must come from disk so
     a parallel heartbeat write doesn't fight us for [meta_version].
     Bare [write_meta] here drops the pause silently in the lost-CAS
     case — the keeper then reports unpaused while the caller
     believes it succeeded.  Same pattern as the unified-turn
     failure path. *)
  (match
     write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       config paused_meta
   with
   | Ok () -> ()
   | Error err when is_version_conflict_error err ->
       Log.Keeper.warn
         "%s: overflow pause write_meta lost CAS race after retries: %s"
         meta.name err
   | Error err ->
       Log.Keeper.error
         "%s: overflow pause write_meta failed: %s"
         meta.name err);
  Keeper_registry.update_meta ~base_path:config.base_path meta.name paused_meta;
  (* Issue #8581: latch the retry-exhausted condition BEFORE the
     Operator_pause that drives the Paused phase. This way the Paused
     state carries the real reason (auto-compact retry budget exhausted)
     for dashboards / operator observability — the right disjunct of
     [derive_phase]'s Paused branch ([context_overflow] /\
     [compact_retry_exhausted]) reaches a real value instead of staying
     dead code. The Operator_pause that follows still drives the actual
     phase transition deterministically (first disjunct:
     [operator_paused]). *)
  dispatch_keeper_phase_event
    ~config
    ~keeper_name:meta.name
    Keeper_state_machine.Compact_retry_exhausted;
  dispatch_keeper_phase_event
    ~config
    ~keeper_name:meta.name
    Keeper_state_machine.Operator_pause;
  Log.Keeper.warn
    "%s: keeper paused after unresolved context overflow (%s)"
    meta.name reason;
  paused_meta

let sync_keeper_paused_state
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(paused : bool) : (keeper_meta, string) result =
  let synced_meta =
    {
      meta with
      paused;
      updated_at = now_iso ();
    }
  in
  (* #9733: pause/resume sync is operator-driven; the [paused]
     field is cycle-owned at this site, so use the same merged-CAS
     write as overflow pause + unified-turn failure paths.  Without
     this, an operator pause/resume that races a heartbeat tick
     can land partially (paused field correct on disk, but write
     reports failure) which leaves the registry update unsync'd
     with disk. *)
  match
    write_meta_with_merge
      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
      config synced_meta
  with
  | Error err ->
      report_keeper_cycle_side_effect_issue
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync write_meta"
                        (if paused then "pause" else "resume"))
        ~severity:`Error
        err;
      Error (Printf.sprintf "failed to write meta: %s" err)
  | Ok () ->
      Keeper_registry.update_meta ~base_path:config.base_path meta.name synced_meta;
      dispatch_keeper_phase_event_checked
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync phase update"
                        (if paused then "pause" else "resume"))
        (if paused
         then Keeper_state_machine.Operator_pause
         else Keeper_state_machine.Operator_resume);
      (if not paused then
         match Keeper_registry.get ~base_path:config.base_path meta.name with
         | Some entry -> Atomic.set entry.fiber_wakeup true
         | None ->
             report_keeper_cycle_side_effect_issue
               ~config
               ~keeper_name:meta.name
               ~side_effect:"resume sync fiber wakeup"
               "registry entry missing after metadata update");
      Ok synced_meta

let current_keeper_meta ~(config : Coord.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

let enqueue_partial_commit_continue_gate
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(failure_reason : Keeper_registry.failure_reason)
    ~(committed_tools : string list)
    ~(error_detail : string) : string =
  let reason_text = Keeper_registry.failure_reason_to_string failure_reason in
  let input =
    `Assoc [
      ("kind", `String "continue_gate_required");
      ("keeper_name", `String meta.name);
      ("failure_reason", `String reason_text);
      ("error_detail", `String error_detail);
      ("committed_tools", `List (List.map (fun tool -> `String tool) committed_tools));
    ]
  in
  Keeper_approval_queue.submit_pending
    ~keeper_name:meta.name
    ~tool_name:"keeper_continue_after_partial_commit"
    ~input
    ~risk_level:Keeper_approval_queue.Critical
    ~on_resolution:(fun decision ->
      let latest_meta = current_keeper_meta ~config ~fallback_meta:meta in
      match decision with
      | Oas.Hooks.Approve
      | Oas.Hooks.Edit _ ->
        (match sync_keeper_paused_state ~config ~meta:latest_meta ~paused:false with
         | Ok resumed_meta ->
             Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name None;
             Keeper_registry.reset_turn_failures ~base_path:config.base_path meta.name;
             Log.Keeper.info
               "%s: partial-commit continue gate approved; auto-resumed keeper"
               resumed_meta.name
         | Error err ->
             Log.Keeper.error
               "%s: partial-commit continue gate approved but keeper resume sync failed: %s"
               meta.name err)
      | Oas.Hooks.Reject reason ->
        (match sync_keeper_paused_state ~config ~meta:latest_meta ~paused:true with
         | Ok paused_meta ->
             Keeper_registry.set_failure_reason
               ~base_path:config.base_path meta.name
               (Some failure_reason);
             Log.Keeper.warn
               "%s: partial-commit continue gate rejected; keeper remains paused (%s)"
               paused_meta.name reason
         | Error err ->
             Log.Keeper.error
               "%s: partial-commit continue gate rejected but keeper pause sync failed: %s (reason=%s)"
               meta.name err reason))
    ()

(* Dedupe "mixed cascade context budget" log: the values are constant
   per (keeper_name, model_labels) because cascade config is static at
   startup.  Logging per turn produces 15-20 duplicates per keeper per
   minute under load. Track (name, primary, cascade_max) tuples we've
   already announced and skip subsequent identical log lines. *)
let cascade_budget_logged : (string * int * int, unit) Hashtbl.t =
  Hashtbl.create 16

let resolved_max_context_for_turn
    ~(meta : keeper_meta)
    (model_labels : string list) : int =
  let resolution =
    Keeper_exec_context.resolve_max_context_resolution
      ~requested_override:meta.max_context_override model_labels
  in
  if resolution.primary_budget < resolution.cascade_budget then begin
    let key = (meta.name, resolution.primary_budget, resolution.cascade_budget) in
    if not (Hashtbl.mem cascade_budget_logged key) then begin
      Hashtbl.add cascade_budget_logged key ();
      Log.Keeper.info
        "%s: mixed cascade context budget primary=%d cascade_max=%d; using primary for initial turn budget"
        meta.name resolution.primary_budget resolution.cascade_budget
    end
  end;
   (match resolution.requested_override with
    | Some requested ->
     Log.Keeper.debug
       "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d"
       meta.name requested resolution.turn_budget resolution.primary_budget
       resolution.effective_budget
   | None -> ());
  resolution.effective_budget


(* Extracted to Keeper_unified_metrics — see keeper_unified_metrics.ml *)


let run_keeper_cycle ~(config : Coord.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int)
    ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
    ?(semaphore_wait_ms = 0)
    ?shared_context
    () : (keeper_meta, Oas.Error.sdk_error) result =
  (* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 28 anchor for
     B2 (Task Acquisition).  Authoritative spec mirror is
     specs/keeper-state-machine/KeeperTaskAcquisition.tla (Cycle 8 /
     Tier B2, PR #11412).

     Spec line 3 already cites this function: "[run_keeper_cycle]
     (line 1042+)".  This block is the reverse-direction citation
     so code search for "KeeperTaskAcquisition" lands here.

     Action mapping (TLA+ -> OCaml):
       SubmitTask        external producers (operator, supervisor,
                         autoresearch, board) populate
                         [observation.pending_*] before this function
                         is called.
       AssignTask        below (~line 2559) the channel decision —
                         [observation.pending_mentions <> []] OR
                         [pending_board_events <> []] OR
                         [pending_scope_messages <> []] picks
                         channel = "turn", which is the OCaml form of
                         spec's AssignTask.
       EmptyQueueSleep   the [else] branch picks
                         "scheduled_autonomous", which exits the
                         claim-and-finish path for this cycle.
       TurnComplete      the [run_turn] body finishes and returns a
                         [keeper_meta] result; control falls through
                         to the next observation cycle.
       TaskRejected      bug action — claimed task is dropped without
                         a finish.  Spec invariant NoTaskOrphan
                         catches this; in code, the invariant is
                         that every "turn" channel claim eventually
                         reaches one of [Ok updated_meta] /
                         [Error sdk_error].  Silent-drop regressions
                         (early return without recording the turn
                         outcome) would violate the spec. *)
  (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete bracket — the
     ref is set to true on the [Ok updated_meta] return at the end of
     this function; an [Error _] branch leaves it false and skips the
     wrap, mirroring the spec's "completed-on-success" semantics. *)
  let cycle_completed = ref false in
  (* 0. Phase gate + state-aware cascade routing.
     The gate owns turn executability; select_cascade remains a total helper
     so dashboards/tests can inspect the same routing contract for blocked
     phases like Overflowed. *)
  let registry_base_path = config.base_path in
  let previous_social_state = Social.previous_state_of_meta meta in
  (* Decide turn_id at function entry so phase-gate / cascade-routing /
     livelock skip paths can include it in the receipt and observability
     stream.  Previously this was [let turn_id = ...] only after several
     pre-dispatch checks (see turn_livelock guard below), leaving silent
     skip paths without a turn correlator. *)
  let keeper_turn_id = meta.runtime.usage.total_turns in
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  match Keeper_registry.get_phase ~base_path:registry_base_path meta.name with
  | Some phase when not (Keeper_state_machine.can_execute_turn phase) ->
      let phase_string = Keeper_state_machine.phase_to_string phase in
      Log.Keeper.info
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        "%s: keeper cycle skipped in non-executable phase=%s"
        meta.name phase_string;
      let terminal_reason_code =
        Printf.sprintf "non_executable_phase:%s" phase_string
      in
      record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation
        ~cascade_name:meta.cascade_name
        ~outcome:"cancelled"
        ~terminal_reason_code
        ~activity_kind:"keeper.turn_cancelled"
        ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
        ~keeper_turn_id
        ();
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        (Keeper_turn_fsm.Cancelled
           Keeper_turn_fsm.Cancelled_phase_gate_close);
      Ok meta
  | phase_opt ->
      (* State-aware cascade routing (TLA+ KeeperCoreTriad.SelectCascade).
         At this point [phase] is executable; blocked phases returned above. *)
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        Keeper_turn_fsm.Cascade_routing;
      let effective_cascade_name =
        let phase = match phase_opt with
          | Some p -> p
          | None ->
              Log.Keeper.warn
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                "%s: registry phase lookup returned None, defaulting to Failing"
                meta.name;
              Keeper_state_machine.Failing
        in
        let routing = Keeper_cascade_routing.select_cascade
          ~base_cascade:meta.cascade_name ~phase
        in
        Prometheus.inc_counter Prometheus.metric_keeper_fsm_edge_transitions
          ~labels:[("edge", "ksm_to_kcl_routing")] ();
        let routed_meta = { meta with cascade_name = routing.effective_cascade } in
        let routed_labels =
          Keeper_model_labels.configured_model_labels_of_meta routed_meta
        in
        let resolved_cascade =
          fail_open_local_only_when_unavailable
            ~base_cascade:meta.cascade_name
            ~effective_cascade:routing.effective_cascade
            routed_labels
        in
        Log.Keeper.debug "%s: cascade routing: %s -> %s (reason: %s)"
          meta.name meta.cascade_name routing.effective_cascade routing.reason;
        if not (String.equal resolved_cascade routing.effective_cascade) then
          Log.Keeper.warn
            "%s: local_only unavailable for labels [%s]; falling back to base cascade %s"
            meta.name (String.concat ", " routed_labels) resolved_cascade;
        resolved_cascade
      in
      let effective_cascade_name =
        match
          Keeper_world_observation.provider_cooldown_remaining_sec_for_cascade
            ~cascade_name:effective_cascade_name
        with
        | Some remaining_sec ->
            (match
               EC.fallback_cascade_for_unavailable_profile
                 ~base_cascade:meta.cascade_name
                 ~effective_cascade:effective_cascade_name
             with
             | Some fallback_cascade
               when not (String.equal fallback_cascade effective_cascade_name) ->
                 Log.Keeper.warn
                   "%s: cascade %s provider cooldown pending (%ds); fail-opening to %s"
                   meta.name effective_cascade_name remaining_sec fallback_cascade;
                 fallback_cascade
             | _ -> effective_cascade_name)
        | None -> effective_cascade_name
      in
      (* PR-B: ollama saturation pre-skip.  If the resolved cascade
         is ollama-only and the [/api/ps] cache reports zero
         available slots, skip this cycle BEFORE [Agent.run] dispatch
         so the queued request cannot exceed the keeper turn budget
         and trip a FAILED cycle.  Probe failures fall through to the
         normal dispatch path (fail-open) so a flaky probe never
         starves the keeper. *)
      let saturation_skip_meta =
        let meta_for_check =
          { meta with cascade_name = effective_cascade_name }
        in
        let labels =
          Keeper_coordination.effective_model_labels_for_turn meta_for_check
        in
        match resolve_ollama_only_base_url labels with
        | None -> None
        | Some base_url ->
            if not (is_ollama_saturated base_url) then None
            else
              let info = Cascade_ollama_probe.cached_capacity base_url in
              let queue_len =
                match info with
                | Some i -> i.process_queue_length
                | None -> 0
              in
              let available =
                match info with
                | Some i -> i.process_available
                | None -> 0
              in
              Log.Keeper.info
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                "%s: ollama saturated for keeper=%s cascade=%s queue=%d \
                 available=%d \xe2\x80\x94 skipping turn"
                meta.name meta.name effective_cascade_name queue_len
                available;
              record_pre_dispatch_terminal_observation
                ~config
                ~meta
                ~generation
                ~cascade_name:effective_cascade_name
                ~outcome:"error"
                ~terminal_reason_code:"ollama_saturated"
                ~activity_kind:"keeper.turn_failed"
                ~trajectory_outcome:(Trajectory.Gated "ollama_saturated")
                ~keeper_turn_id
                ();
              Keeper_turn_fsm.emit_transition
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                ~prev:Keeper_turn_fsm.Cascade_routing
                (Keeper_turn_fsm.Failed
                   (Keeper_turn_fsm.Failure_cascade_unavailable
                      { base = base_url; resolved = None }));
              Prometheus.inc_counter
                Prometheus.metric_keeper_ollama_saturation_skip
                ~labels:[ ("keeper", meta.name);
                          ("cascade", effective_cascade_name) ]
                ();
              (match Eio_context.get_clock_opt () with
               | Some clock ->
                   (try Eio.Time.sleep clock (saturation_skip_sleep_duration ())
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Keeper.debug
                          "%s: saturation skip sleep failed: %s"
                          meta.name (Printexc.to_string exn))
               | None -> ());
              Some meta
      in
      (match saturation_skip_meta with
       | Some meta_after_skip -> Ok meta_after_skip
       | None ->
      let build_cascade_execution ~(cascade_name : string) :
          (cascade_execution, Oas.Error.sdk_error) result =
        let meta_for_cascade = { meta with cascade_name } in
        let model_labels =
          Keeper_coordination.effective_model_labels_for_turn meta_for_cascade
        in
        match ensure_api_keys_for_labels model_labels with
        | Error e -> Error (Oas.Error.Internal e)
        | Ok () -> (
            match ensure_local_discovery_ready model_labels with
            | Error e -> Error (Oas.Error.Internal e)
            | Ok () ->
                let max_context_resolution =
                  Keeper_exec_context.resolve_max_context_resolution
                    ~requested_override:meta.max_context_override model_labels
                in
                let max_context =
                  resolved_max_context_for_turn ~meta model_labels
                in
                let temperature =
                  Cascade_inference.resolve_temperature
                    ~cascade_name
                    ~fallback:Keeper_config.keeper_unified_temperature
                in
                let max_tokens =
                  let raw =
                    Cascade_inference.resolve_max_tokens
                      ~cascade_name
                      ~fallback:Keeper_config.keeper_unified_max_tokens
                  in
                  (* Capability gate: clamp to provider ceiling (TLA+ S3) *)
                  Cascade_inference.clamp_max_tokens_to_ceiling
                    ~provider_ceiling:(Some max_context) raw
                in
                Ok
                  {
                    cascade_name;
                    max_context_resolution;
                    max_context;
                    temperature;
                    max_tokens;
                  })
      in
      match build_cascade_execution ~cascade_name:effective_cascade_name with
      | Error err ->
          let terminal_reason_code =
            Printf.sprintf "pre_dispatch_%s"
              (Keeper_agent_error.terminal_reason_code_of_sdk_error err)
          in
          let error_message = Oas.Error.to_string err in
          record_pre_dispatch_terminal_observation
            ~config
            ~meta
            ~generation
            ~cascade_name:effective_cascade_name
            ~outcome:"error"
            ~terminal_reason_code
            ~activity_kind:"keeper.turn_blocked"
            ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
            ~error_kind:(sdk_error_kind err)
            ~error_message
            ~keeper_turn_id
            ();
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Cascade_routing
            (Keeper_turn_fsm.Failed
               (Keeper_turn_fsm.Failure_provider_error
                  { kind = sdk_error_kind err;
                    detail = error_message }));
          Error err
      | Ok initial_execution ->
      let turn_id = meta.runtime.usage.total_turns in
      (match
         Keeper_turn_livelock.guard_and_record_turn_start
           ~keeper:meta.name
           ~turn_id
           ~max_attempts:(turn_livelock_max_attempts ())
           ~stuck_after_sec:(turn_livelock_stuck_after_sec ())
           ()
       with
       | Keeper_turn_livelock.Blocked reason ->
           let reason_string =
             Keeper_turn_livelock.gate_reason_to_string reason
           in
           let terminal_reason_code =
             Printf.sprintf "turn_livelock:%s" reason_string
           in
           Log.Keeper.error
             ~keeper_name:meta.name ~turn_id:keeper_turn_id
             "%s: keeper turn livelock guard blocked dispatch turn=%d: %s"
             meta.name turn_id
             reason_string;
           record_pre_dispatch_terminal_observation
             ~config
             ~meta
             ~generation
             ~cascade_name:initial_execution.cascade_name
             (* β6: "blocked" was not in outcome_kind quad-state
                (ok/skipped/error/cancelled), causing operator_disposition
                to classify livelock-blocked turns as "unknown".  Map to
                "error" — livelock IS a turn failure; the specific reason
                is captured in terminal_reason_code. *)
             ~outcome:"error"
             ~terminal_reason_code
             ~activity_kind:"keeper.turn_blocked"
             ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
             ~keeper_turn_id
             ();
           Keeper_turn_fsm.emit_transition
             ~keeper_name:meta.name ~turn_id:keeper_turn_id
             ~prev:Keeper_turn_fsm.Cascade_routing
             (Keeper_turn_fsm.Failed
                (Keeper_turn_fsm.Failure_turn_livelock_blocked
                   { reason = reason_string }));
           Ok meta
       | Keeper_turn_livelock.Started _ ->
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Cascade_routing
        Keeper_turn_fsm.Awaiting_provider;
      (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
      Eio.Fiber.yield ();
      (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
      let system_prompt, user_message =
        Keeper_unified_prompt.build_prompt ~meta ~base_path:config.base_path
          ~observation ()
      in
      Eio.Fiber.yield ();
      let base_dir = session_base_dir config in
      (* Ensure session dir tree for filesystem fallback (issue #3019) *)
      Keeper_types.mkdir_p (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      let masc_root = Coord.masc_root_dir config in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~generation:meta.runtime.generation
      in
      let max_cost_usd = Keeper_config.keeper_tool_cost_max_usd () in
      (* 4. Build turn prompt callback: use our unified system prompt *)
      let build_turn_prompt ~base_system_prompt:_ ~messages:_
          : Keeper_agent_run.turn_prompt =
        (* Unified path already places soft context (continuity, worktree)
           in the user_message via Keeper_unified_prompt.build_prompt.
           No dynamic_context needed here. *)
        { system_prompt; dynamic_context = "" }
      in
      let prompt_timeout_metrics =
        Keeper_agent_run.build_prompt_metrics ~system_prompt
          ~dynamic_context:"" ~user_message
      in
      let prompt_timeout_estimate_tokens =
        max 1 prompt_timeout_metrics.estimated_total_tokens
      in
      let turn_affordances =
        Keeper_unified_metrics.observed_affordances_of_observation ~meta observation
      in
      (* 5. Run via OAS Agent.run() with transient-error retry *)
      (* Track whether side-effecting tool calls have been executed.
         If a board_post/comment/shell/file edit succeeded and then a
         transient error occurs, retrying would replay those tool calls and
         produce duplicates. In that case, we propagate the error instead of
         retrying.

         Uses the OAS Event_bus (ToolCalled + ToolCompleted) rather than
         MASC-side observers. The per-turn subscription is scoped by
         [filter_agent meta.name], so no cross-keeper contamination. *)
      let mutating_tools_committed = ref [] in
      let post_commit_failure_reason = ref None in
      let paused_meta_override = ref None in
      let current_turn_overflow_blocker = ref None in
      let event_bus_drain_active = Atomic.make true in
      let turn_event_bus_mu = Eio.Mutex.create () in
      let mark_paused_after_overflow ~run_meta ~reason =
        let paused_meta =
          pause_keeper_for_overflow
            ~config
            ~meta:run_meta
            ~reason
        in
        paused_meta_override := Some paused_meta
      in
      (* Side-effect tracking is driven by the OAS Event_bus (ToolCalled +
         ToolCompleted) rather than MASC-side observers. Pairing is by
         tool_name order within the per-turn subscription, which is safe
         because the turn is single-fibered and filter_agent restricts to
         this keeper. *)
      let event_bus_sub =
        match Keeper_event_bus.get () with
        | Some bus ->
          Some (Oas_bus_instrument.subscribe
                  ~purpose:"keeper_turn"
                  ~filter:(Oas.Event_bus.filter_agent meta.name) bus)
        | None -> None
      in
      let turn_event_bus = ref empty_turn_event_bus_summary in
      (* Per-tool-name queue of pending inputs from ToolCalled events.
         ToolCompleted pops the oldest input for that tool_name. *)
      let pending_tool_inputs : (string, Yojson.Safe.t Queue.t) Hashtbl.t =
        Hashtbl.create 8
      in
      let with_turn_event_bus_lock f =
        Eio.Mutex.use_rw ~protect:true turn_event_bus_mu f
      in
      let push_pending_input tool_name input =
        let q =
          match Hashtbl.find_opt pending_tool_inputs tool_name with
          | Some q -> q
          | None ->
              let q = Queue.create () in
              Hashtbl.add pending_tool_inputs tool_name q;
              q
        in
        Queue.add input q
      in
      let pop_pending_input tool_name =
        match Hashtbl.find_opt pending_tool_inputs tool_name with
        | Some q when not (Queue.is_empty q) -> Some (Queue.pop q)
        | _ -> None
      in
      let process_tool_events_for_side_effects
          (events : Oas.Event_bus.event list) : unit =
        List.iter
          (fun (evt : Oas.Event_bus.event) ->
            match evt.payload with
            | Oas.Event_bus.ToolCalled { tool_name; input; _ } ->
                push_pending_input tool_name input
            | Oas.Event_bus.ToolCompleted
                { tool_name; output = Ok _; _ } ->
                let input_opt = pop_pending_input tool_name in
                let input =
                  match input_opt with
                  | Some i -> i
                  | None ->
                      (* P2 silent-failure fix: pop_pending_input returns
                         None either when there's no queue for this tool
                         name, or when the queue is empty.  Either case
                         means a ToolCompleted arrived without a matching
                         ToolCalled — likely a race or an OAS event-bus
                         ordering bug.  Falling back to `Null` lets
                         downstream `has_mutating_side_effect_with_input`
                         continue, but it can undercount mutations.
                         Logging surfaces the mismatch so it can be
                         diagnosed instead of silently skewing audit data. *)
                      Log.Keeper.debug
                        "keeper:%s tool=%s ToolCompleted without matching ToolCalled — using Null input"
                        meta.name tool_name;
                      `Null
                in
                if
                  Keeper_exec_tools.has_mutating_side_effect_with_input
                    ~tool_name ~input
                then
                  mutating_tools_committed :=
                    tool_name :: !mutating_tools_committed
            | Oas.Event_bus.ToolCompleted
                { tool_name; output = Error _; _ } ->
                (* Failed tool: drop the matching pending input. *)
                let _ = pop_pending_input tool_name in
                ignore tool_name
            | _ -> ())
          events
      in
      (* PR-J: [?site] labels the call-site so PromQL can attribute
         drain pressure to background polling vs unsubscribe vs the
         retry path. [outcome=drained] when at least one event was
         pulled, [outcome=empty] otherwise (the latter is the no-op
         tick that establishes the lock-acquire baseline). *)
      let drain_turn_event_bus ?(site = "unspecified") () =
        with_turn_event_bus_lock (fun () ->
          let events =
            match event_bus_sub, Keeper_event_bus.get () with
            | Some sub, Some _bus -> Oas_bus_instrument.drain sub
            | _ -> []
          in
          let outcome = if events = [] then "empty" else "drained" in
          Prometheus.inc_counter Prometheus.metric_keeper_event_bus_drain
            ~labels:[("site", site); ("outcome", outcome)] ();
          process_tool_events_for_side_effects events;
          let summary = summarize_turn_event_bus events in
          turn_event_bus :=
            merge_turn_event_bus_summary !turn_event_bus summary;
          !turn_event_bus)
      in
      let committed_mutating_tools_snapshot () =
        with_turn_event_bus_lock (fun () ->
          EC.committed_mutating_tools !mutating_tools_committed)
      in
      let start_background_turn_event_bus_drain ~clock =
        match event_bus_sub, Eio_context.get_switch_opt () with
        | Some _, Some sw ->
            Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                if Atomic.get event_bus_drain_active then begin
                  (try
                     ignore (drain_turn_event_bus ~site:"background_poll" ())
                   with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       Log.Keeper.warn
                         "%s: keeper_turn event-bus drain failed: %s"
                         meta.name (Printexc.to_string exn));
                  (* 2026-04-20: 0.25s → 0.05s.  OAS publishes a burst
                     of events per tool cycle (ToolCalled / ToolResult /
                     ToolCompleted + assistant / usage).  With 0.25s
                     polling, a tool-heavy turn could accumulate >256
                     events for this subscriber before the next drain,
                     saturating the default Eio.Stream buffer and
                     blocking [oas_bus_instrument.publish].  Fleet logs
                     2026-04-20 recorded subscriber_purpose=keeper_turn
                     depth peaks 219–469 (the 469 sample confirmed
                     publishers blocked: 469 − 256 buffer ≈ 213 stuck
                     sends).  50 ms keeps drain latency under the
                     typical inter-event spacing so depth stays below
                     the warn threshold outside tool bursts.  Override
                     via [MASC_KEEPER_TURN_DRAIN_INTERVAL_SEC]. *)
                  Eio.Time.sleep clock (turn_event_bus_drain_interval_sec ());
                  loop ()
                end
              in
              loop ())
        | _ -> ()
      in
      let unsubscribe_event_bus () =
        Atomic.set event_bus_drain_active false;
        ignore (drain_turn_event_bus ~site:"unsubscribe_final" ());
        match event_bus_sub, Keeper_event_bus.get () with
        | Some sub, Some bus -> Oas_bus_instrument.unsubscribe bus sub
        | _ -> ()
      in
      (* Mark turn boundary for the composite observer (issue #7122).
         [mark_turn_started] installs [current_turn_observation = Some _]
         so the composite observer can surface live in-turn states like
         [`Executing`]. The matching [mark_turn_finished] in the finally
         block clears the field, preventing stale state on idle keepers. *)
      Keeper_registry.mark_turn_started
        ~base_path:config.base_path meta.name;
      let meta =
        match Keeper_registry.get ~base_path:config.base_path meta.name with
        | Some entry ->
          let _ =
            write_meta_with_merge
              ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
              config entry.meta
          in
          entry.meta
        | None -> meta
      in
      Keeper_registry.mark_turn_measurement
        ~base_path:config.base_path meta.name;
      (match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some { current_turn_observation = Some { measurement = Some _; _ }; _ } ->
           Keeper_registry.set_turn_decision_stage
             ~base_path:config.base_path meta.name
             Keeper_registry.Decision_guard_ok
       | _ -> ());
      let last_execution = ref initial_execution in
      let last_timeout_budget : oas_timeout_budget_resolution option ref = ref None in
      let degraded_retry_info = ref None in
      let cascade_rotation_attempts = ref [] in
      let record_cascade_rotation_attempt
          ~(from_cascade : string)
          ~(retry : EC.degraded_retry)
          ~(outcome : string)
          (err : Oas.Error.sdk_error) =
        let attempt : Keeper_execution_receipt.cascade_rotation_attempt =
          {
            from_cascade;
            to_cascade = retry.next_cascade;
            reason = retry.fallback_reason;
            outcome;
            error_kind = Some (sdk_error_kind err);
            error_message = Some (Oas.Error.to_string err);
            recorded_at = now_iso ();
          }
        in
        cascade_rotation_attempts := attempt :: !cascade_rotation_attempts
      in
      let run_result, latency_ms =
        (* Cancel-safe cleanup (#9747): stdlib [Fun.protect] wraps cleanup
           exceptions in [Fun.Finally_raised], losing the outer
           [Eio.Cancel.Cancelled]. Cleanup here swallows Cancelled (the
           outer one is already in flight) and logs non-cancel exceptions
           instead of propagating them. *)
        let cleanup () =
          (try unsubscribe_event_bus () with
           | Eio.Cancel.Cancelled _ -> ()
           | e ->
             Log.Keeper.warn
               "%s: unsubscribe_event_bus in turn cleanup raised: %s"
               meta.name (Printexc.to_string e));
          (try
             Keeper_registry.mark_turn_finished
               ~base_path:config.base_path meta.name
           with
           | Eio.Cancel.Cancelled _ -> ()
           | e ->
             Log.Keeper.warn
               "%s: mark_turn_finished in turn cleanup raised: %s"
               meta.name (Printexc.to_string e))
        in
        match
        Keeper_exec_context.timed (fun () ->
          match Eio_context.get_clock () with
          | Error msg -> Error (Oas.Error.Internal msg)
          | Ok clock ->
          let timeout_sec =
            Keeper_runtime_resolved.turn_timeout_sec ()
          in
          start_background_turn_event_bus_drain ~clock;
          let turn_deadline = Eio.Time.now clock +. timeout_sec in
          let remaining_turn_budget_s () =
            Float.max 0.0 (turn_deadline -. Eio.Time.now clock)
          in
          let keeper_profile =
            Keeper_types_profile.load_keeper_profile_defaults meta.name
          in
          let max_idle_turns, max_turns =
            match channel with
            | Keeper_world_observation.Reactive ->
                ( Keeper_runtime_resolved.reactive_max_idle_turns (),
                  Keeper_types_profile.effective_max_turns_per_call
                    keeper_profile )
            | Keeper_world_observation.Scheduled_autonomous ->
                ( Keeper_runtime_resolved.autonomous_max_idle_turns (),
                  Keeper_types_profile
                  .effective_max_turns_per_call_scheduled_autonomous
                    keeper_profile )
          in
          let initial_tool_requirement =
            if
              Keeper_agent_run.should_require_tools_for_initial_turn
                ~max_turns ~turn_affordances
            then "required"
            else "optional"
          in
          let do_run ~(execution : cascade_execution) ~run_meta ~run_generation ~is_retry
              ~oas_timeout_s =
            last_execution := execution;
            Otel_genai.with_keeper_turn_span
              ~keeper_name:run_meta.name
              ~agent_name:run_meta.agent_name
              ~cascade_name:execution.cascade_name
              ~trace_id:(Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
              ~generation:run_generation
              ~max_context:execution.max_context
              ~max_turns
              ~max_idle_turns
              ~channel:(Keeper_world_observation.channel_to_string channel)
              ~is_retry
              ~current_task_id:
                (Option.map Keeper_id.Task_id.to_string
                   run_meta.current_task_id)
              (fun () ->
                Keeper_turn_fsm.emit_transition
                  ~keeper_name:meta.name ~turn_id:keeper_turn_id
                  ~prev:Keeper_turn_fsm.Awaiting_provider
                  Keeper_turn_fsm.Streaming;
                try
                  Keeper_agent_run.run_turn ~config ~meta:run_meta ~base_dir
                    ~max_context:execution.max_context ~build_turn_prompt
                    ~user_message ~cascade_name:execution.cascade_name
                    ~turn_affordances
                    ?provider_filter:(Env_config_keeper.KeeperCascade.provider_allowlist ())
                    ~generation:run_generation
                    ~max_turns
                    ~max_idle_turns
                    ~history_user_source:"world_state_prompt"
                    ~history_assistant_source:"internal_assistant"
                    ~degraded_retry_applied:(Option.is_some !degraded_retry_info)
                    ?degraded_retry_cascade:
                      (Option.map
                         (fun (retry : EC.degraded_retry) -> retry.next_cascade)
                         !degraded_retry_info)
                    ?fallback_reason:
                      (Option.map
                         (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
                         !degraded_retry_info)
                    ~cascade_rotation_attempts:
                      (List.rev !cascade_rotation_attempts)
                    ~temperature:execution.temperature
                    ~max_tokens:execution.max_tokens
                    ~oas_timeout_s
                    ?max_cost_usd
                    ~trajectory_acc
                    ~is_retry
                    ?shared_context
                    ?event_bus:(Keeper_event_bus.get ())
                    ()
                with Eio.Cancel.Cancelled _ as e ->
                  (* Cycle 1b-iv: external cancellation that escapes the
                     in-band receipt builder in [Keeper_agent_run.run_turn].
                     The 14 inner Cancel handlers all re-raise; without an
                     outer catch the receipt for this turn is silently
                     dropped (FSM emits Streaming then nothing — the turn
                     just disappears from the operator's timeline).

                     Emit a minimal cancelled receipt + matching FSM
                     Cancelled transition before re-raising. The cancel
                     reason is conservatively classified as
                     [Cancelled_supervisor_stop] because Eio.Cancel does
                     not expose the originating cancel context here;
                     refining this via supervisor / fleet flag inspection
                     is a follow-up. *)
                  record_pre_dispatch_terminal_observation
                    ~config
                    ~meta:run_meta
                    ~generation:run_generation
                    ~cascade_name:execution.cascade_name
                    ~outcome:"cancelled"
                    ~terminal_reason_code:"external_cancel"
                    ~activity_kind:"keeper.turn_cancelled"
                    ~trajectory_outcome:
                      (Trajectory.Gated "external_cancel")
                    ~keeper_turn_id
                    ();
                  Keeper_turn_fsm.emit_transition
                    ~keeper_name:meta.name ~turn_id:keeper_turn_id
                    ~prev:Keeper_turn_fsm.Streaming
                    (Keeper_turn_fsm.Cancelled
                       Keeper_turn_fsm.Cancelled_supervisor_stop);
                  raise e)
          in
          let fail_open_rotation_cascades =
            active_fail_open_rotation_cascades ()
          in
          let rec retry_loop ~run_meta ~(execution : cascade_execution)
              ~run_generation
              ~attempt ~is_retry
              ~overflow_retry_used
              ~attempted_cascades =
            let mark_terminal_error err =
              if EC.is_cascade_exhausted_error err then begin
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_exhausted;
                Prometheus.inc_counter
                  Prometheus.metric_keeper_fsm_edge_transitions
                  ~labels:[("edge", "kcl_to_ktc_exhaustion")] ();
                (* Cycle 52 narrative: cascade exhaustion is a silent
                   failure on dashboards reading only Turn_failed.  The
                   fsm_edge counter records the transition, but operators
                   forensically investigating "why is this keeper stuck?"
                   benefit from a structured WARN line distinguishing
                   'all cascades exhausted' from 'single transient error'.
                   Companion to PR #11708 (gate rejection narrative) and
                   PR #11717 (unmapped regression alert). *)
                Log.Keeper.warn
                  "%s: all cascades exhausted (terminal) — last_err=%s \
                   attempt=%d attempted_cascades=[%s]"
                  meta.name (Oas.Error.to_string err) attempt
                  (String.concat ", " attempted_cascades)
              end
              else begin
                Keeper_registry.set_turn_phase
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Turn_finalizing;
                (* Cycle 52 narrative companion: non-exhaustion terminal
                   errors (transient).  Logged so dashboard readers can
                   distinguish exhaustion from transient failure without
                   re-parsing Turn_finalizing reason fields. *)
                Log.Keeper.warn
                  "%s: turn terminal (non-exhaustion error) — err=%s \
                   attempt=%d"
                  meta.name (Oas.Error.to_string err) attempt
              end
            in
            let attempt_timeout_budget = ref None in
            let max_turns =
              match channel with
              | Keeper_world_observation.Reactive ->
                  Keeper_types_profile.effective_max_turns_per_call
                    keeper_profile
              | Keeper_world_observation.Scheduled_autonomous ->
                  Keeper_types_profile
                  .effective_max_turns_per_call_scheduled_autonomous
                    keeper_profile
            in
            let attempt_result =
              match
                resolve_bounded_oas_timeout_budget_with_turn_budget
                  ~max_turns
                  ~estimated_input_tokens:prompt_timeout_estimate_tokens
                  ~remaining_turn_budget_s:(remaining_turn_budget_s ())
              with
              | None ->
                  Error
                    (Oas.Error.Api
                       (Timeout
                          {
                            message =
                              Printf.sprintf
                                "Turn wall-clock budget exhausted before retry (remaining=%.1fs)"
                                (remaining_turn_budget_s ());
                          }))
              | Some timeout_budget ->
                  attempt_timeout_budget := Some timeout_budget;
                  last_timeout_budget := Some timeout_budget;
                  Keeper_registry.set_turn_cascade_state
                    ~base_path:config.base_path meta.name
                    Keeper_registry.Cascade_trying;
                  do_run ~execution ~run_meta ~run_generation ~is_retry
                    ~oas_timeout_s:timeout_budget.effective_timeout_sec
            in
            match attempt_result with
            | Ok result ->
                let selected_model =
                  match result.cascade_observation with
                  | Some observation -> observation.selected_model
                  | None -> None
                in
                Keeper_registry.set_turn_selected_model
                  ~base_path:config.base_path meta.name
                  selected_model;
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_done;
                Ok result
            | Error err ->
                let err =
                  reclassify_oas_timeout_for_attempt
                    ~timeout_budget:!attempt_timeout_budget err
                in
                let _ = drain_turn_event_bus ~site:"reconcile_pre_check" () in
                let committed_tools = committed_mutating_tools_snapshot () in
                if committed_tools <> []
                   && Keeper_tool_registry.all_tools_reconcile_safe
                        committed_tools
                   && (EC.is_auto_recoverable_turn_error err
                       || EC.is_required_tool_contract_violation err)
                then begin
                  (* All committed tools are board-like (duplicate-tolerant)
                     AND the failure is transient or the server rejected the
                     request body before processing (parse error).  Parse
                     errors mean the LLM never saw the request, so no risk
                     of duplicate processing.  The keeper's next cycle will
                     build a fresh prompt that may avoid the parse issue. *)
                  let err_preview = short_preview (Oas.Error.to_string err) in
                  let reason =
                    if EC.is_server_rejected_parse_error err then "server parse rejection"
                    else if EC.is_required_tool_contract_violation err then
                      "required tool contract violation"
                    else "transient error"
                  in
                  Log.Keeper.warn
                    "%s: %s after committed reconcile-safe tool(s) [%s] — auto-recovering (error: %s)"
                    meta.name reason
                    (String.concat ", " committed_tools)
                    err_preview;
                  mark_terminal_error err;
                  Error err
                end else if committed_tools <> [] then begin
                  let reclassified, failure_reason =
                    match
                      EC.classify_post_commit_failure
                        ~tool_names:committed_tools
                        err
                    with
                    | Some classified -> classified
                    | None ->
                        ( EC.reclassify_error_after_side_effect
                            ~tool_names:committed_tools err,
                          Keeper_registry.Ambiguous_partial_commit {
                            kind = Keeper_registry.Post_commit_failure;
                            detail =
                              EC.summarize_post_commit_failure
                                ~tool_names:committed_tools
                                ~kind:Keeper_registry.Post_commit_failure
                                err;
                          } )
                  in
                  post_commit_failure_reason := Some failure_reason;
                  let err_preview = short_preview (Oas.Error.to_string err) in
                  if EC.is_transient_network_error err then
                    Log.Keeper.error
                      "%s: transient provider error after committed mutating tool call(s) [%s] — treating as integrity failure, skipping retry to prevent duplicate (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview
                  else
                    Log.Keeper.error
                      "%s: error after committed mutating tool call(s) [%s] — turn outcome is ambiguous and requires reconcile (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview;
                  mark_terminal_error reclassified;
                  Error reclassified
                end else if
                  (* Fast-fail on second consecutive contract violation: if
                     we already rotated once because the LLM only used
                     passive/read-only tools, rotating to a weaker cascade
                     is unlikely to change the LLM's choice on the same
                     prompt.  Each rotation eats ~600s of turn budget, and
                     in production we observe 4–5 rotations all hitting
                     the same violation before the OAS retry guard
                     finally aborts the cycle (see fleet logs:
                     "passive status/read tools" cascade=big_three →
                     keeper_unified → kimi_cli_keeper → … →
                     oas_timeout_budget at 1064s/1200s).  Cap rotation
                     at 1 for this error class so the keeper releases
                     its turn budget for actionable work. *)
                  EC.is_required_tool_contract_violation err
                  && List.length attempted_cascades >= 1
                then begin
                  Log.Keeper.warn
                    "%s: required_tool_contract_violation on second cascade \
                     (%s after %d prior rotation(s)) — skipping further \
                     rotation; rotating again is unlikely to change the \
                     model's passive-tool choice. Error: %s"
                    meta.name execution.cascade_name
                    (List.length attempted_cascades)
                    (short_preview (Oas.Error.to_string err));
                  Prometheus.inc_counter
                    "masc_keeper_contract_violation_rotation_capped_total"
                    ~labels:[ ("keeper", meta.name) ]
                    ();
                  mark_terminal_error err;
                  Error err
                end else
                  match
                    next_fail_open_cascade_for_turn_with_budget
                      ?rotation_cascades:fail_open_rotation_cascades
                      ~base_cascade:meta.cascade_name
                      ~effective_cascade:execution.cascade_name
                      ~tool_requirement:initial_tool_requirement
                      ~attempted_cascades
                      ~estimated_input_tokens:
                        prompt_timeout_estimate_tokens
                      ~max_turns
                      ~remaining_turn_budget_s:(remaining_turn_budget_s ())
                      err
                  with
                  | Degraded_retry_allowed degraded_retry -> (
                      match
                        build_cascade_execution
                          ~cascade_name:degraded_retry.next_cascade
                      with
                      | Error fail_open_err ->
                          record_cascade_rotation_attempt
                            ~from_cascade:execution.cascade_name
                            ~retry:degraded_retry
                            ~outcome:"setup_failed"
                            fail_open_err;
                          Log.Keeper.warn
                            "%s: recoverable cascade failure in %s suggested degraded retry to %s (reason=%s), but retry setup failed: %s"
                            meta.name execution.cascade_name
                            degraded_retry.next_cascade
                            degraded_retry.fallback_reason
                            (short_preview (Oas.Error.to_string fail_open_err));
                          mark_terminal_error fail_open_err;
                          Error fail_open_err
                      | Ok next_execution ->
                          record_cascade_rotation_attempt
                            ~from_cascade:execution.cascade_name
                            ~retry:degraded_retry
                            ~outcome:"retry_scheduled"
                            err;
                          degraded_retry_info := Some degraded_retry;
                          Log.Keeper.warn
                            "%s: recoverable cascade failure in %s; rotation retry on cascade=%s reason=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s: %s"
                            meta.name execution.cascade_name
                            next_execution.cascade_name
                            degraded_retry.fallback_reason
                            next_execution.max_context
                            next_execution.max_context_resolution.effective_budget
                            next_execution.max_context_resolution.primary_budget
                            (match
                               next_execution.max_context_resolution.requested_override
                             with
                             | Some requested -> string_of_int requested
                             | None -> "none")
                            (short_preview (Oas.Error.to_string err));
                          Eio.Fiber.yield ();
                          retry_loop ~run_meta ~execution:next_execution
                            ~run_generation
                            ~attempt:1
                            ~is_retry:true
                            ~overflow_retry_used
                            ~attempted_cascades:
                              (next_execution.cascade_name :: attempted_cascades))
                  | Degraded_retry_budget_exhausted degraded_retry ->
                      Log.Keeper.warn
                        "%s: recoverable cascade failure in %s suggested degraded retry to %s (reason=%s), but remaining turn budget %.1fs is below the OAS retry guard/minimum; ending this cycle: %s"
                        meta.name execution.cascade_name
                        degraded_retry.next_cascade
                        degraded_retry.fallback_reason
                        (remaining_turn_budget_s ())
                        (short_preview (Oas.Error.to_string err));
                      mark_terminal_error err;
                      Error err
                  | No_degraded_retry when EC.is_transient_network_error err
                              && attempt <= EC.max_transient_retries ->
                      let delay = EC.transient_backoff_sec attempt in
                      Log.Keeper.warn
                        "%s: transient network error cascade=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s retry=%d/%d backoff=%.0fs: %s"
                        meta.name execution.cascade_name
                        execution.max_context
                        execution.max_context_resolution.effective_budget
                        execution.max_context_resolution.primary_budget
                        (match execution.max_context_resolution.requested_override with
                         | Some requested -> string_of_int requested
                         | None -> "none")
                        attempt EC.max_transient_retries delay
                        (short_preview (Oas.Error.to_string err));
                      Eio.Time.sleep clock delay;
                      retry_loop ~run_meta ~execution ~run_generation
                        ~attempt:(attempt + 1)
                        ~is_retry:true ~overflow_retry_used
                        ~attempted_cascades
                  | No_degraded_retry when EC.is_context_overflow err ->
                  let current_turn_event_bus =
                    drain_turn_event_bus ~site:"context_overflow_capture" () in
                  dispatch_keeper_phase_event
                    ~config
                    ~keeper_name:meta.name
                    (context_overflow_event_of_error
                       ~fallback_tokens:execution.max_context
                       ~turn_event_bus:current_turn_event_bus
                       err);
                  if not overflow_retry_used then
                    match
                      recover_context_overflow_retry
                        ~meta:run_meta
                        ~base_dir
                        ~max_cascade_context:execution.max_context
                        ~error:err
                    with
                    | Some retry_plan ->
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_compacting;
                        current_turn_overflow_blocker :=
                          Some (Oas.Error.to_string err);
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          Keeper_state_machine.Compaction_started;
                        Prometheus.inc_counter
                          Prometheus.metric_keeper_fsm_edge_transitions
                          ~labels:[("edge", "kmc_to_ksm_compact_completed")] ();
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          (Keeper_state_machine.Compaction_completed
                             {
                               before_tokens =
                                 retry_plan.compaction.before_tokens;
                               after_tokens =
                                 retry_plan.compaction.after_tokens;
                             });
                        Keeper_registry.prepare_turn_retry_after_compaction
                          ~base_path:config.base_path meta.name;
                        let retry_meta =
                          if retry_plan.retry_generation = run_meta.runtime.generation
                          then run_meta
                          else
                            map_runtime
                              (fun rt ->
                                {
                                  rt with
                                  generation = retry_plan.retry_generation;
                                })
                              run_meta
                        in
                        let retry_execution =
                          { execution with max_context = retry_plan.retry_max_context }
                        in
                        Eio.Fiber.yield ();
                        retry_loop
                          ~run_meta:retry_meta
                          ~execution:retry_execution
                          ~run_generation:retry_plan.retry_generation
                          ~attempt:1
                          ~is_retry:true
                          ~overflow_retry_used:true
                          ~attempted_cascades
                    | None ->
                        mark_paused_after_overflow
                          ~run_meta
                          ~reason:"auto_compact_recovery_unavailable";
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_finalizing;
                        Error err
                  else begin
                    mark_paused_after_overflow
                      ~run_meta
                      ~reason:"overflow_persisted_after_auto_compact_retry";
                      Keeper_registry.set_turn_phase
                        ~base_path:config.base_path meta.name
                        Keeper_registry.Turn_finalizing;
                    Error err
                  end
                | No_degraded_retry ->
                    mark_terminal_error err;
                    Error err
          in
          (* Wall-clock timeout guards against indefinite TCP-level hangs
             from upstream LLM providers. Without this, a single stalled
             connection blocks the keeper fiber forever. *)
          (try
            Eio.Time.with_timeout_exn clock timeout_sec
              (fun () ->
                retry_loop ~run_meta:meta ~execution:initial_execution
                  ~run_generation:generation ~attempt:1
                  ~is_retry:false ~overflow_retry_used:false
                  ~attempted_cascades:[initial_execution.cascade_name])
          with Eio.Time.Timeout ->
            let msg =
              Printf.sprintf
                "Turn wall-clock timeout after %.0fs (MASC_KEEPER_TURN_TIMEOUT_SEC)"
                timeout_sec
            in
            Log.Keeper.error "%s: %s" meta.name msg;
            let _ = drain_turn_event_bus ~site:"error_path_drain" () in
            let committed_tools = committed_mutating_tools_snapshot () in
            if committed_tools <> []
               && Keeper_tool_registry.all_tools_reconcile_safe
                    committed_tools
            then begin
              (* Timeouts are inherently transient — the provider was
                 reachable (tools executed) but took too long.  Board-only
                 committed tools are duplicate-tolerant, so we auto-recover
                 instead of recording an integrity failure.  Unlike the
                 retry_loop path, no is_transient check is needed: a
                 wall-clock timeout after successful tool execution is
                 always transient by nature. *)
              Log.Keeper.warn
                "%s: turn wall-clock timeout after committed reconcile-safe tool(s) [%s] — auto-recovering (timeout: %s)"
                meta.name
                (String.concat ", " committed_tools)
                msg;
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error (Oas.Error.Api (Timeout { message = msg }))
            end else if committed_tools <> [] then begin
              let timeout_err =
                Oas.Error.Api (Timeout { message = msg })
              in
              let reclassified, failure_reason =
                match
                  EC.classify_post_commit_failure
                    ~tool_names:committed_tools
                    ~kind:Keeper_registry.Post_commit_timeout
                    timeout_err
                with
                | Some classified -> classified
                | None ->
                    ( EC.reclassify_error_after_side_effect
                        ~tool_names:committed_tools
                        timeout_err,
                      Keeper_registry.Ambiguous_partial_commit {
                        kind = Keeper_registry.Post_commit_timeout;
                        detail =
                          EC.summarize_post_commit_failure
                            ~tool_names:committed_tools
                            ~kind:Keeper_registry.Post_commit_timeout
                            timeout_err;
                      } )
              in
              post_commit_failure_reason := Some failure_reason;
              Log.Keeper.error
                "%s: turn wall-clock timeout after committed mutating tool call(s) [%s] — treating as integrity failure; evidence recorded for next-turn observation"
                meta.name
                (String.concat ", " committed_tools);
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error reclassified
            end else begin
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error
                (Oas_worker_named.sdk_error_of_masc_internal_error
                   (Oas_worker_named.Turn_timeout
                      { elapsed_sec = timeout_sec }))
            end))
        with
        | result -> cleanup (); result
        | exception e -> cleanup (); raise e
      in
      let turn_event_bus = drain_turn_event_bus ~site:"turn_finalize_capture" () in
      (match turn_event_bus.correlation_id with
       | Some correlation_id ->
           Keeper_registry.set_last_correlation_id
             ~base_path:config.base_path meta.name
             correlation_id
       | None -> ());
      let degraded_retry_info = !degraded_retry_info in
      let degraded_retry_applied = Option.is_some degraded_retry_info in
      let degraded_retry_cascade =
        Option.map
          (fun (retry : EC.degraded_retry) -> retry.next_cascade)
          degraded_retry_info
      in
      let fallback_reason =
        Option.map
          (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
          degraded_retry_info
      in
      match run_result with
      | Error err ->
          let final_execution = !last_execution in
          finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc
            (Trajectory.Failed (Oas.Error.to_string err));
          let e_str = Oas.Error.to_string err in
          let is_transient = EC.is_transient_network_error err in
          (match Oas_worker_named.classify_masc_internal_error err with
           | Some (Oas_worker_named.Oas_timeout_budget _) ->
               Prometheus.inc_counter
                 Prometheus.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", "structural_budget")] ()
           | Some (Oas_worker_named.Turn_timeout _) ->
               Prometheus.inc_counter
                 Prometheus.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", "turn_wall_clock")] ()
           | _ -> (
               match err with
               | Oas.Error.Api (Timeout { message }) ->
               let classification =
                 if is_transient then "transient_network"
                 else if EC.is_structural_oas_timeout_message message then
                   "structural_budget"
                 else "other_timeout"
               in
               Prometheus.inc_counter
                 Prometheus.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", classification)] ()
               | _ -> ()));
          let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
          let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
          let is_ambiguous_partial = EC.is_ambiguous_side_effect_error err in
          Prometheus.inc_counter Prometheus.metric_keeper_turns
            ~labels:[("keeper_name", meta.name); ("outcome", "failure")] ();
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Streaming
            (Keeper_turn_fsm.Failed
               (Keeper_turn_fsm.Failure_provider_error
                  { kind = sdk_error_kind err;
                    detail = short_preview e_str }));
          Log.Keeper.error
            "%s: keeper cycle FAILED cascade=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s latency=%dms%s error=%s"
            meta.name final_execution.cascade_name
            final_execution.max_context
            final_execution.max_context_resolution.effective_budget
            final_execution.max_context_resolution.primary_budget
            (match final_execution.max_context_resolution.requested_override with
             | Some requested -> string_of_int requested
             | None -> "none")
            latency_ms
            (if is_ambiguous_partial then
               " (ambiguous partial commit)"
             else if is_server_parse_rejection then
               " (server parse rejection, auto-recoverable)"
             else if is_transient then
               " (transient, cooldown preserved)"
             else "")
            (short_preview e_str);
          let social_state, social_transition_reason =
            Social.derive_failure_state ~meta ~observation
              ~previous_state:previous_social_state
              ~is_auto_recoverable ~reason:e_str
          in
          let failure_meta_base =
            match !paused_meta_override with
            | Some paused_meta -> paused_meta
            | None -> meta
          in
          let updated_meta =
            Keeper_unified_metrics.update_metrics_from_failure
              failure_meta_base
              ~latency_ms
              ~observation
              ~reason:e_str
              ~is_transient
              ~social_state
              ~social_transition_reason:
                (Social.transition_reason_to_string social_transition_reason)
              ~sdk_error:err
              ()
          in
          let err, updated_meta =
            if is_ambiguous_partial then begin
              (* Ambiguous partial commit must not auto-resume silently.
                 The keeper is paused and an explicit continue gate is
                 raised for the operator. Approving the gate auto-resumes
                 the keeper; rejecting it leaves the keeper paused. *)
              let committed_tools = committed_mutating_tools_snapshot () in
              let failure_reason =
                Option.value
                  ~default:
                    (Keeper_registry.Ambiguous_partial_commit {
                      kind = Keeper_registry.Post_commit_failure;
                      detail = e_str;
                    })
                  !post_commit_failure_reason
              in
              Keeper_registry.set_failure_reason ~base_path:config.base_path
                meta.name
                (Some failure_reason);
              match
                sync_keeper_paused_state
                  ~config
                  ~meta:updated_meta
                  ~paused:true
              with
              | Ok paused_meta ->
                  let approval_id =
                    enqueue_partial_commit_continue_gate
                      ~config
                      ~meta:paused_meta
                      ~failure_reason
                      ~committed_tools
                      ~error_detail:e_str
                  in
                  Log.Keeper.warn
                    "%s: ambiguous partial commit (tools=[%s], reason=%s); \
                     paused keeper and opened continue gate id=%s"
                    meta.name
                    (String.concat ", " committed_tools)
                    (Keeper_registry.failure_reason_to_string failure_reason)
                    approval_id;
                  (err, paused_meta)
              | Error sync_err ->
                  let combined_err =
                    Oas.Error.Internal
                      (Printf.sprintf
                         "%s: ambiguous partial commit pause sync failed: %s \
                          (original_error=%s)"
                         meta.name sync_err (short_preview e_str))
                  in
                  Log.Keeper.error "%s" (Oas.Error.to_string combined_err);
                  (combined_err, updated_meta)
            end else
              (err, updated_meta)
          in
          let e_str = Oas.Error.to_string err in
          Keeper_unified_metrics.append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms
            ~outcome:(if is_ambiguous_partial then "partial" else "error")
            ~degraded_retry_applied
            ?degraded_retry_cascade
            ?fallback_reason
            ~social_state
            ~error:e_str ();
          (* #9769 root fix: heartbeat-field-merge prevents the
             turn-failure retry from clobbering heartbeat-owned fields
             (joined_room_ids, last_seen_seq_by_room), which was the
             dominant source of the observed CAS race exhaustion after
             keeper OAS timeout. *)
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               config updated_meta
           with
           | Ok () -> ()
           | Error msg ->
               if is_version_conflict_error msg then
                 Log.Keeper.warn
                   "write_meta lost CAS race after retries (turn failure path): %s" msg
               else
                 Log.Keeper.error
                   "write_meta failed after unified turn failure: %s" msg);
          if is_ambiguous_partial then begin
            let failure_reason =
              Option.value
                ~default:
                  (Keeper_registry.Ambiguous_partial_commit {
                    kind = Keeper_registry.Post_commit_failure;
                    detail = e_str;
                  })
                !post_commit_failure_reason
            in
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some failure_reason);
            let committed_tools = committed_mutating_tools_snapshot () in
            Log.Keeper.info
              "%s: reconcile-required failure latched as %s after committed tools [%s]"
              meta.name
              (Keeper_registry.failure_reason_to_string failure_reason)
              (String.concat ", " committed_tools)
          end;
          let base_path = config.base_path in
          (* Transient errors (429 rate limit, 503 overloaded, network
             timeout) do not count toward the consecutive failure threshold.
             They are already retried at the turn level with backoff; killing
             the keeper fiber for a transient API blip is an overreaction
             that causes unnecessary restarts and context loss.
             Only persistent errors (auth failure, config error, context
             overflow after compaction) increment the crash counter. *)
          if not is_auto_recoverable then
            Keeper_registry.increment_turn_failures ~base_path meta.name
          else
            Log.Keeper.info
              "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
              meta.name (short_preview e_str);
          let count = Keeper_registry.get_turn_failures ~base_path meta.name in
          let threshold =
            Runtime_params.get Governance_registry.keeper_max_turn_failures
          in
          record_turn_failure_stress
            ~meta
            ~is_auto_recoverable
            ~consecutive:count
            ~threshold
            ~err;
          (* Stamp [last_failure_reason] on FIRST cascade_exhausted-class
             failure (not just at threshold).  Without this, the stale
             watchdog kills with [idle 328s] and operators see no signal
             until the 3rd failure trips auto-pause below — by which time
             the keeper has been silently burning cycles for ~90s on a
             cascade with zero callable models.

             Production evidence (2026-04-27 system_log): 18 events of
             "no callable models" today on cascade=keeper_unified, but
             [last_failure_reason] stayed None for the affected keepers
             so the watchdog kill message read [idle 328s] with no
             attribution.  Operators had no way to distinguish
             "stuck=cascade_exhausted" from "stuck=genuinely idle".

             Reset path is unchanged: any successful turn clears the
             field via [reset_turn_failures] + [set_failure_reason None]
             at line 966-967.  Auto-pause site below (line 2275) still
             stamps the same value at threshold — idempotent overwrite. *)
          if EC.is_cascade_exhausted_error err && count > 0 then
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some (Keeper_registry.Turn_consecutive_failures count));
          (* task-074 (#fleet-stall 2026-04-26): break the supervisor restart
             loop on cascade_exhausted. Without this guard, [count >= threshold]
             below raises [Keeper_fiber_crash], the supervisor restarts the
             fiber, the same cascade still has no working provider, and the
             keeper bursts then stalls again. Auto-pausing instead gives the
             operator a chance to fix the cascade before another restart cycle
             burns more turns. The pause uses the same [sync_keeper_paused_state]
             entry point as operator-driven pause, so [operator_paused] stays
             the SSOT — no new state surface, dashboard already renders this. *)
          let cascade_auto_paused =
            EC.is_cascade_exhausted_error err
            && count >= Keeper_behavioral_regime.turn_fail_streak_threshold
            && not updated_meta.paused
          in
          if cascade_auto_paused then begin
            match
              sync_keeper_paused_state ~config ~meta:updated_meta ~paused:true
            with
            | Ok _ ->
                Keeper_registry.set_failure_reason ~base_path:config.base_path
                  meta.name
                  (Some (Keeper_registry.Turn_consecutive_failures count));
                Log.Keeper.warn
                  "%s: auto-paused after %d cascade_exhausted failures \
                   (pause_threshold=%d, crash_threshold=%d); operator must \
                   resume after cascade fix"
                  meta.name count
                  Keeper_behavioral_regime.turn_fail_streak_threshold
                  threshold
            | Error sync_err ->
                Log.Keeper.error
                  "%s: cascade auto-pause sync failed: %s \
                   (falling through to crash path)" meta.name sync_err
          end;
          if count >= threshold && not cascade_auto_paused then begin
            Log.Keeper.error
              "%s: %d consecutive persistent turn failures (threshold=%d), escalating to supervisor crash path"
              meta.name count threshold;
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some (Keeper_registry.Turn_consecutive_failures count));
            raise Keeper_registry.Keeper_fiber_crash
          end;
          Error err
      | Ok result ->
          let final_execution = !last_execution in
          finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc
            Trajectory.Completed;
          let explicit_accountability_claim =
            Social.extract_accountability_claim result
          in
          let result, social_state, social_transition_reason =
            Social.apply_to_result ~meta ~observation
              ~previous_state:previous_social_state result
          in
          let used_model_id =
            Keeper_agent_run.surface_model_used result
          in
          let resolved_model_id =
            Keeper_agent_run.surface_resolved_model_id result
          in
          let usage_trust_for_cost =
            Keeper_unified_metrics.classify_usage_trust
              ~usage_reported:result.usage_reported
              ~usage:result.usage
              ~model_used:used_model_id
              ~resolved_model_id
              ~context_max:0
          in
          let turn_cost =
            Keeper_unified_metrics.estimate_trusted_usage_cost_usd
              ~usage_trusted:
                (Keeper_unified_metrics.usage_trust_is_trusted
                   usage_trust_for_cost)
              ~model:used_model_id
              result.usage
          in
          let lifecycle =
            apply_post_turn_lifecycle ~base_dir
              ~on_compaction_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Compaction_started)
              ~on_handoff_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Handoff_started)
              ~meta
              ~model:result.model_used
              ~primary_model_max_tokens:final_execution.max_context
              ~current_turn_overflow_blocker:!current_turn_overflow_blocker
              ~checkpoint:result.checkpoint
          in
          dispatch_post_turn_lifecycle_events
            ~config
            ~keeper_name:meta.name
            lifecycle;
          (* 6. Observe result and update metrics.
             Always update proactive_rt regardless of turn type.
             Previously, scope-only reactive turns (pending_scope but no
             mentions/board) skipped the timestamp update, freezing the
             proactive cooldown timer so the second autonomous turn never
             fired.  See Bug #3 in the root-cause analysis. *)
          let updated_meta =
            Keeper_unified_metrics.update_metrics_from_result lifecycle.updated_meta ~latency_ms
              ~observation
              ~social_state
              ~social_transition_reason:
                (Social.transition_reason_to_string social_transition_reason)
              ~context_max:lifecycle.context_max
              ~update_proactive_rt:true
              result
          in
          (* #9926: observe consecutive stay_silent turns to detect the
             masc-improver-style loop that burned 13.3h of LLM time on
             unclaimable backlog. Pure in-memory counter; fires a latched
             warn + counter metric when the streak crosses
             MASC_STAY_SILENT_LOOP_THRESHOLD (default 10). *)
          Keeper_stay_silent_loop_detector.record_turn
            ~keeper_name:updated_meta.Keeper_types.name
            ~speech_act:updated_meta.Keeper_types.runtime.last_speech_act;
          (try
             (* Spec: KeeperTaskAcquisition.tla AssignTask vs
                EmptyQueueSleep — non-empty queue picks "turn"
                (claim-and-finish path), empty picks
                "scheduled_autonomous" (no claim this cycle). *)
             let any_pending =
               observation.pending_mentions <> []
               || observation.pending_board_events <> []
               || observation.pending_scope_messages <> []
             in
             let channel =
               if any_pending then "turn" else "scheduled_autonomous"
             in
             (* Cycle 44: KeeperTaskAcquisition.tla post-action guards
                pin the structural invariant the decision relied on. *)
             if any_pending
             then
               Keeper_fsm_guard_runtime.wrap_unit
                 ~action:"AssignTask" ~stage:"post"
                 (fun () -> post_assign_task ~any_pending ~channel)
             else
               Keeper_fsm_guard_runtime.wrap_unit
                 ~action:"EmptyQueueSleep" ~stage:"post"
                 (fun () -> post_empty_queue_sleep ~any_pending ~channel);
             Keeper_unified_metrics.append_metrics_snapshot ~config ~meta:updated_meta ~observation
               ~result ~latency_ms ~turn_cost
               ~turn_generation:lifecycle.turn_generation
               ~channel
               ~snapshot_source:"keeper_unified_turn"
               ~context_ratio:lifecycle.context_ratio
               ~context_tokens:lifecycle.context_tokens
               ~context_max:lifecycle.context_max
               ~message_count:lifecycle.message_count
               ~compaction:lifecycle.compaction
               ~handoff_json:lifecycle.handoff_json
               ?timeout_budget_json:
                 (Option.map oas_timeout_budget_resolution_to_yojson
                    !last_timeout_budget)
               ()
          with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               (* #10047: surface drop as a Prometheus counter so
                  dashboards can alert when state advances without a
                  matching metric record (keeper was running but jsonl
                  shows no turn). *)
               let channel =
                 if observation.pending_mentions <> []
                    || observation.pending_board_events <> []
                    || observation.pending_scope_messages <> []
                 then "turn"
                 else "scheduled_autonomous"
               in
               Prometheus.inc_counter
                 Prometheus.metric_keeper_metric_emit_dropped
                 ~labels:[
                   ("keeper", updated_meta.Keeper_types.name);
                   ("channel", channel);
                   ("site", "keeper_unified_turn");
                 ] ();
               Log.Keeper.error
                 "write metrics snapshot failed after keeper cycle: %s"
                 (Printexc.to_string exn));
          let turn_mode = Keeper_unified_metrics.turn_mode_of_result result in
          let turn_mode_label =
            Keeper_unified_metrics.turn_mode_to_string turn_mode
          in
          let model_used = Keeper_agent_run.surface_model_used result in
          let resolved_model_id =
            Keeper_agent_run.surface_resolved_model_id result
          in
          let usage_trust =
            Keeper_unified_metrics.classify_usage_trust
              ~usage_reported:result.usage_reported
              ~usage:result.usage
              ~model_used
              ~resolved_model_id
              ~context_max:lifecycle.context_max
          in
          let usage_trusted =
            Keeper_unified_metrics.usage_trust_is_trusted usage_trust
          in
          let wall_tokens_per_second =
            if usage_trusted && latency_ms > 0 then
              Some
                (float_of_int result.usage.output_tokens
                 /. (float_of_int latency_ms /. 1000.0))
            else None
          in
          (* Emit turn-completed event to Activity Graph for timeline token visibility *)
          (try
            let event =
              Activity_graph.emit config
                ~actor:{ kind = "agent"; id = updated_meta.agent_name }
                ~kind:"keeper.turn_completed"
                ~payload:(`Assoc
                  ([
                    ("keeper_name", `String updated_meta.name);
                    ("input_tokens", (if usage_trusted then `Int result.usage.input_tokens else `Null));
                    ("output_tokens", (if usage_trusted then `Int result.usage.output_tokens else `Null));
                    ("cache_creation_tokens", (if usage_trusted then `Int result.usage.cache_creation_input_tokens else `Null));
                    ("cache_read_tokens", (if usage_trusted then `Int result.usage.cache_read_input_tokens else `Null));
                    ("cost_usd", (if usage_trusted then `Float turn_cost else `Null));
                    ("latency_ms", `Int latency_ms);
                    ("model_used", `String model_used);
                    ("resolved_model_id", `String resolved_model_id);
                    ( "usage_trust",
                      `String
                        (Keeper_unified_metrics.usage_trust_to_string
                           usage_trust) );
                    ( "usage_anomaly_reasons",
                      `List
                        (List.map
                           (fun reason -> `String reason)
                           (Keeper_unified_metrics.usage_trust_reasons
                              usage_trust)) );
                    ("turn_mode", `String turn_mode_label);
                    ("context_ratio", `Float lifecycle.context_ratio);
                    ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
                  ]
                  @ (match wall_tokens_per_second with
                     | Some v -> [("tokens_per_second", `Float v)]
                     | None -> [])
                  @ (match result.inference_telemetry with
                     | Some t ->
                       (match t.reasoning_tokens with Some n -> [("reasoning_tokens", `Int n)] | None -> [])
                       @ (match t.timings with
                          | Some ti ->
                            (match ti.prompt_per_second with
                             | Some v -> [("prompt_per_second", `Float v)]
                             | None -> [])
                            @ (match ti.predicted_per_second with
                               | Some v -> [("hw_decode_tokens_per_second", `Float v)]
                               | None -> [])
                          | None -> [])
                     | None -> [])))
                ~tags:["keeper"; "turn"; "metrics"]
                ()
            in
            Log.Keeper.debug
              "%s: activity graph turn_completed emitted seq=%d"
              updated_meta.name event.seq
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              report_keeper_cycle_side_effect_issue
                ~config
                ~keeper_name:updated_meta.name
                ~side_effect:"activity graph turn_completed emit"
                (Printexc.to_string exn));
          Keeper_unified_metrics.broadcast_lifecycle_events ~name:updated_meta.name
            ~turn_generation:lifecycle.turn_generation
            ~compaction:lifecycle.compaction
            ~handoff_json:lifecycle.handoff_json;
          Keeper_unified_metrics.append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms ~outcome:"success"
            ~degraded_retry_applied
            ?degraded_retry_cascade
            ?fallback_reason
            ~turn_mode
            ~social_state
            ~result:(Some result) ();
          (match explicit_accountability_claim with
          | Some claim ->
              let trace_id =
                Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id
              in
              let validated_evidence = Keeper_unified_metrics.visible_run_validation result in
              let strong_evidence =
                Keeper_unified_metrics.has_substantive_tool_calls result.tools_used
                || Option.is_some validated_evidence
              in
              Keeper_accountability.record_completion_claim config
                ~keeper_name:updated_meta.name
                ~agent_name:updated_meta.agent_name
                ~trace_id
                ~turn_number:updated_meta.runtime.usage.total_turns
                ~subject:claim.subject
                ?task_id:claim.task_id
                ~evidence_refs:claim.evidence_refs
                ~surface:(Social.delivery_surface_to_string social_state.delivery_surface)
                ~strong_evidence
                ~strong_evidence_refs:
                  (Keeper_unified_metrics.accountability_evidence_refs
                     ~trace_id
                     ~turn_number:updated_meta.runtime.usage.total_turns
                     ~result
                     ~validated_evidence)
                ()
          | None -> ());
          let outcome_str =
            match result.stop_reason with
            | Oas_worker.Completed -> "completed"
            | Oas_worker.TurnBudgetExhausted { turns_used; limit; _ } ->
                Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
            | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
                (match tool_name with
                 | Some tool ->
                     Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                 | None ->
                     Printf.sprintf "mutation_boundary(%d)" turns_used)
          in
          let outcome_label =
            match result.stop_reason with
            | Oas_worker.Completed -> "success"
            | Oas_worker.TurnBudgetExhausted _ -> "budget_exhausted"
            | Oas_worker.MutationBoundaryReached _ -> "mutation_boundary"
          in
          Prometheus.inc_counter Prometheus.metric_keeper_turns
            ~labels:[("keeper_name", updated_meta.name); ("outcome", outcome_label)] ();
          if usage_trusted then begin
            Prometheus.inc_counter Prometheus.metric_keeper_input_tokens
              ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
              ~delta:(float_of_int result.usage.input_tokens) ();
            Prometheus.inc_counter Prometheus.metric_keeper_output_tokens
              ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
              ~delta:(float_of_int result.usage.output_tokens) ();
            (* #7469 Step 1: emit prompt-cache usage so Anthropic/Bedrock
               hit rate is observable. Skip when both are zero — non-caching
               providers (GLM/local-llama) would otherwise register a series
               per keeper+model combination that never moves off zero.
               Metric names pulled from [Prometheus] constants so a typo
               here would fail to compile instead of silently creating a
               dead series. *)
            (if result.usage.cache_creation_input_tokens > 0 then
               Prometheus.inc_counter Prometheus.metric_keeper_cache_creation_tokens
                 ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
                 ~delta:(float_of_int result.usage.cache_creation_input_tokens) ());
            (if result.usage.cache_read_input_tokens > 0 then
               Prometheus.inc_counter Prometheus.metric_keeper_cache_read_tokens
                 ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
                 ~delta:(float_of_int result.usage.cache_read_input_tokens) ())
          end else begin
            let reasons =
              match Keeper_unified_metrics.usage_trust_reasons usage_trust with
              | [] -> [Keeper_unified_metrics.usage_trust_to_string usage_trust]
              | reasons -> reasons
            in
            List.iter
              (fun reason ->
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_usage_anomalies
                   ~labels:
                     [
                       ("keeper_name", updated_meta.name);
                       ("model", model_used);
                       ("reason", reason);
                     ]
                   ())
              reasons;
            Log.Keeper.warn
              "%s: keeper usage telemetry untrusted model=%s resolved_model=%s reasons=%s input=%d output=%d context_max=%d"
              updated_meta.name model_used resolved_model_id
              (String.concat "," reasons)
              result.usage.input_tokens
              result.usage.output_tokens
              lifecycle.context_max
          end;
          let logged_total_tokens =
            if usage_trusted then
              result.usage.input_tokens + result.usage.output_tokens
            else 0
          in
          Log.Keeper.info
            "%s: keeper cycle OK model=%s tokens=%d latency=%dms mode=%s stop=%s"
            updated_meta.name model_used logged_total_tokens
            latency_ms
            turn_mode_label
            outcome_str;
          (* 7. Persist updated meta — RMW retry to avoid losing the cycle's
             usage/trace data when a heartbeat fiber bumps meta_version
             between the cycle's read and its write. #9764 / #9769:
             field-level merge preserves heartbeat-owned fields from
             disk so the retry does not clobber concurrent heartbeat
             writes (previous "caller wins" retry was losing the race). *)
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               config updated_meta
           with
           | Ok () -> ()
           | Error msg ->
               if is_version_conflict_error msg then
                 Log.Keeper.warn
                   "write_meta lost CAS race after retries (keeper cycle): %s" msg
               else
                 Log.Keeper.error
                   "write_meta failed after keeper cycle: %s" msg);
          (* 8. Handle stop reason *)
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Streaming
            Keeper_turn_fsm.Completing;
          (match result.stop_reason with
           | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
             (* INFO, not WARN: mirrors MutationBoundaryReached below.
                The keeper made progress and saved a checkpoint; this is
                a normal pause-and-resume signal, not a failure. *)
             Log.Keeper.info
               "keeper:%s turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
               updated_meta.name turns_used limit;
             (* Do NOT increment turn_failures — this is not a crash.
                The keeper made progress and saved a checkpoint.
                Reset failures since the turn itself ran successfully. *)
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.MutationBoundaryReached { tool_name; _ } ->
             Log.Keeper.info
               "keeper:%s mutation boundary reached after %s, checkpoint saved — will resume next cycle"
               updated_meta.name
               (match tool_name with Some tool -> tool | None -> "committed tool");
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.Completed ->
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name);
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Completing
            Keeper_turn_fsm.Done;
          (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete post-action
             — the cycle ran to completion and is about to return an
             [Ok] result. *)
          cycle_completed := true;
          Keeper_fsm_guard_runtime.wrap_unit
            ~action:"TurnComplete" ~stage:"post"
            (fun () -> post_turn_complete_task ~cycle_completed);
          Ok updated_meta))

let run_unified_turn = run_keeper_cycle
