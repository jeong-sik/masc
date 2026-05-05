(* Keeper_turn_cascade_budget — cascade execution types, fail-open rotation,
   OAS timeout budget resolution, context overflow recovery, keeper pause/resume
   sync, partial-commit continue gate, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_exec_context
module EC = Keeper_error_classify

(* Absolute floor for context overflow retry when the API does not report
   the actual token limit.  Prevents retrying with an unreasonably small
   context window. *)
let fallback_context_overflow_floor_tokens = 4096

type cascade_execution = {
  cascade_name : Keeper_cascade_profile.runtime_name;
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
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
    ~(attempted_cascades : string list)
    (err : Agent_sdk.Error.sdk_error) : EC.degraded_retry option =
  let fallback_hint =
    Keeper_cascade_profile.fallback_cascade_for effective_cascade
  in
  EC.degraded_rotation_after_recoverable_error
    ?rotation_cascades
    ?fallback_hint
    ~base_cascade ~effective_cascade ~tool_requirement
    ~attempted_cascades err

let sdk_error_kind = function
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.A2a _ -> "a2a"
  | Agent_sdk.Error.Internal _ -> "internal"

let record_turn_failure_stress
    ~(meta : keeper_meta)
    ~(is_auto_recoverable : bool)
    ~(consecutive : int)
    ~(threshold : int)
    ~(err : Agent_sdk.Error.sdk_error)
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
        error_kind = Some (Agent_stress.error_kind_of_string (sdk_error_kind err));
      };
    timestamp = Unix.gettimeofday ();
  }

(* Retry guard floor: relaxed 30->15 (2026-04-27).
   Original 60s threshold (guard 30 + min 30) caused keeper cycle FAILED when
   remaining turn budget fell into the 30-60s band, increasing noop count and
   eventually fleet auto-pause. Field evidence (post v0.18.4): keepers hung on
   cohttp-eio bulk read for ~600s and arrived at the retry branch with <60s
   remaining -> guarded out -> cycle terminal.

   New threshold (15+15=30s) accommodates small-tail retries:
   - cohttp connect 1s + first-token 2-5s = ~6s baseline
   - 30s leaves ~9-12s headroom for actual response

   Root cause is OAS HTTP body lacking timeout (`http_client.ml take_all`);
   this is a band-aid until that lands. *)
let oas_timeout_guard_sec = 15.0

let min_oas_timeout_budget_sec = 15.0

(* Profiles with a declared fallback must not spend the whole turn on the
   first provider. Keep half of the usable budget for the degraded retry. *)
let degraded_retry_budget_reserve_fraction = 0.5

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
    ~(is_retry : bool)
    ~(reserve_degraded_retry_budget : bool)
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : oas_timeout_budget_resolution option =
  let runtime = Keeper_runtime_resolved.current () in
  let adaptive_timeout_sec =
    Keeper_runtime_resolved
    .oas_timeout_for_estimated_input_tokens_with_turn_budget
      ~estimated_input_tokens ~max_turns
  in
  if is_retry then begin
    let time_spent_in_turn = runtime.turn_timeout_sec.value -. remaining_turn_budget_s in
    let usable_retry_budget = adaptive_timeout_sec -. time_spent_in_turn in

    (* Guard: cascade rotation cannot consume more than 1x per-attempt budget
       per slot acquisition. If we've already spent more than the adaptive timeout
       budget in this turn, do not allow further retries. This prevents a retry
       loop from hogging the slot for the entire outer turn budget when inner
       OAS attempts timeout early. *)
    if remaining_turn_budget_s <= 0.0 || usable_retry_budget < min_oas_timeout_budget_sec then None
    else begin
      let effective_timeout_sec = usable_retry_budget
      in
      let source =
        match runtime.oas_timeout_override_sec.value with
        | Some _ -> "override_per_attempt_retry"
        | None -> "adaptive_per_attempt_retry"
      in
      Some
        {
          effective_timeout_sec;
          adaptive_timeout_sec;
          keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
          remaining_turn_budget_sec = remaining_turn_budget_s;
          estimated_input_tokens = max 0 estimated_input_tokens;
          max_turns;
          source;
        }
    end
  end else begin
    let usable_budget = remaining_turn_budget_s -. oas_timeout_guard_sec in
    if usable_budget < min_oas_timeout_budget_sec
    then None
    else
      let turn_capped_timeout_sec =
        Float.min adaptive_timeout_sec usable_budget
      in
      let retry_capped_timeout_sec =
        if reserve_degraded_retry_budget then
          let retry_reserved_cap =
            usable_budget *. degraded_retry_budget_reserve_fraction
          in
          if retry_reserved_cap >= min_oas_timeout_budget_sec
          then Float.min turn_capped_timeout_sec retry_reserved_cap
          else turn_capped_timeout_sec
        else turn_capped_timeout_sec
      in
      let effective_timeout_sec = retry_capped_timeout_sec in
      let capped_by_turn_budget =
        turn_capped_timeout_sec < adaptive_timeout_sec
      in
      let capped_by_degraded_retry_budget =
        retry_capped_timeout_sec < turn_capped_timeout_sec
      in
      let source =
        match
          ( runtime.oas_timeout_override_sec.value,
            capped_by_turn_budget,
            capped_by_degraded_retry_budget )
        with
        | Some _, _, true -> "override_capped_by_degraded_retry_budget"
        | Some _, true, false ->
            "override_capped_by_turn_budget"
        | Some _, false, false -> "override"
        | None, true, true ->
            "adaptive_estimated_input_tokens_capped_by_turn_budget_and_degraded_retry_budget"
        | None, false, true ->
            "adaptive_estimated_input_tokens_capped_by_degraded_retry_budget"
        | None, true, false ->
            "adaptive_estimated_input_tokens_capped_by_turn_budget"
        | None, false, false -> "adaptive_estimated_input_tokens"
      in
      Some
        {
          effective_timeout_sec;
          adaptive_timeout_sec;
          keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
          remaining_turn_budget_sec = remaining_turn_budget_s;
          estimated_input_tokens = max 0 estimated_input_tokens;
          max_turns;
          source;
        }
  end

let bounded_oas_timeout_for_turn_budget_with_turn_budget
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : float option =
  Option.map
    (fun (budget : oas_timeout_budget_resolution) -> budget.effective_timeout_sec)
    (resolve_bounded_oas_timeout_budget_with_turn_budget
       ~is_retry:false ~reserve_degraded_retry_budget:false
       ~estimated_input_tokens ~max_turns ~remaining_turn_budget_s)

let bounded_oas_timeout_for_turn_budget ~(estimated_input_tokens : int)
    ~(remaining_turn_budget_s : float) : float option =
  bounded_oas_timeout_for_turn_budget_with_turn_budget ~estimated_input_tokens
    ~max_turns:(Keeper_runtime_resolved.reactive_max_turns_per_call ())
    ~remaining_turn_budget_s

let oas_retry_budget_available_for_turn ~(is_retry : bool)
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : bool =
  Option.is_some
    (resolve_bounded_oas_timeout_budget_with_turn_budget
       ~reserve_degraded_retry_budget:false ~is_retry ~estimated_input_tokens
       ~max_turns ~remaining_turn_budget_s)

(* PR #13120 review: declared in [Env_config_keeper.KeeperRetryBackoff]
   so the env knob catalog generator at [bin/env_knob_catalog.ml]
   picks it up — that generator only scans [lib/config/env_config_*.ml],
   so a knob declared here would silently drift from
   [docs/runtime-tunables.md] and from [env_config_snapshot]. *)
let degraded_retry_slot_phase_budget_sec =
  Env_config_keeper.KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec
;;

let degraded_retry_slot_phase_available ~(time_spent_in_turn_s : float) : bool =
  Float.max 0.0 time_spent_in_turn_s < degraded_retry_slot_phase_budget_sec

let reclassify_oas_timeout_for_attempt
    ~(timeout_budget : oas_timeout_budget_resolution option)
    (err : Agent_sdk.Error.sdk_error) : Agent_sdk.Error.sdk_error =
  match err, timeout_budget with
  | Agent_sdk.Error.Api (Timeout { message }), Some timeout_budget
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
  | Degraded_retry_slot_phase_exhausted of EC.degraded_retry
  | Degraded_retry_budget_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

let next_fail_open_cascade_for_turn_with_budget
    ?rotation_cascades
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
    ~(attempted_cascades : string list)
    ~(estimated_input_tokens : int)
    ~(max_turns : int)
    ?time_spent_in_turn_s
    ~(remaining_turn_budget_s : float)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry_budget_decision =
  match
    next_fail_open_cascade_for_turn
      ?rotation_cascades
      ~base_cascade ~effective_cascade ~tool_requirement
      ~attempted_cascades err
  with
  | None -> No_degraded_retry
  | Some retry ->
      (* The candidate is always a retry, so use per-attempt budget semantics
         regardless of whether the current attempt was itself a retry. *)
      if
        Option.fold ~none:false
          ~some:(fun time_spent_in_turn_s ->
            not
              (degraded_retry_slot_phase_available ~time_spent_in_turn_s))
          time_spent_in_turn_s
      then Degraded_retry_slot_phase_exhausted retry
      else if
        oas_retry_budget_available_for_turn
          ~is_retry:true ~estimated_input_tokens ~max_turns
          ~remaining_turn_budget_s
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
    No local token-budget math -- OAS owns context budgeting.
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
    ~(error : Agent_sdk.Error.sdk_error) : overflow_retry_plan option =
  let actual_limit =
    match error with
    | Agent_sdk.Error.Api (ContextOverflow { limit = Some limit; _ }) -> limit
    | Agent_sdk.Error.Agent (TokenBudgetExceeded { limit; _ }) -> limit
    | _ ->
      (* Overflow detected but limit not available -- use 80% of cascade max
         as a conservative fallback, with an absolute floor. *)
      max fallback_context_overflow_floor_tokens (max_cascade_context * 4 / 5)
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
        "%s: context overflow retry -- compacted checkpoint (%d->%d tokens, max_context=%d, generation=%d)"
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
      Prometheus.inc_counter
        Prometheus.metric_keeper_checkpoint_failures
        ~labels:[("keeper", meta.name); ("phase", "overflow_recovery_unavailable")]
        ();
      Log.Keeper.warn
        "%s: context overflow detected but checkpoint recovery unavailable: %s"
        meta.name (short_preview (Agent_sdk.Error.to_string error));
      None

let summarize_turn_event_bus
    (events : Agent_sdk.Event_bus.event list) : turn_event_bus_summary =
  List.fold_left
    (fun acc (evt : Agent_sdk.Event_bus.event) ->
      let correlation_id =
        match acc.correlation_id with
        | Some _ -> acc.correlation_id
        | None -> Some evt.meta.correlation_id
      in
      match evt.payload with
      | Agent_sdk.Event_bus.ContextOverflowImminent
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
    (err : Agent_sdk.Error.sdk_error) : Keeper_state_machine.event =
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
      | Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; used; limit }) ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Oas_signal;
              token_count = used;
              limit_tokens = Some limit;
            }
      | Agent_sdk.Error.Api (ContextOverflow { limit; _ }) ->
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
     case -- the keeper then reports unpaused while the caller
     believes it succeeded.  Same pattern as the unified-turn
     failure path. *)
  (match
     write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       config paused_meta
   with
   | Ok () -> ()
   | Error err when is_version_conflict_error err ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_write_meta_failures
         ~labels:[("keeper", meta.name); ("phase", "overflow_pause_cas_race")]
         ();
       Log.Keeper.warn
         "%s: overflow pause write_meta lost CAS race after retries: %s"
         meta.name err
   | Error err ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_write_meta_failures
         ~labels:[("keeper", meta.name); ("phase", "overflow_pause")]
         ();
       Log.Keeper.error
         "%s: overflow pause write_meta failed: %s"
         meta.name err);
  Keeper_registry.update_meta ~base_path:config.base_path meta.name paused_meta;
  (* Issue #8581: latch the retry-exhausted condition BEFORE the
     Operator_pause that drives the Paused phase. This way the Paused
     state carries the real reason (auto-compact retry budget exhausted)
     for dashboards / operator observability -- the right disjunct of
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
      Prometheus.inc_counter
        Prometheus.metric_keeper_write_meta_failures
        ~labels:[("keeper", meta.name);
                 ("phase",
                  if paused then "pause_sync" else "resume_sync")]
        ();
      Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync write_meta"
                        (if paused then "pause" else "resume"))
        ~severity:`Error
        err;
      Error (Printf.sprintf "failed to write meta: %s" err)
  | Ok () ->
      Keeper_registry.update_meta ~base_path:config.base_path meta.name synced_meta;
      Keeper_turn_helpers.dispatch_keeper_phase_event_checked
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync phase update"
                        (if paused then "pause" else "resume"))
        (if paused
         then Keeper_state_machine.Operator_pause
         else Keeper_state_machine.Operator_resume);
      (if not paused then
         match Keeper_registry.get ~base_path:config.base_path meta.name with
         (* tla-lint: allow-mutation: fiber signal — wake on resume from cascade budget gate *)
         | Some entry -> Atomic.set entry.fiber_wakeup true
         | None ->
             Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
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
      | Agent_sdk.Hooks.Approve
      | Agent_sdk.Hooks.Edit _ ->
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
               meta.name err);
             Prometheus.inc_counter
               Prometheus.metric_keeper_cascade_sync_failures
               ~labels:[("keeper", meta.name); ("site", "resume_sync")]
               ()
      | Agent_sdk.Hooks.Reject reason ->
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
               meta.name err reason);
             Prometheus.inc_counter
               Prometheus.metric_keeper_cascade_sync_failures
               ~labels:[("keeper", meta.name); ("site", "pause_sync")]
               ())
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
