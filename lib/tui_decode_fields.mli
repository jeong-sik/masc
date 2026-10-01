(** Field readers shared by TUI wire decoders.
    These functions retain the wire contracts' distinction between required,
    nullable and optional fields; malformed values return a field error.
    They perform no I/O and contain no domain or display projection. *)

val member : string -> Yojson.Safe.t -> Yojson.Safe.t
(** A missing member is [Null]. Use [required_member] when absence and null
    must be distinguished. *)

val required_member : Yojson.Safe.t -> string -> (Yojson.Safe.t, string) result
(** A present null remains [Ok Null]; an absent key is an error. *)

val missing_field : string -> ('a, string) result
val field_type_error : string -> string -> Yojson.Safe.t -> ('a, string) result

val optional_string : Yojson.Safe.t -> string -> (string option, string) result
val required_nullable_int_field : Yojson.Safe.t -> string -> (int option, string) result
val required_nullable_float_field : Yojson.Safe.t -> string -> (float option, string) result
val required_nullable_string_field : Yojson.Safe.t -> string -> (string option, string) result
val required_nullable_bool_field : Yojson.Safe.t -> string -> (bool option, string) result
val require_null_field : Yojson.Safe.t -> string -> (unit, string) result
val required_bool_field : Yojson.Safe.t -> string -> (bool, string) result
val require_string_list : Yojson.Safe.t -> string -> (string list, string) result
val required_string_field : Yojson.Safe.t -> string -> (string, string) result
val optional_string_field : Yojson.Safe.t -> string -> (string option, string) result
val required_nullable_nonblank_string_field : Yojson.Safe.t -> string -> (string option, string) result
val optional_bool_field : Yojson.Safe.t -> string -> (bool option, string) result
val optional_float_field : Yojson.Safe.t -> string -> (float option, string) result
val required_int_field : Yojson.Safe.t -> string -> (int, string) result
val required_nonnegative_int_field : Yojson.Safe.t -> string -> (int, string) result
val required_list_field : Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val optional_list_field : Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val required_object_field : Yojson.Safe.t -> string -> (Yojson.Safe.t, string) result
val optional_object_field : Yojson.Safe.t -> string -> (Yojson.Safe.t option, string) result

(** Optional scalar readers accept an absent member or null as [None]; their
    required_nullable siblings reject absence and accept null as [None].
    [optional_list_field] accepts absence or null as an empty list.
    Object/list readers reject a present value of the wrong JSON shape. *)

val int_field_or :
  Yojson.Safe.t -> string -> default:int -> (int, string) result
(** Absence or null selects the caller's default; a malformed integer fails. *)

val decode_list :
  string -> ('a -> ('b, string) result) -> 'a list -> ('b list, string) result
(** Preserve order; report the first failed element with its zero-based index. *)

val optional_int_field : Yojson.Safe.t -> string -> (int option, string) result
val decode_string_name_list : Yojson.Safe.t -> string -> (string list, string) result
val decode_bool_field_or : Yojson.Safe.t -> string -> default:bool -> (bool, string) result
val required_nonempty_string_field : Yojson.Safe.t -> string -> (string, string) result

val require_exact_object_fields :
  string -> string list -> Yojson.Safe.t -> (unit, string) result
(** Reject missing, unknown and duplicate object fields, naming each mismatch. *)
