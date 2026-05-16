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

let registry_key ~base_path name =
  if String.contains name '\x1f'
  then invalid_arg (Printf.sprintf "keeper name contains unit separator: %s" name);
  base_path ^ "\x1f" ^ name
;;

let put_entry key entry =
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key entry current in
    if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()
;;

(* P0-2 (2026-05-07): orphan turn-loop observability.

   Background — [update_entry] returns silently when the key is absent
   (the keeper was deregistered while a caller still held its name).
   At fleet scale the WARN line is invisible: a single orphan keeper
   emits 30+ drops per turn (each tool-dispatch + each phase setter).
   See verifier-loop incident 2026-05-07.

   Surgical observability fix:
   - Track per-(name) drop count in a [(int * float) StringMap.t Atomic]
     (count, first_drop_at) so we can detect "many drops in a short
     window" without a wall-clock heuristic at every caller.
   - Bump [metric_keeper_registry_update_dropped] every drop.
   - Edge-trigger: when count crosses [orphan_drop_threshold] inside
     [orphan_drop_window_sec], emit one WARN and bump
     [metric_keeper_registry_orphan_threshold_breached] exactly once
     per breach window.  Individual drops stay DEBUG; the metric is the
     durable signal and the threshold log is the operator attention point.
   - Reset state on the successful Some-entry path (orphan resolved)
     and after the window expires.

   Behavior is otherwise unchanged: the dropped update is still
   silently absorbed (29 caller signatures preserved). Fiber
   cancellation on orphan detection is intentionally out of scope —
   that requires unregister-time fiber cancel and is RFC-level. *)
let orphan_drop_threshold = 5
let orphan_drop_window_sec = 60.0
let orphan_drop_state : (int * float) StringMap.t Atomic.t = Atomic.make StringMap.empty

(* Returns [(count, breached_now)]. [breached_now] is [true] exactly
   on the transition from below-threshold to at-threshold within an
   active window. *)
let record_orphan_drop ~base_path name =
  let key = registry_key ~base_path name in
  let now = Time_compat.now () in
  let rec loop () =
    let current = Atomic.get orphan_drop_state in
    let count, first_at, breached_now =
      match StringMap.find_opt key current with
      | Some (prev_count, prev_first_at)
        when now -. prev_first_at <= orphan_drop_window_sec ->
        let new_count = prev_count + 1 in
        let breached =
          prev_count < orphan_drop_threshold && new_count >= orphan_drop_threshold
        in
        new_count, prev_first_at, breached
      | _ ->
        (* Fresh window (no prior state, or prior window expired). *)
        1, now, false
    in
    let updated = StringMap.add key (count, first_at) current in
    if Atomic.compare_and_set orphan_drop_state current updated
    then count, breached_now
    else loop ()
  in
  loop ()
;;

let clear_orphan_drop ~base_path name =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get orphan_drop_state in
    if StringMap.mem key current
    then (
      let updated = StringMap.remove key current in
      if not (Atomic.compare_and_set orphan_drop_state current updated) then loop ())
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
      let count, breached = record_orphan_drop ~base_path name in
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
          orphan_drop_window_sec)
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
      else clear_orphan_drop ~base_path name
  in
  loop ()
;;

let update_entry_if_registered ~base_path name f =
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    match StringMap.find_opt key current with
    | None -> false
    | Some entry ->
      let updated = StringMap.add key (f entry) current in
      if Atomic.compare_and_set registry current updated
      then (
        clear_orphan_drop ~base_path name;
        true)
      else loop ()
  in
  loop ()
;;

let max_crash_log_entries = 5

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
  match loop () with
  | Some entry when entry.phase = Running ->
    decr_running_count_clamped ();
    Log.Keeper.debug
      "registry: unregistered running keeper name=%s running_count=%d"
      name
      (Atomic.get running_count_atomic)
  | Some entry ->
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
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_lifecycle_transitions
    ~labels:[ "keeper", name; "from_phase", "direct"; "to_phase", "Dead" ]
    ();
  Log.Keeper.error "registry: marking keeper dead name=%s at=%.0f" name at;
  update_entry ~base_path name (fun entry ->
    if entry.phase <> Dead
    then (
      (* Enumerate every phase so the compiler flags any new variant.
         Only the Running phase contributes to [running_count_atomic];
         all other phases were never counted, so transitioning to
         Dead from them must not decrement. Same FSM Sparse Match
         anti-pattern as PR #14857 (this file's [is_running]). *)
      (match entry.phase with
       | Running -> decr_running_count_clamped ()
       | Offline
       | Failing
       | Overflowed
       | Compacting
       | HandingOff
       | Draining
       | Paused
       | Stopped
       | Crashed
       | Restarting
       | Dead
       | Zombie -> ());
      let conditions =
        { Keeper_state_machine.default_conditions with
          launch_pending = false
        ; fiber_alive = false
        ; restart_budget_remaining = false
        }
      in
      let phase = Keeper_state_machine.derive_phase conditions in
      { entry with dead_since_ts = Some at; phase; conditions })
    else
      { entry with dead_since_ts = Some (Option.value ~default:at entry.dead_since_ts) })
;;

let record_restart ~base_path name =
  Log.Keeper.warn "registry: recording restart name=%s" name;
  update_entry ~base_path name (fun e ->
    { e with restart_count = e.restart_count + 1; last_restart_ts = Time_compat.now () })
;;

let record_error ~base_path name err =
  Log.Keeper.error "registry: recording error name=%s error=%s" name err;
  Keeper_fd_pressure.note_if_fd_exhaustion ~site:"keeper_registry.record_error" err;
  update_entry ~base_path name (fun e -> { e with last_error = Some err })
;;

let clear_error ~base_path name =
  update_entry ~base_path name (fun e -> { e with last_error = None })
;;

let set_failure_reason ~base_path name reason =
  update_entry ~base_path name (fun e -> { e with last_failure_reason = reason })
;;

let set_last_correlation_id ~base_path name cid =
  update_entry ~base_path name (fun e -> { e with last_event_bus_correlation = Some cid })
;;

let turn_phase_of_cascade_state (s : packed_cascade_state) : packed_turn_phase =
  match s with
  | Packed Cascade_idle -> Packed Turn_prompting
  | Packed Cascade_selecting -> Packed Turn_routing
  | Packed Cascade_trying -> Packed Turn_executing
  | Packed Cascade_done -> Packed Turn_finalizing
  | Packed Cascade_exhausted -> Packed Turn_exhausted
;;

let broadcast_composite_changed ~name ~ts_unix =
  try
    let json =
      `Assoc
        [ "type", `String "keeper_composite_changed"
        ; "name", `String name
        ; "ts_unix", `Float ts_unix
        ]
    in
    Sse.broadcast json;
    Sse.broadcast_presence json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* P2 silent-failure fix: previously this discarded the exception
         silently, hiding the case where the SSE broadcast pipe is dead
         (subscriber cleanup race, transport tear-down).  Operators
         investigating "dashboard stopped updating" had no signal that
         the broadcast itself was failing.  PR-C (#11075) added a
         counter on the SSE side, but only for per-client failures
         inside broadcast_impl — exceptions thrown out of
         Sse.broadcast itself bypass that counter.  Logging here
         makes the exception visible at the call site. *)
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
      ~labels:[ "keeper", name; "event", "broadcast_composite_failed" ]
      ();
    Log.Keeper.warn
      "registry: broadcast_composite_changed name=%s failed: %s"
      name
      (Printexc.to_string exn)
;;

let record_phase_broadcast_failure ~name exn =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_sse_broadcast_failures
    ~labels:[ "keeper", name; "site", "phase_changed" ]
    ();
  Log.Keeper.warn
    "registry: keeper_phase_changed broadcast failed name=%s err=%s"
    name
    (Printexc.to_string exn)
;;

let completed_turn_outcome_of_observation (obs : turn_observation)
  : Keeper_transition_audit.completed_turn_outcome
  =
  (* P1 silent-failure fix: the previous wildcard `| _ -> Turn_failed`
     meant that adding a new variant to either ADT (decision_stage or
     cascade_state) would silently fall through to Turn_failed without
     a compile error.  Spelling out every variant lets the OCaml
     exhaustiveness checker catch missing cases at build time. *)
  match obs.decision_stage with
  | Packed Decision_gate_rejected -> Keeper_transition_audit.Turn_gate_rejected
  | Packed (Decision_undecided | Decision_guard_ok | Decision_tool_policy_selected) ->
    (match obs.cascade_state with
     | Packed Cascade_done -> Keeper_transition_audit.Turn_substantive
     | Packed Cascade_idle
     | Packed Cascade_selecting
     | Packed Cascade_trying
     | Packed Cascade_exhausted -> Keeper_transition_audit.Turn_failed)
;;

let update_current_turn e f =
  let current_turn_observation =
    match e.current_turn_observation with
    | None -> None
    | Some obs -> Some (f obs)
  in
  { e with current_turn_observation }
;;

let mark_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    let turn_id = e.meta.runtime.usage.total_turns + 1 in
    let obs =
      { turn_id
      ; started_at = now
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
    }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
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
  ignore (update_entry_if_registered ~base_path name (fun e ->
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
          { obs with
            turn_phase = Packed Turn_prompting
          ; cascade_state = Packed Cascade_idle
          ; decision_stage = Packed Decision_undecided
          }
        in
        { e with current_turn_observation = Some new_obs })));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_measurement ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    match e.current_turn_observation, e.pending_turn_measurement with
    | Some obs, Some measurement ->
      changed := true;
      { e with
        current_turn_observation =
          Some
            { obs with
              measurement = Some measurement
            ; measurement_bind_count = obs.measurement_bind_count + 1
            }
      ; pending_turn_measurement = None
      }
    | _ -> e));
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
let validate_cascade_transition ~from ~to_ =
  (* Wrapped in [Keeper_fsm_guard_runtime.wrap_unit] for symmetry with
     [validate_turn_phase_transition] and the setters
     ([set_turn_cascade_state] / [set_turn_phase]): a forbidden pair
     reached via this validator bumps [metric_fsm_guard_violation]
     (action=cascade_transition, stage=guard) before re-raising the typed
     [Cascade_transition_violation] with its backtrace intact. Without
     this wrap, a direct call to this validator on a forbidden pair was
     uninstrumented (RFC-0072 Phase 5 left it as a thin shim). *)
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"cascade_transition"
    ~stage:"guard"
    (fun () ->
       match resolve_cascade_transition ~from ~target:to_ with
       | Resolved_idempotent | Resolved_transition _ -> ()
       | Resolved_violation violation ->
         raise_cascade_transition_violation
           ~where:"validate_cascade_transition"
           ~from
           ~to_
           ~violation)
;;

(* RFC-0072 Phase 4b + Phase 5: collapse the 49-pair turn_phase matrix onto
   [resolve_turn_phase_transition] (PR #14912) and raise the typed
   [Turn_phase_transition_violation] (Phase 5) on the 19 forbidden pairs.
   Wrapped in [Keeper_fsm_guard_runtime.wrap_unit] so the existing metric /
   observability instrumentation ([metric_fsm_guard_violation], etc.) keeps
   firing on forbidden pairs.  The typed
   [turn_phase_transition_spec_violation] payload travels on the exception;
   a [Printexc] printer reproduces the prior message text for log output. *)
let validate_turn_phase_transition ~from ~to_ =
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"turn_phase_transition"
    ~stage:"guard"
    (fun () ->
       match resolve_turn_phase_transition ~from ~target:to_ with
       | Resolved_turn_idempotent | Resolved_turn_transition _ -> ()
       | Resolved_turn_violation violation ->
         raise_turn_phase_transition_violation
           ~where:"validate_turn_phase_transition"
           ~from
           ~to_
           ~violation)
;;

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
  ignore (update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      if obs.decision_stage = target_packed
      then obs
      else (
        changed := true;
        { obs with decision_stage = target_packed }))));
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
  ignore (update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      let new_turn_phase = turn_phase_of_cascade_state cascade_state in
      match resolve_cascade_transition ~from:obs.cascade_state ~target:cascade_state with
      | Resolved_idempotent -> obs
      | Resolved_transition _ ->
        validate_turn_phase_transition ~from:obs.turn_phase ~to_:new_turn_phase;
        changed := true;
        { obs with cascade_state; turn_phase = new_turn_phase }
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
        obs)));
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

let mark_turn_provider_attempt_started ~base_path name =
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
       set_cascade_state Cascade_trying
     | Packed Cascade_selecting ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected;
       set_cascade_state Cascade_trying
     | Packed Cascade_trying ->
       set_turn_decision_stage
         ~base_path
         name
         Decision_active_tool_policy_selected
     | Packed Cascade_done
     | Packed Cascade_exhausted ->
       Log.Keeper.warn
         "registry: ignoring provider-attempt start after terminal cascade state \
          name=%s base_path=%s"
         name
         base_path)
;;

let set_turn_phase ~base_path name (turn_phase : packed_turn_phase) =
  (* RFC-0072 Phase 4b + Phase 5: dispatch via [resolve_turn_phase_transition]
     (PR #14912) instead of the [validate_turn_phase_transition] call.
     Mirrors the cascade-side wiring (PR #14908) — idempotent self-loops no
     longer flip [changed] or emit a broadcast, and forbidden transitions
     raise the typed [Turn_phase_transition_violation] (Phase 5) carrying
     the [turn_phase_transition_spec_violation] payload directly.  The
     violation branch stays wrapped by [Keeper_fsm_guard_runtime.wrap_unit]
     (PR #14926 pattern) so direct setter rejections keep incrementing
     [masc_fsm_guard_violation_total] — see the [Resolved_turn_violation]
     arm below. *)
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      match resolve_turn_phase_transition ~from:obs.turn_phase ~target:turn_phase with
      | Resolved_turn_idempotent -> obs
      | Resolved_turn_transition _ ->
        changed := true;
        { obs with turn_phase }
      | Resolved_turn_violation violation ->
        (* #14926: route the violation raise through [wrap_unit] so the
           guard's Prometheus counter [metric_fsm_guard_violation]
           (action=turn_phase_transition, stage=guard) keeps firing for
           forbidden transitions reached via this setter — prior to
           RFC-0072 Phase 4b (#14918) the instrumentation was transitive
           through [validate_turn_phase_transition], and the resolver swap
           dropped it.  Phase 5: the inner raise is now the typed
           [Turn_phase_transition_violation]; [wrap_unit]'s catch was
           widened to all exceptions so it still bumps the counter.  The
           trailing [obs] is unreachable (a no-op transition is the
           correct fallback should [wrap_unit] ever return). *)
        Keeper_fsm_guard_runtime.wrap_unit
          ~action:"turn_phase_transition"
          ~stage:"guard"
          (fun () ->
             raise_turn_phase_transition_violation
               ~where:"set_turn_phase"
               ~from:obs.turn_phase
               ~to_:turn_phase
               ~violation);
        obs)));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let set_turn_selected_model ~base_path name selected_model =
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      { obs with selected_model })));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let prepare_turn_retry_after_compaction ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      validate_cascade_transition
        ~from:obs.cascade_state
        ~to_:(Packed Cascade_idle : packed_cascade_state);
      validate_turn_phase_transition ~from:obs.turn_phase ~to_:(Packed Turn_prompting);
      changed := true;
      { obs with
        turn_phase = Packed Turn_prompting
      ; decision_stage = Packed Decision_guard_ok
      ; cascade_state = Packed Cascade_idle
      ; selected_model = None
      })));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_gate_rejected_by_name name =
  let target =
    StringMap.fold
      (fun _k v acc ->
         match acc with
         | Some _ -> acc
         | None -> if String.equal v.name name then Some v else None)
      (Atomic.get registry)
      None
  in
  match target with
  | None -> ()
  | Some entry ->
    let changed = ref false in
    let now = Time_compat.now () in
    update_entry ~base_path:entry.base_path name (fun e ->
      update_current_turn e (fun obs ->
        validate_turn_phase_transition ~from:obs.turn_phase ~to_:(Packed Turn_finalizing);
        changed := true;
        { obs with
          decision_stage = Packed Decision_gate_rejected
        ; turn_phase = Packed Turn_finalizing
        }));
    if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let mark_turn_finished ~base_path name =
  let completed_turn_to_record = ref None in
  let changed = ref false in
  let now = Time_compat.now () in
  ignore (update_entry_if_registered ~base_path name (fun e ->
    let had_live_turn =
      match e.current_turn_observation with
      | Some _ -> true
      | None -> false
    in
    let last_completed_turn =
      match e.current_turn_observation with
      | Some obs ->
        let ended_at = now in
        changed := true;
        completed_turn_to_record
        := Some
             { Keeper_transition_audit.turn_id = obs.turn_id
             ; started_at = obs.started_at
             ; ended_at
             ; outcome = completed_turn_outcome_of_observation obs
             };
        Some
          { ct_turn_id = obs.turn_id
          ; ct_started_at = obs.started_at
          ; ct_ended_at = ended_at
          ; ct_decision_stage = obs.decision_stage
          ; ct_cascade_state = obs.cascade_state
          ; ct_selected_model = obs.selected_model
          }
      | None -> e.last_completed_turn (* no live turn → preserve previous *)
    in
    let meta =
      if had_live_turn
      then
        { e.meta with
          runtime =
            { e.meta.runtime with
              usage = { e.meta.runtime.usage with last_turn_ts = now }
            }
        }
      else e.meta
    in
    { e with meta; current_turn_observation = None; last_completed_turn }));
  Option.iter
    (Keeper_transition_audit.record_completed_turn ~keeper_name:name)
    !completed_turn_to_record;
  (* IR-1 belt-and-suspenders: reset wakeup after turn completes so a stale
     true cannot suppress the next wakeup signal.  The primary consumer is
     [interruptible_sleep]'s CAS, but an explicit reset here guarantees the
     flag is clean regardless of whether the heartbeat loop's sleep path ran. *)
  (match get ~base_path name with
   (* tla-lint: allow-mutation: fiber signal — clear stale wakeup flag, paired with [interruptible_sleep] CAS *)
   | Some entry -> Atomic.set entry.fiber_wakeup false
   | None -> ());
  if !changed then broadcast_composite_changed ~name ~ts_unix:now
;;

let record_skip_reasons ~base_path name ~reasons =
  (* Only stamp when there's at least one reason — empty lists from a
     [Run] verdict path would otherwise overwrite the last legitimate
     skip stamp with a no-op. *)
  if reasons <> []
  then (
    let now = Time_compat.now () in
    update_entry ~base_path name (fun e ->
      { e with last_skip_observation = Some (now, reasons) }))
;;

let touch_last_turn_ts ~base_path name =
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    let runtime = e.meta.runtime in
    let usage = runtime.usage in
    { e with
      meta =
        { e.meta with
          runtime = { runtime with usage = { usage with last_turn_ts = now } }
        }
    })
;;

let increment_turn_failures ~base_path name =
  update_entry ~base_path name (fun e ->
    { e with turn_consecutive_failures = e.turn_consecutive_failures + 1 })
;;

let reset_turn_failures ~base_path name =
  update_entry ~base_path name (fun e -> { e with turn_consecutive_failures = 0 })
;;

let get_turn_failures ~base_path name =
  match get ~base_path name with
  | Some e -> e.turn_consecutive_failures
  | None -> 0
;;

let is_running ~base_path name =
  (* Enumerate every [Keeper_state_machine.phase] variant so the
     compiler flags any new phase added to the FSM.

     This predicate is intentionally narrower than
     [Keeper_state_machine.can_execute_turn] (defined alongside the
     phase type): [can_execute_turn] returns [true] for both [Running]
     and [Failing] because a keeper in [Failing] may still complete
     its in-flight turn before the recovery transition; [is_running]
     answers the operator-facing question "is this keeper currently
     running?" and treats only [Running] as such. The 12 other phases
     (Offline, Failing, Overflowed, Compacting, HandingOff, Draining,
     Paused, Stopped, Crashed, Restarting, Dead, Zombie) yield [false]
     here. A future phase variant (e.g. a hypothetical [Migrating] or
     [Healing]) would silently inherit [false] under the previous
     [Some _ -> false] catch-all without a review point on whether
     the new phase should count as "running" for any downstream
     consumer.

     Same FSM Sparse Match anti-pattern fix as PRs #14716, #14790,
     #14806, #14810, #14816, #14823, #14829, #14842, #14849. *)
  match get ~base_path name with
  | Some { phase = Running; _ } -> true
  | Some
      { phase =
          ( Offline
          | Failing
          | Overflowed
          | Compacting
          | HandingOff
          | Draining
          | Paused
          | Stopped
          | Crashed
          | Restarting
          | Dead
          | Zombie )
      ; _
      } -> false
  | None -> false
;;

(** True if the keeper has ANY registry entry (regardless of state).
    Used by reconcile to avoid re-launching Crashed/Dead keepers. *)
let is_registered ~base_path name = Option.is_some (get ~base_path name)

let count_running ?base_path () =
  match base_path with
  | None -> Atomic.get running_count_atomic
  | Some expected ->
    StringMap.fold
      (fun _k v acc ->
         if String.equal expected v.base_path && v.phase = Running then acc + 1 else acc)
      (Atomic.get registry)
      0
;;

let record_crash ~base_path name ts msg =
  Log.Keeper.error "registry: recording crash name=%s msg=%s" name msg;
  update_entry ~base_path name (fun e ->
    { e with
      crash_log =
        List.filteri (fun i _ -> i < max_crash_log_entries) ((ts, msg) :: e.crash_log)
    })
;;

let set_grpc_close ~base_path name close_fn =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> Atomic.set entry.grpc_close close_fn
  | None -> ()
;;

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None
;;

let set_started_at_for_test ~base_path name started_at =
  update_entry ~base_path name (fun entry -> { entry with started_at })
;;

let spawn_slots_available () =
  let max_keepers = Keeper_runtime_resolved.bootstrap_max_active_keepers () in
  let running_count = Atomic.get running_count_atomic in
  (not (Keeper_fd_pressure.active ()))
  && Keeper_fd_pressure.admit_start
       ~active_keepers:running_count
       ~starting_keepers:1
       ()
  && (max_keepers <= 0 || running_count < max_keepers)
;;

let wakeup ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  (* tla-lint: allow-mutation: fiber signal — public wakeup API for a single keeper *)
  | Some entry -> Atomic.set entry.fiber_wakeup true
  | None -> ()
;;

let wakeup_all ?base_path () =
  StringMap.iter
    (fun _k entry ->
       match base_path with
       | Some expected when not (String.equal expected entry.base_path) -> ()
       (* tla-lint: allow-mutation: fiber signal — bulk wakeup for Running keepers under base_path filter *)
       | _ -> if entry.phase = Running then Atomic.set entry.fiber_wakeup true)
    (Atomic.get registry)
;;

let fiber_health_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> Fiber_unknown
  | Some entry ->
    (match entry.phase with
     | Dead | Zombie -> Fiber_dead
     | Crashed | Restarting ->
       let max_restarts =
         Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
       in
       if entry.restart_count >= max_restarts then Fiber_dead else Fiber_zombie
     | Stopped | Offline -> Fiber_unknown
     | Running | Paused | Failing | Overflowed | Compacting | HandingOff | Draining ->
       (match Eio.Promise.peek entry.done_p with
        | None -> Fiber_alive
        | Some `Stopped -> Fiber_unknown
        | Some (`Crashed _) ->
          let max_restarts =
            Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
          in
          if entry.restart_count >= max_restarts then Fiber_dead else Fiber_zombie))
;;

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []
;;

let restore_supervisor_state ~base_path name ~restart_count ~last_restart_ts ~crash_log =
  update_entry ~base_path name (fun e ->
    { e with
      restart_count
    ; last_restart_ts
    ; dead_since_ts = None
    ; crash_log
    ; last_failure_reason = None
    })
;;

let get_last_agent_count ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.last_agent_count
  | None -> 0
;;

let set_last_agent_count ~base_path name count =
  update_entry ~base_path name (fun e -> { e with last_agent_count = count })
;;

let board_wakeup_allowed ~base_path name ~post_id ~debounce_sec =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> true
  | Some entry ->
    let now_ts = Time_compat.now () in
    (match StringMap.find_opt post_id entry.board_wakeups with
     | Some last_ts when now_ts -. last_ts < debounce_sec -> false
     | _ ->
       update_entry ~base_path name (fun e ->
         { e with board_wakeups = StringMap.add post_id now_ts e.board_wakeups });
       true)
;;

let clear_board_wakeups ~base_path name =
  update_entry ~base_path name (fun e -> { e with board_wakeups = StringMap.empty })
;;

let cleanup_tracking ~base_path name =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | Some entry ->
    put_entry
      key
      { entry with
        board_wakeups = StringMap.empty
      ; tool_usage = StringMap.empty
      ; last_agent_count = 0
      ; board_cursor_ts = 0.0
      ; board_cursor_post_id = None
      }
  | None -> ()
;;

let clear () =
  Atomic.set registry StringMap.empty;
  Atomic.set running_count_atomic 0
;;

(* -- Board cursor -------------------------------------------------- *)

let get_board_cursor_ts ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.board_cursor_ts
  | None -> 0.0
;;

let set_board_cursor_ts ~base_path name ts =
  update_entry ~base_path name (fun e ->
    let board_cursor_post_id =
      if Float.compare ts e.board_cursor_ts = 0 then e.board_cursor_post_id else None
    in
    { e with board_cursor_ts = ts; board_cursor_post_id })
;;

let get_board_cursor ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.board_cursor_ts, entry.board_cursor_post_id
  | None -> 0.0, None
;;

let set_board_cursor ~base_path name ts post_id =
  update_entry ~base_path name (fun e ->
    { e with board_cursor_ts = ts; board_cursor_post_id = post_id })
;;

(* -- Tool usage tracking ------------------------------------------- *)

(* Safe without a mutex: updates go through [update_entry]'s CAS loop, so
   keeper-turn OAS callbacks and runtime MCP server callbacks can both
   record usage for the same keeper without clobbering each other. *)
let record_tool_use ~base_path name ~tool_name ~success =
  update_entry ~base_path name (fun entry ->
    let e =
      match StringMap.find_opt tool_name entry.tool_usage with
      | Some e -> e
      | None -> { count = 0; successes = 0; failures = 0; last_used_at = 0.0 }
    in
    let updated =
      { count = e.count + 1
      ; successes = (if success then e.successes + 1 else e.successes)
      ; failures = (if success then e.failures else e.failures + 1)
      ; last_used_at = Time_compat.now ()
      }
    in
    { entry with tool_usage = StringMap.add tool_name updated entry.tool_usage })
;;

let tool_usage_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)
;;

(** Look up a keeper by name across all base_paths (O(n) scan). *)
let find_by_name name =
  StringMap.fold
    (fun _k v acc ->
       match acc with
       | Some _ -> acc
       | None -> if String.equal v.name name then Some v else None)
    (Atomic.get registry)
    None
;;

let find_by_agent_name agent_name =
  StringMap.fold
    (fun _k v acc ->
       match acc with
       | Some _ -> acc
       | None -> if String.equal v.meta.agent_name agent_name then Some v else None)
    (Atomic.get registry)
    None
;;

let find_by_id (uid : Keeper_id.Uid.t) =
  StringMap.fold
    (fun _k v acc ->
       match acc with
       | Some _ -> acc
       | None ->
         (match v.meta.keeper_id with
          | Some id when Keeper_id.Uid.equal id uid -> Some v
          | _ -> None))
    (Atomic.get registry)
    None
;;

let tool_usage_of_by_name name =
  match find_by_name name with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)
;;

(* -- Config resolution --------------------------------------------- *)

let resolve_config (config : Coord_utils_backend_setup.config) keeper_name
  : Coord_utils_backend_setup.config
  =
  if keeper_name = ""
  then config
  else (
    (* Keeper config resolution is scoped to the caller's current base_path.
       Do not retarget requests across other base_path registries. *)
    match get ~base_path:config.base_path keeper_name with
    | Some _ | None -> config)
;;

(* -- Tool usage persistence ---------------------------------------- *)

let tool_usage_path ~base_path name =
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers/tool_usage"
  in
  Filename.concat dir (name ^ ".json")
;;

let flush_tool_usage ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> ()
  | Some entry ->
    let items =
      StringMap.fold
        (fun tool_name (e : tool_call_entry) acc ->
           `Assoc
             [ "tool", `String tool_name
             ; "count", `Int e.count
             ; "successes", `Int e.successes
             ; "failures", `Int e.failures
             ; "last_used_at", `Float e.last_used_at
             ]
           :: acc)
        entry.tool_usage
        []
    in
    let json =
      `Assoc
        [ "keeper", `String name
        ; "flushed_at", `Float (Time_compat.now ())
        ; "tools", `List items
        ]
    in
    let path = tool_usage_path ~base_path name in
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file path (Yojson.Safe.to_string json ^ "\n")
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_tool_usage_flush_failures
         ~labels:[ "keeper", name ]
         ();
       Log.Keeper.error "flush_tool_usage %s: %s" name (Printexc.to_string exn))
;;

let restore_tool_usage ~base_path name =
  let path = tool_usage_path ~base_path name in
  if not (Fs_compat.file_exists path)
  then ()
  else (
    match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
    | None -> ()
    | Some _entry ->
      (try
         let content = Fs_compat.load_file path in
         let json = Yojson.Safe.from_string content in
         let tools =
           match json with
           | `Assoc fields ->
             (match List.assoc_opt "tools" fields with
              | Some (`List items) -> items
              | _ -> [])
           | _ -> []
         in
         List.iter
           (fun item ->
              match
                ( Safe_ops.json_string_opt "tool" item
                , Safe_ops.json_int_opt "count" item
                , Safe_ops.json_int_opt "successes" item
                , Safe_ops.json_int_opt "failures" item
                , Safe_ops.json_float_opt "last_used_at" item )
              with
              | ( Some tool_name
                , Some count
                , Some successes
                , Some failures
                , Some last_used_at )
                when tool_name <> "" ->
                let e = { count; successes; failures; last_used_at } in
                update_entry ~base_path name (fun ent ->
                  { ent with tool_usage = StringMap.add tool_name e ent.tool_usage })
              | _ -> ())
           tools
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_checkpoint_failures
           ~labels:[ "keeper", name; "site", "restore_tool_usage" ]
           ();
         Log.Keeper.warn "restore_tool_usage %s: %s" name (Printexc.to_string exn)))
;;

(* ── RFC-0002 Event Dispatch ───────────────────────────── *)

type lifecycle_event_origin =
  | Generic_dispatch
  | Post_turn_lifecycle
  | Operator_compact

let lifecycle_event_origin_to_string = function
  | Generic_dispatch -> "generic_dispatch"
  | Post_turn_lifecycle -> "post_turn_lifecycle"
  | Operator_compact -> "operator_compact"
;;

let is_paired_lifecycle_event = function
  | Keeper_state_machine.Compaction_started
  | Keeper_state_machine.Compaction_completed _
  | Keeper_state_machine.Compaction_failed _
  | Keeper_state_machine.Handoff_started
  | Keeper_state_machine.Handoff_completed _
  | Keeper_state_machine.Handoff_failed _ -> true
  | _ -> false
;;

let origin_allows_paired_lifecycle_event origin event =
  match origin, event with
  | Post_turn_lifecycle, event when is_paired_lifecycle_event event -> true
  | ( Operator_compact
    , ( Keeper_state_machine.Compaction_started
      | Keeper_state_machine.Compaction_completed _
      | Keeper_state_machine.Compaction_failed _ ) ) -> true
  | Generic_dispatch, event when is_paired_lifecycle_event event -> false
  | Operator_compact, event when is_paired_lifecycle_event event -> false
  | _, _ -> true
;;

let validate_paired_lifecycle_origin origin event =
  if origin_allows_paired_lifecycle_event origin event
  then Ok ()
  else
    Error
      (Keeper_state_machine.Precondition_violation
         { event = Keeper_state_machine.event_to_string event
         ; reason =
             Printf.sprintf
               "paired lifecycle event requires origin=post_turn_lifecycle%s; got %s"
               (match event with
                | Keeper_state_machine.Compaction_started
                | Keeper_state_machine.Compaction_completed _
                | Keeper_state_machine.Compaction_failed _ -> " or origin=operator_compact"
                | _ -> "")
               (lifecycle_event_origin_to_string origin)
         })
;;

let execute_entry_action_observability
      ~(name : string)
      ~(phase : Keeper_state_machine.phase)
      ~(ts_unix : float)
      (action : Keeper_state_machine.entry_action)
  : unit
  =
  match action with
  | Keeper_state_machine.Publish_lifecycle { event_name; detail } ->
    Log.Keeper.info
      "registry: lifecycle name=%s phase=%s event=%s detail=%s"
      name
      (Keeper_state_machine.phase_to_string phase)
      event_name
      detail;
    let (_ignore_ts : float) = ts_unix in
    ()
  | Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart _
  | Mark_dead_tombstone
  | Mark_zombie_tombstone
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_oas -> ()
;;

let followup_event_of_entry_action
      ~(phase : Keeper_state_machine.phase)
      (action : Keeper_state_machine.entry_action)
  : Keeper_state_machine.event option
  =
  match phase, action with
  | Keeper_state_machine.Overflowed, Start_compaction ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_fsm_edge_transitions
      ~labels:[ "edge", "ksm_to_kmc_compact_trigger" ]
      ();
    Some Keeper_state_machine.Auto_compact_triggered
  | _ -> None
;;

let record_followup_dispatch_rejection event =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
    ~labels:[ "event", Keeper_state_machine.event_to_string event ]
    ()
;;

let pending_measurement_after_event now entry event =
  match event with
  | Keeper_state_machine.Context_measured { auto_rules; _ } ->
    Some { tm_captured_at = now; tm_auto_rules = auto_rules }
  | _ -> entry.pending_turn_measurement
;;

let compaction_stage_of_event entry event =
  match event with
  | Keeper_state_machine.Compaction_started
  | Keeper_state_machine.Auto_compact_triggered
  | Keeper_state_machine.Operator_compact_requested -> Packed Compaction_compacting
  | Keeper_state_machine.Compaction_completed _ -> Packed Compaction_done
  | Keeper_state_machine.Compaction_failed _ -> Packed Compaction_accumulating
  | _ -> entry.compaction_stage
;;

(* RFC-0072 Phase 6: the 3×3 compaction matrix dispatched as an exhaustive
   match — the 3 valid pairs (incl. idempotent self-loops) return [()], the
   3 forbidden pairs raise the typed [Compaction_transition_violation]
   (replacing the prior bare [assert], whose [Assert_failure] carried no
   labels).  Still wrapped in [Keeper_fsm_guard_runtime.wrap_unit] so
   [metric_fsm_guard_violation] (action=compaction_transition, stage=guard)
   fires on a forbidden pair; the match stays exhaustive so adding a
   [compaction_stage] variant triggers Warning 8 here.  No
   [Compaction_transition] GADT / [resolve_*] helper: with 3 states and a
   single consumer the resolver indirection would be premature. *)
let validate_compaction_transition ~from ~to_ =
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"compaction_transition"
    ~stage:"guard"
    (fun () ->
       match from, to_ with
       (* Idempotent self-loops + valid cross-state transitions (6). *)
       | Packed Compaction_accumulating, Packed Compaction_accumulating
       | Packed Compaction_accumulating, Packed Compaction_compacting
       (* via set_compaction_stage *)
       | Packed Compaction_compacting, Packed Compaction_accumulating
       (* via set_compaction_stage: retry after a failed compaction *)
       | Packed Compaction_compacting, Packed Compaction_compacting
       | Packed Compaction_compacting, Packed Compaction_done
       (* via set_compaction_stage *)
       | Packed Compaction_done, Packed Compaction_done -> ()
       (* Forbidden transitions (3). *)
       | Packed Compaction_accumulating, Packed Compaction_done ->
         raise_compaction_transition_violation
           ~where:"validate_compaction_transition"
           ~from
           ~to_
           ~violation:Accumulating_to_done
       | Packed Compaction_done, Packed Compaction_accumulating ->
         (* terminal; a fresh compaction is a reset, not a transition *)
         raise_compaction_transition_violation
           ~where:"validate_compaction_transition"
           ~from
           ~to_
           ~violation:Done_to_accumulating
       | Packed Compaction_done, Packed Compaction_compacting ->
         (* terminal *)
         raise_compaction_transition_violation
           ~where:"validate_compaction_transition"
           ~from
           ~to_
           ~violation:Done_to_compacting)
;;

let compaction_stage_after_event entry event =
  let old_stage = entry.compaction_stage in
  let new_stage = compaction_stage_of_event entry event in
  validate_compaction_transition ~from:old_stage ~to_:new_stage;
  new_stage
;;

(** Registry mutation is still non-yielding (StringMap lookup + put,
    Atomic.set). Entry actions run only after [put_entry], so any
    observability or follow-up state transitions happen after the registry
    state is consistent. *)
let rec dispatch_event_with_audit
          ~base_path
          ?(origin = Generic_dispatch)
          ?snapshot
          ?events_fired
          ?selected_event
          name
          (event : Keeper_state_machine.event)
  =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | None ->
    Error
      (Keeper_state_machine.Invalid_transition
         { from_phase = Keeper_state_machine.Offline
         ; to_phase = Keeper_state_machine.Offline
         ; reason = Printf.sprintf "keeper %s not registered" name
         })
  | Some entry ->
    let now = Time_compat.now () in
    (* Retain the last auto-rule summary emitted with a [Context_measured]
       event so downstream read-only observers (RFC-0003 composite
       observer) can project it without reading history files. Other
       events leave the field untouched. *)
    let last_auto_rules =
      match event with
      | Keeper_state_machine.Context_measured { auto_rules; _ } -> Some (now, auto_rules)
      | _ -> entry.last_auto_rules
    in
    let origin_result = validate_paired_lifecycle_origin origin event in
    let pending_turn_measurement = pending_measurement_after_event now entry event in
    let compaction_stage =
      match origin_result with
      | Error _ -> entry.compaction_stage
      | Ok () -> compaction_stage_after_event entry event
    in
    let result =
      match origin_result with
      | Error _ as err -> err
      | Ok () ->
        Keeper_state_machine.apply_event
          ~current_phase:entry.phase
          ~conditions:entry.conditions
          ~event
          ~now
    in
    Dashboard_attribution.record
      (Keeper_state_machine.attribution_of_transition ~event result);
    (match result with
     | Ok tr when tr.new_phase <> tr.prev_phase ->
       Log.Keeper.info
         "registry: phase transition name=%s old=%s new=%s event=%s"
         name
         (Keeper_state_machine.phase_to_string tr.prev_phase)
         (Keeper_state_machine.phase_to_string tr.new_phase)
         (Keeper_state_machine.event_to_string event);
       (* Record transition in audit ring buffer for dashboard API *)
       Keeper_transition_audit.record_transition
         ~keeper_name:name
         { snapshot
         ; events_fired = Option.value events_fired ~default:[ event ]
         ; selected_event = Option.value selected_event ~default:event
         ; prev_phase = tr.prev_phase
         ; new_phase = tr.new_phase
         ; transition_outcome = "applied"
         ; wall_clock_at_decision = now
         };
       Keeper_lifecycle_hooks.run
         ~base_dir:base_path
         ~meta:entry.meta
         ~keeper_id:name
         (Keeper_lifecycle_hooks.Phase_transition
            { from_phase = tr.prev_phase; to_phase = tr.new_phase });
       (* Broadcast phase transition to SSE subscribers *)
       (try
          Sse.broadcast
            (`Assoc
                [ "type", `String "keeper_phase_changed"
                ; "name", `String name
                ; ( "prev_phase"
                  , `String (Keeper_state_machine.phase_to_string tr.prev_phase) )
                ; "new_phase", `String (Keeper_state_machine.phase_to_string tr.new_phase)
                ; "event", `String (Keeper_state_machine.event_to_string event)
                ; "ts_unix", `Float now
                ])
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> record_phase_broadcast_failure ~name exn);
       (* Update running count based on phase transition *)
       (match tr.prev_phase, tr.new_phase with
        | Running, phase when phase <> Running -> decr_running_count_clamped ()
        | phase, Running when phase <> Running -> Atomic.incr running_count_atomic
        | _ -> ());
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_lifecycle_transitions
         ~labels:
           [ "keeper", name
           ; "from_phase", Keeper_state_machine.phase_to_string tr.prev_phase
           ; "to_phase", Keeper_state_machine.phase_to_string tr.new_phase
           ]
         ();
       (* Update dead_since_ts: always set to now on Dead transition *)
       let dead_since_ts =
         match tr.new_phase with
         | Keeper_state_machine.Dead -> Some now
         | _ -> None
       in
       let new_seq = entry.transition_seq + 1 in
       (* TLA+ trace emission (MASC_TLA_TRACE=1) *)
       if Keeper_trace_emit.enabled ()
       then
         Keeper_trace_emit.emit_transition
           ~keeper_name:name
           ~base_path
           ~seq:new_seq
           ~event
           ~prev_phase:tr.prev_phase
           ~new_phase:tr.new_phase
           ~conditions_after:tr.updated_conditions
           ~restart_count:entry.restart_count;
       put_entry
         key
         { entry with
           phase = tr.new_phase
         ; conditions = tr.updated_conditions
         ; dead_since_ts
         ; transition_seq = new_seq
         ; last_auto_rules
         ; pending_turn_measurement
         ; compaction_stage
         };
       List.iter
         (execute_entry_action_observability ~name ~phase:tr.new_phase ~ts_unix:now)
         tr.entry_actions;
       List.iter
         (fun followup_event ->
            match dispatch_event_with_audit ~base_path name followup_event with
            | Ok _ -> ()
            | Error
                (Keeper_state_machine.Invalid_transition { from_phase; to_phase; reason })
              ->
              record_followup_dispatch_rejection followup_event;
              Log.Keeper.error
                "registry(%s): followup dispatch failed: %s -> %s (%s)"
                name
                (Keeper_state_machine.phase_to_string from_phase)
                (Keeper_state_machine.phase_to_string to_phase)
                reason
            | Error (Keeper_state_machine.Terminal_state { current; attempted_event }) ->
              record_followup_dispatch_rejection followup_event;
              Log.Keeper.warn
                "registry(%s): followup skipped, already terminal: %s (event: %s)"
                name
                (Keeper_state_machine.phase_to_string current)
                attempted_event
            | Error (Keeper_state_machine.Precondition_violation { event = ev; reason })
              ->
              record_followup_dispatch_rejection followup_event;
              Log.Keeper.warn
                "registry(%s): followup skipped, precondition violated: %s (%s)"
                name
                ev
                reason)
         (List.filter_map
            (followup_event_of_entry_action ~phase:tr.new_phase)
            tr.entry_actions);
       (* Composite-lifecycle SSE envelope — RFC-0003 §6.
          The body carries only the keeper name and observation timestamp;
          subscribers re-fetch [/api/v1/keepers/:name/composite] for the
          full snapshot so the spec's "single writer, pull observers"
          invariant is preserved. *)
       broadcast_composite_changed ~name ~ts_unix:now;
       Ok tr
     | Ok tr ->
       (* No phase change — still update conditions *)
       let new_seq = entry.transition_seq + 1 in
       if Keeper_trace_emit.enabled ()
       then
         Keeper_trace_emit.emit_transition
           ~keeper_name:name
           ~base_path
           ~seq:new_seq
           ~event
           ~prev_phase:tr.prev_phase
           ~new_phase:tr.new_phase
           ~conditions_after:tr.updated_conditions
           ~restart_count:entry.restart_count;
       put_entry
         key
         { entry with
           conditions = tr.updated_conditions
         ; transition_seq = new_seq
         ; last_auto_rules
         ; pending_turn_measurement
         ; compaction_stage
         };
       broadcast_composite_changed ~name ~ts_unix:now;
       Ok tr
     | Error e ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
         ~labels:[ "event", Keeper_state_machine.event_to_string event ]
         ();
       Log.Keeper.warn
         "registry: dispatch_event rejected name=%s error=%s"
         name
         (Keeper_state_machine.transition_error_to_string e);
       Error e)
;;

let dispatch_event ~base_path ?(origin = Generic_dispatch) name event =
  dispatch_event_with_audit ~base_path ~origin name event
;;

let dispatch_event_and_log ~base_path ?(origin = Generic_dispatch) name event =
  match dispatch_event ~base_path ~origin name event with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
      | Keeper_state_machine.Precondition_violation _ -> "precondition_violation"
    in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_dispatch_event_failures
      ~labels:[ "keeper", name; "reason", reason_label ]
      ();
    Error e
;;

let dispatch_event_unit ~base_path ?(origin = Generic_dispatch) name event =
  match dispatch_event_and_log ~base_path ~origin name event with
  | Ok _ -> ()
  | Error e ->
    Log.Keeper.warn
      "%s: dispatch_event failed: %s"
      name
      (Keeper_state_machine.transition_error_to_string e)
;;

let dispatch_event_with_audit_and_log
      ~base_path
      ?(origin = Generic_dispatch)
      ?snapshot
      ?events_fired
      ?selected_event
      name
      event
  =
  match
    dispatch_event_with_audit
      ~base_path
      ~origin
      ?snapshot
      ?events_fired
      ?selected_event
      name
      event
  with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
      | Keeper_state_machine.Precondition_violation _ -> "precondition_violation"
    in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_dispatch_event_failures
      ~labels:[ "keeper", name; "reason", reason_label ]
      ();
    Error e
;;

let prepare_fiber_launch ~base_path name =
  (match get ~base_path name with
   | Some entry ->
     (* tla-lint: allow-mutation: fiber signal — initialise per-fiber Atomic flags before keeper launch *)
     Atomic.set entry.fiber_stop false;
     Atomic.set entry.fiber_wakeup false;
     Atomic.set entry.waiting_for_inference false
   | None ->
     (* P3 cleanup: previously this was a silent no-op when the
          keeper was not yet registered.  The dispatch_event call
          below still fires even in this case, which can leave a
          Fiber_started event with no corresponding atomic-flag
          reset.  Log so the race is at least visible — caller
          (server_runtime_bootstrap.ml) is responsible for ensuring
          register_with_state has happened before this point. *)
     Log.Keeper.warn
       "registry: prepare_fiber_launch name=%s base_path=%s: entry not registered, \
        skipping flag reset"
       name
       base_path);
  dispatch_event ~base_path name Keeper_state_machine.Fiber_started
;;

let get_phase ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.phase
  | None -> None
;;

let get_conditions ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.conditions
  | None -> None
;;

let enqueue_event ~base_path name stimulus =
  match get ~base_path name with
  | None ->
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered"
      name
      base_path
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let next = Keeper_event_queue.enqueue cur stimulus in
      if not (Atomic.compare_and_set entry.event_queue cur next) then loop ()
    in
    loop ()
;;

let event_queue_snapshot ~base_path name =
  match get ~base_path name with
  | None -> Keeper_event_queue.empty
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue_event ~base_path name =
  match get ~base_path name with
  | None -> None
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      match Keeper_event_queue.dequeue cur with
      | None -> None
      | Some (stim, rest) ->
        if Atomic.compare_and_set entry.event_queue cur rest then Some stim else loop ()
    in
    loop ()
;;

let drain_board_events ?window_sec ~base_path name =
  match get ~base_path name with
  | None -> []
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let board, rest = Keeper_event_queue.drain_board_window ?window_sec cur in
      if Atomic.compare_and_set entry.event_queue cur rest then board else loop ()
    in
    loop ()
;;
