(** The ranges a Keeper's lane refused, held by its writer between asks
    (RFC librarian-call-only-proposes §7.6, §21.2).

    Without them every commit would ask the widest width again and be
    refused again. A refused range is held with its size and with how much
    of it is still unread. The next ask is no wider than the innermost
    range, and asks all of a range only after part of it was committed.

    The writer holds this in memory and nothing of it is on disk. Time does
    not change it; only the events §7.6 names do. A boot starts with none,
    and so do a declaration of another lane value, a restart of reading and
    an adoption. Nothing here reads a file or a clock.

    [specs/bug-models/LibrarianWidth.tla] has the same rules. Its names are
    these:

    {v
    model                                here
    su, si                               the units level and the items level of t
    Entry(n) = [size, left]              a range { size; left }
    w, NextW, EntryWidth                 next
    OfferUnits, HeadItems                offered.units, offered.head_items
    PartialHead                          a commit whose within is Item _
    FullUnits                            passed's Whole_units
    Sub, AfterCommitU, AfterCommitI      committed
    Same, Push, PushUnits, PushItems     refused
    Narrower                             next (refused t ~asked w)
    OfferUnits >= 2 \/ HeadItems >= 2    breadth's Wider
    v} *)

(** One or more: no width is narrower than one item. *)
type count = private int

type width =
  | All (** Every unit not yet read. *)
  | Units of count
  (** The first this many units that hold items, with the units that hold
      none among them. *)
  | Items of count (** The first this many unread items of the first unit that holds items. *)

(** The first unread item alone: what a question that shows one item and
    no Memory reads (§7.4, [Read_item_alone]). *)
val head_item : width

(** What one question carried, as the ask that made it counted (§7.1). *)
type offered =
  { units : int (** Units that hold items. A unit that holds none is not counted. *)
  ; head_items : int (** Items of the first unit that holds items. *)
  }

(** A question that carried more than one item. Only {!breadth} makes one. *)
type wider = private offered

type breadth =
  | One_item
  (** The question carried one item: the bottom (§7.4). A question of no
      unit is never made. *)
  | Wider of wider

val breadth : offered -> breadth

(** How much a commit passed of what its question carried. A skip passes
    what its question would have carried. *)
type passed =
  | Whole_units of int (** Every unit carried, the last read whole. *)
  | Head_items of int (** Items of the first unit, which goes on after them. *)

(** A commit through [within]: [Whole] passed every unit carried, [Item _]
    the head's items and not the head. *)
val passed : offered -> Librarian_log.within -> passed

type t

val empty : t

(** A refusal of a question asked at [asked]. The units it carried go onto
    the units level for [All] and [Units _]. A question of one unit puts its
    items onto the items level. A level whose innermost range is exactly
    this count and still whole takes nothing: a range refused again from
    the same place is the same range. One partly committed and refused for
    what is left is another range. *)
val refused : t -> asked:width -> wider -> t

(** A commit: every range of the level it passed counts that many less, and
    one with nothing left is dropped. Whole units end the head, so the items
    level is emptied. *)
val committed : t -> passed -> t

(** The width of the next ask, from the innermost range, the items level
    first. A range still whole is asked by half, rounded down; one partly
    committed is asked for what is left. With no range it is [All]. *)
val next : t -> width
