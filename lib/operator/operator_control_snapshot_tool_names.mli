(** Tool-name extraction + dedupe helpers for operator control snapshot. *)

val merge_tool_name_lists : string list -> string list -> string list
val tool_names_of_recent_json : Yojson.Safe.t -> string list

type recent_tool_name_parse_error

val recent_tool_name_parse_error_to_json :
  source:string ->
  ?keeper:string ->
  ?path:string ->
  recent_tool_name_parse_error ->
  Yojson.Safe.t

val collect_recent_tool_names_with_errors :
  ?limit:int -> string list -> string list * recent_tool_name_parse_error list

val collect_recent_tool_names : ?limit:int -> string list -> string list
