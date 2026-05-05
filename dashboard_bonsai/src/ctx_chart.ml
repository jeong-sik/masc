(** Context pressure chart — 60-min rolling % per keeper.

    SVG polyline chart with 75/90% threshold guides. design_v2 의 context
    pressure section을 Phase 1에서 logs_view.ml에 인라인, Phase 2.A shell
    추출로 공용 모듈 분리.

    좌표계:
    - viewBox 0..600 × 0..100
    - x = (60 - t_minus_min) × 10  (t-60 → 0, t-0 → 600)
    - y = 100 - ctx_pct             (SVG origin 상단)

    색:
    - Live/Warn keepers: palette 순환 (--t-llm / --t-tool / --t-think / --t-wait)
    - Dead keepers: var(--t-err) + dashed stroke

    레이아웃 프레임(axis + tick)은 [Swim] 모듈의 Style 재사용 — 같은
    section 계열로 시각 연속성 유지. 이 모듈은 Swim에 의존. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .chart { display: grid; grid-template-columns: 140px 1fr; }
  .meta {
    border-right: 1px solid var(--color-border-default);
    padding: 10px 14px;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 4px;
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .meta_v {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.08em;
    text-transform: none;
    color: var(--color-fg-primary);
  }
  .track {
    position: relative;
    height: 120px;
    background: linear-gradient(180deg,
      color-mix(in oklab, var(--accent-blood) 4%, transparent) 0%,
      color-mix(in oklab, var(--accent-blood) 2%, transparent) 10%,
      transparent 25%,
      transparent 100%);
  }
  .svg { display: block; width: 100%; height: 120px; }
  .track_lbl {
    position: absolute;
    right: 8px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    pointer-events: none;
  }
  .lbl_warn { top: 22px; color: color-mix(in oklab, var(--color-accent-fg) 80%, var(--color-fg-muted)); }
  .lbl_dang { top: 6px;  color: color-mix(in oklab, var(--accent-blood) 80%, var(--color-fg-muted)); }

  @media (prefers-contrast: more) {
    .meta { border-right-width: 2px; border-right-color: var(--text-bright); color: var(--text-bright); }
    .track { outline: 1px solid var(--text-bright); }
    .lbl_warn, .lbl_dang { color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .meta { border-right-color: CanvasText; }
    .lbl_warn { color: Mark; }
    .lbl_dang { color: MarkText; }
  }

  @media (max-width: 760px) {
    .chart { grid-template-columns: 80px 1fr; }
  }
|}]

let svg_a k v = Attr.create k v

let polyline ~points ~stroke_var ~dashed =
  let dash_attr =
    if dashed then [ svg_a "stroke-dasharray" "3,3" ] else []
  in
  Node.create_svg "polyline"
    ~attrs:
      ([ svg_a "points" points
       ; svg_a "fill" "none"
       ; svg_a "stroke" stroke_var
       ; svg_a "stroke-width" "1.4"
       ; svg_a "stroke-linejoin" "round"
       ; svg_a "stroke-linecap" "round"
       ; svg_a "vector-effect" "non-scaling-stroke"
       ]
       @ dash_attr)
    []
;;

let guide ~y ~stroke_var =
  Node.create_svg "line"
    ~attrs:
      [ svg_a "x1" "0"
      ; svg_a "y1" (Printf.sprintf "%d" y)
      ; svg_a "x2" "600"
      ; svg_a "y2" (Printf.sprintf "%d" y)
      ; svg_a "stroke" stroke_var
      ; svg_a "stroke-width" "1"
      ; svg_a "stroke-dasharray" "4,4"
      ; svg_a "opacity" "0.55"
      ; svg_a "vector-effect" "non-scaling-stroke"
      ]
    []
;;

let hairline ~x =
  Node.create_svg "line"
    ~attrs:
      [ svg_a "x1" (Printf.sprintf "%d" x)
      ; svg_a "y1" "0"
      ; svg_a "x2" (Printf.sprintf "%d" x)
      ; svg_a "y2" "100"
      ; svg_a "stroke" "var(--color-border-default)"
      ; svg_a "stroke-width" "1"
      ; svg_a "opacity" "0.5"
      ; svg_a "vector-effect" "non-scaling-stroke"
      ]
    []
;;

(** Rotating palette for per-keeper ctx polylines. Dead keepers always use
    [--t-err] regardless of index so crashed lanes stand out. *)
let palette =
  [| "var(--t-llm)"; "var(--t-tool)"; "var(--t-think)"; "var(--t-wait)" |]
;;

let stroke_of ~(index : int) ~(status : Keepers_types.keeper_status) =
  match status with
  | Dead -> "var(--t-err)"
  | _ -> palette.(index mod Array.length palette)
;;

(** Build SVG [points] attribute from ctx_history. x = (60 - t_minus_min) * 10
    (so t-60 → 0, t-0 → 600). y = 100 - pct (SVG origin at top). Samples
    sorted by descending t_minus_min (older first). *)
let points_of (samples : Keepers_types.ctx_sample list) : string =
  let sorted =
    List.sort samples
      ~compare:(fun (a : Keepers_types.ctx_sample)
                    (b : Keepers_types.ctx_sample) ->
        Int.compare b.t_minus_min a.t_minus_min)
  in
  List.map sorted ~f:(fun (s : Keepers_types.ctx_sample) ->
    Printf.sprintf "%d,%d" ((60 - s.t_minus_min) * 10) (100 - s.ctx_pct))
  |> String.concat ~sep:" "
;;

(** Empty-state baseline — single dashed midline rendered when no keeper
    telemetry is available. Mirrors cockpit-kit Spark/Heartbeat empty branch
    (cb-shared.jsx:14-23, 29-50): a [data-empty="true"] svg with a dashed
    baseline communicates absence rather than fabricating a curve that looks
    like real data. Audit response 2026-05-05 §1.1. *)
let empty_baseline () =
  [ Node.create_svg "line"
      ~attrs:
        [ svg_a "x1" "0"
        ; svg_a "y1" "50"
        ; svg_a "x2" "600"
        ; svg_a "y2" "50"
        ; svg_a "stroke" "var(--color-fg-muted)"
        ; svg_a "stroke-width" "1"
        ; svg_a "stroke-dasharray" "3,3"
        ; svg_a "opacity" "0.6"
        ; svg_a "vector-effect" "non-scaling-stroke"
        ]
      []
  ]
;;

let polylines_of_keepers (ks : Keepers_types.keeper list) =
  List.mapi ks ~f:(fun i (k : Keepers_types.keeper) ->
    let dashed =
      match k.status with
      | Dead -> true
      | _ -> false
    in
    polyline
      ~points:(points_of k.ctx_history)
      ~stroke_var:(stroke_of ~index:i ~status:k.status)
      ~dashed)
;;

let meta_lines_of (ks : Keepers_types.keeper list) : string list =
  let pair (k : Keepers_types.keeper) =
    match k.status with
    | Dead -> Printf.sprintf "%s ×" k.name
    | _ -> Printf.sprintf "%s %d" k.name k.ctx_pct
  in
  let rec chunks = function
    | [] -> []
    | [ a ] -> [ a ]
    | a :: b :: rest -> (a ^ " · " ^ b) :: chunks rest
  in
  chunks (List.map ks ~f:pair)
;;

let view ?(keepers : Keepers_types.response = Keepers_types.fixture) () =
  let hairlines = List.init 7 ~f:(fun i -> hairline ~x:(i * 100)) in
  let guides =
    [ guide ~y:25 ~stroke_var:"var(--color-accent-fg-dim)" (* 75% warn  *)
    ; guide ~y:10 ~stroke_var:"var(--accent-blood)"     (* 90% danger *)
    ]
  in
  let is_empty = List.is_empty keepers.keepers in
  let polylines =
    if is_empty then empty_baseline ()
    else polylines_of_keepers keepers.keepers
  in
  let meta_lines =
    if is_empty then [ "no keeper data" ]
    else meta_lines_of keepers.keepers
  in
  let aria_desc =
    if is_empty then
      "Context usage chart over 60 minutes. No keeper data available."
    else
      "Context usage chart over 60 minutes. "
      ^ String.concat ~sep:"; " meta_lines
  in
  let svg_attrs =
    let base =
      [ svg_a "viewBox" "0 0 600 100"
      ; svg_a "preserveAspectRatio" "none"
      ; Style.svg
      ; Attr.role "img"
      ; Attr.create "aria-label" aria_desc
      ]
    in
    if is_empty then base @ [ Attr.create "data-empty" "true" ] else base
  in
  let svg =
    Node.create_svg "svg" ~attrs:svg_attrs (hairlines @ guides @ polylines)
  in
  Node.div
    ~attrs:[ Swim.Style.swim ]
    [ Node.div
        ~attrs:[ Swim.Style.axis ]
        [ Node.div ~attrs:[ Swim.Style.axis_sp ] [ Node.text "ctx · 60m" ]
        ; Node.div
            ~attrs:[ Swim.Style.axis_ax ]
            (List.init 6 ~f:(fun i ->
               let left_pct = i * 20 in
               let style =
                 Attr.create "style" (Printf.sprintf "left:%d%%" left_pct)
               in
               Node.div
                 ~attrs:[ Swim.Style.tick; style ]
                 [ Node.span
                     ~attrs:[ Swim.Style.tick_lbl ]
                     [ Node.text (Printf.sprintf "t-%d" ((5 - i) * 12)) ]
                 ]))
        ]
    ; Node.div
        ~attrs:[ Style.chart ]
        [ Node.div
            ~attrs:[ Style.meta ]
            (Node.text "keepers · %"
             :: List.map meta_lines ~f:(fun line ->
                  Node.span ~attrs:[ Style.meta_v ] [ Node.text line ]))
        ; Node.div
            ~attrs:[ Style.track ]
            [ svg
            ; Node.span
                ~attrs:[ Style.track_lbl; Style.lbl_dang ]
                [ Node.text "90% danger" ]
            ; Node.span
                ~attrs:[ Style.track_lbl; Style.lbl_warn ]
                [ Node.text "75% warn" ]
            ]
        ]
    ]
;;
