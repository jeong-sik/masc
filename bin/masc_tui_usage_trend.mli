(** Usage's quota scope trend, built once when a provider history answer
    arrives. The rows only change when a new answer does, so the frame draws
    them as they are instead of regrouping every point on every repaint. *)

type day_report =
  | Measured of Masc.Tui_decode_usage.provider_usage_utilization * float option
  | Reported_no_windows

type sample = { observed_at : float; report : day_report }

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

val empty_report_mark : string
(** A successful complete report with no windows, distinct from zero usage or no report. *)

val of_history :
  share:(Masc.Tui_decode_usage.provider_usage_utilization -> float option) ->
  Masc.Tui_decode_usage.provider_usage_history ->
  t
(** [share] reads a reported value as a part of its full window. An uncapped
    monetary report has no share and draws [$], distinct from no report. A report
    without windows draws [empty_report_mark] and counts as a reported day.
    A point outside the answered window keeps its row and draws no day. When one day
    holds several points for a row, the last one in the answer is drawn. *)

val latest : row -> sample option
(** Most recent report in the answered window, not the answer's generation time. *)

val plot : width:int -> t -> row -> string list
(** A five-row braille line plot over the fixed 0–100% scale, with UTC day
    labels. Each cell draws a 2x4 dot matrix, so the scale has twenty
    dot-levels. Consecutive reported days are joined; a missing report, an
    empty report and an uncapped amount break the line and keep their
    baseline marks, so a gap is never interpolated. Reported zero draws the
    line along the bottom and 0 on the baseline. Values outside the scale
    are clipped only for drawing and retain their original [sample.report];
    an above-limit day keeps its up-arrow in the top row, a below-zero day
    its down-arrow on the baseline. *)
