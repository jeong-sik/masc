(** Small stdlib-only state machine for per-fingerprint event dedupe.

    The module owns the repeated [Hashtbl + Mutex + threshold-once]
    mechanics used by keeper/task log-noise reducers. Domain modules
    still own their typed classifiers, public outcomes, metric labels,
    and reset policy. *)

type t

type occurrence_outcome =
  | First
  | Repeated of int

type threshold_payload =
  { count : int
  ; threshold : int
  }

type threshold_outcome =
  | First_threshold
  | Repeated_threshold of int
  | Threshold of threshold_payload

val default_normalize_length_cap : int

(** [normalize_signature raw] trims leading/trailing ASCII whitespace,
    collapses whitespace runs to one space, lowercases ASCII letters,
    preserves non-ASCII bytes, and truncates to [length_cap] bytes. *)
val normalize_signature : ?length_cap:int -> string -> string

(** Build a collision-resistant string key from already-typed
    fingerprint components. The separator is outside normal textual
    labels, avoiding the prefix-collision bug of raw concatenation. *)
val key : string list -> string

val create : ?initial_capacity:int -> unit -> t
val record : t -> key:string -> occurrence_outcome

(** [record_threshold t ~key ~threshold] records an occurrence and
    returns [Threshold] at most once for that key. The first occurrence
    always returns [First_threshold]; thresholding starts on repeats so
    existing first-ERROR behaviour is preserved. *)
val record_threshold : t -> key:string -> threshold:int -> threshold_outcome

val reset : t -> unit
val remove : t -> key:string -> unit
val cardinality : t -> int
val count : t -> key:string -> int
