(** Usage's Calls section: how many tool calls ran, how many failed and how
    slow the slowest 5% were, hour by hour or day by day. The model is built
    once when a series answer arrives, so a repaint draws it as it is. The
    Dashboard draws one row of the same model ({!summary_line}). *)

(** The span the section covers. It follows the Usage view's history window
    (1, 7 or 14 days, cycled with [w]): one day is drawn in UTC hours, a week
    or a fortnight in UTC days. *)
type window =
  | Last_day
  | Last_week
  | Last_fortnight

val window_of_days : int -> window option
(** [None] for a number of days the Usage view does not cycle through. *)

val days : window -> int
(** The days the window covers: 1, 7 or 14. [window_of_days (days w)] is
    [Some w]. *)

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

val lines : width:int -> rows:int -> t -> string list
(** The section as styled rows, none wider than [width] cells: a heading, the
    window's totals, a bar for calls, failed calls and p95, a legend, and a
    table of the same numbers with the newest bucket first. A bucket in which
    no call ran draws [·] and no latency, never zero. A bucket is red only when
    every call in it failed.

    The heading and the legend take the longest wording that fits [width]; the
    heading always keeps the time the numbers are from. [rows] is the room the
    screen has for the section. While the section fits in it, blank rows
    separate its parts and the legend may take two rows. When it is taller, the
    legend takes one row and the blank rows go, so the table shows more of its
    rows before the reader has to scroll. *)

val summary_line : cells:int -> t -> string
(** The Dashboard's one row, none wider than [cells]: the window named in a few
    characters ([24h], [7d], [14d]), the calls as one glyph per bucket, then the
    window's calls and failed calls. The glyphs scale to the window's own
    largest bucket, and a bucket in which every call failed is red, as in
    {!lines}. A width without room for the glyphs drops them; a narrower one
    cuts the rest. A window in which no call ran says [no calls], not zero. *)

val summary_note : cells:int -> window -> string -> string
(** The same row while there is no series to chart: the window and [note], cut
    to [cells]. The Dashboard draws it before the first read and when a read
    failed, so a reading that is missing is never drawn as a count of zero. *)
