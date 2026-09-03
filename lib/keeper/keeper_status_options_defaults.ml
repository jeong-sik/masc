(** Canonical defaults, limits, and field names for [masc_keeper_status].
    Shared by runtime parsing and the public tool schema so the advertised
    contract cannot drift from execution. *)

let tail_turns = 3
let tail_messages = 5
let tail_bytes = 60_000
let min_tail_turns = 0
let min_tail_messages = 0
let min_tail_bytes = 1_000

(* How many source bytes one tail request may read. Count ceilings are derived
   from it and the exact overscan factors used by the readers, so the decoder
   cannot admit values that overflow the downstream products.

   This is an admission bound on the read, not on what gets published, and
   nothing downstream bounds the publish. [masc_keeper_status] is registered
   [~keeper_model_projection:Operator_only], [keeper_model_names] answers []
   for that projection, and the agent-core bundle builds a [Tool.t] only over
   the names that function returns, so no [Tool_bridge] conversion exists for
   this tool and its result never meets a model projection. It leaves over
   MCP at whatever size the readers produce.

   It used to be written as the tool-response cap, on the premise that a tail
   must not read more than one result publishes. That tied an operator
   surface to a keeper-wire ceiling it never crosses, so the number is stated
   directly here instead. Changing it changes what an operator may ask for,
   not what a Keeper receives. *)
let max_tail_bytes = 64 * 1024
let metrics_lines_per_turn = 10
let max_tail_turns = max_tail_bytes / metrics_lines_per_turn
let max_tail_messages = max_tail_bytes

type tail_order =
  | Oldest_first
  | Newest_first

let tail_order_to_string = function
  | Oldest_first -> "oldest_first"
  | Newest_first -> "newest_first"

let all_tail_orders = [ Oldest_first; Newest_first ]
let valid_tail_order_strings = List.map tail_order_to_string all_tail_orders

let tail_order_of_string value =
  List.find_opt
    (fun order -> String.equal value (tail_order_to_string order))
    all_tail_orders

module Argument = struct
  let name = "name"
  let tail_turns = "tail_turns"
  let tail_messages = "tail_messages"
  let tail_bytes = "tail_bytes"
  let tail_order = "tail_order"
  let fast = "fast"
  let include_context = "include_context"
  let include_metrics_overview = "include_metrics_overview"
  let include_history_tail = "include_history_tail"

  let all =
    [ name
    ; tail_turns
    ; tail_messages
    ; tail_bytes
    ; tail_order
    ; fast
    ; include_context
    ; include_metrics_overview
    ; include_history_tail
    ]
end
