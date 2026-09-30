(** The card an issued play invite is drawn as (RFC
    play-link-for-the-shared-machine §2.4).

    Pure, so a test reads the exact rows an operator sees. The link a card
    holds is a credential: the server keeps only the token's hash, so the
    answer that carries the link is its only copy. Nothing in this module
    writes it anywhere but the rows {!draw} returns. *)

type t

val project_for_terminal :
  Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option
(** The colours a QR can be drawn in on this terminal. [None] under NO_COLOR
    and on a terminal that cannot show an exact black and white (16 colours or
    fewer, or no colour depth reported): a QR drawn in the terminal's own
    theme colours is a pattern of blocks that no phone reads, so the card says
    so and leaves the link. *)

val make :
  project:
    (Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  name:string ->
  expires_at:string ->
  link:string ->
  (t, string) result
(** The card for an issued invite. The QR is encoded and coloured here, once,
    not on every frame. [Error] when [link] is not an http(s) URL of printable
    ASCII with no blank in it: a card draws its link as text and encodes it as
    a QR, and only a link of that shape can be trusted to do both. [name] and
    [expires_at] come from the far end and are made safe to draw. *)

val name : t -> string
(** The invite's name, safe to draw. *)

val link : t -> string
(** The link itself, for the terminal clipboard. The one place it leaves the
    card apart from {!draw}; a caller that logs it has copied a credential. *)

val issued_notice : t -> retained:bool -> string
(** The line the conversation keeps of an issue: which invite, when it
    expires, and that [/play link] opens the card again. It never carries the
    link. [retained] says whether another card remains available by name in
    this TUI session; the server itself keeps only a hash of each link. *)

(** One row of the card, in the order they are drawn. The renderer styles each
    kind and pushes it; where the rows fall is decided here, once. *)
type row =
  | Heading of string  (** The invite's name and when it expires. *)
  | Advice of string  (** What the link is, in a few short lines. *)
  | Link_row of string  (** A piece of the link, cut to the width. *)
  | Qr_row of string  (** A row of the QR, already coloured. *)
  | Note of string  (** Why there is no QR: this terminal or this link cannot have one. *)
  | Qr_needs of { columns : int; rows : int }
      (** There is no QR because it does not fit. The cells the card needs,
          in the units of [draw]'s [width] and [rows]: what is asked for is
          what is missing, so a dimension that already fits comes back as it
          was given. The caller adds what surrounds the card to say it in
          window units. *)
  | Blank

val draw : t -> width:int -> rows:int -> row list
(** The card laid out for [width] cells and [rows] body rows. The QR is drawn
    only when the whole of it fits: a QR cut short scans as nothing, so when it
    does not fit the card says what it needs instead ({!Qr_needs}). *)
