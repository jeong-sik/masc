(** Sep — atomic divider primitive (Bonsai mirror of Preact [sep.ts]).

    1px hairline rule between adjacent siblings. Two orientations:

    - [`Horizontal] (default) — 1px tall, full-width, with 8px vertical
      margin. Drops between block siblings inside a stacked card or
      list (between two paragraph blocks, between a description and an
      action row).
    - [`Vertical] — 1px wide × 16px tall with 8px horizontal margin.
      Drops between inline siblings inside a flex row (keyboard
      shortcut hint groups, action button clusters, breadcrumb
      separators).

    Two tones (per-orientation default reflects SPEC):
    - [`Vertical] → [`Strong] default ([--color-border-strong]) — inline
      rows want a heavier tone so the eye can resolve the boundary
      between dense sibling clusters.
    - [`Horizontal] → [`Default] default ([--color-border-default]) —
      block stacks already have generous whitespace; a softer tone
      reads as "section break".

    Either default can be overridden when the adjacent context calls
    for it.

    Visual contract = SPEC primitives.css [.sep-h] / [.sep-v]
    selectors + Preact reference [dashboard/src/components/sep.ts]
    (PR #11203 atom 10/14). *)

open! Bonsai_web
open Virtual_dom.Vdom

type orientation =
  [ `Horizontal
  | `Vertical
  ]

type tone =
  [ `Default
  | `Strong
  ]

(** [view ?orientation ?tone ?no_margin ()] renders the separator.

    [orientation] (default [`Horizontal]): see {!type:orientation}.

    [tone] (default per-orientation): SPEC default is [`Strong] for
    vertical and [`Default] for horizontal. Pass explicitly to flip
    the per-orientation default.

    [no_margin] (default [false]): drops the 8px SPEC margin. Use
    when the parent layout already provides the gap (flex-gap,
    space-y-N) or when the separator should hug its siblings.

    Renders a [<div role="separator">] with [aria-orientation] set to
    the chosen axis. *)
val view : ?orientation:orientation -> ?tone:tone -> ?no_margin:bool -> unit -> Node.t
