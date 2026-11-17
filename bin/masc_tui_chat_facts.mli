(** The facts drawn below a Keeper chat, laid out so none of them is cut
    (RFC tui-one-screen-grammar §5.5).

    A row that cannot hold every fact breaks between two of them. A fact wider
    than a whole row breaks at the row's edge and continues on the next. No
    value is shortened and no fact is left out for width. *)

(** What kind of thing a value is. The kind picks its colour (§7.3); the label
    says the same thing in words, so the row reads without colour. *)
type 'reading tone =
  | Who
      (** Whom the composer addresses and through what: the Keeper, its
          runtime, its mode, its gate. *)
  | Amount  (** How much: context, tokens, counts, elapsed time. *)
  | Reading of 'reading
      (** A reading of state. The caller's own type says which, and its
          palette gives the status colour, so a module that builds facts
          needs no colours. *)
  | Plain

type 'reading t =
  { label : string
        (** Drawn receded, directly before the value, with its own punctuation
            and space: ["gate: "]. Empty for a value that names itself. *)
  ; value : string  (** Terminal-safe text without SGR. *)
  ; tone : 'reading tone
  }

val fact : ?label:string -> 'reading tone -> string -> 'reading t

val line : 'reading t list -> string
(** The facts on one line of any width, joined the way a row joins them. For a
    caller that wants the text and does no layout. *)

type 'reading piece

type 'reading layout =
  { rows : 'reading piece list list
  ; omitted : int
        (** Facts not drawn at all because [max_rows] ran out. When there are
            any, the last row ends with [more omitted]. *)
  ; cut : bool
        (** The last fact drawn is only its head, ending in ["…"]. *)
  }

val layout
  :  max_cells:int
  -> max_rows:int
  -> more:(int -> string)
  -> 'reading t list
  -> 'reading layout
(** Rows of at most [max_cells] display cells. A fact with neither label nor
    value is not drawn and not counted.

    When the facts need more than [max_rows] rows, the longest leading run of
    facts that fits together with [more n] is drawn, [n] being how many facts
    follow it. A fact that fits a row is drawn whole or not at all, so a
    capped block never shows part of a number or a name. The fact after that
    run is cut instead when it is wider than a row: it is prose, drawn in
    pieces at any height, and its head is drawn as far as the rows go, ending
    in ["…"] before the count of the facts behind it. [max_rows <= 0] draws
    nothing and omits every fact.

    Two widths are outside this: [max_cells] is read as at least 1, and a row
    of one cell holds a two-cell character whole, so that row is two cells
    wide. When [more n] alone needs more than [max_rows] rows, the rows hold
    its beginning. A label as wide as a row is broken with its value and takes
    the value's colour. *)

val rows_wanted : max_cells:int -> 'reading t list -> int
(** How many rows {!layout} takes for these facts when nothing caps it. *)

type 'reading palette =
  { label_style : string  (** Labels, separators and the omission mark. *)
  ; who_style : string
  ; amount_style : string
  ; reading_style : 'reading -> string
  ; reset : string
  }

val draw : 'reading palette -> 'reading piece list -> string
(** One row with its styles, each span closed by [palette.reset]. *)

val text : 'reading piece list -> string
(** The same row without styles. *)
