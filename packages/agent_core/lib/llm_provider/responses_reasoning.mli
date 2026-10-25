(** Native Responses reasoning channels. Full text and its condensation are
    distinct sources. Absence of a channel is distinct from its empty array. *)
type channel = Summary | Full
type plaintext =
  { summary : (int * string) list option
  ; full : (int * string) list option
  }
type t = Plaintext of plaintext | Opaque of Yojson.Safe.t

val selected : plaintext -> (channel * string) option
(** Prefer nonblank full reasoning in wire order, then summary. *)
val decode : Yojson.Safe.t -> (t, string) result
(** Nonblank encrypted content has priority and retains the entire object.
    Unknown part types are extensions; malformed recognized full text fails. *)
