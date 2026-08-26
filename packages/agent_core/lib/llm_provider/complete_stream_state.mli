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

(** Assembly-only compatibility API. [transition state event] returns the next
    immutable snapshot, but callers projecting live events must use
    {!transition_with_resolution}. The first terminal stream failure is sticky:
    later events cannot mutate or replace it. *)
val transition : t -> Types.sse_event -> t

(** Resolve one raw event against the canonical state.
    [Types.Stream_event_accepted] carries the
    exact event downstream consumers must project; an explicitly typed
    [TextSnapshot] may become its unseen [TextDelta] suffix.
    [Types.Stream_event_suppressed] means the raw event must not be projected
    (an exact/older typed snapshot replay, or input after a sticky failure).
    [Types.Stream_event_rejected] carries the first sticky typed failure.
    Ordinary [TextDelta] values always append. *)
val transition_with_resolution
  :  t
  -> Types.sse_event
  -> t * Types.stream_event_resolution

(** Whether a typed provider or wire failure has been captured. *)
val has_failed : t -> bool

(** The first captured typed failure, when present. *)
val failure : t -> Types.stream_error option

(** Resolve the accumulated state into one typed terminal receipt. Missing
    stop semantics and malformed content remain distinct failures. *)
val finalize : t -> receipt
