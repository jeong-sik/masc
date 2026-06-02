(** Phantom-typed wrapper for Keeper lifecycle.
    Enforces valid state transitions at compile time.
    See RFC-0005 for the design of typed state machines. *)

type offline
type running
type failing
type completed

type 'state t

(** Create a new, offline keeper handle. *)
val create : name:string -> offline t

(** Start the keeper, transitioning it to the running state. *)
val start : offline t -> running t

(** Run a turn, which may succeed (staying running) or fail. *)
val run_turn :
  running t ->
  (running t, failing t) result

(** Attempt to restart a failing keeper. *)
val restart : failing t -> offline t

(** Stop a keeper from any state, putting it into a terminal completed state. *)
val stop : 'state t -> completed t

(** Extract the underlying keeper name. *)
val name : 'state t -> string
