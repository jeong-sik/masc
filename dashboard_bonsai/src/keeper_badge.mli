(** KeeperBadge — keeper attribution sigil-square primitive.

    SPEC §3.6.3 attribution rule: color + sigil. Renders a colored
    [--color-keeper-N] background with a 2-letter mono uppercase sigil in
    [--color-bg-page] foreground. See [keeper_badge.ml] for the full
    visual contract. *)

open! Bonsai_web
open Virtual_dom.Vdom

type size =
  [ `Sm
  | `Md
  | `Lg
  ]

(** [view ?size ~slot ~sigil ()] renders a keeper sigil-square.

    [size] (default [`Md]): badge edge length. [`Sm] = 14px / 8px font,
    [`Md] = 18px / 9px font, [`Lg] = 24px / 11px font.

    [slot]: 1..12 keeper color slot per SPEC §3.6.1. Out-of-range values
    clamp to a neutral grey badge (data-slot="oob") so malformed callers
    still render.

    [sigil]: 2-letter monogram. Longer strings are byte-truncated to the
    first 2 chars; empty strings render as a chromeless square. *)
val view : ?size:size -> slot:int -> sigil:string -> unit -> Node.t
