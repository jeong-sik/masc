(** JSON-extract helpers for keeper OAS diagnostics. *)

val detail_json_opt : Yojson.Safe.t -> Yojson.Safe.t option
val json_or_detail_string_opt : string -> Yojson.Safe.t -> string option
val json_or_detail_bool_opt : string -> Yojson.Safe.t -> bool option
val diagnosis_json_opt : Yojson.Safe.t -> Yojson.Safe.t option
