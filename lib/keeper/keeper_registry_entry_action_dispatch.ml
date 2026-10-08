(** Entry-action observability (RFC-0002): the lifecycle log line the
    registry writes on phase entry. No registry state is read or written. *)

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
;;
