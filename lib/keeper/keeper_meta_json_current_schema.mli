(** Exact Keeper meta current-schema contract. *)

type validation_error = Invalid_current of string

val validation_error_detail : validation_error -> string

val current_field_names : string list
(** Exact top-level keys emitted by the current writer. *)

val validate_current_object :
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, validation_error) result
(** Require exactly the current top-level key set. Every field outside that set
    has the same [Invalid_current] classification. *)
