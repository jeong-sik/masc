(** Usage's Calls section: how many tool calls ran, how many failed and how
    slow the slowest 5% were, hour by hour or day by day. The model is built
    once when a series answer arrives, so a repaint draws it as it is. *)

(** The span the section covers. It follows the Usage view's history window
    (1, 7 or 14 days, cycled with [w]): one day is drawn in UTC hours, a week
    or a fortnight in UTC days. *)
type window =
  | Last_day
  | Last_week
  | Last_fortnight

val window_of_days : int -> window option
(** [None] for a number of days the Usage view does not cycle through. *)

val bucket_count : window -> int
(** The buckets drawn: 24 hours, 7 days or 14 days. *)

val width : window -> Masc.Tui_decode_tool_series.tool_series_width

val since_hours : window -> int
(** The [since_hours] to ask the server for: the hours the window covers. The
    server counts the bucket that holds [since], so unless the clock sits
    exactly on an edge the answer holds one bucket more than the window draws,
    and that first bucket starts before the window and holds only part of its
    hour or day. [of_series] drops it. The same number every time, so the
    server's 30 second cache answers repeated reads. *)

val reread_s : float
(** Seconds from an answer to the next read while the section stays open. No
    server push says that the store took a call, so a clock owes the read. The
    server holds an answer for 30 seconds, then serves it stale while a
    background fiber computes the next one ([Dashboard_cache]), and a scan of a
    window costs up to about a second of CPU (its comment on the route). A read
    a minute after the last one asks for at most one scan a minute and gets the
    answer that the read before it started, so the numbers are the store as of
    that read. The heading's time says which. *)

type t = {
  window : window;
  series : Masc.Tui_decode_tool_series.tool_series;
      (** Its buckets are the last [bucket_count window] of the answer: all
          of them are whole, except the newest, which is still open. *)
}

val of_series :
  window -> Masc.Tui_decode_tool_series.tool_series -> (t, string) result
(** Drops the buckets before the last [bucket_count window]. An answer in the
    other bucket width, on edges that do not follow UTC, or with fewer buckets
    than the window draws is an error: its labels would be wrong or its chart
    shorter than the window it names. *)

val note_lines : days:int -> string -> string list
(** The heading followed by [note], drawn while there is no series to chart:
    before the first read and when a read failed. A number of days the section
    does not draw is named by its days. *)

val lines : width:int -> t -> string list
(** The section as styled rows, none wider than [width] cells: a heading, the
    window's totals, a bar for calls, failed calls and p95, and a table of the
    same numbers with the newest bucket first. A bucket in which no call ran
    draws [·] and no latency, never zero. A bucket is red only when every call
    in it failed. *)
