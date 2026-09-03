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

type context_pressure =
  | Quiet
  | Pressure
  | Danger

val percentage_tenths : float -> int
(** A ratio projected to tenths of one percent, using the rounding visible in
    the Keeper detail row. For example, [0.4999] becomes [500] ([50.0%]). *)

val context_pressure : float -> context_pressure
(** The pressure band for the rounded percentage shown to the operator. *)

val log_kind_label : Tui_decode.log_kind -> string
val log_channel_label : Tui_decode.log_channel -> string
val usage_label : input:int option -> output:int option -> string
val latency_label : int option -> string
val cost_label : float option -> string
val plain_log_header : string
(** The metrics tail's column names. Drawn from the same description as
    {!plain_log_row}, which is what holds the two at one set of offsets: the
    widths lived here and the names lived in the renderer, and only care kept
    them agreeing. *)

val plain_log_row : time:string -> Tui_decode.log_entry -> string
(** One observed turn. The tools that ran follow the last named column,
    unbounded, so nothing after it can be pushed. *)
val context_summary : Tui_decode.context_observation -> context_summary
val context_header_item : max_cells:int -> Tui_decode.context_observation -> string option
