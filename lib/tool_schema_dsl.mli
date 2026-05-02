
(** Shared JSON Schema builder helpers for MCP tool definitions. *)

val string_prop : string -> Yojson.Safe.t
val integer_prop : ?default:int -> string -> Yojson.Safe.t
val boolean_prop : ?default:bool -> string -> Yojson.Safe.t
val string_array_prop : string -> Yojson.Safe.t
val object_schema : ?required:string list -> (string * Yojson.Safe.t) list -> Yojson.Safe.t
