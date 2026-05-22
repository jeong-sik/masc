(** Small JSON / string utility helpers for the dashboard HTTP surface. *)

(** Trim [text], then truncate to [max_chars] characters with a
    trailing ["..."] suffix when over budget. Returns
    [(preview, truncated)]. *)
val compact_preview : max_chars:int -> string -> string * bool

(** [`Assoc] field-by-key with [`Null] fallback on miss or
    non-Assoc input. *)
val json_member : string -> Yojson.Safe.t -> Yojson.Safe.t

(** Typed-getter aliases for [Json_util.get_*] with [(key, json)]
    argument order. *)
val json_string : string -> Yojson.Safe.t -> string option
val json_int : string -> Yojson.Safe.t -> int option
val json_float : string -> Yojson.Safe.t -> float option
val json_bool : string -> Yojson.Safe.t -> bool option

(** RFC-0142 PR-5 typed-failure variant: accepts both [`Float] and
    [`Int]; collapses Wrong_shape / Field_absent to [None] at the
    boundary. *)
val json_number : string -> Yojson.Safe.t -> float option

(** [Json_field.assoc] adapter wrapping back to [`Assoc fields]
    option. *)
val json_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t option

(** Explicit-length prefix equality without throwing on short
    input. *)
val string_has_prefix : prefix:string -> string -> bool
