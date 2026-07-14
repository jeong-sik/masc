(** Shared validation contracts for externally supplied stable identifiers. *)

val portable_name_pattern : string
(** Portable name grammar used for keeper/runtime lane identifiers:
    [[A-Za-z0-9._-]+], excluding the reserved path components [.] and [..]. *)

val is_portable_name : string -> bool
(** [true] when the value is non-empty, matches {!portable_name_pattern}, and
    is not [.] or [..]. *)

val portable_name_error : field:string -> string
(** Canonical field-level validation message for {!portable_name_pattern}. *)
