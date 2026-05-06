(** Silent-failure wrapper for [try ... with _ -> ()] anti-patterns.

    The masc-mcp codebase has accumulated several "P1/P2 silent-failure
    fix" comments where IO/network/cancel-adjacent failures were
    silently swallowed and only a counter incremented.  This module
    provides a typed alternative so the choice between {b silently
    ignore} and {b log + return Error} is made explicitly at the call
    site.

    Step 0b of the bloodflow restoration plan introduces only the
    module itself; caller-site adoption (rewriting individual
    [try ... with _ -> ()] sites) is left to subsequent stacked PRs. *)

val observe_or_fail :
  kind:string ->
  ?keeper_name:string ->
  (unit -> 'a) ->
  ('a, string) result
(** [observe_or_fail ~kind f] runs [f ()] and returns its [Ok]
    result.  On any exception other than [Eio.Cancel.Cancelled],
    emits a structured warn log tagged with [kind] (and
    [keeper_name] if supplied) and returns [Error msg].

    [Cancelled] is re-raised so cooperative-cancel semantics are
    preserved — Step 5 (Cancelled swallow removal) depends on this. *)

val observe_silent :
  kind:string ->
  (unit -> unit) ->
  unit
(** [observe_silent ~kind f] runs [f ()] and absorbs any exception
    other than [Eio.Cancel.Cancelled] without emitting another log line.

    Use only for caller contracts that must remain fully non-throwing
    even when the logging/telemetry backend is the failing component.
    The [kind] label is still required at call sites so silent usage
    remains explicit in reviews. *)

val observe_or_default :
  kind:string ->
  ?keeper_name:string ->
  default:'a ->
  (unit -> 'a) ->
  'a
(** [observe_or_default ~kind ~default f] runs [f ()] and returns
    its result, or [default] on exception while emitting a
    structured log.  For call sites that genuinely need a
    value-returning silent fall-back but want the failure surfaced
    in observability. *)
