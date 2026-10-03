(** Usage's quota scope trend, built once when a provider history answer
    arrives. The rows only change when a new answer does, so the frame draws
    them as they are instead of regrouping every point on every repaint. *)

type sample = {
  observed_at : float;
  value : Masc.Tui_decode_usage.provider_usage_utilization;
  share : float;
}

type row = {
  scope_id : string;  (** The server's opaque scope id. *)
  kind : string;  (** The provider's window kind. *)
  limit_id : string option;
  marks : string;
      (** One glyph per UTC day, oldest first: the day's latest reported
          share as a {!Masc_tui_chart.sparkline} level (0 for reported zero), or {!no_report_mark}
          for a day with no report. *)
  samples : sample option list; (** UTC days, oldest first; gaps stay absent. *)
  reported_days : int;  (** Days in the window that have a report. *)
}

type t = {
  days : int;  (** The UTC day window the server answered for. *)
  generated_at : float;  (** When the server answered; its day is the last. *)
  unreadable_reports : int;
      (** Stored reports the server could not read and left out. *)
  rows : row list;  (** One per (scope, kind, limit), in that order. *)
}

val no_report_mark : string
(** What a day without a report draws. Never a zero-height bar: a missing
    report is not an idle day. *)

val of_history :
  share:(Masc.Tui_decode_usage.provider_usage_utilization -> float) ->
  Masc.Tui_decode_usage.provider_usage_history ->
  t
(** [share] reads a reported value as a part of its full window. A point
    outside the answered window keeps its row and draws no day. When one day
    holds several points for a row, the last one in the answer is drawn. *)

val latest : row -> sample option
(** Most recent report in the answered window, not the answer's generation time. *)

val plot : width:int -> t -> row -> string list
(** A four-row, fixed 0–100% daily bar plot with UTC day labels. Missing days
    draw a dot at the baseline; reported zero draws 0. Values outside the scale
    are clipped only for drawing and retain their original [sample.value]. *)
