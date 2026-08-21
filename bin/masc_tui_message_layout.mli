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

val fit_width : string -> int -> string
(** Fit plain UTF-8 text to an exact byte budget without splitting a scalar. *)

val visible_rows : inner_width:int -> height:int -> entry list -> row list
(** Render chat entries into plain, UTF-8-safe physical rows and retain the
    newest rows. The newest entry always keeps its metadata row. *)
