(** Error/failure tracking mutations for {!Keeper_registry}. *)

open Keeper_registry_types

let max_crash_log_entries = 5

let record_crash_entry entry ts msg =
  { entry with
    crash_log =
      List.filteri (fun i _ -> i < max_crash_log_entries) ((ts, msg) :: entry.crash_log)
  }
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
    ; crash_log
    ; last_failure_reason = None
    })
;;
