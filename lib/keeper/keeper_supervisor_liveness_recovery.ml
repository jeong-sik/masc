(** Dead-keeper liveness recovery scan. *)

open Keeper_types
open Keeper_execution
open Keeper_supervisor_types

type state =
  { mutable attempt_count : int
  ; mutable last_attempt_ts : float
  }

let table : (string, state) Hashtbl.t = Hashtbl.create 4
let table_mu = Eio.Mutex.create ()

let get_or_create_state name =
  Eio.Mutex.use_rw ~protect:true table_mu (fun () ->
    match Hashtbl.find_opt table name with
    | Some state -> state
    | None ->
      let state = { attempt_count = 0; last_attempt_ts = 0.0 } in
      Hashtbl.replace table name state;
      state)
;;

type credential_recovery_outcome =
  | Credential_recovery_not_needed
  | Credential_recovery_reissued of string
  | Credential_recovery_failed of string

let has_prefix s prefix =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.equal (String.sub s 0 prefix_len) prefix
;;

let has_suffix s suffix =
  let suffix_len = String.length suffix in
  let len = String.length s in
  len >= suffix_len && String.equal (String.sub s (len - suffix_len) suffix_len) suffix
;;

let canonical_keeper_agent_name name =
  if has_prefix name "keeper-" && has_suffix name "-agent"
  then name
  else Keeper_types_profile.keeper_agent_name name
;;

let credential_recovery_before_restart ~base_path
      (entry : Keeper_registry.registry_entry)
  =
  if not entry.conditions.credential_archived
  then Credential_recovery_not_needed
  else (
    let agent_name = canonical_keeper_agent_name entry.name in
    match Auth.ensure_keeper_credential base_path ~agent_name with
    | Ok _ -> Credential_recovery_reissued agent_name
    | Error err -> Credential_recovery_failed (Masc_domain.masc_error_to_string err))
;;

let credential_recovery_before_restart_for_test = credential_recovery_before_restart

let bump_state ~now state =
  Eio.Mutex.use_rw ~protect:true table_mu (fun () ->
    state.attempt_count <- state.attempt_count + 1;
    state.last_attempt_ts <- now)
;;

let scan ~supervise_keepalive ~publish_lifecycle (ctx : _ context) =
  if not Env_config.KeeperSupervisor.liveness_recovery_enabled
  then ()
  else (
    let now = Time_compat.now () in
    let base_path = ctx.config.base_path in
    let max_attempts = Env_config.KeeperSupervisor.liveness_recovery_max_attempts in
    let entries = Keeper_registry.all ~base_path () in
    let liveness_ym = Eio_guard.create_yield_meter () in
    List.iter
      (fun (entry : Keeper_registry.registry_entry) ->
         if not (should_attempt_liveness_recovery ~now entry)
         then ()
         else (
           let state = get_or_create_state entry.name in
           if state.attempt_count >= max_attempts
           then
             Log.Keeper.debug
               "%s: liveness recovery budget exhausted (%d/%d attempts)"
               entry.name
               state.attempt_count
               max_attempts
           else (
             let backoff = liveness_recovery_backoff state.attempt_count in
             if now -. state.last_attempt_ts < backoff
             then ()
             else (
               let dead_secs = now -. Option.value ~default:now entry.dead_since_ts in
               Log.Keeper.warn
                 "%s: liveness recovery attempt %d/%d (dead_for=%.0fs, backoff=%.0fs)"
                 entry.name
                 (state.attempt_count + 1)
                 max_attempts
                 dead_secs
                 backoff;
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_liveness_recovery_attempts
                 ~labels:[ "keeper", entry.name ]
                 ();
               let credential_recovered =
                 match credential_recovery_before_restart ~base_path entry with
                 | Credential_recovery_failed reason ->
                   bump_state ~now state;
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                     ~labels:
                       [ "keeper", entry.name; "outcome", "credential_reissue_failed" ]
                     ();
                   Log.Keeper.error
                     "%s: liveness recovery credential self-heal failed: %s"
                     entry.name
                     reason;
                   false
                 | Credential_recovery_not_needed -> true
                 | Credential_recovery_reissued agent_name ->
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                     ~labels:[ "keeper", entry.name; "outcome", "credential_reissued" ]
                     ();
                   Log.Keeper.warn
                     "%s: credential_archived self-healed via %s; relaunching keeper"
                     entry.name
                     agent_name;
                   true
               in
               if credential_recovered
               then (
                 Keeper_registry.unregister ~base_path entry.name;
                 Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
                 Keeper_stay_silent_loop_detector.reset ~keeper_name:entry.name;
                 Keeper_passive_loop_detector.reset ~keeper_name:entry.name;
                 match read_meta ctx.config entry.name with
                 | Ok (Some meta) ->
                   let recovery_meta =
                     { meta with
                       paused = false
                     ; auto_resume_after_sec = None
                     ; updated_at = now_iso ()
                     ; runtime = { meta.runtime with last_blocker = None }
                     }
                   in
                   (match
                      write_meta_with_merge
                        ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                        ctx.config
                        recovery_meta
                    with
                    | Ok () ->
                      supervise_keepalive ~proactive_warmup_sec:0 ctx recovery_meta;
                      bump_state ~now state;
                      if Keeper_registry.is_running ~base_path entry.name
                      then (
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                          ~labels:[ "keeper", entry.name; "outcome", "started" ]
                          ();
                        publish_lifecycle
                          ~event:
                            (Keeper_lifecycle_events.Custom_event
                               { verb = Keeper_lifecycle_events.Restarted
                               ; phase = Some Keeper_state_machine.Running
                               })
                          entry.name
                          (Printf.sprintf
                             "liveness recovery attempt %d"
                             state.attempt_count)
                          ();
                        Log.Keeper.warn
                          "%s: liveness recovery SUCCESS (attempt %d/%d)"
                          entry.name
                          state.attempt_count
                          max_attempts)
                      else (
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                          ~labels:[ "keeper", entry.name; "outcome", "not_running" ]
                          ();
                        Log.Keeper.error
                          "%s: liveness recovery: keeper not in Running state after \
                           relaunch (attempt %d/%d)"
                          entry.name
                          state.attempt_count
                          max_attempts)
                    | Error err ->
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                        ~labels:[ "keeper", entry.name; "outcome", "meta_write_failed" ]
                        ();
                      Log.Keeper.error
                        "%s: liveness recovery meta write failed: %s"
                        entry.name
                        err)
                 | Ok None ->
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                     ~labels:[ "keeper", entry.name; "outcome", "meta_missing" ]
                     ();
                   Log.Keeper.error "%s: liveness recovery: meta file missing" entry.name
                 | Error err ->
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_liveness_recovery_outcomes
                     ~labels:[ "keeper", entry.name; "outcome", "meta_read_failed" ]
                     ();
                   Log.Keeper.error
                     "%s: liveness recovery read_meta failed: %s"
                     entry.name
                     err))));
         Eio_guard.yield_step liveness_ym)
      entries)
;;
