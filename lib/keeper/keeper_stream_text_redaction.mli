(** Redaction of streamed model text across delta boundaries.

    A provider streams text, reasoning and tool arguments as deltas, and a
    secret can arrive split between two of them. Redacting each delta on its
    own misses it: neither half is a whole exact value, and a pattern such as
    [sk-...] matches neither half, or matches the first and leaves the rest of
    the key in the next delta. This module runs the overlap-aware
    {!Keeper_secret_redaction.redact_stream_chunk} over each content block
    instead, and forwards the provider's events with those deltas replaced by
    their redacted output.

    Each [(block index, channel)] owns its redactor. A newline releases a
    complete record; an unfinished line remains bounded by
    {!Keeper_secret_redaction}. Another block's start, delta, snapshot or stop
    cannot finalize it. A block stop releases only that block's channels. The
    message's stop reason, stop or failure and explicit {!flush} release all
    channels. Authored Text/Thinking chunks keep their original arrival order
    across channels. A later completed line waits for an earlier unresolved
    chunk; copied bytes keep their source position, and a mask spanning chunks
    belongs to the chunk containing its first source byte.

    Headers and opaque metadata do not end content. In particular a replayed
    [MessageStart] does not finalize text. The caller owns provider-call
    boundaries: use {!Scoped} or explicitly flush between calls. Published
    tool observations and argument fields remain independently observable while
    authored content is withheld. Model block stops follow their queued content.
    Adapters must preserve actual content stops
    rather than using an unrelated tool start as an implicit text boundary.

    A typed Text/Thinking delta or snapshot establishes model-index occupancy,
    including when empty. If no header was observed for that index, a normalized
    non-tool [ContentBlockStart] precedes buffering. This reserves the observed
    channel before a malformed tool header can acquire the same index, without
    exposing withheld text or inventing model activity.

    A whole-value [TextSnapshot] or [InputJsonSnapshot] replaces its channel's
    unpublished delta tail and is redacted with {!Keeper_secret_redaction.redact_text}.
    It does not release superseded fragments or touch another channel. This
    module does not coalesce whole snapshot events or perform snapshot-to-delta
    reconciliation. A thinking signature, a redacted
    thinking carrier and a media chunk are opaque provider payloads rather than
    text and pass through unchanged. [ReasoningDetailsDelta] is forwarded as the
    [ThinkingDelta] of its text projection, which is the only part a chat reader
    receives. *)

type t

val create : Keeper_secret_redaction.t -> t
(** One redactor for one provider stream. *)

val on_event : t -> Agent_core.Types.sse_event -> Agent_core.Types.sse_event list
(** Events that become publishable after [event]. Authored deltas and their
    block stops may remain queued for a later call; model content cannot
    overtake an earlier authored chunk. Argument fields and other observations
    keep their independent visibility. A delta with no safe output is withheld
    rather than replaced with an empty displayed event. *)

val flush : t -> Agent_core.Types.sse_event list
(** Release every channel's held text as redacted deltas, or nothing when no
    content remains. *)

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
