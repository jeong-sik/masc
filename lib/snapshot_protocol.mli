(** Producer-owned conditional snapshot responses. *)

type response =
  | Snapshot of { revision : string; value : Yojson.Safe.t }
  | Unchanged of { revision : string }

val if_revision : Yojson.Safe.t -> (string option, string) result

val respond : revision:string -> if_revision:string option -> Yojson.Safe.t -> response

val to_yojson : response -> Yojson.Safe.t

val revision_of_json : namespace:string -> Yojson.Safe.t -> string
