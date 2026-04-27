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

let should_cleanup_dead ~now ~dead_ttl_sec
    (entry : Keeper_registry.registry_entry) =
  match entry.phase, entry.dead_since_ts with
  | Keeper_state_machine.Dead, Some dead_since ->
      now -. dead_since >= dead_ttl_sec
  | _ -> false

(** Check if a paused keeper meta file on disk is stale enough to remove. *)
let is_stale_paused_meta ~now ~paused_ttl_sec (meta : keeper_meta) =
  if not meta.paused then false
  else
    let updated_ts =
      Resilience.Time.parse_iso8601_opt meta.updated_at
      |> Option.value ~default:0.0
    in
    updated_ts > 0.0 && now -. updated_ts >= paused_ttl_sec

let paused_meta_requires_reconcile_recovery (meta : keeper_meta) =
  meta.paused
  && (match meta.runtime.last_blocker_class with
      | Some Ambiguous_post_commit_timeout | Some Ambiguous_post_commit_failure ->
          true
      | None ->
          (match Keeper_status_bridge.blocker_class_of_string
                  meta.runtime.last_blocker with
           | Some Ambiguous_post_commit_timeout
           | Some Ambiguous_post_commit_failure -> true
           | _ -> false)
      | _ -> false)

let committed_tools_of_ambiguous_blocker (blocker : string) =
  let trimmed = String.trim blocker in
  (* Try structured JSON extraction first (new masc_internal_error format) *)
  if String.starts_with ~prefix:"[masc_oas_error]" trimmed then
    let payload =
      String.sub trimmed
        (String.length "[masc_oas_error]")
        (String.length trimmed - String.length "[masc_oas_error]")
    in
    (try
       match Yojson.Safe.from_string payload with
       | `Assoc fields ->
           (match List.assoc_opt "tools" fields with
            | Some (`List values) ->
                values
                |> List.filter_map (function
                     | `String value -> Some value
                     | _ -> None)
            | _ -> [])
       | _ -> []
     with Yojson.Json_error _ -> [])
  else
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
  match Keeper_keepalive.get_bus () with
  | Some bus ->
      Oas_events.publish_keeper_lifecycle bus ~event ~keeper_name ~detail ()
  | None -> ()

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_phase_lifecycle ~phase keeper_name detail () =
  publish_lifecycle ~event:(Keeper_lifecycle_events.Phase_event phase)
    keeper_name detail ()

(* ── Stale-turn watchdog (delegated to Keeper_stale_watchdog) ── *)

let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog

(* ── Supervised fiber launch ─────────────────────────────── *)

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
         (Keeper_state_machine.transition_error_to_string err));
  fork_stale_watchdog ctx meta reg;
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let resolved = ref false in
    let resolve_done value =
      if not !resolved && Option.is_none (Eio.Promise.peek reg.done_p) then begin
        resolved := true;
        Eio.Promise.resolve reg.done_r value;
        true
      end else
        false
    in
    Fun.protect
      (fun () ->
        (try
           Keeper_keepalive.run_heartbeat_loop ~proactive_warmup_sec
             ctx meta reg.fiber_stop ~wakeup:reg.fiber_wakeup;
           (* Check if watchdog set a failure reason that should trigger
              crash recovery instead of a clean stop. When the stale
              watchdog sets fiber_stop + Stale_turn_timeout, the heartbeat
              loop exits normally but the supervisor must treat this as a
              crash so sweep_and_recover restarts the keeper. *)
           let watchdog_triggered =
             match Keeper_registry.get ~base_path meta.name with
             | Some e -> (
                 match e.last_failure_reason with
                 | Some (Keeper_registry.Stale_turn_timeout _) -> true
                 | _ -> false)
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
                  Log.Keeper.warn "supervisor: Stop_requested dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
             (match Keeper_registry.dispatch_event ~base_path meta.name
                Keeper_state_machine.Drain_complete with
              | Ok _ -> ()
              | Error e ->
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
              let ts = Time_compat.now () in
              Keeper_registry.record_crash ~base_path
                meta.name ts reason;
              let rc = match Keeper_registry.get ~base_path meta.name with
                | Some e -> e.restart_count | None -> 0 in
              Keeper_crash_persistence.enqueue_record ~keepers_dir
                ~name:meta.name ~ts ~reason ~restart_count:rc;
              Keeper_registry.record_error ~base_path meta.name reason;
              ignore (Keeper_registry.dispatch_event ~base_path meta.name
                (Keeper_state_machine.Fiber_terminated { outcome = reason }));
              if resolve_done (`Crashed reason) then
                publish_phase_lifecycle ~phase:Keeper_state_machine.Crashed
                  meta.name reason ()
            end
          end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "%s: supervisor finally cleanup failed (suppressed to avoid Fun.Finally_raised): %s"
            meta.name (Printexc.to_string exn)))

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context)
    (meta : keeper_meta) =
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path meta.name
  then ()
  else if not (Keeper_registry.spawn_slots_available ()) then ()
  else begin
    (* Register in Keeper_registry — single source of truth. *)
    let reg =
      Keeper_registry.register_offline ~base_path:ctx.config.base_path meta.name meta
    in
    (* Coord initialization *)
    (try
       if not (Coord_utils.is_initialized ctx.config) then
         let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in ()
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Keeper.error "supervisor room init failed: %s"
         (Printexc.to_string exn));
    let live_meta =
      try
        let synced = ensure_keeper_room_presence ctx.config meta in
        (match write_meta ctx.config synced with
         | Ok () -> ()
         | Error msg ->
           Log.Keeper.warn
             "supervisor presence sync: write_meta failed for %s: %s"
             meta.name msg);
        synced
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
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
          last_blocker = "";
          last_blocker_class = None;
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
       Log.Keeper.warn
         "%s: reconcile gate resume write_meta lost CAS race after retries: %s"
         resumed_meta.name err
   | Error err ->
       Log.Keeper.error
         "%s: reconcile gate resume write_meta failed: %s"
         resumed_meta.name err);
  Keeper_registry.update_meta ~base_path:ctx.config.base_path resumed_meta.name
    resumed_meta;
  Keeper_registry.set_failure_reason ~base_path:ctx.config.base_path
    resumed_meta.name None;
  Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path
    resumed_meta.name;
  ignore
    (Keeper_registry.dispatch_event ~base_path:ctx.config.base_path
       resumed_meta.name Keeper_state_machine.Operator_resume);
  match Keeper_registry.get ~base_path:ctx.config.base_path resumed_meta.name with
  | Some entry when Option.is_none (Eio.Promise.peek entry.done_p) ->
      Atomic.set entry.fiber_wakeup true
  | Some _ ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path
        resumed_meta.name;
      supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
  | None -> supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta

let restore_reconcile_continue_gate (ctx : _ context) (meta : keeper_meta) =
  let blocker = String.trim meta.runtime.last_blocker in
  let committed_tools = committed_tools_of_ambiguous_blocker blocker in
  let failure_reason =
    match meta.runtime.last_blocker_class with
    | Some Ambiguous_post_commit_timeout ->
        "ambiguous_partial_commit(post_commit_timeout)"
    | Some Ambiguous_post_commit_failure ->
        "ambiguous_partial_commit(post_commit_failure)"
    | None ->
        (match Keeper_status_bridge.blocker_class_of_string blocker with
         | Some Ambiguous_post_commit_timeout ->
             "ambiguous_partial_commit(post_commit_timeout)"
         | Some Ambiguous_post_commit_failure ->
             "ambiguous_partial_commit(post_commit_failure)"
         | Some _ -> "ambiguous_partial_commit(post_commit_failure)"
         | None -> "ambiguous_partial_commit(post_commit_failure)")
    | Some _ -> "ambiguous_partial_commit(post_commit_failure)"
  in
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
      ~on_resolution:(fun decision ->
        match decision with
        | Oas.Hooks.Approve
        | Oas.Hooks.Edit _ ->
            resume_keeper_after_reconcile_gate ctx meta;
            Log.Keeper.info
              "%s: restored reconcile continue gate approved; keeper resumed"
              meta.name
        | Oas.Hooks.Reject reason ->
            Log.Keeper.warn
              "%s: restored reconcile continue gate rejected; keeper remains paused (%s)"
              meta.name reason)
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
  Log.Keeper.info "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  List.iter (fun name ->
         match read_meta ctx.config name with
         | Ok (Some meta) when not meta.paused ->
             let dominated_by_sweep =
               match Keeper_registry.get ~base_path meta.name with
               | None -> false  (* no entry = orphaned, reconcile OK *)
               | Some e ->
                 match e.phase with
                 | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
                 | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> true
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
             Log.Keeper.debug "reconcile: read_meta failed for %s: %s" name err)
    names;
  Log.Keeper.info "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
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
              Log.Keeper.warn
                "%s: dead tombstone cleanup paused write lost CAS race after retries: %s"
                entry.name err;
              false
          | Error err ->
              Log.Keeper.warn
                "%s: dead tombstone cleanup paused write failed: %s"
                entry.name err;
              false
      in
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
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
        Log.Keeper.warn "%s: dead tombstone unregistered despite meta write failure" entry.name
      end
  | Ok None ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      publish_lifecycle
        ~event:(Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name "meta missing" ();
      Log.Keeper.warn "%s: dead tombstone unregistered (meta missing)" entry.name
  | Error err ->
      Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
      publish_lifecycle
        ~event:(Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        (Printf.sprintf "meta read error: %s" err) ();
      Log.Keeper.warn "%s: dead tombstone unregistered (meta error: %s)"
        entry.name err

(** Cohort key from structured failure_reason ADT.
    #10584: delegates to [Keeper_registry.failure_reason_cohort_key] so a
    new variant in keeper_registry forces a same-PR converter update via
    the source module's exhaustive-match check, instead of breaking main
    here on first build (the recurring P0 pattern from #10490 + #10574). *)
let cohort_key_of_reason = Keeper_registry.failure_reason_cohort_key

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

(** Reset the escape-valve state.  Test-only; production code never
    needs to call this (state cycles through the [last_dominant_cohort]
    inequality branch naturally). *)
let reset_self_preservation_escape_state () =
  sp_escape_state.last_dominant_cohort <- "";
  sp_escape_state.consecutive_suppressions <- 0

(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count.
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
           if ratio >= 0.99 then
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
    end else begin
      (* Dominant cohort below sp_min — no suppression this cycle,
         so the streak no longer applies to this cohort. *)
      reset_self_preservation_escape_state ();
      to_restart
    end
  end else begin
    (* No suppression: streak resets. *)
    reset_self_preservation_escape_state ();
    to_restart
  end

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts = Runtime_params.get Governance_registry.keeper_supervisor_max_restarts in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* Phase 2: sweep order — restart/unregister FIRST, reconcile LAST.
     This prevents reconcile from re-launching keepers that sweep is about
     to process (defense-in-depth alongside is_registered check). *)
  let entries = Keeper_registry.all ~base_path () in
  let to_restart = ref [] in
  let to_unregister = ref [] in
  let to_mark_dead = ref [] in
  let to_cleanup_dead = ref [] in
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    match entry.phase with
    | Keeper_state_machine.Dead ->
        (match entry.dead_since_ts with
         | Some dead_since when now -. dead_since >= dead_ttl_sec ->
             to_cleanup_dead := entry :: !to_cleanup_dead
         | _ -> ())
    | Keeper_state_machine.Stopped ->
        to_unregister := entry :: !to_unregister
    | Keeper_state_machine.Running | Keeper_state_machine.Paused
    | Keeper_state_machine.Crashed
    | Keeper_state_machine.Failing | Keeper_state_machine.Overflowed
    | Keeper_state_machine.Compacting
    | Keeper_state_machine.HandingOff | Keeper_state_machine.Draining
    | Keeper_state_machine.Restarting | Keeper_state_machine.Offline ->
      (match Eio.Promise.peek entry.done_p with
      | None when entry.phase = Keeper_state_machine.Stopped ->
          to_unregister := entry :: !to_unregister
      | None -> ()  (* Alive — skip *)
      | Some `Stopped ->
          to_unregister := entry :: !to_unregister
      | Some (`Crashed msg) ->
          if entry.restart_count >= max_restarts then
            to_mark_dead := (entry, msg) :: !to_mark_dead
          else begin
            let delay = backoff_delay entry.restart_count in
            if now -. entry.last_restart_ts >= delay then
              to_restart := (entry, msg) :: !to_restart
          end)
  ) entries;
  List.iter (fun (entry : Keeper_registry.registry_entry) ->
    Keeper_registry.unregister ~base_path entry.name
  ) !to_unregister;
  List.iter (fun ((entry : Keeper_registry.registry_entry), msg) ->
    (* RFC-0002: dispatch budget exhaustion before marking dead *)
    ignore (Keeper_registry.dispatch_event ~base_path entry.name
      Keeper_state_machine.Restart_budget_exhausted);
    Keeper_registry.mark_dead ~base_path entry.name ~at:now;
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
         Oas_events.publish_keeper_dead bus
           ~keeper_name:entry.name
           ~reason:msg
           ~restart_count:entry.restart_count
           ~last_failure_reason:last_fr_str
           ()
     | None -> ());
    Prometheus.inc_counter Prometheus.metric_keeper_dead_total
      ~labels:[
        ("keeper", entry.name);
        ("reason", Option.value last_fr_str ~default:"unknown");
      ] ();
    Log.Keeper.error
      "keeper DEAD (max_restarts exhausted): name=%s reason=%s \
       restart_count=%d — operator action required"
      entry.name msg entry.restart_count
  ) !to_mark_dead;
  List.iter (cleanup_dead_tombstone ctx) !to_cleanup_dead;
  let active_count =
    List_util.count_if (fun (e : Keeper_registry.registry_entry) ->
      e.phase = Keeper_state_machine.Running || e.phase = Keeper_state_machine.Crashed
    ) entries in
  let restart_list =
    let keepers_dir =
      Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count !to_restart in
  (* Restart crashed keepers *)
  List.iter (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
    match read_meta ctx.config old_entry.name with
    | Ok (Some meta) ->
        let attempt = old_entry.restart_count + 1 in
        (* RFC-0002: dispatch restart attempt event *)
        ignore (Keeper_registry.dispatch_event ~base_path old_entry.name
          (Keeper_state_machine.Supervisor_restart_attempt { attempt }));
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
        Log.Keeper.info "%s: restarted (attempt %d, backoff %.0fs)"
          old_entry.name attempt (backoff_delay (attempt - 1));
        (* Soft pre-warning when this is the FINAL allowed restart: next
           crash will trip the budget and mark Dead. Operator-actionable
           but not yet a fault — investigate root cause now. *)
        if attempt >= max_restarts then begin
          Log.Keeper.warn
            "keeper near-exhaustion: name=%s restart=%d/%d — investigate"
            old_entry.name attempt max_restarts;
          Prometheus.inc_counter Prometheus.metric_keeper_near_exhaustion_total
            ~labels:[("keeper", old_entry.name)] ()
        end
    | _ ->
        Log.Keeper.error "%s: cannot read meta for restart, removing"
          old_entry.name;
        Keeper_registry.unregister ~base_path old_entry.name
  ) restart_list;
  (* Phase 2: restore paused reconcile gates whose approval queue was lost
     on restart. The queue itself is in-memory, but paused keeper meta is
     durable, so rebuild the human gate from persisted blocker evidence. *)
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         match read_meta ctx.config name with
         | Ok (Some meta)
           when paused_meta_requires_reconcile_recovery meta
                && not
                     (Keeper_approval_queue.has_pending_for_keeper
                        ~keeper_name:meta.name) ->
             restore_reconcile_continue_gate ctx meta
         | _ -> ());
  (* Phase 3: prune stale paused keeper meta files from disk. Keep
     reconcile-recovery pauses until the operator explicitly resolves them. *)
  let paused_ttl_sec = Env_config.KeeperSupervisor.paused_cleanup_ttl_sec in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
         if Keeper_registry.is_running ~base_path name then ()
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
                    name (Printexc.to_string exn))
           | _ -> ());
  (* Phase 4: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx
