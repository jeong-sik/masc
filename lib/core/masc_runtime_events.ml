(** Runtime_events event registrations for masc (Wave 2A).

    Registers a user event handle for agent turns and provides a
    start helper so that Olly (or a custom [Runtime_events.Callbacks]
    consumer) can observe both stock OCaml runtime events (GC,
    phases) and masc-specific turn-boundary events.

    The turn event uses [Runtime_events.Type.span] so consumers pair
    [Begin]/[End] bounds natively — no external correlation id is
    required.  Writers bracket the turn body with [with_turn_span] so
    the [Begin]/[End] pair cannot drift apart; [keeper_agent_run]
    keeps a manual pair because its finally is a composite (phase
    event + cancel-ref bookkeeping), not a bare [emit_turn_end]. *)

type Runtime_events.User.tag +=
  | Turn

let ev_turn =
  Runtime_events.User.register "masc.turn"
    Turn Runtime_events.Type.span

let emit_turn_start () =
  Runtime_events.User.write ev_turn Runtime_events.Type.Begin

let emit_turn_end () =
  Runtime_events.User.write ev_turn Runtime_events.Type.End

let with_turn_span f =
  emit_turn_start ();
  Eio_guard.protect ~finally:emit_turn_end f

let runtime_events_enabled () =
  Safe_ops.get_env_bool_logged "MASC_RUNTIME_EVENTS" ~default:true

let start_listener () =
  if runtime_events_enabled () then Runtime_events.start ()
