(** One fetched thing, and what is known about it right now.

    A pane that models this as a snapshot option beside an error option
    cannot say "asked, still waiting": [None, None] means both "never asked"
    and "in flight". That is why the TUI can report a failure in 71 places
    and a fetch in progress in five, and why a pane before its first answer
    is drawn exactly like a pane with no rows.

    Here the states are a closed sum, so a renderer has to answer for each of
    them. The value is immutable; every transition returns a new one. *)

type 'k request
type ('k, 'a) t

type 'a view =
  | Absent  (** Never asked. *)
  | Loading  (** Asked, no answer yet, and nothing to show meanwhile. *)
  | Ready of 'a
  | Stale of 'a * string
      (** The last good value, and why the refresh after it failed. A failed
          refresh does not throw away what was read; the pane keeps drawing
          it and says it is stale. A retry in flight stays [Stale] until it
          answers. *)
  | Failed of string
      (** Failed with nothing read before it. Explicit refresh retains this
          known cause until its replacement settles; {!in_flight} distinguishes
          the pending retry from a settled failure. No value is invented. *)

val value : 'a view -> 'a option
(** What the pane draws: the value when {!Ready}, and the last good value
    when {!Stale}. Rows, counts, the cursor and edit targets read this, so a
    failed refresh does not empty them. [None] when nothing has been read. *)

type ('k, 'a) start_result =
  | Already_loading
  | Started of ('k, 'a) t * 'k request

val initial : ('k, 'a) t

val start : equal:('k -> 'k -> bool) -> ('k, 'a) t -> key:'k -> ('k, 'a) start_result
(** Ask for [key]. [Already_loading] when a request for the same key is
    already in flight, so a pane that redraws per keystroke asks once. Asking
    for a key already shown keeps the last good value on screen while the new
    request runs, rather than flashing back to {!Loading}. *)

val clear : ('k, 'a) t -> ('k, 'a) t
val cancel_pending : reason:string -> ('k, 'a) t -> ('k, 'a) t
(** Retire pending reply admission, retaining completed values and their
    existing [Ready]/[Stale] observation or a retry's prior failure. An initial
    read without a value becomes [Failed reason]. Settled sources are unchanged.
    This neither publishes a new read result nor stops the underlying worker;
    late replies cannot settle the source. *)
val refresh : equal:('k -> 'k -> bool) -> ('k, 'a) t -> key:'k -> ('k, 'a) start_result
(** Explicitly supersede an outstanding request, including for the same key.
    Retain that key's last good value or known no-value failure while its replacement
    runs. Only the returned request may settle the source; {!start} keeps its
    existing same-key sharing behavior. This does not launch any work. *)
val suspend : ('k, 'a) t -> ('k, 'a) t
(** Retire a pending read while retaining its key and last completed value.
    Initial reads become [Failed]; previous values become explicitly [Stale].
    A no-value retry retires its owner but keeps its original failure cause. *)
val request_key : 'k request -> 'k
val request_id : 'k request -> int64
(** Diagnostic generation within this fetched source; include its key/scope. *)
val same_request : equal:('k -> 'k -> bool) -> 'k request -> 'k request -> bool
val is_current : equal:('k -> 'k -> bool) -> ('k, 'a) t -> 'k request -> bool
val in_flight : ('k, 'a) t -> bool
(** A read is pending, including a refresh that still exposes a prior value
    or a no-value retry retaining its known failure.
    This observes retrieval, not work execution or effect admission. *)

val complete
  :  equal:('k -> 'k -> bool)
  -> ('k, 'a) t
  -> 'k request
  -> ('a, string) result
  -> ('k, 'a) t
(** Settle a request. An answer for a request the pane has moved past is
    dropped: rendering it beside a different key reads as that key's value.
    A failure for a revalidation of a value already shown settles as
    {!Stale}; a failure with nothing before it settles as {!Failed}. *)

val view_for : equal:('k -> 'k -> bool) -> ('k, 'a) t -> key:'k -> 'a view

val current : ('k, 'a) t -> ('k * 'a view) option
(** What this pane is about right now, and what is known about it. [None]
    before the first request.

    A pane whose key comes from the fetch itself -- the open file, the
    selected post -- cannot ask {!view_for} without already knowing the key,
    and the key is the thing it is asking for. *)

val current_key : ('k, 'a) t -> 'k option

val current_request : ('k, 'a) t -> 'k request option
(** The identity of the current reading, including after it has settled.
    [None] when cleared; clearing preserves the next request's generation. *)
