(** Immutable Board routing audience.

    The constructors separate deterministic delivery from semantic discovery.
    Only {!Discoverable} may enter the LLM attention router. *)

type t = private
  | Targets of string list
  | Broadcast
  | Thread_participants of string list
  | Discoverable

val targets : string list -> (t, string) result
(** Canonical non-empty direct targets. *)

val thread_participants : string list -> t
(** Canonical participant identities.  The empty audience is valid and means
    there is no deterministic recipient for this thread event. *)

val broadcast : t
val discoverable : t

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
