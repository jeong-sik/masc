(** Caps — uppercase tracked label primitive (SPEC §3.2 [type-label]).

    11px sans-serif, uppercase, [--track-caps] letter-spacing. Three
    tones: [`Muted] (default), [`Dim], [`Brass]. See [caps.ml] for the
    full visual contract. *)

open! Bonsai_web
open Virtual_dom.Vdom

type tone =
  [ `Muted
  | `Dim
  | `Brass
  ]

(** [view ?tone label] renders an inline uppercase tracked label.

    [tone] (default [`Muted]): color slot. [`Muted] uses
    [--color-fg-muted], [`Dim] uses [--color-fg-disabled], [`Brass] uses
    [--color-accent-fg]. *)
val view : ?tone:tone -> string -> Node.t
