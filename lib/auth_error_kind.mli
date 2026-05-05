(** Closed-enum classification of [Masc_domain.t] for auth-related logging
    and prometheus metric labels. See [auth_error_kind.ml] for the
    rationale and migration scope. *)

type t =
  | Token_mismatch
  | Token_expired
  | Unauthorized
  | Forbidden
  | Agent_not_found
  | Io_error
  | Invalid_json
  | Other

(** Stable string label used in prometheus metric dimensions and log lines.
    Round-trips with [of_string]. *)
val to_string : t -> string

(** Inverse of [to_string]. Returns [None] for unrecognised labels rather
    than collapsing to [Other], so callers can detect contract drift. *)
val of_string : string -> t option

(** Map a [Masc_domain.t] value to its label. Constructors not modelled here
    fall through to [Other]; add an explicit arm rather than relying on
    that fallback when introducing a new auth-relevant error. *)
val classify : Masc_domain.t -> t

(** All inhabitants in declaration order. Used by exhaustiveness tests. *)
val all : t list
