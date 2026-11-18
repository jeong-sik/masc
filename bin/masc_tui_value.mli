(** The text a screen draws for a value it holds as a value.

    A screen hands over the reading itself -- seconds since the epoch -- and
    says where it is drawn; this module alone decides the notation. Screens
    used to build the text themselves, each with its own [Printf] format, so
    one moment read [11-11 15:36:13] on one screen and [2026-11-11T06:36:13Z]
    on the next, the first in the operator's zone and the second in UTC with
    nothing marking which was which (RFC tui-one-screen-grammar, section 6). *)

(** When the text of the frame being built next reads differently with no new
    data. Without new data only time text changes: the zone-1 clock, moments
    and lengths (RFC tui-one-screen-grammar §8). Each function in this module
    that draws such text notes the instant its reading next changes, and the
    loop redraws on the first whole second at or after the earliest one. *)
module Redraw : sig
  val begin_frame : unit -> unit
  (** Forget what the previous frame noted. Called where a frame starts. *)

  val note_change_at : float -> unit
  (** A text drawn on this frame reads differently from this wall-clock
      instant on. A non-finite instant is no instant and is not noted. *)

  val next_change : unit -> float option
  (** The earliest instant noted since {!begin_frame}, [None] when the frame
      drew no text that changes with time. Read in the domain that built the
      frame. *)

  val holds : now:float -> until:float -> bool
  (** Whether a reading that lasts until the instant [until] still holds at
      [now] ([now <= until]): a notice shown for a while, a clause added once
      a stream has been quiet for a time. A frame that words a text one way
      while it holds and another way after asks this, and while it holds
      [until] is noted ({!note_change_at}), since without new data that text
      changes then. *)

  val measuring : (unit -> 'a) -> 'a
  (** Run a computation whose text is measured and not drawn, such as the
      widest of every row's sentence, offscreen rows included. What it notes
      is forgotten: only drawn text asks for a redraw. *)
end

(** A moment, drawn in the time zone of the machine the TUI runs on. *)
module Instant : sig
  type distance =
    | Same_day
    | Same_year
    | Other_year
  (** How far a moment lies from now on the operator's calendar. The nearer
      it is, the less of its date a reader still needs. *)

  val distance : now:Unix.tm -> Unix.tm -> distance
  (** Both arguments broken down in the same zone. *)

  type precision =
    | To_minute
    | To_second
        (** A log whose rows are seconds apart, where the order of two rows
            is what the reader came for. *)

  val cell_text : precision -> now:float -> float -> string
  (** The moment in a table column: the clock alone when it is today
      ([15:43:07]), month and day before it within this year
      ([11-10 23:58:02]), and the date alone in another year ([2025-11-10])
      -- a run that old is found by its day, and the row's detail keeps the
      clock. Never wider than {!cell_width}. *)

  val cell_width : precision -> int
  (** Cells the widest {!cell_text} occupies, so a column sized by it holds
      every row whole. *)

  val detail_text :
    ?localtime:(float -> Unix.tm) -> precision -> now:float -> float -> string
  (** The moment where one value has a line to itself. As {!cell_text}, but
      another year keeps its clock ([2025-11-10 23:58]). [localtime] breaks
      both moments down, [Unix.localtime] when it is not given. A screen that
      is handed its zone as an argument passes that zone, so every moment it
      draws reads in one zone. *)

  val offset_minutes : utc:Unix.tm -> local:Unix.tm -> int
  (** How far the operator's zone runs ahead of UTC, from the two breakdowns
      of one moment. Negative west of Greenwich. *)

  val zone_label : offset_minutes:int -> string
  (** The zone as its distance from UTC: [UTC+9], [UTC-8], [UTC+5:30], and
      [UTC] alone at zero. A zone's abbreviation would need a table this
      program does not have; its offset is what the breakdown already holds. *)

  val wall_clock : now:float -> string
  (** The current time with the zone every other moment on the screen is
      drawn in ([15:43 UTC+9]). The one place a screen names the zone. *)

  val next_minute : now:float -> float
  (** The instant the local minute next turns over: when {!wall_clock} next
      reads differently. A screen that draws the clock notes it with
      {!Redraw.note_change_at}; one too narrow to draw it does not. *)
end

(** The length of something still going, how long ago something happened, or
    how long until something comes: a length that changes while the reader
    looks at it (RFC tui-one-screen-grammar §6.2). It has no decimal, and past
    a minute it has no seconds, so past a minute it changes at most once a
    minute. A finished length keeps the finer ladder
    ({!Masc_tui_message_layout.elapsed_text}). *)
module Ongoing : sig
  val text : float -> string
  (** [45s], [3m], [1h04m], [2d03h], [120d]: whole seconds below a minute,
      whole minutes below an hour, then two units, and days alone from a
      hundred days. Never wider than six cells. A span at or below zero, or
      one that is not a number, reads [0s]. *)

  val next_change : float -> float option
  (** The shortest span longer than the given one that {!text} reads
      differently: the next whole second below a minute, the next whole
      minute below a day, then the next hour, then the next day. [None] past
      the longest span the ladder reads. *)

  val reading_floor : float -> float
  (** The shortest span {!text} reads the same as the given one. A
      countdown changes when what is left drops below it. *)

  val since : now:float -> float -> string
  (** {!text} of the span from a past moment to [now], noting when it next
      reads differently ({!Redraw.note_change_at}). A moment ahead of [now]
      (clocks that disagree) reads [0s]. *)

  val age : now:float -> float -> string
  (** {!since} for a length measured on another clock, such as the monotonic
      age of a pending read: [age ~now seconds] reads [seconds] and notes when
      it next reads differently, counting from the wall-clock [now]. *)

  val until : now:float -> float -> string
  (** {!text} of the span from [now] to a coming moment, noting when it next
      reads differently and when the moment arrives, since a screen words an
      arrived moment differently. A moment already passed reads [0s] and
      notes nothing. *)

  (** The same lengths in a narrow column, in one unit cut down to a whole
      count: [45s], [3m], [1h], [2d] (RFC tui-one-screen-grammar §6.2). A
      column reads every row on this ladder or none. *)
  module Narrow : sig
    val text : float -> string
    (** Whole seconds below a minute, whole minutes below an hour, whole hours
        below a day, then whole days. A span at or below zero, or one that is
        not a number, reads [0s]. *)

    val next_change : float -> float option
    (** As {!Ongoing.next_change}, for {!text}: the next whole second, minute,
        hour or day. *)

    val reading_floor : float -> float
    (** As {!Ongoing.reading_floor}, for {!text}. *)

    val since : now:float -> float -> string
    (** As {!Ongoing.since}, read with {!text}. *)

    val until : now:float -> float -> string
    (** As {!Ongoing.until}, read with {!text}. *)
  end
end

(** The mark ahead of a state word. One mark has one meaning on every screen
    (RFC tui-one-screen-grammar, section 7.2); the word beside it says which
    state of that kind it is. *)
module Mark : sig
  type t =
    | Settled  (** in order, finished, succeeded *)
    | Under_way
    | Waiting  (** waiting or resting *)
    | Paused  (** paused or cancelled *)
    | Caution  (** needs a look; stale *)
    | Failed  (** failed or rejected *)
    | Yours  (** the operator's turn *)

  val glyph : t -> string
  (** One display cell. *)
end

(** A value the screen does not have, drawn where the value goes as one mark
    that says why (RFC tui-one-screen-grammar, section 6.4). The sentence
    that says more belongs to the section or to the selected row's detail:
    [not observed], [미확인] and their like are not drawn where a value goes.

    A value that was read and found to be none is not unknown. It draws the
    dash the theme draws for an empty field. *)
module Unknown : sig
  type t =
    | Unread  (** being read, or not read yet *)
    | Read_failed
    | Unreported  (** read, and the answer did not carry it *)

  val glyph : t -> string
  (** One display cell: [◌], the {!Mark.Failed} mark [✕], and [?]. *)
end

(** How many of something. *)
module Count : sig
  val grouped : int -> string
  (** The whole number with a comma between each three digits: [8347] reads
      [8,347] and [774273] reads [774,273]. A number under a thousand is its
      digits alone, and a negative keeps its sign ahead of the first group
      ([-1,250]). Three screens each carried a copy of this, and the titles
      that count a long list -- [(50 of 8347)] -- carried none (RFC
      tui-one-screen-grammar, section 6.3). *)

  (** What a reading counts. A noun carries both languages, so a count
      cannot be written in one: the readings built with an English-only
      helper stayed English on a Korean screen ([0 runs], [0 entries]). *)
  type noun =
    | Keeper
    | Run
    | Call
    | Post
    | Entry  (** One record of a log. *)
    | Row  (** One row a list draws. *)
    | Event
    | Image  (** One picture staged on a message. *)
    | File  (** One file a keeper wrote. *)
    | Task  (** One Task of the Work hub. *)
    | Open_task  (** A Task not yet done or cancelled. *)

  val reading : ko:bool -> noun -> int -> string
  (** The count and what it counts, in the screen's language: [3 keepers],
      [1 entry], [8,347 posts]; [키퍼 3명], [기록 1건], [글 8,347개]. English
      names one thing in the singular and any other number in the plural.
      Korean names the thing first and counts it with the counter that
      thing takes. The figure is {!grouped}. *)

  val at_least : ko:bool -> noun -> int -> string
  (** {!reading} for a lower bound: [≥3 tasks], [작업 ≥3개]. A list read
      in part holds this many and may hold more (RFC tui-one-screen-grammar,
      section 6.3). *)
end

(** A digest, such as a revision or a SHA-256. *)
module Hash : sig
  val short : string -> string
  (** The digest's first twelve characters, or the whole value when it has
      no more than that (RFC tui-one-screen-grammar, section 5.2). A screen
      that draws a digest this way offers the whole value as a copy. *)
end

(** Where the reader is in what the screen holds. *)
module Position : sig
  type t =
    | Row of { at : int; total : int }
        (** The selected row, counted from one, and how many rows there
            are: [7/29]. Nothing selected is [at = 0] and draws a dash in
            the row's place. *)
    | Partial of { at : int; loaded : int; total : int }
        (** A list read in part: the selected row among the rows read, and
            how many the server holds: [1/50 · whole 8,347]. *)

  val text : whole:string -> t -> string
  (** [whole] is the word ahead of the server's total, in the screen's
      language. *)
end
