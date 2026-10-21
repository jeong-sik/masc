type request = private {
  token : unit ref;
  base_path : string;
  keeper : Keeper_id.Keeper_name.t;
}
type outcome =
  | Saved of Runtime.config_durability
  | Refused of string
  | Unobserved of string
  | Not_started of string
type completion = private { request : request; outcome : outcome }
type t

val create : unit -> t
val same_request : request -> request -> bool
val submit : t -> sw:Eio.Switch.t option -> base_path:string -> Keeper_id.Keeper_name.t -> request
(** Admit one immutable explicit visit. One session writer preserves FIFO order;
    each effect reads current file text under Runtime's existing shared lock.
    No switch produces a retained not-started outcome, without inline I/O. *)
val drain_completed : t -> can_take:(unit -> bool) -> apply:(completion -> unit) -> unit
(** Apply a finite prefix of owned results, rechecking admission between results,
    without a bounded mailbox write.
    Queue/control methods run on the session's Eio domain; workers only read
    immutable requests. *)
val close : t -> unit
(** Stop admission and await the active session writer. Called before the UI's
    Break leaves its switch. Graceful draining assumes each config operation
    settles; it has no bounded-shutdown guarantee. A permanently blocked config
    lock/storage operation leaves close waiting in Closing and prevents normal
    exit. It does not fabricate Saved, Unobserved or Not_started for that active
    effect. Cancellation of this caller is deferred while awaiting the writer.
    Cancellation reaching the writer retains an unknown active outcome and
    not-started queued outcomes only after its actual submission settles; a
    blocked/protected effect may delay that too. No timeout or replay. *)
