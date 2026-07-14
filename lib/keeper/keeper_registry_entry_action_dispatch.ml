(** Entry-action dispatch observability helpers (RFC-0002).

    Extracted from keeper_registry.ml (lines 1507-1555) as part of the
    godfile decomp campaign. Pure side-effect helpers; no registry state is
    read or written. *)

let execute_observability
      ~(name : string)
      ~(phase : Keeper_state_machine.phase)
      ~(ts_unix : float)
      (action : Keeper_state_machine.entry_action)
  : unit
  =
  match action with
  | Keeper_state_machine.Publish_lifecycle { event_name; detail } ->
    let phase_str = Keeper_state_machine.phase_to_string phase in
    Log.Keeper.emit
      Log.Info
      ~category:Log.Lifecycle
      ~details:
        (`Assoc
          [ "name", `String name
          ; "phase", `String phase_str
          ; "event", `String event_name
          ; "detail", `String detail
          ])
      (Printf.sprintf
         "registry: lifecycle name=%s phase=%s event=%s detail=%s"
         name
         phase_str
         event_name
         detail);
    let (_ignore_ts : float) = ts_unix in
    ()
  | Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart _
  | Mark_dead_tombstone
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_oas -> ()
;;

let followup_event_of_action
      ~(phase : Keeper_state_machine.phase)
      (action : Keeper_state_machine.entry_action)
  : Keeper_state_machine.event option
  =
  let _ = phase, action in
  None
;;

let record_dispatch_rejection event =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleDispatchRejections)
    ~labels:[ "event", Keeper_state_machine.event_to_string event ]
    ()
;;
