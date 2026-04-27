(** Band — atomic primitive (Bonsai mirror of Preact [band.ts]).

    Visual contract = SPEC §3.5 status (data, not chrome) + Preact
    [dashboard/src/components/band.ts] (PR #11174).

    A 2px tall, 100%-wide decorative strip rendered at the top of cards.
    Pure decoration: no role, [aria-hidden="true"]. Distinct from Bar
    (4px progress with fill width%), Chip (label), and Pill (capsule
    badge): Band is a *card-level* state strip, no quantity, no label.

    SPEC mapping (primitives.css [.band]):
    - default            → [--color-border-strong] (idle, no state)
    - [.band.is-running] → [--color-accent-fg] + glow shadow
    - [.band.is-ok]      → [--color-status-ok]
    - [.band.is-warn]    → [--color-status-warn]
    - [.band.is-err]     → [--color-status-err]
    - [.band.is-stalled] → [--color-status-stalled]

    Kind mapping (mission spec polyvars, 6 kinds):
    - [`Default]: idle / no-state, uses [--color-border-strong].
    - [`Running]: accent fg + 6px glow box-shadow consuming
      [--color-accent-glow] triplet (added in #11163).
    - [`Ok | `Warn | `Err | `Stalled]: solid status color from
      [--color-status-{kind}] tokens.

    Polyvar choice: [`Default] (not [`Idle]) mirrors Preact's [default]
    string literal. Preact band.ts has no [`Ghost`] variant — the 6
    kinds are: default, running, ok, warn, err, stalled. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .band_base {
    display: block;
    height: 2px;
    width: 100%;
  }

  .top_radius {
    border-radius: 1px 1px 0 0;
  }

  .k_default {
    background: var(--color-border-strong, #3a2e20);
  }

  .k_running {
    background: var(--color-accent-fg, #968228);
    box-shadow: 0 0 6px rgb(var(--color-accent-glow, 71 184 255) / 0.5);
  }

  .k_ok {
    background: var(--color-status-ok, #6a9a4a);
  }

  .k_warn {
    background: var(--color-status-warn, #b87828);
  }

  .k_err {
    background: var(--color-status-err, #e85050);
  }

  .k_stalled {
    background: var(--color-status-stalled, #8a6abf);
  }

  @media (forced-colors: active) {
    .band_base    { background: ButtonText; }
    .k_default    { background: GrayText; }
    .k_running    { background: Highlight; box-shadow: none; }
    .k_ok         { background: Highlight; }
    .k_warn       { background: Mark; }
    .k_err        { background: MarkText; }
    .k_stalled    { background: ButtonText; }
  }
|}]

type kind =
  [ `Default
  | `Running
  | `Ok
  | `Warn
  | `Err
  | `Stalled
  ]

let kind_class : kind -> Attr.t = function
  | `Default -> Style.k_default
  | `Running -> Style.k_running
  | `Ok -> Style.k_ok
  | `Warn -> Style.k_warn
  | `Err -> Style.k_err
  | `Stalled -> Style.k_stalled
;;

let kind_string : kind -> string = function
  | `Default -> "default"
  | `Running -> "running"
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
  | `Stalled -> "stalled"
;;

let view ?(top_radius = true) ?(kind = `Default) () : Node.t =
  let attrs =
    [ Style.band_base
    ; kind_class kind
    ; Attr.create "aria-hidden" "true"
    ; Attr.create "data-kind" (kind_string kind)
    ]
  in
  let attrs = if top_radius then Style.top_radius :: attrs else attrs in
  Node.div ~attrs []
;;
