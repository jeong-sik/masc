(** Splitting reasoning a provider embeds in the content channel.

    Some models answer on two channels at once: part of the reasoning arrives
    in the response's own reasoning field, and part arrives inside the reply
    text wrapped in [<think>...</think>]. Nothing read the second kind, so it
    reached the chat pane as speech. Measured on the live fleet: of 85 text
    blocks carrying this model's replies, 46 opened with reasoning, and
    stripping it left a real answer of 338 characters at the median.

    This is declared per model through [content_inline_reasoning], never
    applied to text on suspicion. A model that does not declare it keeps every
    byte of its content channel. *)

type state
type snapshot

val snapshot : state -> snapshot
(** Immutable capture of the current channel and held tag-prefix bytes. *)

val restore : state -> snapshot -> unit
(** Restore a captured parser state after its projected chunk is rejected.
    Snapshots may be reused and are not mutated by subsequent feeds. *)

val create : unit -> state

val inside : state -> bool
(** [true] while the stream sits between an open and a close tag. *)

type segment = Text of string | Reasoning of string

val feed_segments : state -> string -> segment list
(** Ordered, nonempty typed segments. Tag fragments are retained across calls.
    Adjacent same-channel segments may span transport deltas; their bytes and
    channel order do not depend on delta partitioning. *)

val flush_segments : state -> segment list
(** Release pending bytes in their current channel, exactly once. *)
