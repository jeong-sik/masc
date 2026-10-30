(** Shared validation contracts for externally supplied stable identifiers. *)

val is_portable_name : string -> bool
(** [true] when the value is non-empty, matches {!portable_name_pattern}, and
    is not [.] or [..]. *)

val portable_name_error : field:string -> string
(** Canonical field-level validation message for {!portable_name_pattern}. *)
