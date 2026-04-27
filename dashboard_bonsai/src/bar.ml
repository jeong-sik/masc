(** Bar — atomic primitive (Bonsai mirror of Preact [bar.ts]).

    Visual contract = SPEC primitives §[bar] (4px progress bar with
    kind-tinted fill) + Preact [dashboard/src/components/bar.ts] (PR
    #11170). Pure quantity primitive — shows "how full" without
    announcing a state transition. Distinct from Pill (16px stateful
    capsule) and Chip (sharp 2px label).

    [role="progressbar"] on the host gives assistive tech the
    value/min/max contract directly.

    Fill token mapping (no glow channel — Bar is solid fill):
    - [`Default] → [--color-accent-fg]    (brass)
    - [`Ok]      → [--color-status-ok]
    - [`Warn]    → [--color-status-warn]
    - [`Err]     → [--color-status-err]

    Width is data-driven (depends on value), so it is applied as an
    inline style. Static geometry (4px height, 2px radius, track
    background, transition) lives in [ppx_css]. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .track {
    display: block;
    width: 100%;
    height: 4px;
    background: var(--color-bg-elevated, #1a1410);
    border-radius: 2px;
    overflow: hidden;
  }

  .fill_base {
    display: block;
    height: 100%;
    transition: width 500ms;
  }

  .fill_no_transition {
    display: block;
    height: 100%;
  }

  .k_default { background: var(--color-accent-fg, #968228); }
  .k_ok      { background: var(--color-status-ok, #6a9a4a); }
  .k_warn    { background: var(--color-status-warn, #b87828); }
  .k_err     { background: var(--color-status-err, #e85050); }

  @media (prefers-contrast: more) {
    .track { border: 1px solid var(--text-bright); }
  }

  @media (forced-colors: active) {
    .track     { border: 1px solid ButtonText; background: Canvas; }
    .k_default { background: Highlight; }
    .k_ok      { background: Highlight; }
    .k_warn    { background: Mark; }
    .k_err     { background: MarkText; }
  }
|}]

type kind =
  [ `Default
  | `Ok
  | `Warn
  | `Err
  ]

(** [bar_percent v] clamps [v] to [[0, 100]] and rounds to integer
    percent. Mirrors Preact's [barPercent] (pure helper). [Float.is_nan
    v] coerces to [0] to match Preact's [Number.isNaN] guard. *)
let bar_percent (v : float) : int =
  if Float.is_nan v
  then 0
  else (
    let clamped = Float.max 0.0 (Float.min 100.0 v) in
    Float.iround_nearest_exn clamped)
;;

let kind_class : kind -> Attr.t = function
  | `Default -> Style.k_default
  | `Ok -> Style.k_ok
  | `Warn -> Style.k_warn
  | `Err -> Style.k_err
;;

let kind_data : kind -> string = function
  | `Default -> "default"
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
;;

let view
      ?(kind : kind = `Default)
      ?(aria_label : string option)
      ?(test_id : string option)
      ?(title : string option)
      ?(no_transition : bool = false)
      ~(value : int)
      ()
  : Node.t
  =
  let pct = bar_percent (Float.of_int value) in
  let announce =
    match aria_label with
    | Some s -> s
    | None -> Printf.sprintf "%d%%" pct
  in
  let host_attrs =
    [ Style.track
    ; Attr.create "role" "progressbar"
    ; Attr.create "aria-valuenow" (Int.to_string pct)
    ; Attr.create "aria-valuemin" "0"
    ; Attr.create "aria-valuemax" "100"
    ; Attr.create "aria-label" announce
    ; Attr.create "data-kind" (kind_data kind)
    ]
  in
  let host_attrs =
    match test_id with
    | Some t -> Attr.create "data-testid" t :: host_attrs
    | None -> host_attrs
  in
  let host_attrs =
    match title with
    | Some t -> Attr.create "title" t :: host_attrs
    | None -> host_attrs
  in
  let fill_base =
    if no_transition then Style.fill_no_transition else Style.fill_base
  in
  let fill_attrs =
    [ fill_base
    ; kind_class kind
    ; Attr.create "aria-hidden" "true"
    ; Attr.style (Css_gen.create ~field:"width" ~value:(Printf.sprintf "%d%%" pct))
    ]
  in
  Node.div ~attrs:host_attrs [ Node.span ~attrs:fill_attrs [] ]
;;
