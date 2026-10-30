(** Current-only typed admission for dashboard prompt-override writes. *)

type t =
  | Set of
      { key : string
      ; value : string
      }
  | Clear of { key : string }

type error

val decode : string -> (t, error) result
(** Parse and validate one complete request body. Required fields must occur
    exactly once and prompt keys must already be canonical. *)

val key : t -> string
val error_message : error -> string
