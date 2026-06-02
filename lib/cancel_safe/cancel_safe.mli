(** Cancel-safe try-with discipline. RFC-0106.

    Catch-all handlers ([try ... with | exn -> ...]) silently absorb
    [Eio.Cancel.Cancelled] which must propagate to the surrounding
    switch for proper fiber tree unwind. These combinators are the
    SSOT site that re-raises Cancelled; everything else flows through
    [on_exn]. *)

val protect : on_exn:(exn -> 'a) -> (unit -> 'a) -> 'a
(** [protect ~on_exn f] runs [f ()] and re-raises [Eio.Cancel.Cancelled]
    verbatim. Any other exception is passed to [on_exn], whose return
    value becomes the result of the [protect] call.

    Use this when the failure path must produce a value (record an
    outcome, return a default, lift to [Result], etc.). [on_exn] must
    not re-raise the [exn] argument unchanged — that would defeat the
    purpose of using a combinator. To re-raise selectively, match on
    the exception inside [on_exn] and raise as needed. *)

val observe : on_exn:(exn -> unit) -> (unit -> unit) -> unit
(** [observe ~on_exn f] is [protect ~on_exn f] specialised for callbacks
    whose result is [unit]. Typical use: lifecycle observers that must
    record a failure but continue the surrounding workflow. *)
