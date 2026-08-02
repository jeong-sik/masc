(** Producer-owned conditional snapshot responses. *)

type response =
  | Snapshot of { revision : string; value : Yojson.Safe.t }
  | Unchanged of { revision : string }

val if_revision : Yojson.Safe.t -> (string option, string) result

val unchanged_if_revision_matches :
  revision:string -> if_revision:string option -> response option

val respond : revision:string -> if_revision:string option -> Yojson.Safe.t -> response

val to_yojson : response -> Yojson.Safe.t

val revision_of_backlog_version : int -> string

val revision_of_board_cursor : float * string option -> string

val revision_of_json : namespace:string -> Yojson.Safe.t -> string
