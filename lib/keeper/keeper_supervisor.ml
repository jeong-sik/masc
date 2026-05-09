(** Keeper_supervisor — keeper keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. Uses [Keeper_registry] as
    the single source of truth for keeper state. The Promise-based
    liveness tracking ([done_p]/[done_r]) lives in registry entries.

    This is not the OAS [Agent.run] lifecycle; it sits outside the turn
    loop and only manages keepalive liveness/restart policy.

    @since 2.102.0 *)

open Keeper_types
open Keeper_execution

module StringMap = Map.Make (String)

(* ── Pure helpers ────────────────────────────────────────── *)

let backoff_delay attempt =
  let base = Env_config.KeeperSupervisor.backoff_base_s in
  let max_delay = Env_config.KeeperSupervisor.backoff_max_s in
  Float.min max_delay (base *. Float.of_int (1 lsl (min attempt 20)))

let keep_last_n n item lst =
  let full = item :: lst in
  if List.length full <= n then full
  else List.filteri (fun i _ -> i < n) full

let supervision_cohort_size = 8

type supervision_cohort = {
  cohort_id : int;
  keepers : Keeper_registry.registry_entry list;
}

let supervision_cohorts ?(cohort_size = supervision_cohort_size)
    (entries : Keeper_registry.registry_entry list) =
  let cohort_size = max 1 cohort_size in
  let sorted =
    List.sort
      (fun (a : Keeper_registry.registry_entry)
           (b : Keeper_registry.registry_entry) ->
        String.compare a.name b.name)
      entries
  in
  let rec take n acc rest =
    match n, rest with
    | 0, rest -> (List.rev acc, rest)
    | _, [] -> (List.rev acc, [])
    | n, entry :: rest -> take (n - 1) (entry :: acc) rest
  in
  let rec loop cohort_id acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
        let keepers, rest = take cohort_size [] remaining in
        loop (cohort_id + 1) ({ cohort_id; keepers } :: acc) rest
  in
  loop 0 [] sorted

let fresh_supervision_cohort_keepers ~base_path
    (cohort : supervision_cohort) =
  List.filter_map
    (fun (entry : Keeper_registry.registry_entry) ->
      Keeper_registry.get ~base_path entry.name)
    cohort.keepers

let iter_supervision_cohorts ?(yield_between = Eio_guard.fair_yield)
    cohorts ~f =
  let rec loop = function
    | [] -> ()
    | [ cohort ] -> f cohort
    | cohort :: rest ->
        f cohort;
        yield_between ();
        loop rest
  in
  loop cohorts

let should_cleanup_dead ~now ~dead_ttl_sec
    (entry : Keeper_registry.registry_entry) =
  match entry.phase, entry.dead_since_ts with
  | Keeper_state_machine.Dead, Some dead_since ->
      now -. dead_since >= dead_ttl_sec
  (* Dead but no [dead_since_ts] yet — first observation will set it. *)
  | Keeper_state_machine.Dead, None -> false
  (* Non-Dead phases never trigger Dead cleanup, regardless of timestamp. *)
  | (Keeper_state_machine.Offline
    | Keeper_state_machine.Running
    | Keeper_state_machine.Failing
    | Keeper_state_machine.Overflowed
    | Keeper_state_machine.Compacting
    | Keeper_state_machine.HandingOff
    | Keeper_state_machine.Draining
    | Keeper_state_machine.Paused
    | Keeper_state_machine.Stopped
    | Keeper_state_machine.Crashed
    | Keeper_state_machine.Restarting
    | Keeper_state_machine.Zombie), _ -> false

(** Check if a paused keeper meta file on disk is stale enough to remove. *)
let is_stale_paused_meta ~now ~paused_ttl_sec (meta : keeper_meta) =
  if not meta.paused then false
  else
    let updated_ts =
      Coord_resilience.Time.parse_iso8601_opt meta.updated_at
      |> Option.value ~default:0.0
    in
    updated_ts > 0.0 && now -. updated_ts >= paused_ttl_sec

let paused_meta_requires_reconcile_recovery (meta : keeper_meta) =
  meta.paused
  && (match meta.runtime.last_blocker with
      | Some info -> blocker_class_continue_gate info.klass
      | None -> false)

let committed_tools_of_ambiguous_blocker (blocker : string) =
  let trimmed = String.trim blocker in
  match Cascade_error_classify.classify_masc_internal_error_of_string trimmed with
  | Some (Cascade_error_classify.Ambiguous_post_commit { tools; _ }) -> tools
  | _ ->
    (* Legacy: extract from bracket notation "prefix: [tool1, tool2]; ..." *)
    match String.index_opt trimmed '[' with
    | None -> []
    | Some open_idx -> (
        match String.index_from_opt trimmed (open_idx + 1) ']' with
        | Some close_idx when close_idx > open_idx + 1 ->
            String.sub trimmed (open_idx + 1) (close_idx - open_idx - 1)
            |> String.split_on_char ','
            |> List.map String.trim
            |> List.filter (fun tool -> tool <> "")
      | _ -> [])

(* ── Event publishing ────────────────────────────────────── *)

(* #8856 / #8605 family: single helper takes the unified
   [Keeper_lifecycle_events.lifecycle_event] variant. The legacy
   [publish_lifecycle ?phase event_name] (string event_name) and
   [publish_phase_lifecycle ~phase] are folded into [publish_lifecycle
   ~event] -- the compiler now enforces that every call site picks
   either Custom_event (with optional phase context) or Phase_event,
   eliminating the [~phase:Stopped ~event:"crashed"] typo class
   originally addressed at runtime by #8572 / #8575. *)
let publish_lifecycle
    ~(event : Keeper_lifecycle_events.lifecycle_event) keeper_name detail () =
  let event_name = Keeper_lifecycle_events.lifecycle_event_to_string event in
  let phase =
    Option.map Keeper_state_machine.phase_to_string
      (Keeper_lifecycle_events.lifecycle_event_phase event)
  in
  (* #12798: record in the per-keeper lifecycle audit ring for dashboard. *)
  Keeper_lifecycle_audit.record ~keeper_name ~event_name ~phase ~detail;
  match Keeper_keepalive.get_bus () with
  | Some bus ->
      Cascade_events.publish_keeper_lifecycle bus ~event ~keeper_name ~detail ()
  | None -> ()

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_phase_lifecycle ~phase keeper_name detail () =
  publish_lifecycle ~event:(Keeper_lifecycle_events.Phase_event phase)
    keeper_name detail ()

(* ── Stale-turn watchdog (delegated to Keeper_stale_watchdog) ── *)

let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog

(* ── Supervised fiber launch ─────────────────────────────── *)

type restart_launch_noop_state = {
  enabled : bool;
  scope_depth : int;
  scope_previous : bool;
}

let restart_launch_noop_for_test =
  Atomic.make { enabled = false; scope_depth = 0; scope_previous = false }

let update_restart_launch_noop_state f =
  let rec loop () =
    let current = Atomic.get restart_launch_noop_for_test in
    let next = f current in
    if not (Atomic.compare_and_set restart_launch_noop_for_test current next) then
      loop ()
  in
  loop ()

let set_restart_launch_noop_for_test enabled =
  update_restart_launch_noop_state (fun state -> { state with enabled })

let restart_launch_noop_enabled_for_test () =
  (Atomic.get restart_launch_noop_for_test).enabled

let with_restart_launch_noop_for_test f =
  let enter () =
    update_restart_launch_noop_state (fun state ->
        if state.scope_depth = 0 then
          {
            enabled = true;
            scope_depth = 1;
            scope_previous = state.enabled;
          }
        else { state with enabled = true; scope_depth = state.scope_depth + 1 })
  in
  let leave () =
    update_restart_launch_noop_state (fun state ->
        if state.scope_depth <= 1 then
          {
            enabled = state.scope_previous;
            scope_depth = 0;
            scope_previous = false;
          }
        else { state with scope_depth = state.scope_depth - 1 })
  in
  enter ();
  Eio_guard.protect
    ~finally:leave
    f

let launch_supervised_fiber ~proactive_warmup_sec ctx (meta : keeper_meta)
    (reg : Keeper_registry.registry_entry) =
  let base_path = ctx.config.base_path in
  let keepers_dir =
    Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
  (match Keeper_registry.prepare_fiber_launch ~base_path meta.name with
   | Ok _ -> ()
   | Error err ->
       Log.Keeper.warn
         "%s: Fiber_started rejected during supervised launch: %s"
         meta.name
         (Keeper_state_machine.transition_error_to_string err);
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_supervisor_cleanup_failures
         ~labels:[("keeper", meta.name); ("site", "fiber_start_rejected")]
         ());
  if restart_launch_noop_enabled_for_test () then ()
  else begin
  fork_stale_watchdog ctx meta reg;
  (* Task 137: Inject bootstrap signal to ensure at least one warm-up turn runs
     and break the initial proactive deadlock. *)
  let bootstrap_signal : Keeper_event_queue.stimulus = {
    post_id = "bootstrap";
    urgency = Keeper_event_queue.Normal;
    arrived_at = Unix.gettimeofday ();
    payload = "Keeper bootstrap signal";
  } in
  Keeper_registry.enqueue_event ~base_path meta.name bootstrap_signal;
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let resolved = ref false in
    let resolve_done value =
      if not !resolved && Keeper_registry.try_resolve_done reg value then begin
        resolved := true;
        true
      end else
        false
    in
    Eio_guard.protect
      (fun () ->
        (try
           Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
             ctx meta reg.fiber_stop ~wakeup:reg.fiber_wakeup;
           (* Check if watchdog set a failure reason that should trigger
              crash recovery instead of a clean stop. When the stale
              watchdog sets fiber_stop + Stale_turn_timeout, the heartbeat
              loop exits normally but the supervisor must treat this as a
              crash so sweep_and_recover restarts the keeper.
              #10765 Phase 2: [Stale_termination_storm] and
              [Stale_fleet_batch] also funnel through the crash path, but
              [sweep_and_recover]'s [`Crashed] branch detects these variants
              and routes to auto-pause instead of [to_restart], breaking the
              restart-loop-back-to-stale cycle. *)
           let watchdog_triggered =
             match Keeper_registry.get ~base_path meta.name with
             | Some e -> (
                 match e.last_failure_reason with
                 | Some (Keeper_registry.Stale_turn_timeout _)
                 | Some (Keeper_registry.Stale_termination_storm _)
                 | Some (Keeper_registry.Stale_fleet_batch _)
                 | Some (Keeper_registry.Oas_timeout_budget_loop _) -> true
                 (* Other failure reasons are not stale-watchdog signals. *)
                 | Some (Keeper_registry.Heartbeat_consecutive_failures _)
                 | Some (Keeper_registry.Turn_consecutive_failures _)
                 | Some (Keeper_registry.Provider_runtime_error _)
                 | Some (Keeper_registry.Tool_required_unsatisfied _)
                 | Some (Keeper_registry.Ambiguous_partial_commit _)
                 | Some Keeper_registry.Fiber_unresolved
                 | Some (Keeper_registry.Exception _)
                 | None -> false)
             | None -> false
           in
           if watchdog_triggered then begin
             let reason =
               match Keeper_registry.get ~base_path meta.name with
               | Some e ->
                   Option.map Keeper_registry.failure_reason_to_string
                     e.last_failure_reason
                   |> Option.value ~default:"stale_turn_timeout"
               | None -> "stale_turn_timeout"
             in
             (match Keeper_registry.dispatch_event ~base_path meta.name
                (Keeper_state_machine.Fiber_terminated { outcome = reason }) with
              | Ok _ -> ()
              | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[("keeper", meta.name); ("event", "fiber_terminated")]
                    ();
                  Log.Keeper.warn "supervisor: Fiber_terminated dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
             if resolve_done (`Crashed reason) then
               publish_phase_lifecycle ~phase:Keeper_state_machine.Crashed
                 meta.name reason ()
           end else begin
             (* Normal exit: stop flag was set — dispatch typed events *)
             (match Keeper_registry.dispatch_event ~base_path meta.name
                Keeper_state_machine.Stop_requested with
              | Ok _ -> ()
              | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[("keeper", meta.name); ("event", "stop_requested")]
                    ();
                  Log.Keeper.warn "supervisor: Stop_requested dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
             (match Keeper_registry.dispatch_event ~base_path meta.name
                Keeper_state_machine.Drain_complete with
              | Ok _ -> ()
              | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[("keeper", meta.name); ("event", "drain_complete")]
                    ();
                  Log.Keeper.warn "supervisor: Drain_complete dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
             if resolve_done `Stopped then
               publish_phase_lifecycle ~phase:Keeper_state_machine.Stopped
                 meta.name "normal exit" ()
           end
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* RFC-0002: unified crash handler.
                Keeper_fiber_crash carries no payload — failure_reason is
                pre-stored in registry by the raise site.
                For unexpected exceptions, wrap in Exception variant. *)
             let fr = match exn with
               | Keeper_registry.Keeper_fiber_crash ->
                 (match Keeper_registry.get ~base_path meta.name with
                  | Some e ->
                    Option.value
                      ~default:(Keeper_registry.Exception "fiber_crash")
                      e.last_failure_reason
                  | None ->
                    Keeper_registry.Exception "fiber_crash (unregistered)")
               | _ -> Keeper_registry.Exception (Printexc.to_string exn)
             in
             let reason = Keeper_registry.failure_reason_to_string fr in
             Keeper_registry.set_failure_reason ~base_path meta.name (Some fr);
             (match Keeper_registry.dispatch_event ~base_path meta.name
                (Keeper_state_machine.Fiber_terminated { outcome = reason }) with
              | Ok _ -> ()
              | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[("keeper", meta.name); ("event", "fiber_terminated")]
                    ();
                  Log.Keeper.warn "supervisor: Fiber_terminated dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
             let ts = Time_compat.now () in
             Keeper_registry.record_crash ~base_path
               meta.name ts reason;
             let rc = match Keeper_registry.get ~base_path meta.name with
               | Some e -> e.restart_count | None -> 0 in
             Keeper_crash_persistence.enqueue_record ~keepers_dir
               ~name:meta.name ~ts ~reason ~restart_count:rc;
             Keeper_registry.record_error ~base_path meta.name reason;
             if resolve_done (`Crashed reason) then
               publish_phase_lifecycle ~phase:Keeper_state_machine.Crashed
                 meta.name reason ()))
      ~finally:(fun () ->
        (* Finally runs best-effort. Any exception raised here (including
           Eio.Cancel.Cancelled, which propagates during concurrent fiber
           teardown) would be re-wrapped by [Fun.protect] as
           [Fun.Finally_raised], masking the original body exception and
           crashing the server (see masc-mcp crash 2026-04-17). Swallow
           everything and log — cleanup is advisory, state-machine events
           already fired on the body's happy/error paths. *)
        try
          Keeper_registry.cleanup_tracking ~base_path meta.name;
          (* #14187 follow-up: a keeper that crashed after exhausting its
             turn-livelock budget would restart into the same turn_id
             (because blocked turns do not increment total_turns).  The
             in-memory livelock state then immediately re-blocked the
             fresh restart, making recovery impossible.  Clear the
             per-keeper livelock bookkeeping during cleanup so the next
             restart starts with a fresh counter. *)
          Keeper_turn_livelock.reset_keeper_livelock ~keeper:meta.name;
          if not !resolved then begin
            if Shutdown.is_shutting_down_global () then begin
              Log.Keeper.warn "%s: fiber unresolved during shutdown (not a crash)" meta.name;
              Keeper_registry.mark_dead ~base_path meta.name
                ~at:(Time_compat.now ());
              ignore (resolve_done (`Crashed "shutdown"))
            end else begin
              let reason =
                Keeper_registry.failure_reason_to_string
                  Keeper_registry.Fiber_unresolved in
              Keeper_registry.set_failure_reason ~base_path meta.name
                (Some Keeper_registry.Fiber_unresolved);
              (* 2026-05-05 fleet-stuck cycle: keeper meta runtime
                 [last_blocker] stayed null for 5+ hours while supervisor
                 self-preservation suppressed restarts under
                 [cohort=fiber_unresolved].  The diagnosis was buried in the
                 crash registry but invisible on the per-keeper meta surface
                 dashboards read.  Stamp the same cohort onto runtime so
                 operators (and the dashboard "차단된 키퍼" card) see why a
                 keeper is silent.  Best-effort: write_meta failure does not
                 abort cleanup, mirroring [handle_crash_auto_pause]. *)
              (match Keeper_registry.get ~base_path meta.name with
               | Some entry ->
                 let stamped_meta =
                   { entry.meta with
                     runtime =
                       { entry.meta.runtime with
                         last_blocker =
                           Some (blocker_info_of_class
                                   ~detail:"fiber_unresolved" Fiber_unresolved);
                       };
                   }
                 in
                 (match
                    write_meta_with_merge
                      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                      ctx.config stamped_meta
                  with
                  | Ok () -> ()
                  | Error err ->
                    Prometheus.inc_counter
                      Keeper_metrics.metric_keeper_write_meta_failures
                      ~labels:[("keeper", meta.name); ("phase", "fiber_unresolved_stamp")]
                      ();
                    Log.Keeper.warn
                      "%s: fiber_unresolved meta stamp failed: %s"
                      meta.name err)
               | None -> ());
              let ts = Time_compat.now () in
              Keeper_registry.record_crash ~base_path
                meta.name ts reason;
              let rc = match Keeper_registry.get ~base_path meta.name with
                | Some e -> e.restart_count | None -> 0 in
              Keeper_crash_persistence.enqueue_record ~keepers_dir
                ~name:meta.name ~ts ~reason ~restart_count:rc;
              Keeper_registry.record_error ~base_path meta.name reason;
              Keeper_registry.dispatch_event_unit ~base_path meta.name
                (Keeper_state_machine.Fiber_terminated { outcome = reason });
              if resolve_done (`Crashed reason) then
                publish_phase_lifecycle ~phase:Keeper_state_machine.Crashed
                  meta.name reason ()
            end
          end
        with
        | Eio.Cancel.Cancelled _ ->
          (* Swallow cleanup cancellation without incrementing the cleanup
             failure counter. Re-raising Cancelled here is what the docstring
             above warns against: [Fun.protect] would wrap it as
             [Fun.Finally_raised], masking the body exception and crashing
             the supervisor. See 2026-05-05 cycle9 incident: 5+ FATALs/day
             traced to a re-raise at this exact site (commit bb10b80ee4
             leftover from #12910 revert). *)
          Log.Keeper.debug
            "%s: supervisor finally cleanup cancelled (suppressed to avoid Fun.Finally_raised)"
            meta.name
        | exn ->
          (* Swallow non-cancellation cleanup failures too. Cleanup is
             advisory; re-raising here would still become [Fun.Finally_raised]
             and could mask the body outcome. Count only these unexpected
             cleanup exceptions so the metric remains actionable. *)
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_supervisor_cleanup_failures
            ~labels:[("keeper", meta.name)]
            ();
          Log.Keeper.warn
            "%s: supervisor finally cleanup failed (suppressed to avoid Fun.Finally_raised): %s"
            meta.name (Printexc.to_string exn)))
  end

(* #10993: persona drift visibility.

   [Keeper_identity.normalize_all_names ~check_persona:true] runs on
   every dispatch via [Tool_inline_dispatch_coord] (RFC P3-a
   logging-only mode), but its [Persona_not_found] branch emits a
   Log.Misc.warn that is hard to triage:

   - WARN level (alert ROC blends with normal degradation noise).
   - Per-event (24h sample: 11 events × 5 keepers vs the underlying
     truth of 9 keepers permanently mis-configured), so operators can
     not tell whether the gap is widening or stable.
   - Lacks the per-keeper startup snapshot that would let an operator
     run a quick \[ls personas/\] and reconcile.

   Surface the gap once at supervise_keepalive entry — the code path
   that actually puts the keeper into the registry. Behaviour is
   unchanged (still proceeds with fallback) so the boot path stays
   compatible with the current 9-missing-personas fleet; the value is
   in turning a silent runtime drift into a single ERROR per keeper
   per supervisor restart.

   The visibility ERROR is bounded by fleet size (~14 keepers) and
   only fires on first registration — the [is_registered] guard above
   skips repeat calls. *)
let log_persona_drift_if_missing ~base_path (meta : keeper_meta) =
  match
    Keeper_identity.normalize_all_names
      ~input_agent_name:meta.name
      ~base_path
      ~check_persona:true
      ~check_credential:false
      ()
  with
  | Ok _ -> ()
  | Error (Keeper_identity.Persona_not_found { resolved; searched; _ }) ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_persona_drift_missing
        ~labels:[("keeper", meta.name)]
        ();
      Log.Keeper.error
        "[#10993][persona_drift] keeper=%s resolved=%s persona file missing at %s \
         — runtime falls through to logging-only RFC P3-a path; \
         operator action: create persona file or remove keeper from registry"
        meta.name resolved searched
  | Error _ ->
      (* Other validation errors (Empty_input, Credential_missing — but
         we passed check_credential:false) are not the silent-drift
         class this hook is documenting. Stay silent to avoid noise. *)
      ()

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path meta.name
  then ()
  else if not (Keeper_registry.spawn_slots_available ()) then ()
  else begin
    log_persona_drift_if_missing ~base_path:ctx.config.base_path meta;
    (* Register in Keeper_registry — single source of truth. *)
    let reg =
      Keeper_registry.register_offline ~base_path:ctx.config.base_path meta.name meta
    in
    (* Coord initialization *)
    (try
       if not (Coord_utils.is_initialized ctx.config) then
         let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in ()
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_room_init_failures
         ~labels:[("keeper", meta.name)]
         ();
       Log.Keeper.error "supervisor room init failed: %s"
         (Printexc.to_string exn));
    let live_meta =
      try
        let synced = ensure_keeper_room_presence ctx.config meta in
        (match write_meta ctx.config synced with
         | Ok () -> ()
         | Error msg ->
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_write_meta_failures
             ~labels:[("keeper", meta.name); ("phase", "presence_sync")]
             ();
           Log.Keeper.warn
             "supervisor presence sync: write_meta failed for %s: %s"
             meta.name msg);
        synced
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_presence_sync_failures
          ~labels:[("keeper", meta.name)]
          ();
        Log.Keeper.error "supervisor presence sync failed: %s"
          (Printexc.to_string exn);
        meta
    in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path meta.name
      live_meta;
    launch_supervised_fiber ~proactive_warmup_sec ctx live_meta reg;
    publish_lifecycle
      ~event:(Keeper_lifecycle_events.Custom_event
                { verb = Keeper_lifecycle_events.Started;
                  phase = Some Keeper_state_machine.Running })
      meta.name "supervised" ()
  end

let resume_keeper_after_reconcile_gate (ctx : _ context) (meta : keeper_meta) =
  let latest_meta =
    match read_meta ctx.config meta.name with
    | Ok (Some latest) -> latest
    | _ -> meta
  in
  let resumed_meta =
    {
      latest_meta with
      paused = false;
      updated_at = now_iso ();
      runtime =
        {
          latest_meta.runtime with
          last_blocker = None;
        };
    }
  in
  (* #9733: same race shape as keeper_msg/overflow-pause/sync paths
     already migrated by #10135 / #10145.  The supervisor reconcile
     fiber clears [paused] and [runtime.last_blocker] (cycle-owned
     fields); a heartbeat fiber bumping [joined_room_ids] /
     [last_seen_seq_by_room] in parallel can still steal the CAS
     write and silently leave the keeper paused while
     [Keeper_registry.update_meta] applies the resume in-memory —
     a registry/disk split that hides the failure. *)
  (match
     write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       ctx.config resumed_meta
   with
   | Ok () -> ()
   | Error err when is_version_conflict_error err ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_write_meta_failures
         ~labels:[("keeper", resumed_meta.name); ("phase", "reconcile_resume_cas_race")]
         ();
       Log.Keeper.warn
         "%s: reconcile gate resume write_meta lost CAS race after retries: %s"
         resumed_meta.name err
   | Error err ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_write_meta_failures
         ~labels:[("keeper", resumed_meta.name); ("phase", "reconcile_resume")]
         ();
       Log.Keeper.error
         "%s: reconcile gate resume write_meta failed: %s"
         resumed_meta.name err);
  Keeper_registry.update_meta ~base_path:ctx.config.base_path resumed_meta.name
    resumed_meta;
  Keeper_registry.set_failure_reason ~base_path:ctx.config.base_path
    resumed_meta.name None;
  Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path
    resumed_meta.name;
  Keeper_registry.dispatch_event_unit ~base_path:ctx.config.base_path
    resumed_meta.name Keeper_state_machine.Operator_resume;
  match Keeper_registry.get ~base_path:ctx.config.base_path resumed_meta.name with
  | Some entry when Option.is_none (Eio.Promise.peek entry.done_p) ->
      (* tla-lint: allow-mutation: fiber signal — wake the keeper after operator resume *)
      Atomic.set entry.fiber_wakeup true
  | Some _ ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path
        resumed_meta.name;
      supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
  | None -> supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta

let restore_reconcile_continue_gate (ctx : _ context) (meta : keeper_meta) =
  let blocker_detail, blocker_klass =
    match meta.runtime.last_blocker with
    | Some info -> String.trim info.detail, Some info.klass
    | None -> "", None
  in
  let committed_tools = committed_tools_of_ambiguous_blocker blocker_detail in
  let failure_reason =
    match blocker_klass with
    | Some Ambiguous_post_commit_timeout ->
        "ambiguous_partial_commit(post_commit_timeout)"
    | Some Ambiguous_post_commit_failure ->
        "ambiguous_partial_commit(post_commit_failure)"
    | Some _ | None ->
        "ambiguous_partial_commit(post_commit_failure)"
  in
  let blocker = blocker_detail in
  let input =
    `Assoc
      [
        ("kind", `String "reconcile_required");
        ("keeper_name", `String meta.name);
        ("failure_reason", `String failure_reason);
        ("error_detail", `String blocker);
        ("committed_tools", `List (List.map (fun tool -> `String tool) committed_tools));
      ]
  in
  let _approval_id =
    Keeper_approval_queue.submit_pending
      ~keeper_name:meta.name
      ~tool_name:"keeper_continue_after_reconcile"
      ~input
      ~risk_level:Keeper_approval_queue.Critical
      ~base_path:ctx.config.base_path
      ~on_resolution:(fun decision ->
        match decision with
        | Agent_sdk.Hooks.Approve
        | Agent_sdk.Hooks.Edit _ ->
            resume_keeper_after_reconcile_gate ctx meta;
            Log.Keeper.info
              "%s: restored reconcile continue gate approved; keeper resumed"
              meta.name
        | Agent_sdk.Hooks.Reject reason ->
            Log.Keeper.warn
              "%s: restored reconcile continue gate rejected; keeper remains paused (%s)"
              meta.name reason;
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_supervisor_cleanup_failures
              ~labels:[("keeper", meta.name); ("site", "reconcile_gate_rejected")]
              ())
      ()
  in
  Log.Keeper.warn
    "%s: restored reconcile continue gate from persisted paused meta"
    meta.name

(* ── Sweep and recover ───────────────────────────────────── *)

(** Reconcile only orphaned or cleanly stopped durable keepers.
    Running/Paused/Crashed/Dead entries are actively managed by sweep
    and must NOT be re-launched by reconcile. Stopped entries with
    unresolved fibers (done_p = None) are also skipped — sweep will
    handle them once the fiber terminates. *)
let reconcile_keepalive_keepers (ctx : _ context) =
  let base_path = ctx.config.base_path in
  let names = Keeper_types.keepalive_keeper_names ctx.config in
  Log.Keeper.debug "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  let reconcile_ym = Eio_guard.create_yield_meter () in
  List.iter (fun name ->
         (match read_meta ctx.config name with
         | Ok (Some meta) when not meta.paused ->
             let dominated_by_sweep =
               match Keeper_registry.get ~base_path meta.name with
               | None -> false  (* no entry = orphaned, reconcile OK *)
               | Some e ->
                 match e.phase with
                 | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
                 | Keeper_state_machine.Crashed | Keeper_state_machine.Dead
                 | Keeper_state_machine.Zombie -> true
                 | Keeper_state_machine.Failing | Keeper_state_machine.Overflowed
                 | Keeper_state_machine.Compacting
                 | Keeper_state_machine.HandingOff | Keeper_state_machine.Draining
                 | Keeper_state_machine.Restarting -> true
                 | Keeper_state_machine.Offline -> false
                 | Keeper_state_machine.Stopped ->
                     (* Stopped with unresolved fiber → sweep will clean up *)
                     Eio.Promise.peek e.done_p = None
             in
             if not dominated_by_sweep then begin
               supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
               if Keeper_registry.is_running ~base_path meta.name then begin
                 publish_lifecycle
                   ~event:(Keeper_lifecycle_events.Custom_event
                             { verb = Keeper_lifecycle_events.Reconciled;
                               phase = Some Keeper_state_machine.Running })
                   meta.name "durable keeper" ();
                 Log.Keeper.info "%s: reconciled durable keeper" meta.name
               end
             end
         | Ok (Some _meta) -> () (* paused, skip *)
         | Ok None -> ()
         | Error err ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_observation_query_failures
               ~labels:[("operation", "reconcile_read_meta")]
               ();
             Log.Keeper.warn "reconcile: read_meta failed for %s: %s" name err);
         Eio_guard.yield_step reconcile_ym)
    names;
  Log.Keeper.debug "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
    (int_of_float ((Time_compat.now () -. t0) *. 1000.0))

let cleanup_dead_tombstone (ctx : _ context)
    (entry : Keeper_registry.registry_entry) =
  match read_meta ctx.config entry.name with
  | Ok (Some meta) ->
      let persisted_paused =
        if meta.paused then true
        else
          (* #9733: dead tombstone cleanup writes [paused = true] —
             cycle-owned field — while heartbeat fibers can still
             update the same record's heartbeat-owned fields.  Use
             the same merged-CAS retry as the resume + overflow-pause
             paths so a parallel heartbeat write doesn't make this
             write fail and leave the keeper unpaused on disk while
             the supervisor proceeds to unregister it. *)
          match
            write_meta_with_merge
              ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
              ctx.config { meta with paused = true }
          with
          | Ok () -> true
          | Error err when is_version_conflict_error err ->
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_write_meta_failures
                ~labels:[("keeper", entry.name); ("phase", "dead_cleanup_cas_race")]
                ();
              Log.Keeper.warn
                "%s: dead tombstone cleanup paused write lost CAS race after retries: %s"
                entry.name err;
              false
          | Error err ->
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_write_meta_failures
                ~labels:[("keeper", entry.name); ("phase", "dead_cleanup")]
                ();
              Log.Keeper.warn
                "%s: dead tombstone cleanup paused write failed: %s"
                entry.name err;
              false
      in
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
      if persisted_paused then begin
        publish_lifecycle
          ~event:(Keeper_lifecycle_events.Custom_event
                    { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
          entry.name "paused meta persisted" ();
        Log.Keeper.info "%s: dead tombstone cleaned up" entry.name
      end else begin
        publish_lifecycle
          ~event:(Keeper_lifecycle_events.Custom_event
                    { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
          entry.name "meta write failed, unregistered anyway" ();
        Log.Keeper.warn "%s: dead tombstone unregistered despite meta write failure" entry.name;
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_supervisor_cleanup_failures
          ~labels:[("keeper", entry.name); ("site", "dead_tombstone_meta_write")]
          ()
      end
  | Ok None ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
      publish_lifecycle
        ~event:(Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name "meta missing" ();
      Log.Keeper.warn "%s: dead tombstone unregistered (meta missing)" entry.name;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_supervisor_cleanup_failures
        ~labels:[("keeper", entry.name); ("site", "dead_tombstone_meta_missing")]
        ()
  | Error err ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
      publish_lifecycle
        ~event:(Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        (Printf.sprintf "meta read error: %s" err) ();
      Log.Keeper.warn "%s: dead tombstone unregistered (meta error: %s)"
        entry.name err;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_supervisor_cleanup_failures
        ~labels:[("keeper", entry.name); ("site", "dead_tombstone_meta_error")]
        ()

(** Cohort key from structured failure_reason ADT.
    #10584: delegates to [Keeper_registry.failure_reason_cohort_key] so a
    new variant in keeper_registry forces a same-PR converter update via
    the source module's exhaustive-match check, instead of breaking main
    here on first build (the recurring P0 pattern from #10490 + #10574). *)
let cohort_key_of_reason = Keeper_registry.failure_reason_cohort_key

let stale_turn_timeout_cohort_key =
  cohort_key_of_reason
    (Some
       (Keeper_registry.Stale_turn_timeout
          (Keeper_registry.Idle_turn { stall_seconds = 0.0 })))

(* #10887: persistent self-preservation lock.  Fleet log shows 125
   identical [ratio=1.00, cohort=stale_turn_timeout] events / 2 days
   with no escape — every sweep re-suppresses the same dominant
   cohort because [apply_self_preservation] is stateless across calls.
   Without an escape valve, a transient cohort (token rotation lag,
   cascade.toml fix mid-flight, etc.) keeps the fleet locked even
   after the underlying condition has cleared.

   Add a probe: after [probe_after_n_suppressions] consecutive
   suppressions of the same dominant cohort, allow ONE keeper from
   the cohort to attempt restart.  If the underlying condition has
   cleared, the keeper survives → it stops appearing in [to_restart]
   on subsequent sweeps → counter naturally resets via "different
   dominant cohort or no suppression at all".  If the condition
   persists, the keeper crashes again, lands back in the next
   sweep's [to_restart] with the same cohort, and the counter
   resumes. *)
type sp_escape_state = {
  mutable last_dominant_cohort : string;
  mutable consecutive_suppressions : int;
}

let sp_escape_state =
  { last_dominant_cohort = ""; consecutive_suppressions = 0 }

(** Probe cadence.  10 sweeps × default 30s sweep interval = 5
    minute probe — long enough that genuine systemic issues aren't
    probed back into life every cycle, short enough that a transient
    cohort clears within 1-2 probes once the root condition is fixed.
    Code constant rather than env knob per
    [feedback_no-hyperparameter-as-env-knob] — this is calibration,
    not operator policy. *)
let probe_after_n_suppressions = 10

(** Bounded minority exception for partial stale recovery.

    The live regression was 6/17 keepers: enough to trip the global
    self-preservation ratio gate, but not a fleet-wide provider/cascade
    storm.  Keep this below a majority so large-but-not-universal stale
    cohorts still go through the circuit breaker/probe path. *)
let partial_stale_recovery_max_ratio = 0.50

(** Reset the escape-valve state.  Test-only; production code never
    needs to call this (state cycles through the [last_dominant_cohort]
    inequality branch naturally). *)
let reset_self_preservation_escape_state_for_test () =
  sp_escape_state.last_dominant_cohort <- "";
  sp_escape_state.consecutive_suppressions <- 0

let active_supervision_keeper_count entries =
  List_util.count_if
    (fun (e : Keeper_registry.registry_entry) ->
      e.phase = Keeper_state_machine.Running
      || e.phase = Keeper_state_machine.Crashed)
    entries

(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count.
    Bounded minority [stale_turn_timeout] cohorts are allowed through so
    alive-but-stuck recovery can drain partial slot starvation; larger stale
    cohorts still use the circuit breaker/probe path.
    #10887: emits a probe restart every [probe_after_n_suppressions]
    consecutive suppressions of the same cohort. *)
let apply_self_preservation ~keepers_dir ~total_keepers to_restart =
  let sp_ratio = Env_config.KeeperSupervisor.self_preservation_ratio in
  let sp_min = Env_config.KeeperSupervisor.self_preservation_min_candidates in
  let n_candidates = List.length to_restart in
  let n_total = max 1 total_keepers in
  let ratio = float_of_int n_candidates /. float_of_int n_total in
  if ratio > sp_ratio
     && n_candidates >= sp_min
  then begin
    (* Group by failure_reason ADT variant (not string prefix) *)
    let insert_cohort acc (entry : Keeper_registry.registry_entry) _msg =
      let key = cohort_key_of_reason entry.last_failure_reason in
      let prev = StringMap.find_opt key acc |> Option.value ~default:[] in
      StringMap.add key ((entry, _msg) :: prev) acc
    in
    let cohorts = List.fold_left (fun acc ((e, m) : _ * string) -> insert_cohort acc e m) StringMap.empty to_restart in
    let dominant_key, dominant_entries =
      StringMap.fold (fun k v (best_k, best_v) ->
        if List.length v > List.length best_v then (k, v) else (best_k, best_v)
      ) cohorts ("", [])
    in
    if List.length dominant_entries >= sp_min then begin
      let dominant_count = List.length dominant_entries in
      let dominant_ratio =
        float_of_int dominant_count /. float_of_int n_total
      in
      if String.equal dominant_key stale_turn_timeout_cohort_key
         && dominant_ratio <= partial_stale_recovery_max_ratio
      then begin
        reset_self_preservation_escape_state_for_test ();
        Log.Keeper.warn
          "self-preservation: allowing partial stale_turn_timeout recovery \
           cohort through (dominant=%d/%d ratio_dominant=%.2f, \
           overall_candidates=%d/%d ratio_overall=%.2f)"
          dominant_count n_total dominant_ratio
          n_candidates n_total ratio;
        to_restart
      end else begin
      (* #10887: track consecutive suppressions of the same dominant
         cohort.  Different cohort -> counter resets to 1; same
         cohort -> counter increments. *)
      if String.equal sp_escape_state.last_dominant_cohort dominant_key then
        sp_escape_state.consecutive_suppressions <-
          sp_escape_state.consecutive_suppressions + 1
      else begin
        sp_escape_state.last_dominant_cohort <- dominant_key;
        sp_escape_state.consecutive_suppressions <- 1
      end;
      let probe_due =
        sp_escape_state.consecutive_suppressions >= probe_after_n_suppressions
      in
      let probe_entry =
        if probe_due
        then
          match dominant_entries with
          | (e, _) :: _ -> Some e.Keeper_registry.name
          | [] -> None
        else None
      in
      let suppressed_names =
        List.filter_map
          (fun ((e : Keeper_registry.registry_entry), _) ->
             match probe_entry with
             | Some probe_name when String.equal e.name probe_name -> None
             | _ -> Some e.name)
          dominant_entries
      in
      let suppressed_count = List.length suppressed_names in
      (match probe_entry with
       | Some probe_name ->
           (* Probe valve fires — positive signal, fleet is attempting
              auto-recovery.  WARN regardless of ratio. *)
           Log.Keeper.warn
             "self-preservation probe: allowing %s through after %d \
              consecutive same-cohort suppressions (ratio=%.2f, cohort=%s)"
             probe_name sp_escape_state.consecutive_suppressions ratio
             dominant_key;
           (* Reset the counter so the next probe is also
              [probe_after_n_suppressions] sweeps away. *)
           sp_escape_state.consecutive_suppressions <- 0
       | None ->
           (* #10945 + #10887: split universal (ratio>=0.99) vs partial
              suppression.  Universal = entire fleet sharing one
              cohort = auto-recovery is structurally OFF — log ERROR
              with operator-actionable hint.  Partial = circuit
              breaker working as designed = WARN.  Both lines carry
              [streak=N] so dashboards can show how close the next
              probe valve is. *)
           if ratio >= 0.99 then begin
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_self_preservation_universal
               ~labels:[("cohort", dominant_key)]
               ();
             Log.Keeper.error
               "self-preservation: UNIVERSAL suppression %d/%d \
                (ratio=%.2f, cohort=%s, streak=%d) — auto-recovery is \
                OFF until operator clears the shared failure mode \
                (e.g. cascade.toml hot-reload, token rotation, or \
                kill the dominant cohort to let SP release).  Probe \
                valve will allow one keeper through after %d \
                consecutive suppressions.  See #10887 / #10765."
               suppressed_count n_total ratio dominant_key
               sp_escape_state.consecutive_suppressions
               probe_after_n_suppressions
           end
           else
             Log.Keeper.warn
               "self-preservation: suppressing %d/%d restarts \
                (ratio=%.2f, cohort=%s, streak=%d)"
               suppressed_count n_total ratio dominant_key
               sp_escape_state.consecutive_suppressions);
      publish_lifecycle
        ~event:(Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Self_preservation;
                    phase = None })
        "supervisor"
        (Printf.sprintf "%d/%d suppressed, cohort=%s%s"
           suppressed_count n_total dominant_key
           (match probe_entry with
            | Some name -> Printf.sprintf ", probe=%s" name
            | None -> "")) ();
      Keeper_crash_persistence.enqueue_sp_event
        ~keepers_dir
        ~ts:(Time_compat.now ())
        ~suppressed_count
        ~total:n_total
        ~ratio
        ~dominant_cohort:dominant_key;
      List.filter (fun ((e : Keeper_registry.registry_entry), _) ->
        not (List.mem e.name suppressed_names)
      ) to_restart
      end
    end else begin
      (* Dominant cohort below sp_min — no suppression this cycle,
         so the streak no longer applies to this cohort. *)
      reset_self_preservation_escape_state_for_test ();
      to_restart
    end
  end else begin
    (* No suppression: streak resets. *)
    reset_self_preservation_escape_state_for_test ();
    to_restart
  end

let next_auto_resume_after_sec ~initial_sec ~max_sec previous =
  if initial_sec <= 0.0 then None
  else
    Some (
      match previous with
      | None -> Float.min max_sec initial_sec
      | Some prev -> Float.min max_sec (prev *. 2.0))

(** #10765 Phase 2: persist [meta.paused = true] for a keeper whose stale
    watchdog detected a termination storm (window count >= threshold).  The
    caller must skip enqueuing the entry into [to_restart] so the supervisor
    no longer auto-restarts the keeper into the same dead-cascade environment.

    Ordering rationale: write meta first, then publish lifecycle + counter.
    A failed meta write is logged but does not abort the pause path — the
    in-memory [last_failure_reason] still routes the next sweep through this
    branch, so the supervisor remains correct even if the disk write loses
    a CAS race.  The keeper would re-resume on a server restart in that
    edge case, but that is strictly less bad than the pre-Phase-2 baseline
    (continuous restart loop). *)
let handle_crash_auto_pause (ctx : _ context)
    (entry : Keeper_registry.registry_entry) ~reason_tag ~metric_name
    ~lifecycle_detail ~log_message ~blocker_class =
  (match read_meta ctx.config entry.name with
   | Ok (Some meta) ->
       let initial_sec = Env_config.KeeperSupervisor.auto_resume_initial_sec in
       let max_sec = Env_config.KeeperSupervisor.auto_resume_max_sec in
       let auto_resume_after_sec =
         next_auto_resume_after_sec ~initial_sec ~max_sec
           meta.auto_resume_after_sec
       in
       let blocker_text =
         let existing =
           match meta.runtime.last_blocker with
           | Some info -> String.trim info.detail
           | None -> ""
         in
         if existing <> "" then existing
         else
           match blocker_class with
           | Some cls -> blocker_class_to_string cls
           | None -> reason_tag
       in
       let blocker_info_opt =
         match blocker_class with
         | Some klass -> Some (blocker_info_of_class ~detail:blocker_text klass)
         | None ->
           (* No typed class available — preserve pre-existing typed
              info if any, otherwise drop the slot.  We refuse to
              silently fabricate a klass from [reason_tag]. *)
           meta.runtime.last_blocker
       in
       (* Task-138 §"Max no-task-progress 30min = release claimed":
          when the supervisor pauses a keeper because the same blocker
          class is looping (stale_storm or oas_timeout_budget_loop),
          the keeper is no longer making progress on its claimed task.
          Releasing [current_task_id] here lets a peer pick the task
          up while this keeper sits in [paused=true] back-off.

          Without this release the diagnostic state is "executor.json:
          current_task_id=task-147, paused=true, last_blocker.klass=
          oas_timeout_budget" — task is stuck forever because (a) this
          keeper cannot run while paused and (b) other keepers see the
          claim and skip.  The released task ID is not separately audited
          here; [last_blocker] in [runtime] already carries the pause
          reason, and Prometheus [keeper_paused_total] is incremented
          below.  Discovered 2026-05-05 fleet-stuck. *)
       (match
          write_meta_with_merge
            ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
            ctx.config
            { meta with
              paused = true;
              auto_resume_after_sec;
              updated_at = now_iso ();
              current_task_id = None;
              runtime =
                { meta.runtime with
                  last_blocker = blocker_info_opt;
                };
            }
        with
        | Ok () -> ()
        | Error err ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_write_meta_failures
              ~labels:[("keeper", entry.name); ("phase", "blocker_pause")]
              ();
            Log.Keeper.warn
              "%s: %s pause meta write failed (in-memory \
               failure_reason still gates restart, but persisted state \
               will not survive server restart): %s"
              entry.name reason_tag err)
   | Ok None ->
       Log.Keeper.warn
         "%s: %s pause: meta missing, cannot persist paused=true"
         entry.name reason_tag;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_write_meta_failures
         ~labels:[("keeper", entry.name); ("phase", "pause_meta_missing")]
         ()
   | Error err ->
       Log.Keeper.warn
         "%s: %s pause read_meta failed: %s"
         entry.name reason_tag err;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_write_meta_failures
         ~labels:[("keeper", entry.name); ("phase", "pause_read_meta")]
         ());
  Prometheus.inc_counter
    metric_name
    ~labels:[ ("keeper", entry.name) ]
    ();
  publish_phase_lifecycle
    ~phase:Keeper_state_machine.Paused
    entry.name
    lifecycle_detail ();
  Log.Keeper.error "%s: %s" entry.name log_message

let handle_stale_storm_pause (ctx : _ context)
    (entry : Keeper_registry.registry_entry) ~count =
  handle_crash_auto_pause ctx entry
    ~reason_tag:"stale_storm"
    ~metric_name:Keeper_metrics.metric_keeper_stale_storm_paused
    ~lifecycle_detail:(Printf.sprintf "stale_termination_storm count=%d" count)
    ~blocker_class:(Some Turn_timeout)
    ~log_message:
      (Printf.sprintf
         "STALE STORM AUTO-PAUSED (count=%d in 6h window). \
          Supervisor will attempt self-healing auto-resume with exponential \
          back-off (see MASC_KEEPER_AUTO_RESUME_INITIAL_SEC). \
          Operator may also resume manually via masc_keeper_up or API. \
          See issue #10765."
         count)

let handle_stale_fleet_batch_pause (ctx : _ context)
    (entry : Keeper_registry.registry_entry) ~distinct_count =
  handle_crash_auto_pause ctx entry
    ~reason_tag:"stale_fleet_batch"
    ~metric_name:Keeper_metrics.metric_keeper_stale_fleet_batch_paused
    ~lifecycle_detail:
      (Printf.sprintf "stale_fleet_batch distinct_count=%d" distinct_count)
    ~blocker_class:(Some Stale_fleet_batch)
    ~log_message:
      (Printf.sprintf
         "STALE FLEET BATCH AUTO-PAUSED (distinct_keepers=%d in batch \
          window). Supervisor will attempt self-healing auto-resume with \
          exponential back-off instead of restarting each keeper into the \
          same systemic failure mode (cascade dead, provider auth, fd leak, \
          etc.). See #10765 / #10474 / #10745."
         distinct_count)

let handle_oas_timeout_budget_pause (ctx : _ context)
    (entry : Keeper_registry.registry_entry) ~count =
  handle_crash_auto_pause ctx entry
    ~reason_tag:"oas_timeout_budget_loop"
    ~metric_name:Keeper_metrics.metric_keeper_oas_timeout_budget_loop_paused
    ~lifecycle_detail:(Printf.sprintf "oas_timeout_budget_loop count=%d" count)
    ~blocker_class:(Some Oas_timeout_budget)
    ~log_message:
      (Printf.sprintf
         "OAS TIMEOUT BUDGET LOOP AUTO-PAUSED (count=%d). \
          Supervisor will attempt self-healing auto-resume with exponential \
          back-off (see MASC_KEEPER_AUTO_RESUME_INITIAL_SEC). \
          Operator may also tune or reroute the cascade/model before resuming \
          manually; restarting into the same slow-provider budget loop is \
          avoided by the back-off delay."
         count)

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts = Runtime_params.get Governance_registry.keeper_supervisor_max_restarts in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* Refresh the cascade health cache before Phase 3.5 reads it.  Without this
     call the cache stayed cold (PR #14146 introduced the cache and
     [Phase 3.5] guard but never wired a writer), so [is_healthy] returned
     [false] for every cascade and silently disabled auto-resume across the
     fleet.  [run_once] is a registry scan — bounded, no I/O — so running it
     inline on every 30 s sweep is cheap.  [Safe_ops.protect] keeps a
     transient registry exception from killing the sweep. *)
  Safe_ops.protect ~default:() (fun () ->
    Keeper_health_probe.run_once ~base_path);
  (* Phase 2: sweep order — restart/unregister FIRST, reconcile LAST.
     This prevents reconcile from re-launching keepers that sweep is about
     to process (defense-in-depth alongside is_registered check). *)
  let entries = Keeper_registry.all ~base_path () in
  let to_restart = ref [] in
  let to_unregister = ref [] in
  let to_mark_dead = ref [] in
  let to_cleanup_dead = ref [] in
  let queue_crashed_entry (entry : Keeper_registry.registry_entry) msg =
    match entry.last_failure_reason with
    | Some (Keeper_registry.Stale_termination_storm { count }) ->
        (* #10765 Phase 2: skip [to_restart] AND in-memory unregister.
           The watchdog detected a termination storm (>= escalation_
           threshold within the 6h window).  [handle_stale_storm_pause]
           persists [meta.paused = true] so reconcile + future sweeps
           honor the pause across server restarts; we then add the
           entry to [to_unregister] so the in-memory registry slot is
           cleared and subsequent sweep ticks within the same server
           do NOT re-fire the storm-pause path (counter must increment
           once per storm, not once per sweep tick). *)
        handle_stale_storm_pause ctx entry ~count;
        to_unregister := entry :: !to_unregister
    | Some (Keeper_registry.Stale_fleet_batch { distinct_count }) ->
        (* Fleet batch detection means multiple keepers crossed the stale
           watchdog together. Treating those as independent keeper crashes
           immediately replays the batch. Pause/backoff instead. *)
        handle_stale_fleet_batch_pause ctx entry ~distinct_count;
        to_unregister := entry :: !to_unregister
    | Some (Keeper_registry.Oas_timeout_budget_loop { count }) ->
        (* Repeated OAS budget exhaustion means the active
           cascade/model is not producing within the turn budget.
           Restarting the same keeper preserves that bad routing and
           burns another multi-minute budget, so pause instead. *)
        handle_oas_timeout_budget_pause ctx entry ~count;
        to_unregister := entry :: !to_unregister
    (* All other failure reasons (and missing reason) fall through to the
       standard restart-budget path: restart up to [max_restarts], then mark
       Dead.  Any new [failure_reason] variant that warrants pause-instead-of-
       restart must be added explicitly; the compiler will enforce it. *)
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Stale_turn_timeout _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some (Keeper_registry.Tool_required_unsatisfied _)
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some Keeper_registry.Fiber_unresolved
    | Some (Keeper_registry.Exception _)
    | None ->
        if entry.restart_count >= max_restarts then
          to_mark_dead := (entry, msg) :: !to_mark_dead
        else begin
          let delay = backoff_delay entry.restart_count in
          if now -. entry.last_restart_ts >= delay then
            to_restart := (entry, msg) :: !to_restart
        end
  in
  let watchdog_stop_pending (entry : Keeper_registry.registry_entry) =
    Atomic.get entry.fiber_stop
    &&
    match entry.last_failure_reason with
    | Some (Keeper_registry.Stale_turn_timeout _)
    | Some (Keeper_registry.Stale_termination_storm _)
    | Some (Keeper_registry.Stale_fleet_batch _)
    | Some (Keeper_registry.Oas_timeout_budget_loop _) -> true
    (* Other failure reasons are not stale-watchdog signals. *)
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some (Keeper_registry.Tool_required_unsatisfied _)
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some Keeper_registry.Fiber_unresolved
    | Some (Keeper_registry.Exception _)
    | None -> false
  in
  let force_unresolved_watchdog_crash (entry : Keeper_registry.registry_entry) =
    let msg =
      entry.last_failure_reason
      |> Option.map Keeper_registry.failure_reason_to_string
      |> Option.value ~default:"watchdog_stop_pending"
    in
    (* 2026-05-05 cycle 9: stamp the cohort onto keeper_meta.runtime so
       the per-keeper meta surface (and PR #12877's "차단된 키퍼"
       dashboard card) shows the same diagnosis the supervisor used to
       group the keeper into a self-preservation cohort.  Companion to
       PR #12943 which added the same stamp on the [Fiber_unresolved]
       finally branch; this branch — [force_unresolved_watchdog_crash]
       — was the other silent path where the stamp was missing.
       Mapping covers all three watchdog cohorts handled by
       [watchdog_stop_pending]. *)
    let stamp_cohort =
      match entry.last_failure_reason with
      | Some (Keeper_registry.Stale_fleet_batch _) ->
        Some Stale_fleet_batch
      | Some (Keeper_registry.Oas_timeout_budget_loop _) ->
        Some Oas_timeout_budget
      | Some (Keeper_registry.Stale_turn_timeout _)
      | Some (Keeper_registry.Stale_termination_storm _) ->
        Some Stale_turn_timeout
      (* Non-watchdog failure reasons do not seed a watchdog blocker_class. *)
      | Some (Keeper_registry.Heartbeat_consecutive_failures _)
      | Some (Keeper_registry.Turn_consecutive_failures _)
      | Some (Keeper_registry.Provider_runtime_error _)
      | Some (Keeper_registry.Tool_required_unsatisfied _)
      | Some (Keeper_registry.Ambiguous_partial_commit _)
      | Some Keeper_registry.Fiber_unresolved
      | Some (Keeper_registry.Exception _)
      | None -> None
    in
    (match stamp_cohort with
     | None -> ()
     | Some bc ->
       (match Keeper_registry.get ~base_path entry.name with
        | Some current ->
          let stamped_meta =
            { current.meta with
              runtime =
                { current.meta.runtime with
                  last_blocker =
                    Some (blocker_info_of_class ~detail:msg bc);
                };
            }
          in
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               ctx.config stamped_meta
           with
           | Ok () -> ()
           | Error err ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_write_meta_failures
               ~labels:[("keeper", entry.name);
                        ("phase", "stale_turn_timeout_stamp")]
               ();
             Log.Keeper.warn
               "%s: stale_turn_timeout meta stamp failed: %s"
               entry.name err)
        | None -> ()));
    Log.Keeper.warn
      "%s: supervisor forcing unresolved watchdog-stopped keeper to crashed (%s)"
      entry.name msg;
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_supervisor_cleanup_failures
      ~labels:[("keeper", entry.name); ("site", "force_watchdog_crash")]
      ();
    (* 2026-05-05 fleet-stuck cycle: when a keeper fiber is stuck inside
       an LLM subprocess that does not honour [Eio.Cancel.Cancelled],
       the natural [Fun.protect] release in [with_keeper_turn_slot]
       never runs and its [reactive_turn_semaphore] permit is leaked.
       Production observation: 16 keepers held [reactive_slot] for
       18-25 minutes each, [reactive_available=0], every other keeper
       skipped its turn after the 180s [acquire_bounded] timeout, and
       the idle-turn watchdog killed them. Force-releasing here is the
       only path that drains the semaphore short of a process restart.
       Bounded over-release is documented in
       [Keeper_turn_slot.force_release_holder_for]. *)
    (match Keeper_turn_slot.force_release_holder_for ~keeper_name:entry.name with
     | [] -> ()
     | released ->
       let summary =
         released
         |> List.map (fun (label, age) -> Printf.sprintf "%s/%.0fs" label age)
         |> String.concat ","
       in
       Log.Keeper.error
         "%s: force-released stale slots after watchdog crash: %s"
         entry.name summary);
    if Keeper_registry.try_resolve_done entry (`Crashed msg) then begin
      ignore
        (Keeper_registry.dispatch_event_and_log
           ~base_path entry.name
           (Keeper_state_machine.Fiber_terminated { outcome = msg }));
      let ts = Time_compat.now () in
      Keeper_registry.record_crash ~base_path entry.name ts msg;
      Keeper_registry.record_error ~base_path entry.name msg;
      (match Keeper_registry.get ~base_path entry.name with
       | Some updated -> queue_crashed_entry updated msg
       | None -> ())
    end
  in
  (* 2-level supervision slice: process the flat registry through stable
     8-keeper cohorts.  Each cohort re-reads its entries by name before
     processing so earlier cohort actions cannot leave later cohorts walking
     stale registry records.  The iterator yields between cohort groups; the
     yield meter still protects unusually large cohorts or non-default sizes. *)
  let entry_cohorts = supervision_cohorts entries in
  let sweep_ym = Eio_guard.create_yield_meter () in
  iter_supervision_cohorts entry_cohorts ~f:(fun cohort ->
      let cohort_keepers =
        fresh_supervision_cohort_keepers ~base_path cohort
      in
      List.iter
        (fun (entry : Keeper_registry.registry_entry) ->
          (match entry.phase with
           | Keeper_state_machine.Dead | Keeper_state_machine.Zombie ->
               (match entry.dead_since_ts with
                | Some dead_since when now -. dead_since >= dead_ttl_sec ->
                    to_cleanup_dead := entry :: !to_cleanup_dead
                | _ -> ())
           | Keeper_state_machine.Stopped ->
               to_unregister := entry :: !to_unregister
           | Keeper_state_machine.Running | Keeper_state_machine.Paused
           | Keeper_state_machine.Crashed | Keeper_state_machine.Failing
           | Keeper_state_machine.Overflowed | Keeper_state_machine.Compacting
           | Keeper_state_machine.HandingOff | Keeper_state_machine.Draining
           | Keeper_state_machine.Restarting | Keeper_state_machine.Offline ->
               (match Eio.Promise.peek entry.done_p with
                | None when watchdog_stop_pending entry ->
                    force_unresolved_watchdog_crash entry
                | None -> ()  (* Alive — skip *)
                | Some `Stopped ->
                    to_unregister := entry :: !to_unregister
                | Some (`Crashed msg) ->
                    queue_crashed_entry entry msg));
          Eio_guard.yield_step sweep_ym)
        cohort_keepers);
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    Keeper_registry.unregister ~base_path entry.name;
    (* K4c — restart-budget exhaustion: keeper is permanently
       removed (no respawn), so reclaim its accumulator slot. *)
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name
  ) !to_unregister;
  List.iter (fun ((entry : Keeper_registry.registry_entry), msg) ->
    (* RFC-0002: dispatch budget exhaustion before marking dead *)
    Keeper_registry.dispatch_event_unit ~base_path entry.name
      Keeper_state_machine.Restart_budget_exhausted;
    Keeper_registry.mark_dead ~base_path entry.name ~at:now;
    (* Task release: Dead keepers cannot make progress on claimed tasks.
       Without this release, current_task_id stays claimed forever —
       the task is invisible to peers while this keeper is permanently
       stopped.  Mirrors handle_crash_auto_pause (line 1163). *)
    (match entry.meta.current_task_id with
     | Some _ ->
         (match read_meta ctx.config entry.name with
          | Ok (Some meta) ->
              ignore (write_meta_with_merge
                ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                ctx.config
                { meta with current_task_id = None })
          | _ -> ())
     | None -> ());
    let detail =
      Printf.sprintf "restart budget exhausted (%d), last: %s"
        max_restarts msg
    in
    publish_phase_lifecycle ~phase:Keeper_state_machine.Dead entry.name
      detail ();
    (* Loud alert: structured Dead event + Prometheus counter so a fleet-wide
       silent crash (8 keepers, 2026-04-25) is impossible to miss in dashboard
       or PromQL. The free-form [event="dead"] on masc.keeper.lifecycle does
       not carry restart_count or the structured failure reason. *)
    let last_fr_str =
      Option.map Keeper_registry.failure_reason_to_string
        entry.last_failure_reason
    in
    (match Keeper_keepalive.get_bus () with
     | Some bus ->
         Cascade_events.publish_keeper_dead bus
           ~keeper_name:entry.name
           ~reason:msg
           ~restart_count:entry.restart_count
           ~last_failure_reason:last_fr_str
           ()
     | None -> ());
    Prometheus.inc_counter Keeper_metrics.metric_keeper_dead_total
      ~labels:[
        ("keeper", entry.name);
        ("reason", Option.value last_fr_str ~default:"unknown");
      ] ();
    Log.Keeper.error
      "keeper DEAD (max_restarts exhausted): name=%s reason=%s \
       restart_count=%d — operator action required"
      entry.name msg entry.restart_count
  ) !to_mark_dead;
  (* RFC-0036 Phase A.2: fire Tombstone_reaped after cleanup completes.
     Hook is exception-safe; supervisor never observes failure. *)
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    cleanup_dead_tombstone ctx entry;
    Keeper_lifecycle_hooks.run
      ~base_dir:(Coord.masc_root_dir ctx.config)
      ~meta:entry.meta
      ~keeper_id:entry.name
      Keeper_lifecycle_hooks.Tombstone_reaped
  ) !to_cleanup_dead;
  let active_count =
    Keeper_registry.all ~base_path ()
    |> active_supervision_keeper_count
  in
  let restart_list =
    let keepers_dir =
      Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count !to_restart in
  (* Restart crashed keepers *)
  List.iter (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
    let attempt = old_entry.restart_count + 1 in
    Prometheus.inc_counter Keeper_metrics.metric_keeper_restart_attempts
      ~labels:[("keeper", old_entry.name)] ();
    match read_meta ctx.config old_entry.name with
    | Ok (Some meta) ->
        (* RFC-0002: dispatch restart attempt event *)
        Keeper_registry.dispatch_event_unit ~base_path old_entry.name
          (Keeper_state_machine.Supervisor_restart_attempt { attempt });
        let old_crash_log = old_entry.crash_log in
        let reg =
          Keeper_registry.register_restarting ~base_path old_entry.name meta
        in
        Keeper_registry.restore_supervisor_state ~base_path old_entry.name
          ~restart_count:attempt ~last_restart_ts:now
          ~crash_log:(keep_last_n 5 (now, crash_msg) old_crash_log);
        launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta reg;
        publish_lifecycle
          ~event:(Keeper_lifecycle_events.Custom_event
                    { verb = Keeper_lifecycle_events.Restarted;
                      phase = Some Keeper_state_machine.Running })
          old_entry.name
          (Printf.sprintf "attempt %d" attempt) ();
        Prometheus.inc_counter Keeper_metrics.metric_keeper_restart_outcomes
          ~labels:[("keeper", old_entry.name); ("outcome", "started")] ();
        Log.Keeper.info "%s: restarted (attempt %d, backoff %.0fs)"
          old_entry.name attempt (backoff_delay (attempt - 1));
        (* Soft pre-warning when this is the FINAL allowed restart: next
           crash will trip the budget and mark Dead. Operator-actionable
           but not yet a fault — investigate root cause now. *)
        if attempt >= max_restarts then begin
          Log.Keeper.warn
            "keeper near-exhaustion: name=%s restart=%d/%d — investigate"
            old_entry.name attempt max_restarts;
          Prometheus.inc_counter Keeper_metrics.metric_keeper_near_exhaustion_total
            ~labels:[("keeper", old_entry.name)] ()
        end
    | _ ->
        Prometheus.inc_counter Keeper_metrics.metric_keeper_restart_outcomes
          ~labels:[("keeper", old_entry.name); ("outcome", "meta_unavailable")] ();
        Log.Keeper.error "%s: cannot read meta for restart, removing"
          old_entry.name;
        Keeper_registry.unregister ~base_path old_entry.name;
        (* K4c — restart-meta read failure: keeper abandoned, drop. *)
        Keeper_tool_emission_hook.drop_keeper_accumulator old_entry.name
  ) restart_list;
  (* Phase 2: restore paused reconcile gates whose approval queue was lost
     on restart. The queue itself is in-memory, but paused keeper meta is
     durable, so rebuild the human gate from persisted blocker evidence. *)
  let sweep_names_ym = Eio_guard.create_yield_meter () in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         (match read_meta ctx.config name with
         | Ok (Some meta)
           when paused_meta_requires_reconcile_recovery meta
                && not
                     (Keeper_approval_queue.has_pending_for_keeper
                        ~keeper_name:meta.name) ->
             restore_reconcile_continue_gate ctx meta
         | _ -> ());
         Eio_guard.yield_step sweep_names_ym);
  (* Phase 3: prune stale paused keeper meta files from disk. Keep
     reconcile-recovery pauses until the operator explicitly resolves them. *)
  let paused_ttl_sec = Env_config.KeeperSupervisor.paused_cleanup_ttl_sec in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         (if Keeper_registry.is_running ~base_path name then ()
         else
           match read_meta ctx.config name with
           | Ok (Some meta)
             when is_stale_paused_meta ~now ~paused_ttl_sec meta
                  && not (paused_meta_requires_reconcile_recovery meta)
                  && not
                       (Keeper_approval_queue.has_pending_for_keeper
                          ~keeper_name:meta.name) ->
               let path = Keeper_types.keeper_meta_path ctx.config name in
               (try
                  Sys.remove path;
                  publish_lifecycle
                    ~event:(Keeper_lifecycle_events.Custom_event
                              { verb = Keeper_lifecycle_events.Paused_pruned;
                                phase = None })
                    name
                    (Printf.sprintf "last_updated=%s" meta.updated_at) ();
                  Log.Keeper.info "%s: stale paused meta pruned" name
                with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                  Log.Keeper.warn "%s: paused meta prune failed: %s"
                    name (Printexc.to_string exn);
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_supervisor_cleanup_failures
                    ~labels:[("keeper", name); ("site", "paused_meta_prune")]
                    ())
           | _ -> ());
         Eio_guard.yield_step sweep_names_ym);
  (* Phase 3.5: self-healing circuit breaker — auto-resume keepers that were
     auto-paused (have [auto_resume_after_sec = Some sec]) and whose pause
     timer has elapsed.  Clearing [paused = false] here lets Phase 4
     (reconcile_keepalive_keepers) pick them up and restart them on the same
     sweep.  Reconcile-gated pauses (ambiguous commit timeouts) and
     operator-initiated pauses ([auto_resume_after_sec = None]) are
     intentionally skipped so they continue to require human action. *)
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         (if Keeper_registry.is_running ~base_path name then ()
         else
           match read_meta ctx.config name with
           | Ok (Some meta) when meta.paused
                                 && Option.is_some meta.auto_resume_after_sec
                                 && not (paused_meta_requires_reconcile_recovery meta)
                                 && not (Keeper_approval_queue.has_pending_for_keeper
                                           ~keeper_name:meta.name) ->
               let cascade_name = Keeper_types.cascade_name_of_meta meta in
               let cascade_status =
                 Keeper_health_probe.get_cascade_status
                   ~cascade_name
               in
               (* Three-valued admission:
                    Unhealthy   — block, the probe saw restart pressure.
                    Healthy     — proceed with timer check.
                    Unknown     — proceed with timer check.  No probe data
                                  yet (e.g. all keepers in the cascade
                                  paused so the registry has no entries
                                  to score).  Defaulting to "block" here
                                  is the bug PR #14146 shipped: it turned
                                  the boot-time race window into a
                                  permanent lockout.  See instructions/
                                  software-development.md anti-pattern
                                  "Unknown -> Permissive Default". *)
               (match cascade_status with
                | Keeper_health_probe.Unhealthy reason ->
                    Log.Keeper.info
                      "%s: auto-resume blocked; cascade %s is unhealthy (%s)"
                      name cascade_name reason;
                    Prometheus.inc_counter
                      Keeper_metrics.metric_keeper_auto_resume_blocked_total
                      ~labels:[("keeper", name);
                               ("cascade", cascade_name)]
                      ()
                | Keeper_health_probe.Unknown
                | Keeper_health_probe.Healthy ->
                  begin
                 let resume_after_sec =
                   Option.value ~default:0.0 meta.auto_resume_after_sec in
                 let paused_ts =
                   Coord_resilience.Time.parse_iso8601_opt meta.updated_at
                   |> Option.value ~default:0.0
                 in
                 if paused_ts > 0.0 && now -. paused_ts >= resume_after_sec then begin
                   (* Resume: clear [paused] flag but retain [auto_resume_after_sec]
                      so the doubled delay is ready for the next auto-pause.  It
                      will be reset to [None] on a successful turn completion. *)
                   let resumed_meta =
                     { meta with
                       paused = false;
                       updated_at = now_iso ();
                       runtime =
                         { meta.runtime with
                           last_blocker = None;
                         };
                     }
                   in
                   (match
                      write_meta_with_merge
                        ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                        ctx.config resumed_meta
                    with
                    | Ok () ->
                        publish_lifecycle
                          ~event:(Keeper_lifecycle_events.Custom_event
                                    { verb = Keeper_lifecycle_events.Auto_resumed;
                                      phase = None })
                          name
                          (Printf.sprintf "auto_resume backoff=%.0fs" resume_after_sec) ();
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_auto_resumed_total
                          ~labels:[("keeper", name)]
                          ();
                        Log.Keeper.info
                          "%s: auto-resumed after %.0fs backoff (next backoff=%.0fs if \
                           re-paused; resets to initial on successful turn)"
                          name resume_after_sec
                          (Float.min
                             (Env_config.KeeperSupervisor.auto_resume_max_sec)
                             (resume_after_sec *. 2.0))
                    | Error err ->
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_write_meta_failures
                          ~labels:[("keeper", name); ("phase", "auto_resume")]
                          ();
                        Log.Keeper.warn
                          "%s: auto-resume meta write failed: %s"
                          name err)
                 end
                  end)
           | _ -> ());
         Eio_guard.yield_step sweep_names_ym);
  (* Phase 4: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx

(* ── Liveness Recovery (#12801) ─────────────────────────── *)

(** Per-keeper state for the liveness recovery scan. Tracks how many recovery
    attempts have been made and when the last attempt occurred so the scan
    can apply exponential backoff. *)
type liveness_recovery_state = {
  mutable attempt_count : int;
  mutable last_attempt_ts : float;
}

let liveness_recovery_table : (string, liveness_recovery_state) Hashtbl.t =
  Hashtbl.create 4

let liveness_recovery_table_mu = Eio.Mutex.create ()

let get_or_create_recovery_state name =
  Eio.Mutex.use_rw ~protect:true liveness_recovery_table_mu (fun () ->
    match Hashtbl.find_opt liveness_recovery_table name with
    | Some s -> s
    | None ->
        let s = { attempt_count = 0; last_attempt_ts = 0.0 } in
        Hashtbl.replace liveness_recovery_table name s;
        s)

let liveness_recovery_backoff attempt =
  let base = Env_config.KeeperSupervisor.liveness_recovery_backoff_base_sec in
  let max_delay = Env_config.KeeperSupervisor.liveness_recovery_backoff_max_sec in
  Float.min max_delay (base *. Float.of_int (1 lsl (min attempt 20)))

let should_attempt_liveness_recovery ~now
    (entry : Keeper_registry.registry_entry) : bool =
  (* Only Dead keepers, not Zombie (terminal_failure_latched = structural) *)
  if entry.phase <> Keeper_state_machine.Dead then false
  (* Zombie timeout reached: structural terminal — skip *)
  else if entry.conditions.zombie_timeout_reached then false
  else
    let min_dead_sec = Env_config.KeeperSupervisor.liveness_recovery_min_dead_sec in
    (* Pattern-match dead_since_ts directly: collapsing None -> 0.0 via
       Option.value created a strict-`>` guard that rejected legitimate
       at:0.0 fixtures (the synthetic epoch used in tests like
       liveness_recovery_2 — see #12826). *)
    match entry.dead_since_ts with
    | None -> false
    | Some dead_since -> now -. dead_since >= min_dead_sec

type credential_recovery_outcome =
  | Credential_recovery_not_needed
  | Credential_recovery_reissued of string
  | Credential_recovery_failed of string

let has_prefix s prefix =
  let plen = String.length prefix in
  String.length s >= plen && String.equal (String.sub s 0 plen) prefix

let has_suffix s suffix =
  let slen = String.length suffix in
  let len = String.length s in
  len >= slen && String.equal (String.sub s (len - slen) slen) suffix

let canonical_keeper_agent_name name =
  if has_prefix name "keeper-" && has_suffix name "-agent" then name
  else Keeper_types_profile.keeper_agent_name name

let credential_recovery_before_restart ~base_path
    (entry : Keeper_registry.registry_entry) =
  if not entry.conditions.credential_archived then
    Credential_recovery_not_needed
  else
    let agent_name = canonical_keeper_agent_name entry.name in
    match Auth.ensure_keeper_credential base_path ~agent_name with
    | Ok _ -> Credential_recovery_reissued agent_name
    | Error err ->
        Credential_recovery_failed (Masc_domain.masc_error_to_string err)

let credential_recovery_before_restart_for_test =
  credential_recovery_before_restart

let liveness_recovery_scan (ctx : _ context) =
  if not Env_config.KeeperSupervisor.liveness_recovery_enabled then ()
  else begin
    let now = Time_compat.now () in
    let base_path = ctx.config.base_path in
    let max_attempts = Env_config.KeeperSupervisor.liveness_recovery_max_attempts in
    let entries = Keeper_registry.all ~base_path () in
    let liveness_ym = Eio_guard.create_yield_meter () in
    List.iter (fun (entry : Keeper_registry.registry_entry) ->
      (if not (should_attempt_liveness_recovery ~now entry) then ()
      else begin
        let rs = get_or_create_recovery_state entry.name in
        if rs.attempt_count >= max_attempts then
          (* Budget exhausted — log at debug to avoid spam *)
          Log.Keeper.debug
            "%s: liveness recovery budget exhausted (%d/%d attempts)"
            entry.name rs.attempt_count max_attempts
        else begin
          let backoff = liveness_recovery_backoff rs.attempt_count in
          if now -. rs.last_attempt_ts < backoff then ()
          else begin
            let dead_secs = now -. (Option.value ~default:now entry.dead_since_ts) in
            Log.Keeper.warn
              "%s: liveness recovery attempt %d/%d \
               (dead_for=%.0fs, backoff=%.0fs)"
              entry.name (rs.attempt_count + 1) max_attempts
              dead_secs backoff;
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_liveness_recovery_attempts
              ~labels:[("keeper", entry.name)] ();
            let credential_recovered =
              match credential_recovery_before_restart ~base_path entry with
              | Credential_recovery_failed reason ->
                Eio.Mutex.use_rw ~protect:true liveness_recovery_table_mu
                  (fun () ->
                     rs.attempt_count <- rs.attempt_count + 1;
                     rs.last_attempt_ts <- now);
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                  ~labels:[("keeper", entry.name);
                           ("outcome", "credential_reissue_failed")] ();
                Log.Keeper.error
                  "%s: liveness recovery credential self-heal failed: %s"
                  entry.name reason;
                false
              | Credential_recovery_not_needed -> true
              | Credential_recovery_reissued agent_name ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                    ~labels:[("keeper", entry.name);
                             ("outcome", "credential_reissued")] ();
                  Log.Keeper.warn
                    "%s: credential_archived self-healed via %s; relaunching keeper"
                    entry.name agent_name;
                  true
            in
            if credential_recovered then begin
              (* Step 1: unregister the dead tombstone *)
              Keeper_registry.unregister ~base_path entry.name;
              Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
              Keeper_stay_silent_loop_detector.reset ~keeper_name:entry.name;
              Keeper_passive_loop_detector.reset ~keeper_name:entry.name;
              (* Step 2: clear paused and last_blocker from meta *)
              (match read_meta ctx.config entry.name with
             | Ok (Some meta) ->
                 let recovery_meta =
                   { meta with
                     paused = false;
                     auto_resume_after_sec = None;
                     updated_at = now_iso ();
                     runtime =
                       { meta.runtime with
                         last_blocker = None;
                       };
                   }
                 in
                 (match
                    write_meta_with_merge
                      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                      ctx.config recovery_meta
                  with
                  | Ok () ->
                      (* Step 3: re-register and launch a fresh fiber *)
                      supervise_keepalive ~proactive_warmup_sec:0 ctx recovery_meta;
                      (* Update recovery state regardless of launch result *)
                      Eio.Mutex.use_rw ~protect:true liveness_recovery_table_mu
                        (fun () ->
                           rs.attempt_count <- rs.attempt_count + 1;
                           rs.last_attempt_ts <- now);
                      if Keeper_registry.is_running ~base_path entry.name then begin
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                          ~labels:[("keeper", entry.name); ("outcome", "started")] ();
                        publish_lifecycle
                          ~event:(Keeper_lifecycle_events.Custom_event
                                    { verb = Keeper_lifecycle_events.Restarted;
                                      phase = Some Keeper_state_machine.Running })
                          entry.name
                          (Printf.sprintf
                             "liveness recovery attempt %d"
                             rs.attempt_count) ();
                        Log.Keeper.warn
                          "%s: liveness recovery SUCCESS (attempt %d/%d)"
                          entry.name rs.attempt_count max_attempts
                      end else begin
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                          ~labels:[("keeper", entry.name); ("outcome", "not_running")] ();
                        Log.Keeper.error
                          "%s: liveness recovery: keeper not in Running state \
                           after relaunch (attempt %d/%d)"
                          entry.name rs.attempt_count max_attempts
                      end
                  | Error err ->
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                        ~labels:[("keeper", entry.name); ("outcome", "meta_write_failed")] ();
                      Log.Keeper.error
                        "%s: liveness recovery meta write failed: %s" entry.name err)
             | Ok None ->
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                   ~labels:[("keeper", entry.name); ("outcome", "meta_missing")] ();
                 Log.Keeper.error
                   "%s: liveness recovery: meta file missing" entry.name
             | Error err ->
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                   ~labels:[("keeper", entry.name); ("outcome", "meta_read_failed")] ();
                 Log.Keeper.error
                   "%s: liveness recovery read_meta failed: %s" entry.name err)
            end
          end
        end
      end);
      Eio_guard.yield_step liveness_ym
    ) entries
  end

(* ──────────────────────────────────────────────────────────────────
   #12838 Alive-but-stuck detector

   Liveness Recovery Supervisor (#12801, [liveness_recovery_scan]
   above) handles Dead keepers, including credential_archived self-heal,
   while still treating zombie_timeout_reached as structural. It does not
   handle a separate failure mode observed in production on
   2026-05-04: keepers that are alive in every metric the supervisor
   checks but have a flat [proactive_rt.last_ts] for days because
   their [current_task_id] references an orphaned [AwaitingVerification]
   task.

   This detector emits a Prometheus counter and requests a supervised
   restart through the same [failure_reason + fiber_stop] path as the
   stale watchdog.  It also queues an Event Layer recovery wakeup so the
   wake path is visible as structured stimulus.  The next sweep can then
   force unresolved watchdog-stopped entries into the normal crash/restart
   pipeline instead of leaving the keeper at detection-only.
   ────────────────────────────────────────────────────────────────── *)

(** Pure detection: is this keeper alive-but-stuck at [now]?

    Returns [Some elapsed_sec] (the gap since the keeper's reference
    timestamp) when the keeper is non-Dead, non-paused, has done at
    least one autonomous turn, and has gone longer than
    [max(stall_floor_sec, stall_multiplier * cooldown_sec)] without a
    proactive turn.

    Reference timestamp: the newer of [proactive_rt.last_ts] and
    [entry.started_at] when proactive has ever fired ([> 0.0]),
    otherwise [entry.started_at].  Persisted proactive timestamps can
    predate the current server lifecycle; [started_at] is the lower
    bound for the current fiber, so a restart must not immediately mark
    old-but-freshly-booted keepers stuck, while long-running frozen
    keepers still trip the detector.  The [entry.started_at] fallback
    also catches the "never_started" case (e.g. [glm-coding-plan] in the
    production sample) without a separate code path.

    Returns [None] when not stuck.  Pure: no I/O, no global state. *)
let detect_alive_but_stuck ~now ~stall_multiplier ~stall_floor_sec
    (entry : Keeper_registry.registry_entry) : float option =
  let meta = entry.meta in
  if meta.paused then None
  else if entry.phase <> Keeper_state_machine.Running then None
  else if meta.runtime.autonomous_turn_count <= 0 then
    (* Brand-new keeper: not stuck, just hasn't started. *)
    None
  else
    let cooldown_sec = float_of_int meta.proactive.cooldown_sec in
    let stall_threshold =
      Float.max stall_floor_sec
        (cooldown_sec *. float_of_int stall_multiplier)
    in
    let last_proactive_ts = meta.runtime.proactive_rt.last_ts in
    let reference_ts =
      if last_proactive_ts > 0.0 then
        Float.max last_proactive_ts entry.started_at
      else
        entry.started_at
    in
    let elapsed = now -. reference_ts in
    if elapsed > stall_threshold then Some elapsed else None

(* Per-keeper dedup table for [alive_but_stuck_scan].  Bounds counter
   emission to one increment per [alive_but_stuck_dedup_ttl_sec] per
   keeper, even when the sweep fires every 30s.  Mirrors the
   [liveness_recovery_table] pattern above. *)
let alive_but_stuck_last_alert : (string, float) Hashtbl.t =
  Hashtbl.create 16

let alive_but_stuck_last_alert_mu = Eio.Mutex.create ()

let alive_but_stuck_should_emit ~now ~dedup_ttl_sec name =
  Eio.Mutex.use_rw ~protect:false alive_but_stuck_last_alert_mu (fun () ->
    match Hashtbl.find_opt alive_but_stuck_last_alert name with
    | Some last_ts when now -. last_ts < dedup_ttl_sec -> false
    | _ ->
      Hashtbl.replace alive_but_stuck_last_alert name now;
      true)

let alive_but_stuck_threshold ~stall_multiplier ~stall_floor_sec
    (entry : Keeper_registry.registry_entry) =
  Float.max stall_floor_sec
    (float_of_int entry.meta.proactive.cooldown_sec
     *. float_of_int stall_multiplier)

let set_alive_but_stuck_gauges ~(entry : Keeper_registry.registry_entry)
    ~threshold ~elapsed =
  let labels = [("keeper_name", entry.name)] in
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_alive_but_stuck_seconds
    ~labels
    (Option.value elapsed ~default:0.0);
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_alive_but_stuck_threshold_seconds
    ~labels
    threshold

let alive_but_stuck_recovery_stimulus ~now ~elapsed ~threshold
    (entry : Keeper_registry.registry_entry) : Keeper_event_queue.stimulus =
  let payload =
    `Assoc [
      "source", `String "alive_but_stuck_recovery";
      "keeper", `String entry.name;
      "elapsed_sec", `Float elapsed;
      "threshold_sec", `Float threshold;
      "autonomous_turns", `Int entry.meta.runtime.autonomous_turn_count;
      "proactive_count_total", `Int entry.meta.runtime.proactive_rt.count_total;
      "message",
      `String
        "supervisor detected a frozen scheduled-autonomous timestamp; run a recovery cycle";
    ]
    |> Yojson.Safe.to_string
  in
  {
    Keeper_event_queue.post_id = "alive-but-stuck:" ^ entry.name;
    urgency = Keeper_event_queue.Immediate;
    arrived_at = now;
    payload;
  }

let queue_alive_but_stuck_recovery ~base_path ~now ~elapsed ~threshold
    (entry : Keeper_registry.registry_entry) =
  if not Env_config.KeeperSupervisor.alive_but_stuck_recovery_enabled then
    "disabled"
  else if entry.phase <> Keeper_state_machine.Running then
    "skipped_not_running"
  else begin
    let stimulus =
      alive_but_stuck_recovery_stimulus ~now ~elapsed ~threshold entry
    in
    Keeper_registry.enqueue_event ~base_path entry.name stimulus;
    Keeper_registry.wakeup ~base_path entry.name;
    "queued"
  end

(** Test-only: clear the dedup table so each test case starts fresh. *)
let alive_but_stuck_reset_for_test () =
  Eio.Mutex.use_rw ~protect:false alive_but_stuck_last_alert_mu (fun () ->
    Hashtbl.clear alive_but_stuck_last_alert)

let request_alive_but_stuck_recovery ~base_path ~elapsed
    (entry : Keeper_registry.registry_entry) =
  let kill_class =
    Keeper_registry.Idle_turn { stall_seconds = elapsed }
  in
  let current_entry =
    Keeper_registry.get ~base_path entry.name |> Option.value ~default:entry
  in
  (* PR #13106 review: must NOT route through
     [stale_watchdog_failure_reason], which preserves prior reasons
     like [Turn_consecutive_failures] / [Exception] / etc.  Those
     reasons are not in the [watchdog_stop_pending] restart set
     ([Stale_turn_timeout | Stale_termination_storm |
     Stale_fleet_batch | Oas_timeout_budget_loop]), so preserving them would set
     [fiber_stop = true] and then the supervisor's next sweep would
     skip [force_unresolved_watchdog_crash] — the fiber goes dormant
     instead of being restarted, defeating the entire recovery.

     Force the watchdog cohort to [Stale_turn_timeout kill_class] so
     [watchdog_stop_pending] / [record_loop_exit] both treat this as
     a watchdog stop.  The prior reason is captured in the log line
     for postmortem.

     Idempotent: if the keeper is already in a watchdog cohort
     ([Stale_turn_timeout] / [Stale_termination_storm] /
     [Stale_fleet_batch] / [Oas_timeout_budget_loop]), preserve it so we don't churn the
     [stall_seconds] field on every poll. *)
  let prior_str =
    Option.map Keeper_registry.failure_reason_to_string
      current_entry.last_failure_reason
    |> Option.value ~default:"none"
  in
  let reason =
    match current_entry.last_failure_reason with
    | Some
        ( Keeper_registry.Stale_turn_timeout _
        | Keeper_registry.Stale_termination_storm _
        | Keeper_registry.Stale_fleet_batch _
        | Keeper_registry.Oas_timeout_budget_loop _ ) as kept ->
        kept
    (* Non-stale failure reasons (and no prior reason) are overwritten with
       a fresh [Stale_turn_timeout] carrying the current kill class.  Any new
       [failure_reason] variant must be classified explicitly here. *)
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some (Keeper_registry.Tool_required_unsatisfied _)
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some Keeper_registry.Fiber_unresolved
    | Some (Keeper_registry.Exception _)
    | None -> Some (Keeper_registry.Stale_turn_timeout kill_class)
  in
  Keeper_registry.set_failure_reason ~base_path entry.name reason;
  (* tla-lint: allow-mutation: fiber signal — alive-but-stuck recovery asks
     the heartbeat fiber to exit and wakes it if it is in interruptible sleep.
     The next supervisor sweep will route this through the existing
     force_unresolved_watchdog_crash path if the fiber does not resolve on
     its own. *)
  Atomic.set entry.fiber_stop true;
  Atomic.set entry.fiber_wakeup true;
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_alive_but_stuck_recovery_requests
    ~labels:[("keeper", entry.name)]
    ();
  Log.Keeper.error
    "%s: alive-but-stuck recovery requested (elapsed=%.0fs, prior_reason=%s, \
     failure_reason=%s)"
    entry.name elapsed prior_str
    (Option.map Keeper_registry.failure_reason_to_string reason
     |> Option.value ~default:"unknown")

let request_alive_but_stuck_recovery_for_test =
  request_alive_but_stuck_recovery

let alive_but_stuck_scan (ctx : _ context) =
  if not Env_config.KeeperSupervisor.alive_but_stuck_enabled then ()
  else begin
    let now = Time_compat.now () in
    let stall_multiplier =
      Env_config.KeeperSupervisor.alive_but_stuck_stall_multiplier
    in
    let stall_floor_sec =
      Env_config.KeeperSupervisor.alive_but_stuck_stall_floor_sec
    in
    let dedup_ttl_sec =
      Env_config.KeeperSupervisor.alive_but_stuck_dedup_ttl_sec
    in
    let base_path = ctx.config.base_path in
    let entries = Keeper_registry.all ~base_path () in
    let abs_ym = Eio_guard.create_yield_meter () in
    List.iter (fun (entry : Keeper_registry.registry_entry) ->
      let threshold =
        alive_but_stuck_threshold ~stall_multiplier ~stall_floor_sec entry
      in
      let elapsed =
        detect_alive_but_stuck ~now ~stall_multiplier ~stall_floor_sec entry
      in
      set_alive_but_stuck_gauges ~entry ~threshold ~elapsed;
      (match elapsed with
      | None -> ()
      | Some elapsed ->
        if alive_but_stuck_should_emit ~now ~dedup_ttl_sec entry.name then begin
          let recovery =
            queue_alive_but_stuck_recovery ~base_path ~now ~elapsed
              ~threshold entry
          in
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_alive_but_stuck
            ~labels:[("keeper", entry.name)]
            ();
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_alive_but_stuck_recovery
            ~labels:[("keeper", entry.name); ("outcome", recovery)]
            ();
          Log.Keeper.warn
            "%s: alive-but-stuck detected (elapsed=%.0fs, threshold=%.0fs, \
             autonomous_turns=%d, proactive_count_total=%d, recovery=%s)"
            entry.name elapsed threshold
            entry.meta.runtime.autonomous_turn_count
            entry.meta.runtime.proactive_rt.count_total
            recovery;
          if String.equal recovery "queued" then
            request_alive_but_stuck_recovery ~base_path ~elapsed entry
        end);
      Eio_guard.yield_step abs_ym
    ) entries
  end
