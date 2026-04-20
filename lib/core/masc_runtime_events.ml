(** Runtime_events event registrations for masc-mcp (Wave 2A).

    Registers a user event handle for agent turns and provides a
    start helper so that Olly (or a custom [Runtime_events.Callbacks]
    consumer) can observe both stock OCaml runtime events (GC,
    phases) and masc-specific turn-boundary events.

    The turn event uses [Runtime_events.Type.span] so consumers pair
    [Begin]/[End] bounds natively — no external correlation id is
    required.  Writers always call [emit_turn_start] and
    [emit_turn_end] as a pair (see the [Fun.protect] usage at the
    call sites in [worker_oas] and [keeper_agent_run]). *)

type Runtime_events.User.tag +=
  | Turn

let ev_turn =
  Runtime_events.User.register "masc.turn"
    Turn Runtime_events.Type.span

let emit_turn_start () =
  Runtime_events.User.write ev_turn Runtime_events.Type.Begin

let emit_turn_end () =
  Runtime_events.User.write ev_turn Runtime_events.Type.End

let start_listener () = Runtime_events.start ()
