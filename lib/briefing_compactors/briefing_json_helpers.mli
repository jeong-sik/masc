(** Generic JSON extraction and normalization helpers for mission briefing. *)

val compact_text : ?max_len:int -> string -> string
val member_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t
val string_field : ?default:string -> string -> Yojson.Safe.t -> string
val string_json : ?default:string -> ?max_len:int -> Yojson.Safe.t -> Yojson.Safe.t
val string_list_json : Yojson.Safe.t -> Yojson.Safe.t
val int_json : ?default:int -> Yojson.Safe.t -> Yojson.Safe.t
val float_json : ?default:float -> Yojson.Safe.t -> Yojson.Safe.t
val int_field : ?default:int -> string -> Yojson.Safe.t -> int
val take : int -> 'a list -> 'a list
val option_string_json : string option -> Yojson.Safe.t
val trim_to_option : string option -> string option
val parse_iso_opt : string option -> float option
