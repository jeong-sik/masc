(** Runtime_events event registrations for masc-mcp (Wave 2A pilot).

    Registers user event tags/handles and provides a start helper so that
    Olly (or a custom [Runtime_events.Callbacks] consumer) can observe
    both stock OCaml runtime events (GC, phases) and future masc-specific
    turn events.

    This pilot only installs the listener and reserves event handles;
    emit sites will be added in follow-up PRs (worker turn boundary,
    keeper turn boundary). *)

type Runtime_events.User.tag +=
  | Turn_start
  | Turn_end

let ev_turn_start =
  Runtime_events.User.register "masc.turn.start"
    Turn_start Runtime_events.Type.unit

let ev_turn_end =
  Runtime_events.User.register "masc.turn.end"
    Turn_end Runtime_events.Type.unit

let emit_turn_start () = Runtime_events.User.write ev_turn_start ()
let emit_turn_end ()   = Runtime_events.User.write ev_turn_end ()

let start_listener () = Runtime_events.start ()
