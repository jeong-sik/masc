(** Spark — inline mini bar-chart primitive.

    16px row of 2px-wide bars (1px gap) with each bar height proportional
    to its value over the series max. See [spark.ml] for layout and color
    contract. *)

open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Ok
  | `Warn
  | `Err
  | `Info
  | `Idle
  | `Stalled
  | `Brass
  | `Neutral
  ]

(** [view ~values ~kind] renders an inline mini-chart.

    [values]: bar magnitudes. Negative or zero values clamp to a 1px
    baseline tick. Empty list renders an empty 16px placeholder.

    [kind]: bar fill color. Status kinds consume
    [--color-status-{kind}]; [`Brass] uses [--color-accent-fg]; [`Neutral]
    uses [--color-fg-muted]. *)
val view : values:int list -> kind:kind -> Node.t
