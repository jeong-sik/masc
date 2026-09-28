(** How the fleet scan grades the fleet, as it reports it in [status].

    The server writes the wire name; the terminal client and the runtime-info
    reader read it back through {!of_wire_name}, so no reader keeps its own
    copy. The dashboard accepts exactly these three words. *)

type t =
  | Fleet_ok  (** Nothing the scan checks holds. *)
  | Fleet_degraded
      (** Keepers can still take turns, but something the scan checks holds:
          a turn configuration error, a session that needs recovery, turn
          capacity below target, a task owner without a fiber, or a backlog
          read that fell back. *)
  | Fleet_blocked
      (** No keeper can take a turn, or every target keeper waits on the
          operator. *)

val all : t list
(** Every value, once each. *)

val wire_name : t -> string

val of_wire_name : string -> t option
(** The exact wire name only. [None] for any other word -- a newer server's
    grade, or a spelling the dashboard would also refuse. *)
