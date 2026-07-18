(** Canonical defaults, limits, and field names for [masc_keeper_status]. *)

val tail_turns : int
val tail_messages : int
val tail_compactions : int
val tail_bytes : int
val min_tail_turns : int
val min_tail_messages : int
val min_tail_compactions : int
val min_tail_bytes : int
val max_tail_turns : int
val max_tail_messages : int
val max_tail_compactions : int
val max_tail_bytes : int
val metrics_lines_per_turn : int
val compaction_lines_per_event : int
val min_metrics_scan_lines : int
val min_compaction_scan_lines : int

type tail_order =
  | Oldest_first
  | Newest_first

val tail_order_to_string : tail_order -> string
val all_tail_orders : tail_order list
val valid_tail_order_strings : string list
val tail_order_of_string : string -> tail_order option

module Argument : sig
  val name : string
  val tail_turns : string
  val tail_messages : string
  val tail_compactions : string
  val tail_bytes : string
  val tail_order : string
  val fast : string
  val include_context : string
  val include_metrics_overview : string
  val include_memory_bank : string
  val include_history_tail : string
  val include_compaction_history : string
  val all : string list
end
