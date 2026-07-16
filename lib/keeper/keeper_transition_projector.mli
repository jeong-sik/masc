(** Per-Keeper event-transition outbox projector.

    The durable event queue remains the lifecycle authority.  This actor only
    materializes its ordered outbox into the Reaction Ledger read model and
    retires an entry after the ledger append succeeds. *)

type t

val create : base_path:string -> keeper_name:string -> t
(** Create one lane-owned projector.  The initial wake is pending so durable
    backlog left by an earlier process is retried without a timer. *)

val notify : t -> unit
(** Coalescing, nonblocking wake.  Safe to call on the Keeper control path
    after durable settlement. *)

val stop : t -> unit
(** Ask the actor to stop without discarding durable outbox entries. *)

val run : t -> unit
(** Run until {!stop} or structured cancellation.  Projection failures are
    logged and retained for the next explicit wake.  Production projection
    fails explicitly when the server executor is unavailable; it never falls
    back to blocking file I/O on the Keeper Eio domain. *)

val project_pending :
  base_path:string -> keeper_name:string -> (int, string) result
(** Synchronously project every currently ordered outbox entry.  Returns the
    number retired.  This is exposed for recovery commands and focused tests;
    Keeper heartbeat code must use {!notify}. *)

module For_testing : sig
  val create_with_project :
    base_path:string ->
    keeper_name:string ->
    project:(unit -> (int, string) result) ->
    t
end
