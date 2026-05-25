(** Keeper_registry — Single source of truth for keeper state.

    Consolidates keeper_keepalive Hashtbl, keeper_supervisor
    Hashtbl, and file-based meta into one registry.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, the cooperative scheduler only
    switches fibers at yield points (I/O, sleep, stream ops), so
    non-yielding code runs atomically w.r.t. other fibers.  No mutex
    is needed.  See Eio README: "If the operation does not switch
    fibers and the resource is only accessed from one domain, then no
    mutex is needed at all."

    All per-keeper state (board_wakeups, tool_usage) uses immutable
    StringMap values, updated atomically via [update_entry]/[put_entry].

    Implementation: [Atomic.t] for inter-fiber signaling (lock-free
    visibility); persistent [StringMap] behind a single [ref]. *)

open Keeper_types

(** Failure-reason cluster moved to Keeper_registry_types (intra-library
    file split, 2026-05-16). Re-included here so existing 126 callers
    keep using [Keeper_registry.failure_reason] etc. unchanged. *)
include Keeper_registry_types

let registry : registry_entry StringMap.t Atomic.t = Atomic.make StringMap.empty
let running_count_atomic = Atomic.make 0
module Orphan_drops = Keeper_registry_orphan_drops
module Spawn_slots = Keeper_registry_spawn_slots
module Error_tracking = Keeper_registry_error_tracking

(** CAS loop for clamped decrement.  [Atomic.fetch_and_add _ (-1)] can
    leave the counter negative if increment/decrement paths interleave,
    so we retry until we successfully install [max 0 (cur - 1)]. *)
let decr_running_count_clamped () =
  let rec loop () =
    let cur = Atomic.get running_count_atomic in
    let next = max 0 (cur - 1) in
    if not (Atomic.compare_and_set running_count_atomic cur next) then loop ()
  in
  loop ()
;;

(** Serializes every writer path into [registry] via lock-free CAS.
    Concurrent [update_entry]/[put_entry]/[unregister] retry until they
    install their update against the snapshot they observed.

    [Atomic.t] + [compare_and_set] is used (not Eio.Mutex / Stdlib.Mutex)
    because registry helpers run in both Eio fibers and non-Eio contexts
    (unit tests, startup wiring). Eio.Mutex raises
    [Effect.Unhandled(Cancel.Get_context)] outside a scheduler;
    Stdlib.Mutex interacts poorly with Eio fiber scheduling and was
    observed to break test_keeper_reconcile_tool's inspect/clear path.
    The [StringMap] snapshot is immutable, so CAS is correct.

    Pattern follows #7011 (executor_pool) and #7013 (runtime_state). *)

let put_entry key entry =
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key entry current in
    if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()
;;

(** Apply [f entry] and write back.  No-op if key absent.

    The find + apply + write is serialised via CAS so that concurrent
    [update_entry] calls on the same key cannot both operate on a stale
    [entry] and overwrite each other's changes. *)
let update_entry ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None ->
      let count, breached = Orphan_drops.record ~base_path name in
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_registry_update_dropped
        ~labels:[ "name", name ]
        ();
      if breached
      then (
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_registry_orphan_threshold_breached
          ~labels:[ "name", name ]
          ();
        Log.Keeper.warn
          "registry: orphan threshold breached name=%s base_path=%s drops=%d \
           window=%.0fs — turn fiber may be racing post-deregistration; check \
           masc_keeper_status and watchdog"
          name
          base_path
          count
          Orphan_drops.window_sec)
      else
        Log.Keeper.debug
          "registry: update_entry name=%s base_path=%s: entry not found, update dropped \
           (count=%d)"
          name
          base_path
          count
    | Some entry ->
      let updated = StringMap.add key (f entry) current in
      if not (Atomic.compare_and_set registry current updated)
      then loop ()
      else Orphan_drops.clear ~base_path name
  in
  loop ()
;;

let update_entry_if_registered ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> ()
    | Some entry ->
      let updated = StringMap.add key (f entry) current in
      if Atomic.compare_and_set registry current updated
      then Orphan_drops.clear ~base_path name
      else loop ()
  in
  loop ()
;;

let register_with_state
      ~base_path
      name
      meta
      ~(phase : Keeper_state_machine.phase)
      ~(conditions : Keeper_state_machine.conditions)
  =
  Log.Keeper.info
    "registry: registering keeper name=%s base_path=%s phase=%s"
    name
    base_path
    (Keeper_state_machine.phase_to_string phase);
  let done_p, done_r = Eio.Promise.create () in
  let key = registry_key ~base_path name in
  (match StringMap.find_opt key (Atomic.get registry) with
   | Some entry when entry.phase = Running ->
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
       ~labels:[ "keeper", name; "event", "register_overwrite_running" ]
       ();
     Log.Keeper.warn "registry: overwriting running keeper during register name=%s" name;
     decr_running_count_clamped ()
   | _ -> ());
  let entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; event_queue = Atomic.make Keeper_event_queue.empty
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; dead_since_ts = None
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = None
    ; turn_consecutive_failures = 0
    ; last_agent_count = 0
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_auto_rules = None
    ; last_event_bus_correlation = None
    ; pending_turn_measurement = None
    ; current_turn_observation = None
    ; last_completed_turn = None
    ; last_skip_observation = None
    ; compaction_stage = Packed Compaction_accumulating
    }
  in
  put_entry key entry;
  if phase = Running then Atomic.incr running_count_atomic;
  Log.Keeper.debug
    "registry: keeper registered name=%s running_count=%d"
    name
    (Atomic.get running_count_atomic);
  entry
;;

let register ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      fiber_alive = true
    ; restart_budget_remaining = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

let register_offline ~base_path name meta =
  let conditions =
    { Keeper_state_machine.default_conditions with
      launch_pending = true
    ; restart_budget_remaining = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions
;;

(** R-A-6.a — refuse to revive a keeper whose restart_budget was previously
    exhausted.  Pairs with TLA+ §S3 BudgetNeverRevives:

      []( ~restart_budget_remaining => []( ~restart_budget_remaining ))

    Without this guard, [register_restarting] unconditionally writes
    [restart_budget_remaining = true], which would silently revive a
    keeper whose budget was cleared via [Restart_budget_exhausted] event
    or [mark_dead] in a prior sweep.  Three concrete revival vectors are
    documented in `docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md`
    (iter 14 audit memo).  This refusal turns those silent corruptions
    into a typed error the caller must handle. *)
type register_restarting_error = Budget_already_exhausted of { name : string }

let register_restarting ~base_path name meta
  : (registry_entry, register_restarting_error) result
  =
  let key = registry_key ~base_path name in
  let conditions =
    { Keeper_state_machine.default_conditions with
      restart_budget_remaining = true
    ; backoff_elapsed = true
    }
  in
  let phase = Keeper_state_machine.derive_phase conditions in
  (* Build fresh entry once — its per-fiber atomics (fiber_stop,
     event_queue, etc.) are independent of registry contents, so a
     CAS retry can re-use the same record without re-allocating. *)
  let done_p, done_r = Eio.Promise.create () in
  let new_entry =
    { base_path
    ; name
    ; meta
    ; phase
    ; conditions
    ; fiber_stop = Atomic.make false
    ; fiber_wakeup = Atomic.make false
    ; event_queue = Atomic.make Keeper_event_queue.empty
    ; started_at = Time_compat.now ()
    ; grpc_close = Atomic.make None
    ; done_p
    ; done_r
    ; restart_count = 0
    ; last_restart_ts = 0.0
    ; dead_since_ts = None
    ; crash_log = []
    ; last_error = None
    ; last_failure_reason = None
    ; turn_consecutive_failures = 0
    ; last_agent_count = 0
    ; board_wakeups = StringMap.empty
    ; board_cursor_ts = 0.0
    ; board_cursor_post_id = None
    ; tool_usage = StringMap.empty
    ; transition_seq = 0
    ; waiting_for_inference = Atomic.make false
    ; last_auto_rules = None
    ; last_event_bus_correlation = None
    ; pending_turn_measurement = None
    ; current_turn_observation = None
    ; last_completed_turn = None
    ; last_skip_observation = None
    ; compaction_stage = Packed Compaction_accumulating
    }
  in
  (* Guard + write in a single CAS loop so a concurrent budget-exhaust
     update between our read and write cannot be overwritten back to
     [restart_budget_remaining = true].  Without this loop, two threads
     racing — one exhausting the budget, one calling register_restarting
     on the same name — could land with the wrong winner and silently
     resurrect a Dead-bound entry.  See iter 14 audit. *)
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | Some prior when not prior.conditions.restart_budget_remaining ->
      Error (Budget_already_exhausted { name })
    | _ ->
      let updated = StringMap.add key new_entry current in
      if Atomic.compare_and_set registry current updated
      then (
        Log.Keeper.info
          "registry: registering keeper name=%s base_path=%s phase=%s"
          name
          base_path
          (Keeper_state_machine.phase_to_string phase);
        Ok new_entry)
      else loop ()
  in
  loop ()
;;

let unregister ~base_path name =
  Log.Keeper.info "registry: unregistering keeper name=%s base_path=%s" name base_path;
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    let before = StringMap.find_opt key current in
    let updated = StringMap.remove key current in
    if not (Atomic.compare_and_set registry current updated) then loop () else before
  in
  let signal_fibers_to_stop entry =
    (* The watchdog and heartbeat fibers hold their own reference to
       [entry] via the closure they were forked with, so removing the
       entry from the registry map does not stop them. Without an
       explicit fiber_stop signal they continue to tick, observing
       [Keeper_registry.get = None] on every subsequent poll, and
       either spam "registry entry NOT FOUND" warnings (242+ events
       observed in prod, 2026-05-17) or rely on the heartbeat-paused
       latch to self-stop. Make unregister authoritative: when the
       entry leaves the registry, the fibers that watched it stop. *)
    Atomic.set entry.fiber_stop true;
    Atomic.set entry.fiber_wakeup true
  in
  match loop () with
  | Some entry when entry.phase = Running ->
    signal_fibers_to_stop entry;
    decr_running_count_clamped ();
    Log.Keeper.debug
      "registry: unregistered running keeper name=%s running_count=%d"
      name
      (Atomic.get running_count_atomic)
  | Some entry ->
    signal_fibers_to_stop entry;
    Log.Keeper.debug
      "registry: unregistered non-running keeper name=%s state=%s"
      name
      (Keeper_state_machine.phase_to_string entry.phase)
  | None ->
    Log.Keeper.warn "registry: attempted to unregister non-existent keeper name=%s" name
;;

let get ~base_path name =
  let result = StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) in
  (match result with
   | None -> Log.Keeper.debug "registry: lookup miss name=%s base_path=%s" name base_path
   | Some _ -> ());
  result
;;

let all ?base_path () =
  StringMap.fold
    (fun _k v acc ->
       match base_path with
       | Some expected when not (String.equal expected v.base_path) -> acc
       | _ -> v :: acc)
    (Atomic.get registry)
    []
;;

let update_meta ~base_path name meta =
  update_entry ~base_path name (fun e -> { e with meta })
;;

(* Cascade-attempt cluster (cascade_attempt_merge / meta_for_cascade_attempt /
   record_cascade_attempt / cascade_attempt_suffix / last_cascade_attempt /
   cascade_attempt_freshness_threshold_sec / enrich_fiber_unresolved_outcome)
   moved to Keeper_registry_cascade_attempt. *)

let sync_meta_if_registered ~base_path name meta =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> ()
    | Some entry ->
      let updated = StringMap.add key { entry with meta } current in
      if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()
;;

let () =
  register_runtime_meta_write_sync (fun config meta ->
    sync_meta_if_registered ~base_path:config.base_path meta.name meta)
;;

let mark_dead ~base_path name ~at =
  Error_tracking.mark_dead
    ~base_path
    name
    ~at
    ~decr_running_count_clamped
    ~update_entry
;;

let record_restart ~base_path name =
  Error_tracking.record_restart ~base_path name ~update_entry
;;

let set_last_error_entry ~base_path ~name err =
  Error_tracking.set_last_error_entry ~base_path ~name err ~update_entry
;;

(* record_error (MASC/OAS Error-Warn Reduction Goal §P6 dedup logic) moved to
   Keeper_registry_error_recording. No alias here — it would create a cycle
   via [Keeper_registry.set_last_error_entry], so callers call the new
   module directly. *)

let clear_error ~base_path name =
  Error_tracking.clear_error ~base_path name ~update_entry
;;

let set_failure_reason ~base_path name reason =
  Error_tracking.set_failure_reason ~base_path name reason ~update_entry
;;

let set_last_correlation_id ~base_path name cid =
  Error_tracking.set_last_correlation_id ~base_path name cid ~update_entry
;;

(* SSE broadcast helpers (broadcast_composite_changed /
   record_phase_broadcast_failure) moved to Keeper_registry_broadcast. *)
let broadcast_composite_changed = Keeper_registry_broadcast.composite_changed
let record_phase_broadcast_failure = Keeper_registry_broadcast.record_phase_failure

let update_current_turn e f =
  let current_turn_observation =
    match e.current_turn_observation with
    | None -> None
    | Some obs -> Some (f obs)
  in
  { e with current_turn_observation }
;;

let stamp_turn_progress ~now ~event_kind obs =
  { obs with
    last_progress_at = now
  ; last_progress_kind = Some event_kind
  }
;;

let mark_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    let turn_id = e.meta.runtime.usage.total_turns + 1 in
    let obs =
      { turn_id
      ; started_at = now
      ; last_progress_at = now
      ; last_progress_kind = Some "turn_started"
      ; turn_phase = Packed Turn_prompting
      ; decision_stage = Packed Decision_undecided
      ; cascade_state = Packed Cascade_idle
      ; measurement = None
      ; measurement_bind_count = 0
      ; selected_model = None
      }
    in
    changed := true;
    { e with
      current_turn_observation = Some obs
    ; compaction_stage = Packed Compaction_accumulating
    });
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let record_turn_progress ~base_path name ~event_kind =
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (stamp_turn_progress ~now ~event_kind))
;;

(* RFC-0045: SDK-turn boundary reset.  Resets in-turn FSM fields without
   touching keeper-turn-scoped data ([turn_id], [started_at],
   [selected_model], [measurement], [measurement_bind_count]).  Bypasses
   validators the same way [mark_turn_started] does — by installing a new
   observation directly.

   No-op when the observation is already in the post-reset shape (first
   SDK turn after [mark_turn_started]) so the dashboard composite
   broadcast doesn't fire spuriously every SDK turn. *)
let mark_sdk_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    match e.current_turn_observation with
    | None -> e
    | Some obs ->
      if
        obs.turn_phase = Packed Turn_prompting
        && obs.cascade_state = Packed Cascade_idle
        && obs.decision_stage = Packed Decision_undecided
      then e
      else (
        changed := true;
        let new_obs =
          { (stamp_turn_progress ~now ~event_kind:"sdk_turn_started" obs) with
            turn_phase = Packed Turn_prompting
          ; cascade_state = Packed Cascade_idle
          ; decision_stage = Packed Decision_undecided
          }
        in
        { e with current_turn_observation = Some new_obs }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_measurement ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    match e.current_turn_observation, e.pending_turn_measurement with
    | Some obs, Some measurement ->
      changed := true;
      { e with
        current_turn_observation =
          Some
            { obs with
              measurement = Some measurement
            ; measurement_bind_count = obs.measurement_bind_count + 1
            ; last_progress_at = now
            ; last_progress_kind = Some "turn_measurement"
            }
      ; pending_turn_measurement = None
      }
    | _ -> e);
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

(* RFC-0072 Phase 3 + Phase 5: collapse 25-pair matrix onto
   [resolve_cascade_transition] (PR #14903) and raise the typed
   [Cascade_transition_violation] (Phase 5) on the 7 forbidden pairs
   instead of a string-formatted [Invalid_argument].  The transition matrix
   is now a single source of truth in the resolver — this validator becomes
   a thin compatibility shim.  Adding a new [cascade_state] variant only
   requires updating [resolve_cascade_transition]; this function reflects
   the change automatically. *)
(* FSM transition validators (validate_cascade_transition /
   validate_turn_phase_transition) moved to
   Keeper_registry_fsm_validators. *)
let validate_cascade_transition = Keeper_registry_fsm_validators.cascade_transition
let validate_turn_phase_transition = Keeper_registry_fsm_validators.turn_phase_transition

let set_turn_decision_stage ~base_path name (decision_stage : decision_stage_active) =
  (* Spec invariant: the 3 [<active>_to_undecided] transitions are forbidden
     within a turn.  Previously enforced at runtime via [invalid_arg] inside
     a 16-pair match; now unrepresentable through the [decision_stage_active]
     input type, so the matrix collapses to a simple equality check.  All
     12 remaining (from, to) pairs (4 from-states × 3 non-Undecided targets)
     share identical action: idempotent on equality, otherwise replace.
     [Decision_transition] (module above) enumerates the 9 valid cross-state
     transitions; the GADT remains available for future per-transition
     dispatch but is not needed here since this setter has no per-pair
     side effects. *)
  let target_packed = decision_stage_active_to_packed decision_stage in
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      if obs.decision_stage = target_packed
      then obs
      else (
        changed := true;
        { (stamp_turn_progress ~now ~event_kind:"decision_stage" obs) with
          decision_stage = target_packed
        })));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let set_turn_cascade_state ~base_path name (cascade_state : packed_cascade_state) =
  (* RFC-0072 Phase 2: dispatch via [resolve_cascade_transition] (PR #14903)
     instead of the standalone [validate_cascade_transition].  Behavior
     deltas vs the pre-RFC-0072 path:

     - Idempotent self-loop (e.g. Selecting -> Selecting) no longer flips
       [changed] or emits a broadcast.  The prior matrix in
       [validate_cascade_transition] admitted self-loops but the setter
       unconditionally set [changed := true], producing spurious
       [broadcast_composite_changed] events.  This is a small efficiency
       fix bundled with the Phase-2 wiring.

     - Forbidden transitions (7 pairs) raise the typed
       [Cascade_transition_violation] (RFC-0072 Phase 5), carrying the
       [cascade_transition_spec_violation] payload directly instead of a
       string-formatted [Invalid_argument].  The raise is routed through
       [wrap_unit] (same pattern #14926 applied to [set_turn_phase]) so
       [metric_fsm_guard_violation] (action=cascade_transition,
       stage=guard) fires for forbidden transitions reached via this
       setter — without it, the cascade-side setter rejection would be
       uninstrumented (the [validate_cascade_transition] call below only
       runs on the [Resolved_transition] arm).

     [validate_turn_phase_transition] is invoked here for the turn_phase
     axis (which also dispatches through its resolver as of Phase 4b). *)
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      let new_turn_phase = turn_phase_of_cascade_state cascade_state in
      match resolve_cascade_transition ~from:obs.cascade_state ~target:cascade_state with
      | Resolved_idempotent -> obs
      | Resolved_transition _ ->
        validate_turn_phase_transition ~from:obs.turn_phase ~to_:new_turn_phase;
        changed := true;
        { (stamp_turn_progress ~now ~event_kind:"cascade_state" obs) with
          cascade_state
        ; turn_phase = new_turn_phase
        }
      | Resolved_violation violation ->
        Keeper_fsm_guard_runtime.wrap_unit
          ~action:"cascade_transition"
          ~stage:"guard"
          (fun () ->
             raise_cascade_transition_violation
               ~where:"set_turn_cascade_state"
               ~from:obs.cascade_state
               ~to_:cascade_state
               ~violation);
        obs));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_cascade_exhausted ~base_path name =
  let set_cascade_state cascade_state =
    set_turn_cascade_state
      ~base_path
      name
      (Packed cascade_state : packed_cascade_state)
  in
  match get ~base_path name with
  | None | Some { current_turn_observation = None; _ } -> ()
  | Some { current_turn_observation = Some obs; _ } ->
    (match obs.cascade_state with
     | Packed Cascade_idle ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected;
       set_cascade_state Cascade_selecting;
       set_cascade_state Cascade_trying;
       set_cascade_state Cascade_exhausted
     | Packed Cascade_selecting ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected;
       set_cascade_state Cascade_trying;
       set_cascade_state Cascade_exhausted
     | Packed Cascade_trying -> set_cascade_state Cascade_exhausted
     | Packed Cascade_exhausted -> set_cascade_state Cascade_exhausted
     | Packed Cascade_done ->
	       Log.Keeper.warn
	         "registry: ignoring cascade exhaustion after Cascade_done name=%s \
	          base_path=%s"
	         name
         base_path)
;;

let mark_turn_cascade_done ~base_path name =
  let set_cascade_state cascade_state =
    set_turn_cascade_state
      ~base_path
      name
      (Packed cascade_state : packed_cascade_state)
  in
  match get ~base_path name with
  | None | Some { current_turn_observation = None; _ } -> ()
  | Some { current_turn_observation = Some obs; _ } ->
    (match obs.cascade_state with
     | Packed Cascade_idle ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected;
       set_cascade_state Cascade_selecting;
       set_cascade_state Cascade_trying;
       set_cascade_state Cascade_done
     | Packed Cascade_selecting ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected;
       set_cascade_state Cascade_trying;
       set_cascade_state Cascade_done
     | Packed Cascade_trying -> set_cascade_state Cascade_done
     | Packed Cascade_done -> set_cascade_state Cascade_done
     | Packed Cascade_exhausted ->
       Log.Keeper.warn
         "registry: ignoring cascade completion after Cascade_exhausted name=%s \
          base_path=%s"
         name
         base_path)
;;
