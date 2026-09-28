(* The imp emblem's marks as signed distance fields. Each primitive returns
   the usual signed distance -- negative inside -- and [depth_in] flips the
   sign, because the renderer asks "how far inside" when it bevels an edge.

   The sampled square ([extent], 1.08 as it is) and its lattice step are
   adapted from openai/codex codex-rs/tui/src/empty_state_animation/
   geometry.rs at commit 5c5308fc9a9e (Apache License 2.0, Copyright 2025
   OpenAI; license and NOTICE beside this file, listed in
   THIRD-PARTY-LICENSES.md). Changed here: Codex samples its logo's SVG
   paths; the imp and lantern below are this emblem's own analytic fields,
   on a coarser lattice. *)

type mark =
  | Imp
  | Lantern

(* Both marks fit a square this far from the centre, horn tips included. *)
let extent = 1.08

(* Lattice density. At the emblem's largest size one step is under one Braille
   dot, so a splatted surface has no gaps. *)
let grid = 120
let step = extent *. 2.0 /. Float.of_int (grid - 1)

type point =
  { x : float
  ; y : float
  }

(* --- primitives: signed distance, negative inside --- *)

let circle ~x ~y ~centre ~radius = Float.hypot (x -. centre.x) (y -. centre.y) -. radius

(* An ellipse turned by [angle]. The distance is approximate (scaled by the
   shorter radius), which is enough for an outline and a gradient. *)
let ellipse ~x ~y ~centre ~rx ~ry ~angle =
  let c = Float.cos angle and s = Float.sin angle in
  let dx = x -. centre.x and dy = y -. centre.y in
  let u = (dx *. c) +. (dy *. s) and v = (dy *. c) -. (dx *. s) in
  (Float.hypot (u /. rx) (v /. ry) -. 1.0) *. Float.min rx ry

(* A capsule from [a] to [b] whose radius narrows from [ra] to [rb]: a horn,
   an ear, a fang. *)
let taper ~x ~y ~a ~b ~ra ~rb =
  let px = x -. a.x and py = y -. a.y in
  let bx = b.x -. a.x and by = b.y -. a.y in
  let along = ((px *. bx) +. (py *. by)) /. ((bx *. bx) +. (by *. by)) in
  let h = Float.min 1.0 (Float.max 0.0 along) in
  Float.hypot (px -. (bx *. h)) (py -. (by *. h)) -. (ra +. ((rb -. ra) *. h))

(* A box with half-sides [hx], [hy] and corners rounded by [corner]. *)
let box ~x ~y ~centre ~hx ~hy ~corner =
  let qx = Float.abs (x -. centre.x) -. hx +. corner in
  let qy = Float.abs (y -. centre.y) -. hy +. corner in
  Float.hypot (Float.max qx 0.0) (Float.max qy 0.0)
  +. Float.min (Float.max qx qy) 0.0
  -. corner

(* A stroke of [half_width] along a circle's arc from angle [a0] to [a1]
   (radians, measured with y downward, so positive angles are below the
   centre). *)
let arc ~x ~y ~centre ~radius ~half_width ~a0 ~a1 =
  let angle = Float.atan2 (y -. centre.y) (x -. centre.x) in
  if angle >= a0 && angle <= a1
  then Float.abs (Float.hypot (x -. centre.x) (y -. centre.y) -. radius) -. half_width
  else
    let end_distance a =
      Float.hypot
        (x -. (centre.x +. (radius *. Float.cos a)))
        (y -. (centre.y +. (radius *. Float.sin a)))
    in
    Float.min (end_distance a0) (end_distance a1) -. half_width

(* Polynomial smooth minimum: joins two shapes with a fillet [k] wide, so a
   horn grows out of the head instead of being stuck onto it. *)
let smooth_union a b ~k =
  let h = Float.min 1.0 (Float.max 0.0 (0.5 +. (0.5 *. (b -. a) /. k))) in
  (b *. (1.0 -. h)) +. (a *. h) -. (k *. h *. (1.0 -. h))

let mirror p = { p with x = -.p.x }

(* --- the imp --- *)

let head_centre = { x = 0.0; y = 0.18 }
let head_radius = 0.56

(* Each horn is two tapered strokes: a thick root leaning out, then a thin tip
   curling back in. *)
let horn_root = { x = -0.30; y = -0.22 }
let horn_bend = { x = -0.58; y = -0.62 }
let horn_tip = { x = -0.50; y = -0.98 }
let horn_root_radius = 0.16
let horn_bend_radius = 0.07
let horn_tip_radius = 0.012
let horn_fillet = 0.08

let ear_root = { x = -0.50; y = 0.12 }
let ear_tip = { x = -0.86; y = -0.05 }
let ear_root_radius = 0.13
let ear_tip_radius = 0.015
let ear_fillet = 0.06

let imp_left_eye = { x = -0.21; y = 0.08 }
let imp_right_eye = mirror imp_left_eye
let eye_rx = 0.12
let eye_ry = 0.065

(* The eyes slant down toward the nose: a sly look rather than a surprised
   one. *)
let eye_slant = 0.35

let grin_centre = { x = 0.0; y = 0.10 }
let grin_radius = 0.34
let grin_half_width = 0.045

(* How far short of the horizontal the grin's corners stop, in radians. *)
let grin_corner_inset = 0.45

let imp_grin_middle = { x = grin_centre.x; y = grin_centre.y +. grin_radius }
let fang_root = { x = -0.13; y = 0.43 }
let fang_tip = { x = -0.10; y = 0.56 }
let fang_root_radius = 0.035
let fang_tip_radius = 0.005
let imp_brow = { x = 0.0; y = -0.15 }
let imp_left_horn = { x = (horn_bend.x +. horn_tip.x) /. 2.0; y = (horn_bend.y +. horn_tip.y) /. 2.0 }

let imp ~x ~y =
  let head = circle ~x ~y ~centre:head_centre ~radius:head_radius in
  let horn side =
    Float.min
      (taper ~x ~y ~a:(side horn_root) ~b:(side horn_bend) ~ra:horn_root_radius
         ~rb:horn_bend_radius)
      (taper ~x ~y ~a:(side horn_bend) ~b:(side horn_tip) ~ra:horn_bend_radius
         ~rb:horn_tip_radius)
  in
  let ear side =
    taper ~x ~y ~a:(side ear_root) ~b:(side ear_tip) ~ra:ear_root_radius ~rb:ear_tip_radius
  in
  let solid =
    smooth_union
      (smooth_union head (Float.min (horn Fun.id) (horn mirror)) ~k:horn_fillet)
      (Float.min (ear Fun.id) (ear mirror))
      ~k:ear_fillet
  in
  let eyes =
    Float.min
      (ellipse ~x ~y ~centre:imp_left_eye ~rx:eye_rx ~ry:eye_ry ~angle:eye_slant)
      (ellipse ~x ~y ~centre:imp_right_eye ~rx:eye_rx ~ry:eye_ry ~angle:(-.eye_slant))
  in
  let grin =
    arc ~x ~y ~centre:grin_centre ~radius:grin_radius ~half_width:grin_half_width
      ~a0:grin_corner_inset
      ~a1:(Float.pi -. grin_corner_inset)
  in
  let fangs =
    Float.min
      (taper ~x ~y ~a:fang_root ~b:fang_tip ~ra:fang_root_radius ~rb:fang_tip_radius)
      (taper ~x ~y ~a:(mirror fang_root) ~b:(mirror fang_tip) ~ra:fang_root_radius
         ~rb:fang_tip_radius)
  in
  (* The fangs stay solid where they cross the grin's gap. *)
  let holes = Float.max (Float.min eyes grin) (-.fangs) in
  Float.max solid (-.holes)

(* --- the lantern --- *)

let lantern_body = { x = 0.0; y = 0.22 }
let lantern_body_hx = 0.40
let lantern_body_hy = 0.46
let lantern_body_corner = 0.14
let lantern_cap = { x = 0.0; y = -0.30 }
let lantern_cap_hx = 0.30
let lantern_cap_hy = 0.08
let lantern_cap_corner = 0.05
let handle_centre = { x = 0.0; y = -0.52 }
let handle_radius = 0.22
let handle_half_width = 0.05
let lantern_handle_top = { x = handle_centre.x; y = handle_centre.y -. handle_radius }
let lantern_base = { x = 0.0; y = 0.72 }
let lantern_base_hx = 0.46
let lantern_base_hy = 0.06
let lantern_base_corner = 0.04
let window_hx = 0.30
let window_hy = 0.36
let window_corner = 0.08
let flame_centre = { x = 0.0; y = 0.30 }
let flame_rx = 0.16
let flame_ry = 0.26
let flame_tip = { x = 0.0; y = 0.08 }
let flame_tip_radius = 0.05
let flame_fillet = 0.1

let lantern ~x ~y =
  let body =
    box ~x ~y ~centre:lantern_body ~hx:lantern_body_hx ~hy:lantern_body_hy
      ~corner:lantern_body_corner
  in
  let cap =
    box ~x ~y ~centre:lantern_cap ~hx:lantern_cap_hx ~hy:lantern_cap_hy
      ~corner:lantern_cap_corner
  in
  (* Only the ring's upper half: it rises from the cap. *)
  let handle =
    Float.max
      (Float.abs (circle ~x ~y ~centre:handle_centre ~radius:handle_radius)
       -. handle_half_width)
      (y -. handle_centre.y)
  in
  let base =
    box ~x ~y ~centre:lantern_base ~hx:lantern_base_hx ~hy:lantern_base_hy
      ~corner:lantern_base_corner
  in
  let solid = Float.min (Float.min body cap) (Float.min handle base) in
  let flame =
    smooth_union
      (ellipse ~x ~y ~centre:flame_centre ~rx:flame_rx ~ry:flame_ry ~angle:0.0)
      (circle ~x ~y ~centre:flame_tip ~radius:flame_tip_radius)
      ~k:flame_fillet
  in
  let glass =
    box ~x ~y ~centre:lantern_body ~hx:window_hx ~hy:window_hy ~corner:window_corner
  in
  (* The glass is open; the flame inside it stays. *)
  let window = Float.max glass (-.flame) in
  Float.max solid (-.window)

let depth_in mark ~x ~y =
  match mark with
  | Imp -> -.imp ~x ~y
  | Lantern -> -.lantern ~x ~y

type field = float array

let field mark =
  Array.init (grid * grid) (fun i ->
    let col = i mod grid and row = i / grid in
    depth_in mark
      ~x:(-.extent +. (Float.of_int col *. step))
      ~y:(-.extent +. (Float.of_int row *. step)))

let sample field ~col ~row =
  if col < 0 || col >= grid || row < 0 || row >= grid
  then invalid_arg "Masc_tui_imp_shape.sample: outside the lattice"
  else field.((row * grid) + col)
