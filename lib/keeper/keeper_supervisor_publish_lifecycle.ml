(** Lifecycle event publisher, extracted from [keeper_supervisor.ml]
    (godfile decomp).

    [publish_lifecycle] is the supervisor's single event-emission
    helper.  It (a) records the event into the per-keeper lifecycle
    audit ring for the dashboard (#12798), and (b) republishes onto
    the cascade event bus when the process-wide MASC event bus is set.

    [publish_phase_lifecycle ~phase] is a thin convenience that
    constructs a [Keeper_lifecycle_events.Phase_event phase] and
    forwards.  The phase IS the wire event name.

    Background — the legacy [publish_lifecycle ?phase event_name]
    (string event_name) and [publish_phase_lifecycle ~phase] surfaces
    were folded into [publish_lifecycle ~event] (#8856 / #8605
    family) so the compiler enforces that every call site picks
    either [Custom_event] (with optional phase context) or
    [Phase_event], eliminating the [~phase:Stopped ~event:"crashed"]
    typo class addressed at runtime by #8572 / #8575. *)

let publish_lifecycle
      ~(event : Keeper_lifecycle_events.lifecycle_event)
      keeper_name
      detail
      ()
  =
  let event_name = Keeper_lifecycle_events.lifecycle_event_to_string event in
  let phase =
    Option.map
      Keeper_state_machine.phase_to_string
      (Keeper_lifecycle_events.lifecycle_event_phase event)
  in
  (* #12798: record in the per-keeper lifecycle audit ring for dashboard. *)
  Keeper_lifecycle_audit.record ~keeper_name ~event_name ~phase ~detail;
  Cascade_events.publish_keeper_lifecycle ~event ~keeper_name ~detail ()
;;

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_phase_lifecycle ~phase keeper_name detail () =
  publish_lifecycle
    ~event:(Keeper_lifecycle_events.Phase_event phase)
    keeper_name
    detail
    ()
;;
