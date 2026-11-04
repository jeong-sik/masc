(** Says that something a connector status read projects changed: a gateway
    connection state, a ready record, a startup error, a poll state, a
    directory refresh, a binding write or a learned name (RFC-0480 §3.4).

    The connector state modules call {!notify} from the functions that record
    those values. The server installs the observer that announces it; a
    process without one reports nothing. *)

val install : (unit -> unit) -> unit
(** The observer must not yield and must not raise: it runs inside the
    recording functions, some under a store lock. *)

val notify : unit -> unit
