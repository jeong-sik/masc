module Tui_decode = Masc.Tui_decode

type context_summary =
  | Context_measured of {
      ratio : float;
      tokens : int;
      maximum : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_partial of {
      tokens : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of string

val log_kind_label : Tui_decode.log_kind -> string
val log_channel_label : Tui_decode.log_channel -> string
val usage_label : input:int option -> output:int option -> string
val latency_label : int option -> string
val cost_label : float option -> string
val plain_log_row : time:string -> Tui_decode.log_entry -> string
val context_summary : Tui_decode.context_observation -> context_summary
val context_header_item : max_cells:int -> Tui_decode.context_observation -> string option
