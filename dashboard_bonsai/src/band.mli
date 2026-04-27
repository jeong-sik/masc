(** Band — atomic primitive (Bonsai mirror of Preact [band.ts]).

    A 2px tall, 100%-wide decorative card-level state strip. Pure
    decoration ([aria-hidden="true"]); no role, no content, no label.
    See [band.ml] for full visual contract documentation. *)

open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Default
  | `Running
  | `Ok
  | `Warn
  | `Err
  | `Stalled
  ]

(** [view ?top_radius ?kind ()] renders a 2px decorative state strip.

    [kind] (default [`Default]): tone selector. [`Default] uses
    [--color-border-strong] (idle, no state). [`Running] uses
    [--color-accent-fg] plus a 6px box-shadow glow consuming
    [--color-accent-glow]. [`Ok | `Warn | `Err | `Stalled] use solid
    fill from [--color-status-{kind}].

    [top_radius] (default [true]): when [true], applies [1px 1px 0 0]
    border-radius so the strip matches a card's rounded top corners.
    Set [false] when the band is not at the top of a rounded
    container. *)
val view : ?top_radius:bool -> ?kind:kind -> unit -> Node.t
