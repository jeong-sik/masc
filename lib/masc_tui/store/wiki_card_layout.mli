(** Where each part of the Knowledge Wiki tab goes.

    [Screen_knowledge] draws into these rectangles, and [Update_nav] measures
    scrolling and moves between body links with the same ones. A change to the
    card layout therefore moves the drawn rows and the scrolled rows
    together. *)

module Rect = Masc_tui_core.Rect
module Layout = Masc_tui_ui.Layout

type frame = {
  bar : Rect.t;  (** The one-row pill bar above the cards. *)
  preview : Rect.t;  (** The wiki page card. *)
  aside : Rect.t;
      (** The links lint card when zoomed; the topic tree card otherwise. *)
  inline_rail : bool;
      (** Whether the page card may show its TOC and backlinks rail. *)
}

val frame : zoomed:bool -> Layout.breakpoint -> Rect.t -> frame
(** Split the Wiki tab area [rect] into the bar and the two cards. *)

type page_body =
  | Rail of { prose : Rect.t; rule : Rect.t; rail : Rect.t }
      (** Markdown in [prose], a one-column [rule], then the TOC and
          backlinks in [rail]. *)
  | Stacked of { backlinks : Rect.t; rule : Rect.t; markdown : Rect.t }
      (** A backlinks row and a divider row above the Markdown. A row is
          empty when the card has no room for it. *)

type page = {
  band : Rect.t;
      (** The title band: two rows, the second for the subtitle, when the
          card is tall enough; one row otherwise. *)
  body : page_body option;  (** [None] when the band fills the card. *)
}

val page : Layout.breakpoint -> inline_rail:bool -> Rect.t -> page
(** Lay out a loaded page inside the card's inner rectangle
    ({!Masc_tui_ui.Card.inner_rect} of [frame.preview]). The rail is used only
    when [inline_rail] is [true], the breakpoint is [Wide], and the area below
    the band is at least 68 columns by 8 rows. *)

val page_markdown : page -> Rect.t option
(** The rectangle the page Markdown is drawn and scrolled in; [None] when the
    band fills the card. On a very short card the rectangle has no rows. *)

type summary = {
  heading : Rect.t;  (** Slug, author and update time. *)
  counts : Rect.t;  (** Link and source counts. *)
  rule : Rect.t;  (** Divider. *)
  markdown : Rect.t;  (** The index summary as Markdown. *)
}

val summary : Layout.breakpoint -> Rect.t -> summary
(** Lay out the index summary of a page whose body has not loaded, inside the
    card's inner rectangle. Each row is empty when the card has no room for
    it. *)
