(** Bar — atomic primitive (Bonsai mirror of Preact [bar.ts]).

    Visual contract = SPEC primitives §[bar] (4px progress bar with
    kind-tinted fill) + Preact PR #11170. See [bar.ml] for full visual
    contract documentation. *)

open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Default
  | `Ok
  | `Warn
  | `Err
  ]

(** [bar_percent v] clamps [v] to [[0, 100]] and rounds to integer
    percent. [Float.is_nan v] coerces to [0]. Pure — exposed so callers
    that label a Bar inside a parent label can reuse the same rounding
    without mounting the component. Mirrors Preact [barPercent]. *)
val bar_percent : float -> int

(** [view ?kind ?aria_label ?test_id ?title ?no_transition ~value ()]
    renders a 4px progress bar.

    [value] (required, integer 0–100): Out-of-range values clamp on
    render. Float-precision is intentionally not exposed at the
    primitive boundary — callers that need fractional percent should
    pre-round via [bar_percent].

    [kind] (default [`Default]): fill tone selector. [`Default] = brass
    accent; [`Ok] / [`Warn] / [`Err] = status tokens.

    [aria_label] (default [Some "<pct>%"]): override the auto label.

    [test_id]: forwarded to [data-testid].

    [title]: native [title] attribute for hover tooltips.

    [no_transition] (default [false]): drop the 500ms width transition
    when [true]. Useful for first paint or non-animating contexts. *)
val view
  :  ?kind:kind
  -> ?aria_label:string
  -> ?test_id:string
  -> ?title:string
  -> ?no_transition:bool
  -> value:int
  -> unit
  -> Node.t
