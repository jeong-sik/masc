(** Strict structured verdict returned by the configured Board-attention judge. *)

type decision =
  | Relevant
  | Not_relevant

type t =
  { decision : decision
  ; rationale : string
  }

val decision_tokens : string list
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** Batch verdict: one structured response judging several candidates in a
    single model call. Items are keyed by the exact candidate identity; the
    caller validates coverage and rejects unknown identities. *)

type batch_item =
  { candidate_id : string
  ; verdict : t
  }

val batch_of_yojson : Yojson.Safe.t -> (batch_item list, string) result
