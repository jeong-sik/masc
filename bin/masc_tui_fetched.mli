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
  | Failed of string

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
val request_key : 'k request -> 'k
val same_request : equal:('k -> 'k -> bool) -> 'k request -> 'k request -> bool
val is_current : equal:('k -> 'k -> bool) -> ('k, 'a) t -> 'k request -> bool

val complete
  :  equal:('k -> 'k -> bool)
  -> ('k, 'a) t
  -> 'k request
  -> ('a, string) result
  -> ('k, 'a) t
(** Settle a request. An answer for a request the pane has moved past is
    dropped: rendering it beside a different key reads as that key's value. *)

val view_for : equal:('k -> 'k -> bool) -> ('k, 'a) t -> key:'k -> 'a view
