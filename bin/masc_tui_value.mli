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
end
