(** Strict structured verdict returned by the configured Board-attention judge. *)

type decision =
  | Relevant
  | Not_relevant

type t =
  { decision : decision
  ; rationale : string
  }

val schema_name : string
val decision_tokens : string list
val decision_to_string : decision -> string
val decision_of_string : string -> decision option
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
