(** Safe-autonomy domain level + catalog. *)

type domain_level =
  | Pass
  | Warn
  | Fail

val tool_domain_id : string
val sandbox_domain_id : string
val approval_domain_id : string
val cascade_domain_id : string
val audit_domain_id : string

val domain_catalog : (string * string * int) list

val level_to_string : domain_level -> string
val level_rank : domain_level -> int
val worse_level : domain_level -> domain_level -> domain_level
val worst_level : domain_level list -> domain_level
