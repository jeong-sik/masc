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

module StringMap = Map.Make (String)

(** Structured failure reason for cohort detection in self-preservation.
    ADT matching replaces string prefix matching for crash_msg grouping. *)
type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit = {
  kind : ambiguous_partial_commit_kind;
  detail : string;
}

(** Phase B PR-6 (2026-04-28): typed sub-class of stale-watchdog kills.
    See keeper_registry.mli for rationale. *)
type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | In_turn_hung of {
      active_seconds : float;
      timeout_threshold : float;
    }
  | Noop_failure_loop of { noop_count : int }

let stale_kill_class_to_string = function
  | Idle_turn { stall_seconds } ->
      Printf.sprintf "idle_turn(%.0fs)" stall_seconds
  | In_turn_hung { active_seconds; timeout_threshold } ->
      Printf.sprintf "in_turn_hung(active=%.0fs threshold=%.0fs)"
        active_seconds timeout_threshold
  | Noop_failure_loop { noop_count } ->
      Printf.sprintf "noop_failure_loop(noop=%d)" noop_count

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
      (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Oas_timeout_budget_loop of { count : int }
      (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of { code : string; detail : string }
  | Tool_required_unsatisfied of { code : string; detail : string }
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

let ambiguous_partial_commit_kind_to_string = function
  | Post_commit_timeout -> "post_commit_timeout"
  | Post_commit_failure -> "post_commit_failure"

let failure_reason_to_string = function
  | Heartbeat_consecutive_failures n ->
      Printf.sprintf "heartbeat_consecutive_failures(%d)" n
  | Turn_consecutive_failures n ->
      Printf.sprintf "turn_consecutive_failures(%d)" n
  | Stale_turn_timeout cls ->
      Printf.sprintf "stale_turn_timeout(%s)"
        (stale_kill_class_to_string cls)
  | Stale_termination_storm { count } ->
      Printf.sprintf "stale_termination_storm(count=%d)" count
  | Oas_timeout_budget_loop { count } ->
      Printf.sprintf "oas_timeout_budget_loop(count=%d)" count
  | Provider_runtime_error { code; detail } ->
      Printf.sprintf "provider_runtime_error(%s:%s)" code detail
  | Tool_required_unsatisfied { code; detail } ->
      Printf.sprintf "tool_required_unsatisfied(%s:%s)" code detail
  | Ambiguous_partial_commit { kind; detail } ->
      Printf.sprintf "ambiguous_partial_commit(%s:%s)"
        (ambiguous_partial_commit_kind_to_string kind)
        detail
  | Fiber_unresolved -> "fiber_unresolved"
  | Exception s -> Printf.sprintf "exception(%s)" s

(** #10584: cohort key for grouping failures by variant, ignoring
    parameters (e.g. failure count, timeout seconds).  Lives next to
    [failure_reason_to_string] in the source-of-truth module so any
    new variant added to [failure_reason] forces a same-PR update of
    BOTH conversion arms — the consumer in keeper_supervisor (and
    any other dashboard / metrics call site) just delegates here.
    This is Option B from #10584: avoid the recurring-P0 pattern
    where consumer-side exhaustive matches catch up to upstream
    variant additions only after the warn-error build trip. *)
let failure_reason_cohort_key = function
  | Some (Heartbeat_consecutive_failures _) -> "heartbeat_failures"
  | Some (Turn_consecutive_failures _) -> "turn_failures"
  | Some (Stale_turn_timeout _) -> "stale_turn_timeout"
  | Some (Stale_termination_storm _) -> "stale_termination_storm"
  | Some (Oas_timeout_budget_loop _) -> "oas_timeout_budget_loop"
  | Some (Provider_runtime_error _) -> "provider_runtime_error"
  | Some (Tool_required_unsatisfied _) -> "tool_required_unsatisfied"
  | Some (Ambiguous_partial_commit _) -> "ambiguous_partial_commit"
  | Some Fiber_unresolved -> "fiber_unresolved"
  | Some (Exception _) -> "exception"
  | None -> "unknown"

let stale_watchdog_failure_reason ~prior ~kill_class =
  match prior with
  | Some
      ( Oas_timeout_budget_loop _
      | Provider_runtime_error _
      | Tool_required_unsatisfied _
      | Ambiguous_partial_commit _
      | Turn_consecutive_failures _
      | Heartbeat_consecutive_failures _
      | Exception _ ) ->
      prior
  | Some (Stale_termination_storm _ | Stale_turn_timeout _ | Fiber_unresolved)
  | None ->
      Some (Stale_turn_timeout kill_class)

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash

type turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

type decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

type cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

type compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

type turn_measurement = {
  tm_captured_at : float;
  tm_auto_rules : Keeper_state_machine.auto_rule_summary;
}

type registry_entry = {
  base_path : string;
  name : string;
  meta : keeper_meta;
  (** Keeper lifecycle phase (RFC-0002 11-state machine). *)
  phase : Keeper_state_machine.phase;
  (** Observable conditions that derive [phase]. *)
  conditions : Keeper_state_machine.conditions;
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  event_queue : Keeper_event_queue.t Atomic.t;
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
  restart_count : int;
  last_restart_ts : float;
  dead_since_ts : float option;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  turn_consecutive_failures : int;
  last_agent_count : int;
  board_wakeups : float StringMap.t;
  board_cursor_ts : float;
  board_cursor_post_id : string option;
  tool_usage : tool_call_entry StringMap.t;
  transition_seq : int;
  waiting_for_inference : bool Atomic.t;
      (** Ephemeral flag: true when keeper is blocked in admission queue.
          Set/cleared around [Admission_queue.with_permit].
          Does not affect state machine phase derivation. *)
  last_auto_rules :
    (float * Keeper_state_machine.auto_rule_summary) option;
  last_event_bus_correlation : string option;
  pending_turn_measurement : turn_measurement option;
  current_turn_observation : turn_observation option;
  last_completed_turn : completed_turn_observation option;
  last_skip_observation : (float * string list) option;
  compaction_stage : compaction_stage;
}

and turn_observation = {
  turn_id : int;
  started_at : float;
  turn_phase : turn_phase;
  decision_stage : decision_stage;
  cascade_state : cascade_state;
  measurement : turn_measurement option;
  measurement_bind_count : int;
  selected_model : string option;
}

and completed_turn_observation = {
  ct_turn_id : int;
  ct_started_at : float;
  ct_ended_at : float;
  ct_decision_stage : decision_stage;
  ct_cascade_state : cascade_state;
  ct_selected_model : string option;
}

let try_resolve_done entry value =
  match Eio.Promise.peek entry.done_p with
  | Some _ -> false
  | None ->
    (try
       Eio.Promise.resolve entry.done_r value;
       true
     with
     | Invalid_argument _ -> false)
;;

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
  if String.contains name '\x1f' then
    invalid_arg (Printf.sprintf "keeper name contains unit separator: %s" name);
  base_path ^ "\x1f" ^ name

let put_entry key entry =
  let rec loop () =
    let current = Atomic.get registry in
    let updated = StringMap.add key entry current in
    if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()

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
        (* P1 silent-failure fix: previously this returned () silently,
           hiding the case where a caller (e.g. a turn-state setter)
           raced with keeper deregistration and the update was lost.
           29 callers funnel through here; logging once at the helper
           makes every such race observable in operator logs without
           changing any caller's signature. *)
        Log.Keeper.warn
          "registry: update_entry name=%s base_path=%s: entry not found, update dropped"
          name base_path
    | Some entry ->
        let updated = StringMap.add key (f entry) current in
        if not (Atomic.compare_and_set registry current updated) then loop ()
  in
  loop ()

let max_crash_log_entries = 5

let register_with_state ~base_path name meta
    ~(phase : Keeper_state_machine.phase)
    ~(conditions : Keeper_state_machine.conditions) =
  Log.Keeper.info "registry: registering keeper name=%s base_path=%s phase=%s"
    name base_path (Keeper_state_machine.phase_to_string phase);
  let done_p, done_r = Eio.Promise.create () in
  let key = registry_key ~base_path name in
  (match StringMap.find_opt key (Atomic.get registry) with
   | Some entry when entry.phase = Running ->
       Log.Keeper.warn "registry: overwriting running keeper during register name=%s" name;
       decr_running_count_clamped ()
   | _ -> ());
  let entry = {
    base_path;
    name;
    meta;
    phase;
    conditions;
    fiber_stop = Atomic.make false;
    fiber_wakeup = Atomic.make false;
    event_queue = Atomic.make Keeper_event_queue.empty;
    started_at = Time_compat.now ();
    grpc_close = Atomic.make None;
    done_p;
    done_r;
    restart_count = 0;
    last_restart_ts = 0.0;
    dead_since_ts = None;
    crash_log = [];
    last_error = None;
    last_failure_reason = None;
    turn_consecutive_failures = 0;
    last_agent_count = 0;
    board_wakeups = StringMap.empty;
    board_cursor_ts = 0.0;
    board_cursor_post_id = None;
    tool_usage = StringMap.empty;
    transition_seq = 0;
    waiting_for_inference = Atomic.make false;
    last_auto_rules = None;
    last_event_bus_correlation = None;
    pending_turn_measurement = None;
    current_turn_observation = None;
    last_completed_turn = None;
    last_skip_observation = None;
    compaction_stage = Compaction_accumulating;
  } in
  put_entry key entry;
  if phase = Running then
    Atomic.incr running_count_atomic;
  Log.Keeper.debug "registry: keeper registered name=%s running_count=%d"
    name (Atomic.get running_count_atomic);
  entry

let register ~base_path name meta =
  let conditions = {
    Keeper_state_machine.default_conditions with
    fiber_alive = true;
    restart_budget_remaining = true;
  } in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions

let register_offline ~base_path name meta =
  let conditions = {
    Keeper_state_machine.default_conditions with
    launch_pending = true;
    restart_budget_remaining = true;
  } in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions

let register_restarting ~base_path name meta =
  let conditions = {
    Keeper_state_machine.default_conditions with
    restart_budget_remaining = true;
    backoff_elapsed = true;
  } in
  let phase = Keeper_state_machine.derive_phase conditions in
  register_with_state ~base_path name meta ~phase ~conditions

let unregister ~base_path name =
  Log.Keeper.info "registry: unregistering keeper name=%s base_path=%s" name base_path;
  let key = registry_key ~base_path name in
  let rec loop () =
    let current = Atomic.get registry in
    let before = StringMap.find_opt key current in
    let updated = StringMap.remove key current in
    if not (Atomic.compare_and_set registry current updated) then loop ()
    else before
  in
  (match loop () with
   | Some entry when entry.phase = Running ->
       decr_running_count_clamped ();
       Log.Keeper.debug "registry: unregistered running keeper name=%s running_count=%d"
         name (Atomic.get running_count_atomic)
   | Some entry ->
       Log.Keeper.debug "registry: unregistered non-running keeper name=%s state=%s"
         name (Keeper_state_machine.phase_to_string entry.phase)
   | None ->
       Log.Keeper.warn "registry: attempted to unregister non-existent keeper name=%s" name)

let get ~base_path name =
  let result = StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) in
  (match result with
   | None -> Log.Keeper.debug "registry: lookup miss name=%s base_path=%s" name base_path
   | Some _ -> ());
  result

let all ?base_path () =
  StringMap.fold
    (fun _k v acc ->
      match base_path with
      | Some expected when not (String.equal expected v.base_path) -> acc
      | _ -> v :: acc)
    (Atomic.get registry) []

let update_meta ~base_path name meta =
  update_entry ~base_path name (fun e -> { e with meta })

let () =
  register_runtime_meta_write_sync (fun config meta ->
      update_meta ~base_path:config.base_path meta.name meta)

let mark_dead ~base_path name ~at =
  Log.Keeper.error "registry: marking keeper dead name=%s at=%.0f" name at;
  update_entry ~base_path name (fun entry ->
    if entry.phase <> Dead then begin
      (match entry.phase with
       | Running -> decr_running_count_clamped ()
       | _ -> ());
      let conditions =
        { Keeper_state_machine.default_conditions with
          launch_pending = false;
          fiber_alive = false;
          restart_budget_remaining = false;
        }
      in
      let phase = Keeper_state_machine.derive_phase conditions in
      { entry with dead_since_ts = Some at; phase; conditions }
    end else
      { entry with dead_since_ts = Some (Option.value ~default:at entry.dead_since_ts) })

let record_restart ~base_path name =
  Log.Keeper.warn "registry: recording restart name=%s" name;
  update_entry ~base_path name (fun e ->
    { e with restart_count = e.restart_count + 1;
             last_restart_ts = Time_compat.now () })

let record_error ~base_path name err =
  Log.Keeper.error "registry: recording error name=%s error=%s" name err;
  update_entry ~base_path name (fun e -> { e with last_error = Some err })

let clear_error ~base_path name =
  update_entry ~base_path name (fun e -> { e with last_error = None })

let set_failure_reason ~base_path name reason =
  update_entry ~base_path name (fun e -> { e with last_failure_reason = reason })

let set_last_correlation_id ~base_path name cid =
  update_entry ~base_path name (fun e ->
    { e with last_event_bus_correlation = Some cid })

let turn_phase_of_cascade_state = function
  | Cascade_idle | Cascade_selecting -> Turn_prompting
  | Cascade_trying -> Turn_executing
  | Cascade_done | Cascade_exhausted -> Turn_finalizing

let broadcast_composite_changed ~name ~ts_unix =
  try
    let json =
      `Assoc [
        "type", `String "keeper_composite_changed";
        "name", `String name;
        "ts_unix", `Float ts_unix;
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
      Log.Keeper.warn
        "registry: broadcast_composite_changed name=%s failed: %s"
        name (Printexc.to_string exn)

let completed_turn_outcome_of_observation
    (obs : turn_observation) : Keeper_transition_audit.completed_turn_outcome =
  (* P1 silent-failure fix: the previous wildcard `| _ -> Turn_failed`
     meant that adding a new variant to either ADT (decision_stage or
     cascade_state) would silently fall through to Turn_failed without
     a compile error.  Spelling out every variant lets the OCaml
     exhaustiveness checker catch missing cases at build time. *)
  match obs.decision_stage with
  | Decision_gate_rejected -> Keeper_transition_audit.Turn_gate_rejected
  | Decision_undecided
  | Decision_guard_ok
  | Decision_tool_policy_selected ->
      (match obs.cascade_state with
       | Cascade_done -> Keeper_transition_audit.Turn_substantive
       | Cascade_idle
       | Cascade_selecting
       | Cascade_trying
       | Cascade_exhausted -> Keeper_transition_audit.Turn_failed)

let update_current_turn e f =
  let current_turn_observation =
    match e.current_turn_observation with
    | None -> None
    | Some obs -> Some (f obs)
  in
  { e with current_turn_observation }

let mark_turn_started ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    let turn_id = e.meta.runtime.usage.total_turns + 1 in
    let obs = {
      turn_id;
      started_at = now;
      turn_phase = Turn_prompting;
      decision_stage = Decision_undecided;
      cascade_state = Cascade_idle;
      measurement = None;
      measurement_bind_count = 0;
      selected_model = None;
    } in
    changed := true;
    { e with
      current_turn_observation = Some obs;
      compaction_stage = Compaction_accumulating;
    });
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let mark_turn_measurement ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    match e.current_turn_observation, e.pending_turn_measurement with
    | Some obs, Some measurement ->
      changed := true;
      {
        e with
        current_turn_observation =
          Some {
            obs with
            measurement = Some measurement;
            measurement_bind_count = obs.measurement_bind_count + 1;
          };
        pending_turn_measurement = None;
      }
    | _ -> e);
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let set_turn_decision_stage ~base_path name decision_stage =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      { obs with decision_stage }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let set_turn_cascade_state ~base_path name cascade_state =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      {
        obs with
        cascade_state;
        turn_phase = turn_phase_of_cascade_state cascade_state;
      }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let set_turn_phase ~base_path name turn_phase =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      { obs with turn_phase }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let set_turn_selected_model ~base_path name selected_model =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      { obs with selected_model }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let prepare_turn_retry_after_compaction ~base_path name =
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    update_current_turn e (fun obs ->
      changed := true;
      {
        obs with
        turn_phase = Turn_prompting;
        decision_stage = Decision_guard_ok;
        cascade_state = Cascade_idle;
        selected_model = None;
      }));
  if !changed then broadcast_composite_changed ~name ~ts_unix:now

let mark_turn_gate_rejected_by_name name =
  let target =
    StringMap.fold
      (fun _k v acc ->
        match acc with
        | Some _ -> acc
        | None -> if String.equal v.name name then Some v else None)
      (Atomic.get registry) None
  in
  match target with
  | None -> ()
  | Some entry ->
      let changed = ref false in
      let now = Time_compat.now () in
      update_entry ~base_path:entry.base_path name (fun e ->
        update_current_turn e (fun obs ->
          changed := true;
          {
            obs with
            decision_stage = Decision_gate_rejected;
            turn_phase = Turn_finalizing;
          }));
      if !changed then broadcast_composite_changed ~name ~ts_unix:now

let mark_turn_finished ~base_path name =
  let completed_turn_to_record = ref None in
  let changed = ref false in
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
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
          completed_turn_to_record :=
            Some
              {
                Keeper_transition_audit.turn_id = obs.turn_id;
                started_at = obs.started_at;
                ended_at;
                outcome = completed_turn_outcome_of_observation obs;
              };
          Some
            {
              ct_turn_id = obs.turn_id;
              ct_started_at = obs.started_at;
              ct_ended_at = ended_at;
              ct_decision_stage = obs.decision_stage;
              ct_cascade_state = obs.cascade_state;
              ct_selected_model = obs.selected_model;
            }
      | None -> e.last_completed_turn  (* no live turn → preserve previous *)
    in
    let meta =
      if had_live_turn then
        {
          e.meta with
          runtime =
            {
              e.meta.runtime with
              usage =
                { e.meta.runtime.usage with last_turn_ts = now };
            };
        }
      else e.meta
    in
    { e with
      meta;
      current_turn_observation = None;
      last_completed_turn });
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

let record_skip_reasons ~base_path name ~reasons =
  (* Only stamp when there's at least one reason — empty lists from a
     [Run] verdict path would otherwise overwrite the last legitimate
     skip stamp with a no-op. *)
  if reasons <> [] then begin
    let now = Time_compat.now () in
    update_entry ~base_path name (fun e ->
      { e with last_skip_observation = Some (now, reasons) })
  end

let touch_last_turn_ts ~base_path name =
  let now = Time_compat.now () in
  update_entry ~base_path name (fun e ->
    let runtime = e.meta.runtime in
    let usage = runtime.usage in
    { e with
      meta =
        { e.meta with
          runtime =
            { runtime with
              usage = { usage with last_turn_ts = now }
            }
        }
    })

let increment_turn_failures ~base_path name =
  update_entry ~base_path name (fun e ->
    { e with turn_consecutive_failures = e.turn_consecutive_failures + 1 })

let reset_turn_failures ~base_path name =
  update_entry ~base_path name (fun e ->
    { e with turn_consecutive_failures = 0 })

let get_turn_failures ~base_path name =
  match get ~base_path name with
  | Some e -> e.turn_consecutive_failures
  | None -> 0

let is_running ~base_path name =
  match get ~base_path name with
  | Some { phase = Running; _ } -> true
  | _ -> false

(** True if the keeper has ANY registry entry (regardless of state).
    Used by reconcile to avoid re-launching Crashed/Dead keepers. *)
let is_registered ~base_path name =
  Option.is_some (get ~base_path name)

let count_running ?base_path () =
  match base_path with
  | None -> Atomic.get running_count_atomic
  | Some expected ->
      StringMap.fold
        (fun _k v acc ->
          if String.equal expected v.base_path && v.phase = Running then acc + 1
          else acc)
        (Atomic.get registry) 0

let record_crash ~base_path name ts msg =
  Log.Keeper.error "registry: recording crash name=%s msg=%s" name msg;
  update_entry ~base_path name (fun e ->
    { e with crash_log =
        List.filteri (fun i _ -> i < max_crash_log_entries)
          ((ts, msg) :: e.crash_log) })

let set_grpc_close ~base_path name close_fn =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> Atomic.set entry.grpc_close close_fn
  | None -> ()

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None

let spawn_slots_available () =
  let max_keepers = Keeper_runtime_resolved.bootstrap_max_active_keepers () in
  max_keepers <= 0
  || Atomic.get running_count_atomic < max_keepers

let wakeup ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  (* tla-lint: allow-mutation: fiber signal — public wakeup API for a single keeper *)
  | Some entry -> Atomic.set entry.fiber_wakeup true
  | None -> ()

let wakeup_all ?base_path () =
  StringMap.iter (fun _k entry ->
    (match base_path with
     | Some expected when not (String.equal expected entry.base_path) -> ()
     (* tla-lint: allow-mutation: fiber signal — bulk wakeup for Running keepers under base_path filter *)
     | _ -> if entry.phase = Running then Atomic.set entry.fiber_wakeup true)
  ) (Atomic.get registry)

let fiber_health_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> Fiber_unknown
  | Some entry -> (
      match entry.phase with
      | Dead | Zombie -> Fiber_dead
      | Crashed | Restarting ->
          let max_restarts =
            Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
          in
          if entry.restart_count >= max_restarts then Fiber_dead else Fiber_zombie
      | Stopped | Offline -> Fiber_unknown
      | Running | Paused | Failing | Overflowed | Compacting | HandingOff | Draining -> (
          match Eio.Promise.peek entry.done_p with
          | None -> Fiber_alive
          | Some `Stopped -> Fiber_unknown
          | Some (`Crashed _) ->
              let max_restarts =
                Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
              in
              if entry.restart_count >= max_restarts
              then Fiber_dead
              else Fiber_zombie))

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []

let restore_supervisor_state ~base_path name ~restart_count ~last_restart_ts
    ~crash_log =
  update_entry ~base_path name (fun e ->
    {
      e with
      restart_count;
      last_restart_ts;
      dead_since_ts = None;
      crash_log;
      last_failure_reason = None;
    })

let get_last_agent_count ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.last_agent_count
  | None -> 0

let set_last_agent_count ~base_path name count =
  update_entry ~base_path name (fun e -> { e with last_agent_count = count })

let board_wakeup_allowed ~base_path name ~post_id ~debounce_sec =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> true
  | Some entry ->
      let now_ts = Time_compat.now () in
      match StringMap.find_opt post_id entry.board_wakeups with
      | Some last_ts when now_ts -. last_ts < debounce_sec -> false
      | _ ->
          update_entry ~base_path name (fun e ->
            { e with board_wakeups = StringMap.add post_id now_ts e.board_wakeups });
          true

let clear_board_wakeups ~base_path name =
  update_entry ~base_path name (fun e -> { e with board_wakeups = StringMap.empty })

let cleanup_tracking ~base_path name =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | Some entry ->
      put_entry key
        { entry with
          board_wakeups = StringMap.empty;
          tool_usage = StringMap.empty;
          last_agent_count = 0;
          board_cursor_ts = 0.0;
          board_cursor_post_id = None;
        }
  | None -> ()

let clear () =
  Atomic.set registry StringMap.empty;
  Atomic.set running_count_atomic 0

(* -- Board cursor -------------------------------------------------- *)

let get_board_cursor_ts ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> entry.board_cursor_ts
  | None -> 0.0

let set_board_cursor_ts ~base_path name ts =
  update_entry ~base_path name (fun e ->
    let board_cursor_post_id =
      if Float.compare ts e.board_cursor_ts = 0 then e.board_cursor_post_id
      else None
    in
    { e with board_cursor_ts = ts; board_cursor_post_id })

let get_board_cursor ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | Some entry -> (entry.board_cursor_ts, entry.board_cursor_post_id)
  | None -> (0.0, None)

let set_board_cursor ~base_path name ts post_id =
  update_entry ~base_path name (fun e ->
    { e with board_cursor_ts = ts; board_cursor_post_id = post_id })

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

let tool_usage_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)

(** Look up a keeper by name across all base_paths (O(n) scan). *)
let find_by_name name =
  StringMap.fold
    (fun _k v acc ->
      match acc with
      | Some _ -> acc
      | None -> if String.equal v.name name then Some v else None)
    (Atomic.get registry) None

let find_by_agent_name agent_name =
  StringMap.fold
    (fun _k v acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if String.equal v.meta.agent_name agent_name then Some v else None)
    (Atomic.get registry) None

let find_by_id (uid : Keeper_id.Uid.t) =
  StringMap.fold
    (fun _k v acc ->
      match acc with
      | Some _ -> acc
      | None ->
        (match v.meta.keeper_id with
         | Some id when Keeper_id.Uid.equal id uid -> Some v
         | _ -> None))
    (Atomic.get registry) None

let tool_usage_of_by_name name =
  match find_by_name name with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)

(* -- Config resolution --------------------------------------------- *)

let resolve_config (config : Coord_utils_backend_setup.config) keeper_name
    : Coord_utils_backend_setup.config =
  if keeper_name = "" then config
  else
    (* Keeper config resolution is scoped to the caller's current base_path.
       Do not retarget requests across other base_path registries. *)
    match get ~base_path:config.base_path keeper_name with
    | Some _ | None -> config

(* -- Tool usage persistence ---------------------------------------- *)

let tool_usage_path ~base_path name =
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers/tool_usage" in
  Filename.concat dir (name ^ ".json")

let flush_tool_usage ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
  | None -> ()
  | Some entry ->
    let items =
      StringMap.fold (fun tool_name (e : tool_call_entry) acc ->
        `Assoc [
          ("tool", `String tool_name);
          ("count", `Int e.count);
          ("successes", `Int e.successes);
          ("failures", `Int e.failures);
          ("last_used_at", `Float e.last_used_at);
        ] :: acc
      ) entry.tool_usage []
    in
    let json = `Assoc [
      ("keeper", `String name);
      ("flushed_at", `Float (Time_compat.now ()));
      ("tools", `List items);
    ] in
    let path = tool_usage_path ~base_path name in
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file path (Yojson.Safe.to_string json ^ "\n")
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "flush_tool_usage %s: %s" name (Printexc.to_string exn))

let restore_tool_usage ~base_path name =
  let path = tool_usage_path ~base_path name in
  if not (Fs_compat.file_exists path) then ()
  else
    match StringMap.find_opt (registry_key ~base_path name) (Atomic.get registry) with
    | None -> ()
    | Some _entry ->
      (try
         let content = Fs_compat.load_file path in
         let json = Yojson.Safe.from_string content in
         let tools = match json with
           | `Assoc fields ->
             (match List.assoc_opt "tools" fields with
              | Some (`List items) -> items
              | _ -> [])
           | _ -> []
         in
         List.iter (fun item ->
           match
             ( Safe_ops.json_string_opt "tool" item,
               Safe_ops.json_int_opt "count" item,
               Safe_ops.json_int_opt "successes" item,
               Safe_ops.json_int_opt "failures" item,
               Safe_ops.json_float_opt "last_used_at" item )
           with
           | Some tool_name, Some count, Some successes, Some failures, Some last_used_at
             when tool_name <> "" ->
             let e = {
               count;
               successes;
               failures;
               last_used_at;
             } in
             update_entry ~base_path name (fun ent ->
               { ent with tool_usage = StringMap.add tool_name e ent.tool_usage })
           | _ -> ()
         ) tools
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn "restore_tool_usage %s: %s" name (Printexc.to_string exn))

(* ── RFC-0002 Event Dispatch ───────────────────────────── *)

let execute_entry_action_observability
    ~(name : string)
    ~(phase : Keeper_state_machine.phase)
    ~(ts_unix : float)
    (action : Keeper_state_machine.entry_action) : unit =
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
  | Cancel_pending_oas ->
      ()

let followup_event_of_entry_action
    ~(phase : Keeper_state_machine.phase)
    (action : Keeper_state_machine.entry_action)
  : Keeper_state_machine.event option =
  match phase, action with
  | Keeper_state_machine.Overflowed, Start_compaction ->
      Prometheus.inc_counter Prometheus.metric_keeper_fsm_edge_transitions
        ~labels:[("edge", "ksm_to_kmc_compact_trigger")] ();
      Some Keeper_state_machine.Auto_compact_triggered
  | _ ->
      None

let record_followup_dispatch_rejection event =
  Prometheus.inc_counter
    Prometheus.metric_keeper_lifecycle_dispatch_rejections
    ~labels:[ ("event", Keeper_state_machine.event_to_string event) ]
    ()

let pending_measurement_after_event now entry event =
  match event with
  | Keeper_state_machine.Context_measured { auto_rules; _ } ->
    Some {
      tm_captured_at = now;
      tm_auto_rules = auto_rules;
    }
  | _ -> entry.pending_turn_measurement

let compaction_stage_after_event entry event =
  match event with
  | Keeper_state_machine.Compaction_started
  | Keeper_state_machine.Auto_compact_triggered
  | Keeper_state_machine.Operator_compact_requested ->
    Compaction_compacting
  | Keeper_state_machine.Compaction_completed _ -> Compaction_done
  | Keeper_state_machine.Compaction_failed _ -> Compaction_accumulating
  | _ -> entry.compaction_stage

(** Registry mutation is still non-yielding (StringMap lookup + put,
    Atomic.set). Entry actions run only after [put_entry], so any
    observability or follow-up state transitions happen after the registry
    state is consistent. *)
let rec dispatch_event_with_audit
    ~base_path
    ?snapshot
    ?events_fired
    ?selected_event
    name
    (event : Keeper_state_machine.event)
  =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key (Atomic.get registry) with
  | None ->
    Error (Keeper_state_machine.Invalid_transition {
      from_phase = Keeper_state_machine.Offline;
      to_phase = Keeper_state_machine.Offline;
      reason = Printf.sprintf "keeper %s not registered" name;
    })
  | Some entry ->
    let now = Time_compat.now () in
    (* Retain the last auto-rule summary emitted with a [Context_measured]
       event so downstream read-only observers (RFC-0003 composite
       observer) can project it without reading history files. Other
       events leave the field untouched. *)
    let last_auto_rules =
      match event with
      | Keeper_state_machine.Context_measured { auto_rules; _ } ->
        Some (now, auto_rules)
      | _ -> entry.last_auto_rules
    in
    let pending_turn_measurement =
      pending_measurement_after_event now entry event
    in
    let compaction_stage =
      compaction_stage_after_event entry event
    in
    let result =
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
       Log.Keeper.info "registry: phase transition name=%s old=%s new=%s event=%s"
         name
         (Keeper_state_machine.phase_to_string tr.prev_phase)
         (Keeper_state_machine.phase_to_string tr.new_phase)
         (Keeper_state_machine.event_to_string event);
       (* Record transition in audit ring buffer for dashboard API *)
       Keeper_transition_audit.record_transition ~keeper_name:name {
         snapshot;
         events_fired = Option.value events_fired ~default:[event];
         selected_event = Option.value selected_event ~default:event;
         prev_phase = tr.prev_phase;
         new_phase = tr.new_phase;
         transition_outcome = "applied";
         wall_clock_at_decision = now;
       };
       (* Broadcast phase transition to SSE subscribers *)
       (try
          Sse.broadcast
            (`Assoc [
               "type", `String "keeper_phase_changed";
               "name", `String name;
               "prev_phase", `String (Keeper_state_machine.phase_to_string tr.prev_phase);
               "new_phase", `String (Keeper_state_machine.phase_to_string tr.new_phase);
               "event", `String (Keeper_state_machine.event_to_string event);
               "ts_unix", `Float now;
             ])
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _exn -> ());
       (* Update running count based on phase transition *)
       (match tr.prev_phase, tr.new_phase with
        | Running, phase when phase <> Running ->
          decr_running_count_clamped ()
        | phase, Running when phase <> Running ->
          Atomic.incr running_count_atomic
        | _ -> ());
       Prometheus.inc_counter Prometheus.metric_keeper_lifecycle_transitions
         ~labels:[
           ("keeper", name);
           ("from_phase", Keeper_state_machine.phase_to_string tr.prev_phase);
           ("to_phase", Keeper_state_machine.phase_to_string tr.new_phase);
         ] ();
       (* Update dead_since_ts: always set to now on Dead transition *)
       let dead_since_ts = match tr.new_phase with
         | Keeper_state_machine.Dead -> Some now
         | _ -> None
       in
       let new_seq = entry.transition_seq + 1 in
       (* TLA+ trace emission (MASC_TLA_TRACE=1) *)
       if Keeper_trace_emit.enabled () then
         Keeper_trace_emit.emit_transition
           ~keeper_name:name ~base_path
           ~seq:new_seq ~event
           ~prev_phase:tr.prev_phase ~new_phase:tr.new_phase
           ~conditions_after:tr.updated_conditions
           ~restart_count:entry.restart_count;
       put_entry key {
         entry with
         phase = tr.new_phase;
         conditions = tr.updated_conditions;
         dead_since_ts;
         transition_seq = new_seq;
         last_auto_rules;
         pending_turn_measurement;
         compaction_stage;
       };
       List.iter
         (execute_entry_action_observability
            ~name
            ~phase:tr.new_phase
            ~ts_unix:now)
         tr.entry_actions;
       List.iter
         (fun followup_event ->
            match dispatch_event_with_audit ~base_path name followup_event with
            | Ok _ -> ()
            | Error (Keeper_state_machine.Invalid_transition { from_phase; to_phase; reason }) ->
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
                  attempted_event)
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
       if Keeper_trace_emit.enabled () then
         Keeper_trace_emit.emit_transition
           ~keeper_name:name ~base_path
           ~seq:new_seq ~event
           ~prev_phase:tr.prev_phase ~new_phase:tr.new_phase
           ~conditions_after:tr.updated_conditions
           ~restart_count:entry.restart_count;
       put_entry key {
         entry with
         conditions = tr.updated_conditions;
         transition_seq = new_seq;
         last_auto_rules;
         pending_turn_measurement;
         compaction_stage;
       };
       broadcast_composite_changed ~name ~ts_unix:now;
       Ok tr
     | Error e ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_lifecycle_dispatch_rejections
         ~labels:[("event", Keeper_state_machine.event_to_string event)]
         ();
       Log.Keeper.warn "registry: dispatch_event rejected name=%s error=%s"
         name (Keeper_state_machine.transition_error_to_string e);
       Error e)

let dispatch_event ~base_path name event =
  dispatch_event_with_audit ~base_path name event

let dispatch_event_and_log ~base_path name event =
  match dispatch_event ~base_path name event with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
    in
    Prometheus.inc_counter
      Prometheus.metric_keeper_dispatch_event_failures
      ~labels:[("keeper", name); ("reason", reason_label)]
      ();
    Error e

let dispatch_event_unit ~base_path name event =
  match dispatch_event_and_log ~base_path name event with
  | Ok _ -> ()
  | Error e ->
    Log.Keeper.warn "%s: dispatch_event failed: %s" name
      (Keeper_state_machine.transition_error_to_string e)
let dispatch_event_with_audit_and_log ~base_path ?snapshot ?events_fired ?selected_event name event =
  match dispatch_event_with_audit ~base_path ?snapshot ?events_fired ?selected_event name event with
  | Ok tr -> Ok tr
  | Error e ->
    let reason_label =
      match e with
      | Keeper_state_machine.Terminal_state _ -> "terminal_state"
      | Keeper_state_machine.Invalid_transition _ -> "invalid_transition"
    in
    Prometheus.inc_counter
      Prometheus.metric_keeper_dispatch_event_failures
      ~labels:[("keeper", name); ("reason", reason_label)]
      ();
    Error e

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
         "registry: prepare_fiber_launch name=%s base_path=%s: entry not registered, skipping flag reset"
         name base_path);
  dispatch_event ~base_path name Keeper_state_machine.Fiber_started

let get_phase ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.phase
  | None -> None

let get_conditions ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.conditions
  | None -> None

let enqueue_event ~base_path name stimulus =
  match get ~base_path name with
  | None ->
      Log.Keeper.warn
        "registry: enqueue_event name=%s base_path=%s: keeper not registered"
        name base_path
  | Some entry ->
      let rec loop () =
        let cur = Atomic.get entry.event_queue in
        let next = Keeper_event_queue.enqueue cur stimulus in
        if not (Atomic.compare_and_set entry.event_queue cur next) then loop ()
      in
      loop ()

let event_queue_snapshot ~base_path name =
  match get ~base_path name with
  | None -> Keeper_event_queue.empty
  | Some entry -> Atomic.get entry.event_queue

let dequeue_event ~base_path name =
  match get ~base_path name with
  | None -> None
  | Some entry ->
      let rec loop () =
        let cur = Atomic.get entry.event_queue in
        match Keeper_event_queue.dequeue cur with
        | None -> None
        | Some (stim, rest) ->
            if Atomic.compare_and_set entry.event_queue cur rest
            then Some stim
            else loop ()
      in
      loop ()
