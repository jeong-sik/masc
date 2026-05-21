(** Tool-name extraction and dedupe helpers for operator snapshots. *)

val merge_tool_name_lists : string list -> string list -> string list
val tool_names_of_recent_json : Yojson.Safe.t -> string list
val collect_recent_tool_names : ?limit:int -> string list -> string list
