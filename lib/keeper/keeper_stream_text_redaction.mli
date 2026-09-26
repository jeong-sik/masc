(** Redaction of streamed model text across delta boundaries.

    A provider streams text, reasoning and tool arguments as deltas, and a
    secret can arrive split between two of them. Redacting each delta on its
    own misses it: neither half is a whole exact value, and a pattern such as
    [sk-...] matches neither half, or matches the first and leaves the rest of
    the key in the next delta. This module runs the overlap-aware
    {!Keeper_secret_redaction.redact_stream_chunk} over each content block
    instead, and forwards the provider's events with those deltas replaced by
    their redacted output.

    The redactor emits a record once its newline arrives and holds back an
    unterminated line (bounded by {!Keeper_secret_redaction}), so text reaches
    a reader a line at a time. The held text is emitted, never dropped:

    - before any content event of another block, so blocks keep their order;
    - before the block's own stop or snapshot, a new message, the message's
      stop reason or stop, and every provider failure event;
    - by {!flush}, when the stream ends without one of those events.

    [Ping], [Connected] and a [MessageDelta] without a stop reason can arrive
    in the middle of a block, so they pass through without releasing it.

    A whole-value [TextSnapshot] or [InputJsonSnapshot] is redacted with
    {!Keeper_secret_redaction.redact_text}. A thinking signature, a redacted
    thinking carrier and a media chunk are opaque provider payloads rather than
    text and pass through unchanged. [ReasoningDetailsDelta] is forwarded as the
    [ThinkingDelta] of its text projection, which is the only part a chat reader
    receives. *)

type t

val create : Keeper_secret_redaction.t -> t
(** One redactor for one provider stream. *)

val on_event : t -> Agent_core.Types.sse_event -> Agent_core.Types.sse_event list
(** The events to forward for [event], in order: any text released by it,
    then [event] itself unless it is a text, thinking or tool-argument delta,
    which is replaced by its redacted output. A delta whose output is empty is
    not forwarded. *)

val flush : t -> Agent_core.Types.sse_event list
(** Release the held text as one redacted delta, or nothing when none is
    held. *)

(** The same redactor over a request whose provider streams are numbered by
    stream scope. Text held for one scope is released under that scope before
    the first event of another scope, so a reader never sees it attributed to
    the next provider call. *)
module Scoped : sig
  type t

  val create : Keeper_secret_redaction.t -> t

  val on_event :
    t -> stream_scope:int -> Agent_core.Types.sse_event -> (int * Agent_core.Types.sse_event) list

  val flush : t -> (int * Agent_core.Types.sse_event) list
  (** Call at a runtime attempt boundary and when the request ends. *)
end
