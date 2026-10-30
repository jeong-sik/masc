(** Tool-name extraction + dedupe helpers for operator control snapshot. *)

val collect_recent_tool_names : ?limit:int -> string list -> string list
