(** Caps — uppercase tracked label primitive.

    SPEC §3.2 [type-label] role: 11px / [--track-caps] (0.08em letter
    spacing) / sans / uppercase. The closest Preact analogue is
    [dashboard/src/components/common/section-cap.ts] which encodes the
    same "tiny all-caps subhead" pattern in Tailwind utilities. There is
    no standalone [caps] primitive on the Preact side — the Bonsai surface
    inherits the role directly from the SPEC.

    Two tone slots match the existing SectionCap usage on the Preact side:
    - [`Muted] (default) — section heads next to body text
      ([--color-fg-muted]).
    - [`Dim] — denser hush for telemetry rows
      ([--color-fg-disabled]).

    The caller owns layout (margin, flex composition). Caps renders as a
    single [<span>] with no border, background, or padding so it can sit
    inline beside a value or stack as a heading. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .caps {
    display: inline-block;
    font-family: var(--font-sans, ui-sans-serif, system-ui, sans-serif);
    font-size: 11px;
    line-height: var(--lh-tight, 1.1);
    letter-spacing: var(--track-caps, 0.08em);
    text-transform: uppercase;
    font-weight: 600;
    color: var(--color-fg-muted, #9a846e);
  }

  .t_muted { color: var(--color-fg-muted, #9a846e); }
  .t_dim   { color: var(--color-fg-disabled, #6a5a4a); }
  .t_brass { color: var(--color-accent-fg, #968228); }

  @media (forced-colors: active) {
    .t_muted, .t_dim { color: GrayText; }
    .t_brass         { color: ButtonText; }
  }
|}]

type tone =
  [ `Muted
  | `Dim
  | `Brass
  ]

let tone_class : tone -> Attr.t = function
  | `Muted -> Style.t_muted
  | `Dim -> Style.t_dim
  | `Brass -> Style.t_brass
;;

let tone_name : tone -> string = function
  | `Muted -> "muted"
  | `Dim -> "dim"
  | `Brass -> "brass"
;;

let view ?(tone : tone = `Muted) (label : string) : Node.t =
  Node.span
    ~attrs:
      [ Style.caps
      ; tone_class tone
      ; Attr.create "data-tone" (tone_name tone)
      ]
    [ Node.text label ]
;;
