(** Pure semantic validation of an already decoded execution batch.
    The event-store driver retains framing, canonical decoding, digest work,
    cooperative yielding and the atomic commit authority. A validated footer
    describes a structurally valid batch; it does not grant visibility. *)

type header =
  { batch_id : string
  ; expected_next_seq : int
  ; count : int
  ; events_sha256 : string
  }

type footer =
  { batch_id : string
  ; first_seq : int
  ; last_seq : int
  ; count : int
  ; events_sha256 : string
  }

type failure =
  { offset : int64
  ; detail : string
  }

type in_progress
(** A decoded header, its correlation identity and the number of events accepted
    so far. The driver accepts events only while [remaining] is positive and
    finishes only when it is zero. *)

val start :
  offset:int64 ->
  committed_seq:int ->
  correlation_id:Execution_event.Correlation_id.t ->
  header ->
  (in_progress, failure) result
(** Check continuation after [committed_seq]. The caller has already decoded a
    canonical header with a positive sequence/count and a valid digest string.
    [offset] is the begin frame's offset. *)

val remaining : in_progress -> int
val next_seq : in_progress -> int

val accept_event :
  in_progress ->
  offset:int64 ->
  Execution_event.t ->
  (in_progress, failure) result
(** Check the next event's sequence, then correlation identity. The caller has
    canonically decoded the event and established [remaining progress > 0].
    [offset] is the event frame's offset. *)

type validated
(** Structural agreement of the supplied decoded events/footer and digest with
    the header. This value does not establish atomic commit authority. *)

val finish :
  in_progress ->
  offset:int64 ->
  digest:string ->
  footer ->
  (validated, failure) result
(** The caller has established [remaining progress = 0], decoded the canonical
    footer, then finished the digest over the original event payloads. Check
    footer identity, range/count, then both header/footer digests, in that order.
    [offset] is the footer frame's offset. *)

val last_seq : validated -> int
