(** Canonical defaults, limits, and field names for [masc_keeper_status].
    Shared by runtime parsing and the public tool schema so the advertised
    contract cannot drift from execution. *)

let tail_turns = 3
let tail_messages = 5
let tail_compactions = 10
let tail_bytes = 60_000
let min_tail_turns = 0
let min_tail_messages = 0
let min_tail_compactions = 0
let min_tail_bytes = 1_000

type tail_order =
  | Oldest_first
  | Newest_first

let tail_order_to_string = function
  | Oldest_first -> "oldest_first"
  | Newest_first -> "newest_first"

let all_tail_orders = [ Oldest_first; Newest_first ]
let valid_tail_order_strings = List.map tail_order_to_string all_tail_orders

module Argument = struct
  let name = "name"
  let tail_turns = "tail_turns"
  let tail_messages = "tail_messages"
  let tail_compactions = "tail_compactions"
  let tail_bytes = "tail_bytes"
  let tail_order = "tail_order"
  let fast = "fast"
  let include_context = "include_context"
  let include_metrics_overview = "include_metrics_overview"
  let include_memory_bank = "include_memory_bank"
  let include_history_tail = "include_history_tail"
  let include_compaction_history = "include_compaction_history"

  let all =
    [ name
    ; tail_turns
    ; tail_messages
    ; tail_compactions
    ; tail_bytes
    ; tail_order
    ; fast
    ; include_context
    ; include_metrics_overview
    ; include_memory_bank
    ; include_history_tail
    ; include_compaction_history
    ]
end
