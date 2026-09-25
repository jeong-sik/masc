(** One launch for every TUI read that runs off the render loop.

    A read answers exactly once, on [deliver], with either what it loaded
    ([Ok]) or why it did not ([Error cause]). The cause is one of: the read's
    own error, an exception the read raised, the Eio switch being absent, or
    the daemon launch being refused synchronously (a finished switch, see
    {!Masc_tui_fork_guard.launch}). Cancellation is re-raised, never
    delivered.

    [subject], when given, labels every cause exactly once at this boundary
    as ["<subject> load failed: <cause>"]. A read whose loader already
    labels its own errors passes no subject, so no failure is ever labelled
    twice.

    [on_not_run] runs before the error is delivered when the read never
    started (no switch, or a refused launch): the caller releases whatever it
    armed before launching -- an inflight flag, a slot -- so the pane cannot
    stay "loading" forever. A read that did start releases through its
    delivered message instead. *)
val launch :
  ?on_not_run:(unit -> unit) ->
  ?subject:string ->
  deliver:(('a, string) result -> unit) ->
  (unit -> ('a, string) result) ->
  unit
