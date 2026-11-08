(** Visual axis cell for Keeper secondary row (RFC-0511 A1). *)

type tone =
  | Quiet
  | Attention
  | Failure

type t =
  { text : string
  ; tone : tone
  }

val separator : string
(** What sits between two cells of a row. *)

(** The cells of a row that are drawn. *)
type 'a fit =
  { drawn : 'a list  (** The leading cells that are drawn. *)
  ; cells_width : int  (** Their columns, [separator] apart. 0 when none is drawn. *)
  ; left_width : int
        (** The columns left for the text on their left, which keeps one column
            away from the first cell. All of [available] when none is drawn. *)
  }

val fit :
  available:int -> detail_floor:int option -> width:('a -> int) -> 'a list -> 'a fit
(** [fit ~available ~detail_floor ~width cells] draws the longest prefix of
    [cells] that fits a row [available] columns wide, so the last cells are the
    first to go. The first cell only has to fit [available]. A row with DETAIL
    text passes [Some n], and each later cell also has to leave that text [n]
    columns. A row without DETAIL text passes [None], and each later cell only
    has to fit [available]. *)
