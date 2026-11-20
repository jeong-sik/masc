(** The engine screen's time graphs, drawn from [/health] samples (RFC
    tui-one-screen-grammar section 5.6).

    While the engine view is on screen, a sample is due every
    {!interval_s} seconds from the moment the view opened. A due sample takes
    the newest [/health] answer the TUI received in the last {!interval_s}
    seconds, whoever asked for it; only when there is none does the sampler
    ask [/health] itself. One read of its own is out at a time. The graphs
    are as wide as the samples kept: a ring holds as many as the graph has
    times, and drops the oldest. Time before the view opened is blank, and so
    is a time whose read failed.

    When the view closes the samples go with it, and nothing is due until it
    opens again: no read and no timer. The answers stay, so a view opened
    again within {!interval_s} seconds of a read takes that read.

    Pure: the caller passes the clock (monotonic seconds) and launches the
    read {!tick} asks for. *)

(** {1 Readings} *)

type point =
  { live_heap : Masc_tui_braille.sample
        (** The heap words in use, the Engine card's live size. *)
  ; scheduler_p95 : Masc_tui_braille.sample
        (** The scheduler lag card's p95, in whole microseconds. *)
  }
(** The two numbers one sample holds. A number the server did not report is
    [Absent] in it. *)

type reading =
  | Answered of point  (** [/health] answered. *)
  | Failed of string
      (** [/health] did not answer, or its answer did not decode: the
          loader's sentence, which names its subject and its verdict. *)

val reading_of_identity :
  (Masc.Tui_decode.server_identity, string) result -> reading
(** A [/health] answer read as a masc server's identity. The p95 of a window
    with no latency sample is no reading. *)

val reading_of_server :
  (Masc.Tui_decode.server_reading, string) result -> reading
(** A [/health] answer read for which kind of server answers it. The account
    server of a multi-account installation reports no engine, so both numbers
    are [Absent]. *)

type answer =
  { at : Masc_tui_wake.Mono.t  (** When it arrived, on the loop's clock. *)
  ; reading : reading
  }
(** One [/health] answer, as the TUI received it. *)

(** {1 The ring} *)

module Ring : sig
  type 'a t
  (** At most {!capacity} items, oldest first. *)

  val empty : capacity:int -> 'a t
  (** A capacity below zero holds nothing. *)

  val push : 'a -> 'a t -> 'a t
  (** Adds the newest item; past the capacity the oldest goes. *)

  val resize : capacity:int -> 'a t -> 'a t
  (** Keeps the newest [capacity] items. *)

  val capacity : 'a t -> int

  val to_list : 'a t -> 'a list
  (** Oldest first. *)
end

(** {1 The sampler} *)

val interval_s : float
(** [2.0]: btop's default refresh interval. *)

type t

val stopped : t
(** No view open, no read out, no answer received. *)

val shown : t -> now:Masc_tui_wake.Mono.t -> capacity:int -> t
(** The engine view is on screen and its graphs have room for [capacity]
    times. Opens the view's samples at [now] if they are not open, and keeps
    the newest [capacity] samples if the room changed. *)

val hidden : t -> t
(** The engine view is not on screen: its samples go and nothing is due.
    A read already out stays out; its answer is still awaited. *)

type step =
  | Nothing  (** Nothing changed and nothing is to be sent. *)
  | Sampled  (** A sample was taken: the graphs read differently. *)
  | Read
      (** A sample is due and no answer in the last {!interval_s} seconds
          can be taken: send one [/health] read now and hand its reading to
          {!answered}. The sampler counts it as out from here. *)

val tick :
  ?allow_read:bool -> t -> now:Masc_tui_wake.Mono.t -> newest:answer option -> t * step
(** What the view's samples do at [now], given the newest [/health] answer
    the TUI received. A due sample takes the newest answer if it arrived
    within {!interval_s} seconds before the sample's time and was not taken
    already; otherwise it waits for a read, and nothing else is due until
    that read answers ({!answered}). With [allow_read=false], an existing
    read can still finish, and a slot that would start a new read is blank.
    Times passed while the loop or a read was held are also blank. *)

type report =
  | Quiet
  | Failure_began of string
      (** The sampler's own read failed, and its last read in this view did
          not: the caller says so where read failures are said. The blanks
          in the graphs carry each failed time after it. *)

val answered : t -> now:Masc_tui_wake.Mono.t -> reading -> t * step * report
(** The answer to the read {!tick} asked for. A sample still waiting takes
    it at [now]. *)

(** {1 Graphs} *)

type series =
  | Live_heap
  | Scheduler_p95

val samples : series -> t -> Masc_tui_braille.sample list
(** Oldest first. Empty while the view is closed and before its first
    sample. *)

val graph :
  ?baseline_style:string ->
  ?axis_style:string ->
  tint:Masc_tui_braille.tint ->
  width:int ->
  axis_cells:int ->
  axis:(int -> string) ->
  series ->
  t ->
  Masc_tui_braille.graph
(** One text row [width] cells wide. Its axis column is [axis_cells] wide
    whatever the top, so it draws {!Masc_tui_braille.graph_times} times, the
    newest, and a ring the loop sizes with that keeps no time it does not
    draw. [axis] writes the top with its unit, in at most [axis_cells] cells.

    The top is held, not the largest time drawn (RFC tui-one-screen-grammar
    5.6, btop's network auto scale). The first measured time sets it to 1.3
    times that time. Five times above it set it again to 1.3 times the
    average of the five newest measured times (blanks passed over); five
    times under a tenth of it set it to 3 times that average. The average
    holds the times inside the band too, so, as in btop, a rescale can land
    on either side of the old top. A time on one side takes one off the count of
    the other, and a blank counts for neither. It never goes under the
    series' floor (1 MiB of heap, 1 ms of p95), and a top at the floor counts
    no time as low. A time above the top draws at the top until it rises.
    The top lasts while the view stays open.

    With no time measured among those drawn (every read failed, or none
    reported the number) there is no top to write and the column stays
    blank. [Never_read] before the view's first sample. *)
