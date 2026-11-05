(** Generic JSON extraction and normalization helpers for mission briefing. *)

val compact_text : ?max_len:int -> string -> string
val member_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t
val string_field : ?default:string -> string -> Yojson.Safe.t -> string
val take : int -> 'a list -> 'a list
