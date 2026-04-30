(** Tier F3 — provenance DAG renderer.

    Replaces F2's flat origins/descendants id-list with a 3-layer
    SVG diagram:

      [origin1]   [origin2]   [origin3]      ← top row
            \      |        /
             \     |       /
              v    v      v
              [SELECTED]                      ← center
              /    |     \
             /     |      \
            v      v       v
      [desc1]   [desc2]   [desc3]              ← bottom row

    The selected node carries the artifact id (truncated). Origin and
    descendant nodes carry their truncated ids. Edges are simple
    straight lines from each origin to selected, and from selected
    to each descendant. No multi-hop traversal — F3 only renders the
    1-hop neighborhood the server already returned via
    [/api/v1/multimodal/provenance/<id>]. Multi-hop walking is
    deferred to a follow-up (F3.1).

    Layout is computed in OCaml; SVG strings are emitted via
    [Virtual_dom.Svg]. The diagram auto-sizes height based on row
    counts and is horizontally centered around the SELECTED node. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.5rem;
  }
  .svg_wrap {
    width: 100%;
    overflow-x: auto;
    overflow-y: hidden;
    padding: 0.5rem 0;
  }
  .legend {
    display: flex;
    gap: 1.25rem;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.7rem;
    color: var(--color-fg-muted);
  }
  .legend_dot {
    display: inline-block;
    width: 0.6rem;
    height: 0.6rem;
    border-radius: 2px;
    margin-right: 0.4rem;
    vertical-align: middle;
  }
  .empty {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
|}]

(* ── layout primitives ─────────────────────────────────────────── *)

let node_w = 140
let node_h = 32
let h_gap = 16
let v_gap = 56

(** Compute the x-coordinate (top-left of the node) for the [i]-th
    node in a row of [n] nodes, given the diagram canvas width
    [canvas_w]. The row is centered. *)
let row_x ~canvas_w ~n ~i =
  let total_w = (n * node_w) + ((max 0 (n - 1)) * h_gap) in
  let start_x = (canvas_w - total_w) / 2 in
  start_x + (i * (node_w + h_gap))
;;

let truncate_id (s : string) : string =
  if String.length s <= 14 then s else String.sub s ~pos:0 ~len:12 ^ "…"
;;

(* ── SVG primitives ─ Node.create_svg patterns mirror ctx_chart.ml *)

let svg_attr name v = Attr.create name v

let line ~x1 ~y1 ~x2 ~y2 ~stroke =
  Node.create_svg "line"
    ~attrs:
      [ svg_attr "x1" (Int.to_string x1)
      ; svg_attr "y1" (Int.to_string y1)
      ; svg_attr "x2" (Int.to_string x2)
      ; svg_attr "y2" (Int.to_string y2)
      ; svg_attr "stroke" stroke
      ; svg_attr "stroke-width" "1.2"
      ]
    []
;;

let rect ~x ~y ~w ~h ~fill ~stroke =
  Node.create_svg "rect"
    ~attrs:
      [ svg_attr "x" (Int.to_string x)
      ; svg_attr "y" (Int.to_string y)
      ; svg_attr "width" (Int.to_string w)
      ; svg_attr "height" (Int.to_string h)
      ; svg_attr "rx" "4"
      ; svg_attr "ry" "4"
      ; svg_attr "fill" fill
      ; svg_attr "stroke" stroke
      ; svg_attr "stroke-width" "1"
      ]
    []
;;

let label ~x ~y ~fill text =
  Node.create_svg "text"
    ~attrs:
      [ svg_attr "x" (Int.to_string x)
      ; svg_attr "y" (Int.to_string y)
      ; svg_attr "fill" fill
      ; svg_attr "font-family" "'JetBrains Mono', ui-monospace, monospace"
      ; svg_attr "font-size" "11"
      ; svg_attr "text-anchor" "middle"
      ; svg_attr "dominant-baseline" "central"
      ]
    [ Node.text text ]
;;

(* ── per-row + per-edge rendering ──────────────────────────────── *)

type role =
  | Role_origin
  | Role_selected
  | Role_descendant

let colors_for = function
  | Role_origin ->
    "color-mix(in oklab, var(--color-bg-page) 90%, var(--accent-blood) 10%)",
    "var(--color-border-default)",
    "var(--color-fg-primary)"
  | Role_selected ->
    "color-mix(in oklab, var(--accent-blood) 22%, transparent)",
    "color-mix(in oklab, var(--accent-blood) 60%, transparent)",
    "var(--text-bright)"
  | Role_descendant ->
    "color-mix(in oklab, var(--color-bg-page) 90%, var(--accent-blood) 6%)",
    "var(--color-border-default)",
    "var(--color-fg-primary)"
;;

let render_node ~canvas_w ~row_y ~n ~i ~id ~role =
  let x = row_x ~canvas_w ~n ~i in
  let fill, stroke, fg = colors_for role in
  let cx = x + (node_w / 2) in
  let cy = row_y + (node_h / 2) in
  Node.create_svg "g"
    ~attrs:[]
    [ rect ~x ~y:row_y ~w:node_w ~h:node_h ~fill ~stroke
    ; label ~x:cx ~y:cy ~fill:fg (truncate_id id)
    ]
;;

(** Edge from a top-row node to the center selected node. Connects
    the bottom-center of the top node to the top-center of the
    center node. *)
let edge_top_to_center
    ~canvas_w
    ~top_row_y
    ~center_row_y
    ~n_top
    ~i_top
    ~center_x
  =
  let x_top = row_x ~canvas_w ~n:n_top ~i:i_top + (node_w / 2) in
  let y_top = top_row_y + node_h in
  let x_bottom = center_x in
  let y_bottom = center_row_y in
  line ~x1:x_top ~y1:y_top ~x2:x_bottom ~y2:y_bottom
    ~stroke:"color-mix(in oklab, var(--color-border-default) 80%, transparent)"
;;

let edge_center_to_bottom
    ~canvas_w
    ~center_row_y
    ~bottom_row_y
    ~n_bottom
    ~i_bottom
    ~center_x
  =
  let x_top = center_x in
  let y_top = center_row_y + node_h in
  let x_bottom = row_x ~canvas_w ~n:n_bottom ~i:i_bottom + (node_w / 2) in
  let y_bottom = bottom_row_y in
  line ~x1:x_top ~y1:y_top ~x2:x_bottom ~y2:y_bottom
    ~stroke:"color-mix(in oklab, var(--color-border-default) 80%, transparent)"
;;

(* ── public entry point ────────────────────────────────────────── *)

let render
    ~(selected_id : string)
    ~(origins : string list)
    ~(descendants : string list)
    : Node.t
  =
  let n_top = List.length origins in
  let n_bot = List.length descendants in
  let n_max = Int.max 1 (Int.max n_top n_bot) in
  let canvas_w =
    (n_max * node_w) + ((n_max - 1) * h_gap) + 64
    (* +64 = side padding *)
  in
  let canvas_w = Int.max canvas_w (node_w + 64) in
  let top_row_y = if n_top = 0 then -node_h else 0 in
  let center_row_y =
    if n_top = 0 then 0 else top_row_y + node_h + v_gap
  in
  let bottom_row_y = center_row_y + node_h + v_gap in
  let canvas_h =
    (if n_bot = 0 then center_row_y + node_h
     else bottom_row_y + node_h)
    + 8
  in
  let center_x = canvas_w / 2 in
  let edges_top =
    List.mapi origins ~f:(fun i_top _origin_id ->
        edge_top_to_center
          ~canvas_w ~top_row_y ~center_row_y ~n_top ~i_top ~center_x)
  in
  let edges_bot =
    List.mapi descendants ~f:(fun i_bottom _desc_id ->
        edge_center_to_bottom
          ~canvas_w ~center_row_y ~bottom_row_y ~n_bottom:n_bot ~i_bottom
          ~center_x)
  in
  let nodes_top =
    List.mapi origins ~f:(fun i id ->
        render_node ~canvas_w ~row_y:top_row_y ~n:n_top ~i ~id
          ~role:Role_origin)
  in
  let node_center =
    let i = 0 in
    render_node ~canvas_w ~row_y:center_row_y ~n:1 ~i ~id:selected_id
      ~role:Role_selected
  in
  let nodes_bot =
    List.mapi descendants ~f:(fun i id ->
        render_node ~canvas_w ~row_y:bottom_row_y ~n:n_bot ~i ~id
          ~role:Role_descendant)
  in
  let svg =
    Node.create_svg "svg"
      ~attrs:
        [ svg_attr "width" (Int.to_string canvas_w)
        ; svg_attr "height" (Int.to_string canvas_h)
        ; svg_attr "viewBox"
            (Printf.sprintf "0 0 %d %d" canvas_w canvas_h)
        ; svg_attr "role" "img"
        ; svg_attr "aria-label" "provenance DAG: 1-hop"
        ]
      (edges_top @ edges_bot @ nodes_top @ [ node_center ] @ nodes_bot)
  in
  let legend =
    Node.div
      ~attrs:[ Style.legend ]
      [ Node.span
          [ Node.text
              (Printf.sprintf "%d origin%s · 1 selected · %d descendant%s"
                 n_top
                 (if n_top = 1 then "" else "s")
                 n_bot
                 (if n_bot = 1 then "" else "s"))
          ]
      ]
  in
  Node.div
    ~attrs:[ Style.root ]
    [ Node.div ~attrs:[ Style.svg_wrap ] [ svg ]; legend ]
;;

let render_empty : Node.t =
  Node.div
    ~attrs:[ Style.empty ]
    [ Node.text "no provenance recorded" ]
;;
