(** Says that a row landed in a workspace's cost ledger.

    {!Keeper_hooks_agent_core_cost_events.emit_cost_event} is the only writer
    of cost rows and calls {!appended} once the row is in the file. The
    runtime history reads the ledger, so the server installs an observer that
    announces [runtime_metrics] when the ledger is its own workspace's.

    The observer runs on the writer's fiber, after the write. It must be
    short and must not raise. *)

val install : (masc_root:string -> unit) -> unit
val appended : masc_root:string -> unit
