type style =
  | User
  | Keeper
  | Status
  | Error

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
}

type row = {
  style : style;
  text : string;
}

val utf8_scalar_byte_length : char -> int option
(** Expected byte length for one well-formed UTF-8 lead byte. Invalid leads and
    isolated continuation bytes return [None]. *)

val is_printable_utf8_scalar : string -> bool
(** Whether the text is exactly one valid scalar outside C0, DEL, and C1
    control ranges. *)

val drop_last_utf8_scalar : string -> string
(** Remove one complete scalar from valid UTF-8 text. Empty or invalid text is
    preserved rather than truncated into a different malformed value. *)

val fit_width : string -> int -> string
(** Fit plain UTF-8 text to an exact byte budget without splitting a scalar. *)

val visible_rows : inner_width:int -> height:int -> entry list -> row list
(** Render chat entries into plain, UTF-8-safe physical rows and retain the
    newest rows. The newest entry always keeps its metadata row. *)
