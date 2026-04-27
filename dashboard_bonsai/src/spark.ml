(** Spark — inline mini-chart primitive (bar variant).

    Bonsai analogue of Preact [dashboard/src/components/common/sparkline.ts]
    adapted to the SPEC §primitives bar layout: 16px height, 2px bars, 1px
    gap. Unlike the Preact canvas-based sparkline (polyline + filled area),
    this primitive renders one inline-block per data point so it composes
    inside ppx_css and survives forced-colors mode without a custom paint
    path.

    Layout contract:
    - Outer wrapper height = 16px (SPEC primitive row).
    - Each bar width = 2px, gap = 1px (rendered as flex gap).
    - Bar height proportional to [v / max] of the series; minimum visible
      height 1px so a zero value still has a baseline tick.
    - Empty list (or all-zero) renders as a chromeless 16px placeholder so
      callers can keep layout stable.

    Kind axis mirrors [Chip.kind] minus a [`Neutral] / [`Idle] dot
    suppression — every kind has a fill color because there's nothing else
    on a sparkline to carry attribution. [`Brass] uses the accent-fg
    triplet; statuses use [--color-status-{kind}]. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .spark {
    display: inline-flex;
    align-items: flex-end;
    height: 16px;
    gap: 1px;
    line-height: 1;
    vertical-align: middle;
  }

  .bar {
    display: inline-block;
    width: 2px;
    flex: none;
    border-radius: 0;
  }

  .k_ok      { background: var(--color-status-ok, #6a9a4a); }
  .k_warn    { background: var(--color-status-warn, #b87828); }
  .k_err     { background: var(--color-status-err, #e85050); }
  .k_info    { background: var(--color-status-info, #968228); }
  .k_idle    { background: var(--color-status-idle, #807870); }
  .k_stalled { background: var(--color-status-stalled, #8a6abf); }
  .k_brass   { background: var(--color-accent-fg, #968228); }
  .k_neutral { background: var(--color-fg-muted, #9a846e); }

  @media (prefers-contrast: more) {
    .bar { outline: 1px solid var(--text-bright); }
  }

  @media (forced-colors: active) {
    .k_ok, .k_info, .k_brass { background: Highlight; }
    .k_warn                  { background: Mark; }
    .k_err                   { background: MarkText; }
    .k_idle, .k_neutral      { background: GrayText; }
    .k_stalled               { background: ButtonText; }
  }
|}]

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

let kind_class : kind -> Attr.t = function
  | `Ok -> Style.k_ok
  | `Warn -> Style.k_warn
  | `Err -> Style.k_err
  | `Info -> Style.k_info
  | `Idle -> Style.k_idle
  | `Stalled -> Style.k_stalled
  | `Brass -> Style.k_brass
  | `Neutral -> Style.k_neutral
;;

let kind_name : kind -> string = function
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
  | `Info -> "info"
  | `Idle -> "idle"
  | `Stalled -> "stalled"
  | `Brass -> "brass"
  | `Neutral -> "neutral"
;;

(** Pure: largest non-negative value in [vs], or [1] when the series is
    empty / all-zero. The fallback keeps the height divisor non-zero and
    renders an all-zero series as a flat baseline rather than dividing by
    zero. *)
let series_max (vs : int list) : int =
  let m =
    List.fold vs ~init:0 ~f:(fun acc v -> if v > acc then v else acc)
  in
  if m <= 0 then 1 else m
;;

(** Map [v] in [0..max] to a pixel height in [1..16]. Negative / zero
    values clamp to a 1px baseline tick so the column still reads as a
    data point. *)
let bar_height ~(max_v : int) (v : int) : int =
  if v <= 0
  then 1
  else (
    let raw = v * 16 / max_v in
    if raw < 1 then 1 else if raw > 16 then 16 else raw)
;;

let view ~(values : int list) ~(kind : kind) : Node.t =
  let max_v = series_max values in
  let bars =
    List.map values ~f:(fun v ->
      let h = bar_height ~max_v v in
      let style = Attr.create "style" (Printf.sprintf "height:%dpx" h) in
      Node.span
        ~attrs:[ Style.bar; kind_class kind; style ]
        [])
  in
  Node.span
    ~attrs:
      [ Style.spark
      ; Attr.role "img"
      ; Attr.create "data-kind" (kind_name kind)
      ; Attr.create "data-count" (Int.to_string (List.length values))
      ]
    bars
;;
