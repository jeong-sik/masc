(** Splitting reasoning a provider embeds in the content channel.

    Some models answer on two channels at once: part of the reasoning arrives
    in the response's own reasoning field, and part arrives inside the reply
    text wrapped in [<think>...</think>]. Nothing read the second kind, so it
    reached the chat pane as speech. Measured on the live fleet: of 85 text
    blocks carrying this model's replies, 46 opened with reasoning, and
    stripping it left a real answer of 338 characters at the median.

    This is declared per model through [reasoning_streaming_format], never
    applied to text on suspicion. A model that does not declare it keeps every
    byte of its content channel. *)

type state

val create : unit -> state

val inside : state -> bool
(** [true] while the stream sits between an open and a close tag. *)

type piece =
  { reasoning : string
  ; text : string
  }

val feed : state -> string -> piece
(** Split one content delta. Either field may be empty. Bytes that could still
    begin or complete a tag are held until a later call resolves them, so a tag
    split across two deltas is never emitted as reply text. *)

val flush : state -> piece
(** End of stream. Held bytes are released: reply text outside a tag, and
    reasoning inside one, because an unterminated tag is a cut stream rather
    than a reason to drop what it carried. *)
