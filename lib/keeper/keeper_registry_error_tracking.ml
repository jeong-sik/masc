(** Error/failure tracking mutations for {!Keeper_registry}. *)

open Keeper_registry_types

let max_crash_log_entries = 5

let record_crash_entry entry ts msg =
  { entry with
    crash_log =
      List.filteri (fun i _ -> i < max_crash_log_entries) ((ts, msg) :: entry.crash_log)
  }
;;

let mark_dead ~base_path name ~at ~decr_running_count_clamped ~update_entry =
  (* Same metric is also incremented by transition dispatch via
     [phase_to_string tr.new_phase], which emits lowercase wire format
     ([dead], [running], [handing_off], ...). Route this direct-write path
     through the same SSOT casing so Otel_metric_store consumers do not split the
     time series. *)
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleTransitions)
    ~labels:
      [ "keeper", name
      ; "from_phase", "direct"
      ; "to_phase", Keeper_state_machine.phase_to_string Dead
      ]
    ();
  Log.Keeper.error "registry: marking keeper dead name=%s at=%.0f" name at;
  update_entry ~base_path name (fun entry ->
    if entry.phase <> Dead
    then (
      (* Enumerate every phase so the compiler flags any new variant. Only
         [Running] contributes to [running_count_atomic] in the parent module;
         all other phases were never counted, so transitioning from them must
         not decrement. *)
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
       | Dead -> ());
      let conditions =
        { Keeper_state_machine.default_conditions with
          launch_pending = false
        ; fiber_alive = false
        ; dead_tombstone_latched = true
        }
      in
      let phase = Keeper_state_machine.derive_phase conditions in
      { entry with dead_since_ts = Some at; phase; conditions })
    else
      { entry with dead_since_ts = Some (Option.value ~default:at entry.dead_since_ts) })
;;

let record_restart ~base_path name ~update_entry =
  Log.Keeper.warn "registry: recording restart name=%s" name;
  update_entry ~base_path name (fun e ->
    { e with restart_count = e.restart_count + 1; last_restart_ts = Time_compat.now () })
;;

let set_last_error_entry ~base_path ~name err ~update_entry =
  update_entry ~base_path name (fun e -> { e with last_error = Some err })
;;

let clear_error ~base_path name ~update_entry =
  update_entry ~base_path name (fun e -> { e with last_error = None })
;;

let set_failure_reason ~base_path name reason ~update_entry =
  update_entry ~base_path name (fun e -> { e with last_failure_reason = reason })
;;

let set_last_correlation_id ~base_path name cid ~update_entry =
  update_entry ~base_path name (fun e -> { e with last_event_bus_correlation = Some cid })
;;

let record_crash ~base_path name ts msg ~update_entry =
  Log.Keeper.error "registry: recording crash name=%s msg=%s" name msg;
  update_entry ~base_path name (fun entry -> record_crash_entry entry ts msg)
;;

let restore_supervisor_state
      ~base_path
      name
      ~restart_count
      ~last_restart_ts
      ~crash_log
      ~update_entry
  =
  update_entry ~base_path name (fun e ->
    { e with
      restart_count
    ; last_restart_ts
    ; dead_since_ts = None
    ; crash_log
    ; last_failure_reason = None
    })
;;
