(** Pure state machine for assembling provider stream events.

    The transport shell owns the current snapshot. This module only resolves a
    typed event into a new immutable snapshot and projects a terminal receipt;
    it performs no I/O, logging, clock access, or synchronization. *)

type t

type receipt =
  | Completed of Types.api_response
  | Failed of Types.stream_error

(** Empty stream state. *)
val empty : t

(** [transition state event] returns the next immutable snapshot. The first
    terminal stream failure is sticky: later events cannot mutate or replace
    it. *)
val transition : t -> Types.sse_event -> t

(** Whether a typed provider or wire failure has been captured. *)
val has_failed : t -> bool

(** Resolve the accumulated state into one typed terminal receipt. Missing
    stop semantics and malformed content remain distinct failures. *)
val finalize : t -> receipt
