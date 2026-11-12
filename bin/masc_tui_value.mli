(** The text a screen draws for a value it holds as a value.

    A screen hands over the reading itself -- seconds since the epoch -- and
    says where it is drawn; this module alone decides the notation. Screens
    used to build the text themselves, each with its own [Printf] format, so
    one moment read [11-11 15:36:13] on one screen and [2026-11-11T06:36:13Z]
    on the next, the first in the operator's zone and the second in UTC with
    nothing marking which was which (RFC tui-one-screen-grammar, section 6). *)

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

  val detail_text : precision -> now:float -> float -> string
  (** The moment where one value has a line to itself. As {!cell_text}, but
      another year keeps its clock ([2025-11-10 23:58]). *)

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

  val reading : ko:bool -> noun -> int -> string
  (** The count and what it counts, in the screen's language: [3 keepers],
      [1 entry], [8,347 posts]; [키퍼 3명], [기록 1건], [글 8,347개]. English
      names one thing in the singular and any other number in the plural.
      Korean names the thing first and counts it with the counter that
      thing takes. The figure is {!grouped}. *)
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
