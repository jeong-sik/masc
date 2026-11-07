(** Small stdlib-only state machine for per-fingerprint event dedupe.

    The module owns the [Hashtbl + Mutex] mechanics of counting repeats.
    Domain modules still own their typed classifiers, public outcomes,
    metric labels, and reset policy. *)

type t

type occurrence_outcome =
  | First
  | Repeated of int

(** Build a collision-resistant string key from already-typed
    fingerprint components. The separator is outside normal textual
    labels, avoiding the prefix-collision bug of raw concatenation. *)
val key : string list -> string

val create : ?initial_capacity:int -> unit -> t
val record : t -> key:string -> occurrence_outcome
val reset : t -> unit
val cardinality : t -> int
