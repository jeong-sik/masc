(** Sep — atomic divider primitive (Bonsai mirror of Preact [sep.ts]).

    See [sep.mli] for the public contract.

    Visual reference:
    - SPEC primitives.css [.sep-v]: width 1px, height 16px,
      background [var(--color-border-strong)], margin 0 var(--sp-2).
    - SPEC primitives.css [.sep-h]: height 1px,
      background [var(--color-border-default)], margin var(--sp-2) 0.
    - Preact [dashboard/src/components/sep.ts] (PR #11203) maps
      [--sp-2] to a literal 8px since the dashboard runtime does not
      ship the [--sp-N] scale; this mirror does the same.

    Per-orientation tone defaults (SPEC):
    - Vertical → [.sep-v] uses [--color-border-strong]
    - Horizontal → [.sep-h] uses [--color-border-default]
    The bonsai mirror preserves both defaults; passing [tone]
    explicitly overrides them.

    Distinct from sibling primitives:
    - [Band] — 2px decorative state strip at top of a card. Carries
      kind tone, never neutral. Sep is *neutral*, no kind, no state.
    - [Bar] — 4px progress fill. Conveys quantity, not adjacency.
    - Tailwind [divide-y] (Preact-side equivalent) — between-children
      divider applied via parent. Sep is a *self-contained element*
      between two adjacent siblings. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .sep_base {
    flex-shrink: 0;
  }

  .orient_h {
    display: block;
    height: 1px;
    width: 100%;
    margin: 8px 0;
  }

  .orient_v {
    display: inline-block;
    width: 1px;
    height: 16px;
    margin: 0 8px;
    vertical-align: middle;
  }

  .tone_default {
    background: var(--color-border-default, #3a2e20);
  }

  .tone_strong {
    background: var(--color-border-strong, #5a4632);
  }

  .no_margin_h { margin: 0; }
  .no_margin_v { margin: 0; }
|}]

type orientation =
  [ `Horizontal
  | `Vertical
  ]

type tone =
  [ `Default
  | `Strong
  ]

(** SPEC per-orientation default tone:
    - Vertical → strong (heavier inline-row separator)
    - Horizontal → default (softer block-stack section break) *)
let default_tone : orientation -> tone = function
  | `Horizontal -> `Default
  | `Vertical -> `Strong
;;

let orientation_class : orientation -> Attr.t = function
  | `Horizontal -> Style.orient_h
  | `Vertical -> Style.orient_v
;;

let tone_class : tone -> Attr.t = function
  | `Default -> Style.tone_default
  | `Strong -> Style.tone_strong
;;

let orientation_name : orientation -> string = function
  | `Horizontal -> "horizontal"
  | `Vertical -> "vertical"
;;

let tone_name : tone -> string = function
  | `Default -> "default"
  | `Strong -> "strong"
;;

let no_margin_class : orientation -> Attr.t = function
  | `Horizontal -> Style.no_margin_h
  | `Vertical -> Style.no_margin_v
;;

let view ?(orientation = `Horizontal) ?tone ?(no_margin = false) () : Node.t =
  let resolved_tone =
    match tone with
    | Some t -> t
    | None -> default_tone orientation
  in
  let base_attrs =
    [ Style.sep_base
    ; orientation_class orientation
    ; tone_class resolved_tone
    ; Attr.create "role" "separator"
    ; Attr.create "aria-orientation" (orientation_name orientation)
    ; Attr.create "data-orientation" (orientation_name orientation)
    ; Attr.create "data-tone" (tone_name resolved_tone)
    ]
  in
  let attrs =
    if no_margin then no_margin_class orientation :: base_attrs else base_attrs
  in
  Node.div ~attrs []
;;
