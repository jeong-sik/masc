(** One launch for every TUI read that runs off the render loop, and one
    source verdict for its failure.

    A read answers exactly once, on [deliver], with either what it loaded
    ([Ok]) or why it did not ([Error cause]). The cause is one of: the read's
    own HTTP or decode error, an exception the read raised, the Eio switch
    being absent, or the daemon launch being refused synchronously (a
    finished switch, see {!Masc_tui_fork_guard.launch}). Cancellation is
    re-raised, never delivered: the only switch a read runs on is the TUI's
    root switch (set once at startup), which is cancelled only when the TUI
    exits, so no pane is left "loading" by it.

    The caller owns its request generation, inflight flag, retry state and
    mailbox message. *)

type source =
  | Keeper_turns
  | Standalone_lanes
  | Connectors
  | Keeper_schedule
  | Resource_read
(** A read whose failures this boundary names. Its loader and decoder return
    the bare cause; the label is rendered from the constructor here and
    nowhere else. *)

val attribute : source -> ('a, string) result -> ('a, string) result
(** Add the source to one raw HTTP, decode or launch failure. Most reads say
    ["<source> load failed: <cause>"]. A resource read says
    ["resource read: <cause>"] because the HTTP or MCP cause already names its
    failure. Call only at the boundary that owns the context, before handing
    it to a renderer. *)

val launch :
  ?source:source ->
  ?on_not_run:(unit -> unit) ->
  deliver:(('a, string) result -> unit) ->
  (unit -> ('a, string) result) ->
  unit
(** Launch [read] on the current Eio switch and deliver its one answer.

    [source], when given, labels every cause exactly once with {!attribute}.
    A read whose loader still labels its own errors passes no source, so no
    failure is labelled twice.

    [on_not_run] runs before the error is delivered when the read never
    started (no switch, or a refused launch): the caller releases whatever
    it armed before launching -- an inflight flag, a slot -- so the pane
    cannot stay "loading" forever. A read that did start releases through
    its delivered message instead. *)
