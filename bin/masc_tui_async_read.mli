(** One source verdict for a raw TUI read error. The caller owns its request
    generation, inflight flag, retry state and mailbox message. *)

type source =
  | Keeper_turns
  | Standalone_lanes
  | Connectors

val attribute : source -> ('a, string) result -> ('a, string) result
(** Add the source label to one raw HTTP, decode or launch failure. Call only
    at the boundary that owns the verdict, before handing it to a renderer. *)

val launch :
  source:source ->
  switch:Eio.Switch.t option ->
  on_sync_failure:(unit -> unit) ->
  deliver:(('a, string) result -> unit) ->
  read:(unit -> ('a, string) result) ->
  unit ->
  unit
(** Use the guarded daemon path for reads whose caller already clears its
    inflight flag on a synchronous launch failure. Both that failure and an
    unavailable switch run [on_sync_failure] before delivering one attributed
    error. An exception raised by [read] becomes a read error; Eio cancellation
    is re-raised without delivery. Successful and failed reads are delivered
    once; the caller decides how its generation and retry state change. *)
