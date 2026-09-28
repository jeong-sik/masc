open Keeper_portrait_look

type rgb = { red : int; green : int; blue : int }
type size = int
type image = { edge : int; rgba : string }
type pose = { flicker : float; blink : bool; bob : float }

let still = { flicker = 0.0; blink = false; bob = 0.0 }

(* Motion, for the animated uses (the TUI splash). Periods are prime-ish to
   each other so the loop does not visibly repeat every few seconds. *)

(* The flame breathes on two waves: a slow sway and a quick shiver. *)
let flicker_slow_seconds = 0.9
let flicker_quick_seconds = 0.37
let flicker_slow_share = 0.6

(* A blink: this long, once per period. *)
let blink_period_seconds = 3.7
let blink_seconds = 0.14

(* The candle rises and settles once per this many seconds. *)
let bob_seconds = 1.6

let wave seconds period = Float.sin (2.0 *. Float.pi *. seconds /. period)

let pose_at ~seconds =
  let flicker =
    (flicker_slow_share *. wave seconds flicker_slow_seconds)
    +. ((1.0 -. flicker_slow_share) *. wave seconds flicker_quick_seconds)
  in
  let into_blink = Float.rem seconds blink_period_seconds in
  let into_blink = if into_blink < 0.0 then into_blink +. blink_period_seconds else into_blink in
  (* the blink closes each period, so a loop that starts at 0 opens on open eyes *)
  { flicker; blink = into_blink >= blink_period_seconds -. blink_seconds; bob = wave seconds bob_seconds }

(* At full flicker the flame is this much taller and its tip this far aside. *)
let flicker_growth = 0.07
let flicker_sway = 0.035

(* At full bob the candle (not its backdrop) moves this many pixels. *)
let bob_pixels = 1.5

let min_size = 16
let max_size = 512
let size_of_int n = if n >= min_size && n <= max_size then Some n else None
let int_of_size n = n

(* ---- framing ----------------------------------------------------------------

   Shape units: the candle is designed in a square about 2 units wide, y
   growing downward, the wax's bottom edge at [wax_bottom]. *)

(* Half the square the image shows. The tallest candle (flame tip about
   -0.81) and the dish (about 0.85) both fit with a little air. *)
let view_half = 0.95

(* The candle's middle sits a touch below the square's centre. *)
let view_centre_y = 0.02

(* The backdrop disc's radius as a share of [view_half]: a thin transparent
   margin keeps its edge off the image border. *)
let backdrop_share = 0.94

(* Samples per pixel along each axis. Small portraits need three for smooth
   edges; from [fine_edge_limit] up two are enough and cost less than half. *)
let small_supersample = 3
let large_supersample = 2
let fine_edge_limit = 128
let supersample_for n = if n < fine_edge_limit then small_supersample else large_supersample

(* Two parts drawn next to each other get an ink line where a sample differs
   from the one this far away: about two thirds of a pixel, so the line comes
   out a little over a pixel wide. *)
let line_reach_pixels = 0.67
let line_reach_for ss = max 1 (int_of_float (Float.round (line_reach_pixels *. float_of_int ss)))

(* Width of the ink round the silhouette, in output pixels. *)
let outline_pixels = 1.3

(* Depth of the rounded rim at the silhouette, shape units: inside this band
   the surface normal turns toward the edge, so the lower right falls into
   shade. *)
let bevel = 0.11

(* Light from the upper left and toward the viewer (x right, y down, z out). *)
let light =
  let x, y, z = (-0.45, -0.60, 0.66) in
  let l = Float.sqrt ((x *. x) +. (y *. y) +. (z *. z)) in
  (x /. l, y /. l, z /. l)

(* Cel shading: a surface facing the light more than this stays lit. *)
let lit_threshold = 0.42

(* The shade band cools a colour toward violet rather than greying it. *)
let shade_tint = (0.80, 0.70, 0.86)

(* ---- candle geometry, derived from the body ------------------------------ *)

(* The wax's bottom edge; the dish sits just under it. *)
let wax_bottom = 0.74

(* The face was designed on a 0.30-wide candle; it scales with the width. *)
let reference_half_width = 0.30
let face_fill = 0.95

type geometry = {
  w : float;
  h : float;
  top : float;
  centre_y : float;
  fs : float;  (** flame size, after flicker *)
  lean : float;  (** flame tip offset, after flicker *)
  s : float;  (** face scale *)
  fy : float;  (** face centre y *)
  blink : bool;
  (* Everything the candle can reach lies inside this box (shape units); a
     sample outside it is backdrop without evaluating a single part. *)
  reach_left : float;
  reach_right : float;
  reach_top : float;
  reach_bottom : float;
}

(* The widest parts (dish, ram horns, glasses temples) stay within this of
   the wax's side; the flame tip and horn tips within [reach_above] of its
   top; the dish within [reach_below] of its bottom. The extra covers the
   gradient's neighbour samples. *)
let reach_side = 0.30
let reach_above = 0.95
let reach_below = 0.20

let geometry_posed (b : body) (p : pose) =
  let top = wax_bottom -. (2.0 *. b.half_height) in
  let s = b.half_width /. reference_half_width *. face_fill in
  {
    w = b.half_width;
    h = b.half_height;
    top;
    centre_y = wax_bottom -. b.half_height;
    fs = b.flame_size *. (1.0 +. (flicker_growth *. p.flicker));
    lean = b.flame_lean +. (flicker_sway *. p.flicker);
    s;
    fy = top +. (0.30 *. s) +. 0.02;
    blink = p.blink;
    reach_left = -.(b.half_width +. reach_side);
    reach_right = b.half_width +. reach_side;
    reach_top = top -. reach_above;
    reach_bottom = wax_bottom +. reach_below;
  }

let geometry b = geometry_posed b still

(* ---- 2D distance fields (negative inside) -------------------------------- *)

let clamp01 v = Float.max 0.0 (Float.min 1.0 v)
let circle x y cx cy r = Float.hypot (x -. cx) (y -. cy) -. r

let ellipse x y cx cy rx ry angle =
  let dx = x -. cx and dy = y -. cy in
  let u, v =
    if angle = 0.0 then (dx, dy)
    else
      let c = Float.cos angle and sn = Float.sin angle in
      ((dx *. c) +. (dy *. sn), (dy *. c) -. (dx *. sn))
  in
  (Float.hypot (u /. rx) (v /. ry) -. 1.0) *. Float.min rx ry

(* A capsule from a to b whose radius runs from ra to rb. *)
let taper x y ax ay bx by ra rb =
  let px = x -. ax and py = y -. ay and dx = bx -. ax and dy = by -. ay in
  let h = clamp01 (((px *. dx) +. (py *. dy)) /. ((dx *. dx) +. (dy *. dy))) in
  Float.hypot (px -. (dx *. h)) (py -. (dy *. h)) -. (ra +. ((rb -. ra) *. h))

(* A stroke of half width [hw] along a circle of radius [r] from angle a0 to
   a1 (radians, y down, so negative angles are the upper half). *)
let arc x y cx cy r hw a0 a1 =
  let ang = Float.atan2 (y -. cy) (x -. cx) in
  if a0 <= ang && ang <= a1 then Float.abs (Float.hypot (x -. cx) (y -. cy) -. r) -. hw
  else
    let end_distance a = Float.hypot (x -. (cx +. (r *. Float.cos a))) (y -. (cy +. (r *. Float.sin a))) in
    Float.min (end_distance a0) (end_distance a1) -. hw

let rounded_box x y cx cy hx hy corner =
  let qx = Float.abs (x -. cx) -. hx +. corner and qy = Float.abs (y -. cy) -. hy +. corner in
  Float.hypot (Float.max qx 0.0) (Float.max qy 0.0) +. Float.min (Float.max qx qy) 0.0 -. corner

let smooth_union a b k =
  let h = clamp01 (0.5 +. (0.5 *. (b -. a) /. k)) in
  (b *. (1.0 -. h)) +. (a *. h) -. (k *. h *. (1.0 -. h))

let pi = Float.pi

(* ---- the candle's parts -------------------------------------------------- *)

(* Flame: a round body with a tapered tip rising from it. *)
let flame_at g x y ox =
  let base_y = g.top -. (0.14 *. g.fs) in
  let body = circle x y ox base_y (0.12 *. g.fs) in
  let tip = taper x y ox base_y (ox +. g.lean) (base_y -. (0.36 *. g.fs)) (0.11 *. g.fs) 0.01 in
  smooth_union body tip 0.06

(* Where the two wicks of a twin flame stand. *)
let twin_offsets = (-0.07, 0.08)

(* The flames sit wholly above the wax top and within this of the middle. *)
let flame_reach_x = 0.45

let flames (b : body) g x y =
  if y > g.top || Float.abs x > flame_reach_x then Float.infinity
  else if b.twin_flame then
    let left, right = twin_offsets in
    Float.min (flame_at g x y left) (flame_at g x y right)
  else flame_at g x y 0.0

(* The bright heart of a single flame. Twin flames are small enough that a
   core would swallow them, so they have none. *)
let flame_core (b : body) g x y =
  if b.twin_flame then Float.infinity else circle x y 0.0 (g.top -. (0.12 *. g.fs)) (0.065 *. g.fs)

let pair x y bx by tx ty ra rb = Float.min (taper x y (-.bx) by (-.tx) ty ra rb) (taper x y bx by tx ty ra rb)

(* Every horn's base lies within this below the wax top. *)
let horn_reach_below = 0.15

let horns (b : body) g x y =
  if y > g.top +. horn_reach_below then Float.infinity
  else
  let l = b.horn_length in
  let bx = g.w *. 0.68 and by = g.top +. 0.04 in
  match b.horns with
  | Nub -> pair x y bx by (bx +. 0.04) (by -. (0.16 *. l)) 0.065 0.035
  | Long -> pair x y bx by (bx +. 0.10) (by -. (0.30 *. l)) 0.065 0.02
  | One -> taper x y (-.bx) by (-.bx -. 0.08) (by -. (0.34 *. l)) 0.075 0.02
  | Ram ->
      (* a hook that leaves the top corner, curls outward and comes back down *)
      let hook m =
        let ax = m *. (g.w -. 0.04) and ay = g.top +. 0.03 in
        let kx = m *. (g.w +. (0.09 *. l)) and ky = g.top -. (0.10 *. l) in
        let ex = m *. (g.w +. (0.13 *. l)) and ey = g.top +. 0.06 in
        Float.min (taper x y ax ay kx ky 0.06 0.045) (taper x y kx ky ex ey 0.045 0.02)
      in
      Float.min (hook (-1.0)) (hook 1.0)

let wax (b : body) g x y = rounded_box x y 0.0 g.centre_y g.w g.h b.corner

(* Drips start at the wax top and run at most this far down (plus width). *)
let drip_reach = 0.34

let drips (b : body) g x y =
  if y < g.top -. 0.07 || y > g.top +. drip_reach then Float.infinity
  else
  List.fold_left
    (fun acc d ->
      Float.min acc
        (taper x y d.drip_x g.top (d.drip_x +. 0.005) (g.top +. d.drip_length) d.drip_width (d.drip_width *. 0.8)))
    Float.infinity b.drips

let dish_field g x y =
  if y < wax_bottom -. 0.05 then Float.infinity else ellipse x y 0.0 (wax_bottom +. 0.04) (g.w +. 0.14) 0.07 0.0

let scarf_field g x y =
  if y < wax_bottom -. 0.32 then Float.infinity
  else
  Float.min
    (rounded_box x y 0.0 (wax_bottom -. 0.24) (g.w +. 0.02) 0.05 0.03)
    (taper x y (g.w *. 0.5) (wax_bottom -. 0.22) (g.w *. 0.7) (wax_bottom -. 0.02) 0.05 0.04)

let bow_centre g = (-.g.w *. 0.55, g.top +. 0.02)

let bow_field g x y =
  let bx, by = bow_centre g in
  Float.min (ellipse x y (bx -. 0.06) by 0.06 0.035 0.3) (ellipse x y (bx +. 0.06) by 0.06 0.035 (-0.3))

let bow_knot g x y =
  let bx, by = bow_centre g in
  circle x y bx by 0.025

let beard_field g x y =
  Float.max (ellipse x y 0.0 (g.fy +. (0.34 *. g.s)) (0.24 *. g.s) (0.16 *. g.s) 0.0) (g.fy +. (0.20 *. g.s) -. y)

let temples g x y =
  Float.min
    (taper x y (-.g.w) (g.fy -. 0.01) (-.g.w -. 0.03) (g.fy -. 0.03) 0.01 0.01)
    (taper x y g.w (g.fy -. 0.01) (g.w +. 0.03) (g.fy -. 0.03) 0.01 0.01)

(* ---- paint: which part a sample is on ------------------------------------ *)

type paint =
  | Outside
  | Wax
  | Wax_drip
  | Flame
  | Flame_core
  | Horn
  | Dish_metal
  | Eye
  | Glint
  | Blush
  | Mouth
  | Tooth
  | Frame
  | Lens
  | Beard_hair
  | Scarf_cloth
  | Bow_ribbon
  | Plaster_strip
  | Patch
  | Freckle

let paint_index = function
  | Outside -> 0
  | Wax -> 1
  | Wax_drip -> 2
  | Flame -> 3
  | Flame_core -> 4
  | Horn -> 5
  | Dish_metal -> 6
  | Eye -> 7
  | Glint -> 8
  | Blush -> 9
  | Mouth -> 10
  | Tooth -> 11
  | Frame -> 12
  | Lens -> 13
  | Beard_hair -> 14
  | Scarf_cloth -> 15
  | Bow_ribbon -> 16
  | Plaster_strip -> 17
  | Patch -> 18
  | Freckle -> 19

(* Soft marks and highlights sit on a part without an ink line round them. *)
let quiet = function
  | Glint | Blush | Freckle -> true
  | Outside | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal | Eye | Mouth | Tooth | Frame | Lens | Beard_hair
  | Scarf_cloth | Bow_ribbon | Plaster_strip | Patch ->
      false

(* Parts that give light keep their colour in the shade band. *)
let emissive = function
  | Flame | Flame_core | Glint -> true
  | Outside | Wax | Wax_drip | Horn | Dish_metal | Eye | Blush | Mouth | Tooth | Frame | Lens | Beard_hair | Scarf_cloth
  | Bow_ribbon | Plaster_strip | Patch | Freckle ->
      false

let outside = function
  | Outside -> true
  | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens
  | Beard_hair | Scarf_cloth | Bow_ribbon | Plaster_strip | Patch | Freckle ->
      false

(* The flame and its core are one light; no line between them. *)
let flame_part = function
  | Flame | Flame_core -> true
  | Outside | Wax | Wax_drip | Horn | Dish_metal | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens | Beard_hair
  | Scarf_cloth | Bow_ribbon | Plaster_strip | Patch | Freckle ->
      false

let eye_offset = 0.19

let eye_centre_list g = [ (-.eye_offset *. g.s, g.fy); (eye_offset *. g.s, g.fy) ]

(* The upward arc of a closed eye. *)
let closed_eye g x y ex =
  arc x y ex (g.fy +. (0.07 *. g.s)) (0.07 *. g.s) (0.02 *. g.s) (-.pi +. 0.6) (-0.6)

let one_eye (b : body) g x y ~right =
  let s = g.s in
  let ex = (if right then eye_offset else -.eye_offset) *. s and ey = g.fy in
  let closed () = if closed_eye g x y ex < 0.0 then Some Eye else None in
  let oval big =
    if ellipse x y ex ey (0.062 *. s *. big) (0.095 *. s *. big) 0.0 < 0.0 then
      if circle x y (ex -. (0.02 *. s)) (ey -. (0.04 *. s)) (0.024 *. s *. big) < 0.0 then Some Glint
      else Some Eye
    else None
  in
  if g.blink then closed ()
  else
  match b.eyes with
  | Happy -> closed ()
  | Wink -> if right then closed () else oval 1.0
  | Sleepy ->
      let lower = Float.max (ellipse x y ex ey (0.065 *. s) (0.07 *. s) 0.0) (ey -. 0.005 -. y) in
      let lid = taper x y (ex -. (0.07 *. s)) ey (ex +. (0.07 *. s)) ey (0.012 *. s) (0.012 *. s) in
      if lower < 0.0 || lid < 0.0 then Some Eye else None
  | Dot ->
      if circle x y ex ey (0.05 *. s) < 0.0 then
        if circle x y (ex -. (0.017 *. s)) (ey -. (0.017 *. s)) (0.016 *. s) < 0.0 then Some Glint
        else Some Eye
      else None
  | Bean -> oval 1.0
  | Sparkle ->
      let big = 1.25 in
      let inside = ellipse x y ex ey (0.062 *. s *. big) (0.095 *. s *. big) 0.0 < 0.0 in
      let second_glint = circle x y (ex +. (0.025 *. s)) (ey +. (0.04 *. s)) (0.012 *. s) < 0.0 in
      if inside && second_glint then Some Glint else oval big

let mouth_paint (b : body) g x y =
  let s = g.s in
  let my = g.fy +. (0.20 *. s) in
  let smile () = arc x y 0.0 (my -. (0.03 *. s)) (0.06 *. s) (0.012 *. s) 0.4 (pi -. 0.4) in
  let stroke =
    match b.mouth with
    | W ->
        Float.min
          (arc x y (-0.025 *. s) my (0.03 *. s) (0.011 *. s) 0.3 (pi -. 0.3))
          (arc x y (0.025 *. s) my (0.03 *. s) (0.011 *. s) 0.3 (pi -. 0.3))
    | Smile | Fang -> smile ()
    | O -> ellipse x y 0.0 (my +. 0.005) (0.028 *. s) (0.035 *. s) 0.0
    | Flat -> taper x y (-0.04 *. s) my (0.04 *. s) my (0.011 *. s) (0.011 *. s)
  in
  let fang () = taper x y (0.03 *. s) (my +. (0.02 *. s)) (0.035 *. s) (my +. (0.07 *. s)) (0.014 *. s) 0.004 in
  if stroke < 0.0 then Some Mouth
  else
    match b.mouth with
    | Fang -> if fang () < 0.0 then Some Tooth else None
    | W | Smile | O | Flat -> None

let blush_paint (b : body) g x y =
  let s = g.s in
  if
    b.blush
    && (ellipse x y (-0.30 *. s) (g.fy +. (0.14 *. s)) (0.065 *. s) (0.032 *. s) 0.0 < 0.0
       || ellipse x y (0.30 *. s) (g.fy +. (0.14 *. s)) (0.065 *. s) (0.032 *. s) 0.0 < 0.0)
  then Some Blush
  else None

(* Marks on the wax itself, under the eyes and mouth. *)
let skin_mark (e : equipment) g x y =
  let s = g.s in
  match e.face with
  | Plaster -> if rounded_box x y (0.30 *. s) (g.fy +. (0.13 *. s)) (0.07 *. s) (0.03 *. s) 0.01 < 0.0 then Some Plaster_strip else None
  | Freckles ->
      let dot (fx, fy_share) = circle x y (fx *. s) (g.fy +. (fy_share *. s)) (0.012 *. s) < 0.0 in
      if List.exists dot [ (-0.34, 0.10); (-0.28, 0.13); (-0.31, 0.10); (0.28, 0.13); (0.34, 0.10); (0.31, 0.10) ]
      then Some Freckle
      else None
  | Bare_face | Glasses | Shades | Eye_patch | Beard -> None

(* Items worn over the face. *)
let face_overlay (e : equipment) g x y =
  let s = g.s in
  match e.face with
  | Glasses ->
      let ring ex = Float.abs (circle x y ex g.fy (0.11 *. s)) -. 0.014 in
      let bridge = taper x y (-0.08 *. s) g.fy (0.08 *. s) g.fy 0.01 0.01 in
      if ring (-.eye_offset *. s) < 0.0 || ring (eye_offset *. s) < 0.0 || bridge < 0.0 || temples g x y < 0.0 then Some Frame
      else None
  | Shades ->
      if rounded_box x y 0.0 (g.fy -. 0.005) (0.30 *. s) (0.05 *. s) (0.03 *. s) < 0.0 then
        if circle x y (-0.24 *. s) (g.fy -. 0.02) (0.018 *. s) < 0.0 then Some Glint else Some Lens
      else None
  | Eye_patch ->
      if circle x y (eye_offset *. s) g.fy (0.085 *. s) < 0.0 || taper x y (-.g.w) (g.fy -. 0.12) g.w (g.fy -. 0.02) 0.012 0.012 < 0.0
      then Some Patch
      else None
  | Beard -> if beard_field g x y < 0.0 then Some Beard_hair else None
  | Bare_face | Plaster | Freckles -> None

let neck_field (e : equipment) g x y = match e.neck with Scarf -> scarf_field g x y | Bare_neck -> Float.infinity

let head_field (e : equipment) g x y =
  match e.head with Bow -> Float.min (bow_field g x y) (bow_knot g x y) | Bare_head -> Float.infinity

let face_field (e : equipment) g x y =
  match e.face with
  | Beard -> beard_field g x y
  | Glasses -> temples g x y
  | Bare_face | Shades | Eye_patch | Plaster | Freckles -> Float.infinity

let base_field (e : equipment) g x y = match e.base with Dish _ -> dish_field g x y | No_dish -> Float.infinity
let hand_field (e : equipment) = match e.hand with Empty_hand -> Float.infinity

(* Samples outside the candle's reach are this far from it: any positive
   distance reads as backdrop, and no part is ever that close to the box. *)
let beyond_reach = 1.0

(* Eyes, cheeks and mouth all lie within this many face-scales of the face
   centre's row; the rest of the wax is plain. *)
let face_rows_above = 0.16
let face_rows_below = 0.30

(* What is on the wax itself, in drawing order. *)
let on_wax (b : body) (e : equipment) g x y drip_d =
  if y < g.fy -. (face_rows_above *. g.s) || y > g.fy +. (face_rows_below *. g.s) then
    if drip_d < 0.0 then Wax_drip else Wax
  else
  match skin_mark e g x y with
  | Some p -> p
  | None -> (
      match one_eye b g x y ~right:false with
      | Some p -> p
      | None -> (
          match one_eye b g x y ~right:true with
          | Some p -> p
          | None -> (
              match blush_paint b g x y with
              | Some p -> p
              | None -> (
                  match mouth_paint b g x y with
                  | Some p -> p
                  | None -> if drip_d < 0.0 then Wax_drip else Wax))))

(* Distance to the whole silhouette and the part under the sample. *)
let sample (b : body) (e : equipment) g x y =
  if x < g.reach_left || x > g.reach_right || y < g.reach_top || y > g.reach_bottom then (beyond_reach, Outside)
  else
    let wax_d = wax b g x y in
    let drip_d = drips b g x y in
    let flame_d = flames b g x y in
    let horn_d = horns b g x y in
    let neck_d = neck_field e g x y in
    let head_d = head_field e g x y in
    let face_d = face_field e g x y in
    let base_d = base_field e g x y in
    let hand_d = hand_field e in
    let silhouette =
      Float.min
        (Float.min (Float.min wax_d drip_d) (Float.min flame_d horn_d))
        (Float.min (Float.min neck_d head_d) (Float.min face_d (Float.min base_d hand_d)))
    in
    let paint =
      if silhouette >= 0.0 then Outside
      else if flame_d < 0.0 then if flame_core b g x y < 0.0 then Flame_core else Flame
      else if head_d < 0.0 then Bow_ribbon
      else
        match face_overlay e g x y with
        | Some p -> p
        | None ->
            if neck_d < 0.0 then Scarf_cloth
            else if base_d < 0.0 && wax_d > -0.01 then Dish_metal
            else if horn_d < 0.0 && wax_d > -0.02 then Horn
            else if wax_d < 0.0 then on_wax b e g x y drip_d
            else if drip_d < 0.0 then Wax_drip
            else if horn_d < 0.0 then Horn
            else Wax
    in
    (silhouette, paint)

(* ---- colours ------------------------------------------------------------- *)

let rgb red green blue = { red; green; blue }

let wax_colour = function
  | Ivory -> rgb 250 240 222
  | Peach -> rgb 255 214 196
  | Mint -> rgb 196 238 214
  | Lavender -> rgb 222 208 250
  | Sky -> rgb 196 224 252
  | Butter -> rgb 255 236 160
  | Rose -> rgb 250 190 204
  | Charcoal -> rgb 86 84 96

(* Outer flame and its bright core. *)
let flame_colours = function
  | Ember -> (rgb 255 150 64, rgb 255 234 150)
  | Azure -> (rgb 90 160 255, rgb 210 234 255)
  | Jade -> (rgb 80 220 140, rgb 210 255 220)
  | Violet -> (rgb 176 110 255, rgb 236 214 255)
  | Pink -> (rgb 255 110 170, rgb 255 214 232)
  | Gold -> (rgb 255 196 50, rgb 255 246 196)

let horn_rgb = function
  | Crimson -> rgb 200 70 80
  | Soot -> rgb 70 60 80
  | Brass -> rgb 232 182 72
  | Bone -> rgb 240 230 210
  | Blossom -> rgb 236 120 150

let dish_rgb = function Gilt -> rgb 214 176 96 | Silver -> rgb 186 190 204 | Oak -> rgb 150 104 66

(* Drips are the wax a shade deeper. *)
let drip_share = 0.93

let scale_rgb c k =
  let f v = int_of_float (Float.round (float_of_int v *. k)) in
  rgb (f c.red) (f c.green) (f c.blue)

(* Dark wax needs light eyes and a darker line to read. *)
let dark_wax = function
  | Charcoal -> true
  | Ivory | Peach | Mint | Lavender | Sky | Butter | Rose -> false

let ink_rgb (b : body) = if dark_wax b.wax then rgb 24 22 30 else rgb 70 50 56
let eye_colour (b : body) = if dark_wax b.wax then rgb 250 240 230 else rgb 50 36 40

(* Backdrop: the body's hue at low lightness so the candle stands out on it. *)
let backdrop_lightness = 0.30
let backdrop_saturation = 0.35

let hls_to_rgb h l s =
  let q = if l < 0.5 then l *. (1.0 +. s) else l +. s -. (l *. s) in
  let p = (2.0 *. l) -. q in
  let channel t =
    let t = if t < 0.0 then t +. 1.0 else if t > 1.0 then t -. 1.0 else t in
    let v =
      if t < 1.0 /. 6.0 then p +. ((q -. p) *. 6.0 *. t)
      else if t < 0.5 then q
      else if t < 2.0 /. 3.0 then p +. ((q -. p) *. ((2.0 /. 3.0) -. t) *. 6.0)
      else p
    in
    int_of_float (Float.round (v *. 255.0))
  in
  rgb (channel (h +. (1.0 /. 3.0))) (channel h) (channel (h -. (1.0 /. 3.0)))

let backdrop_colour (b : body) = hls_to_rgb b.backdrop_hue backdrop_lightness backdrop_saturation

let paint_colour (b : body) (e : equipment) = function
  | Outside -> backdrop_colour b
  | Wax -> wax_colour b.wax
  | Wax_drip -> scale_rgb (wax_colour b.wax) drip_share
  | Flame -> fst (flame_colours b.flame)
  | Flame_core -> snd (flame_colours b.flame)
  | Horn -> horn_rgb b.horn_colour
  | Dish_metal -> (match e.base with Dish d -> dish_rgb d | No_dish -> wax_colour b.wax)
  | Eye -> eye_colour b
  | Glint -> rgb 255 255 255
  | Blush -> rgb 255 140 160
  | Mouth -> rgb 160 60 80
  | Tooth -> rgb 255 255 255
  | Frame -> rgb 60 56 80
  | Lens -> rgb 30 30 40
  | Beard_hair -> rgb 246 246 250
  | Scarf_cloth -> rgb 214 64 84
  | Bow_ribbon -> rgb 236 110 150
  | Plaster_strip -> rgb 246 220 180
  | Patch -> rgb 40 36 44
  | Freckle -> rgb 150 96 80

(* ---- raster -------------------------------------------------------------- *)

let shade c =
  let kr, kg, kb = shade_tint in
  let f v k = int_of_float (Float.round (float_of_int v *. k)) in
  rgb (f c.red kr) (f c.green kg) (f c.blue kb)

let render_posed (b : body) (e : equipment) (p : pose) (n : size) =
  let g = geometry_posed b p in
  let supersample = supersample_for n in
  let line_reach = line_reach_for supersample in
  let grid = n * supersample in
  let cell = 2.0 *. view_half /. float_of_int grid in
  let x_of i = -.view_half +. ((float_of_int i +. 0.5) *. cell) in
  let y_of j = view_centre_y -. view_half +. ((float_of_int j +. 0.5) *. cell) in
  (* the candle moves with the bob; the backdrop stays *)
  let lift = p.bob *. bob_pixels *. 2.0 *. view_half /. float_of_int n in
  let distance = Array.make (grid * grid) 0.0 in
  let paints = Array.make (grid * grid) Outside in
  for j = 0 to grid - 1 do
    let y = y_of j in
    for i = 0 to grid - 1 do
      let d, part = sample b e g (x_of i) (y +. lift) in
      distance.((j * grid) + i) <- d;
      paints.((j * grid) + i) <- part
    done
  done;
  let at i j = paints.((max 0 (min (grid - 1) j) * grid) + max 0 (min (grid - 1) i)) in
  let dist i j = distance.((max 0 (min (grid - 1) j) * grid) + max 0 (min (grid - 1) i)) in
  let outline = outline_pixels *. 2.0 *. view_half /. float_of_int n in
  let backdrop_r = backdrop_share *. view_half in
  let backdrop = backdrop_colour b in
  let ink = ink_rgb b in
  let lx, ly, lz = light in
  let meets p q = paint_index q <> paint_index p && (not (outside q)) && (not (quiet q)) && not (flame_part p && flame_part q) in
  let boundary i j p =
    (not (quiet p))
    && (meets p (at (i + line_reach) j)
       || meets p (at (i - line_reach) j)
       || meets p (at i (j + line_reach))
       || meets p (at i (j - line_reach)))
  in
  let colour_of i j =
    let part = at i j in
    match part with
    | Outside ->
        let x = x_of i and y = y_of j in
        if Float.hypot x (y -. view_centre_y) < backdrop_r then Some backdrop else None
    | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens
    | Beard_hair | Scarf_cloth | Bow_ribbon | Plaster_strip | Patch | Freckle ->
        let d = dist i j in
        if d > -.outline || boundary i j part then Some ink
        else
          let base = paint_colour b e part in
          if emissive part then Some base
          else
            let gx = dist (i + 1) j -. dist (i - 1) j and gy = dist i (j + 1) -. dist i (j - 1) in
            let gl = Float.hypot gx gy in
            let gx, gy = if gl > 0.0 then (gx /. gl, gy /. gl) else (0.0, 0.0) in
            let rim = clamp01 (1.0 +. (d /. bevel)) in
            let nz = Float.sqrt (1.0 -. (rim *. rim)) in
            let facing = (gx *. rim *. lx) +. (gy *. rim *. ly) +. (nz *. lz) in
            Some (if facing > lit_threshold then base else shade base)
  in
  let out = Bytes.make (n * n * 4) '\000' in
  let samples = supersample * supersample in
  for py = 0 to n - 1 do
    for px = 0 to n - 1 do
      let r = ref 0 and gr = ref 0 and bl = ref 0 and count = ref 0 in
      for sj = 0 to supersample - 1 do
        for si = 0 to supersample - 1 do
          match colour_of ((px * supersample) + si) ((py * supersample) + sj) with
          | Some c ->
              r := !r + c.red;
              gr := !gr + c.green;
              bl := !bl + c.blue;
              incr count
          | None -> ()
        done
      done;
      if !count > 0 then begin
        let k = ((py * n) + px) * 4 in
        let mean v = Char.chr ((v + (!count / 2)) / !count) in
        Bytes.set out k (mean !r);
        Bytes.set out (k + 1) (mean !gr);
        Bytes.set out (k + 2) (mean !bl);
        Bytes.set out (k + 3) (Char.chr (((!count * 255) + (samples / 2)) / samples))
      end
    done
  done;
  { edge = n; rgba = Bytes.unsafe_to_string out }

let render b e n = render_posed b e still n

let pixel img ~x ~y =
  let x = max 0 (min (img.edge - 1) x) and y = max 0 (min (img.edge - 1) y) in
  let k = ((y * img.edge) + x) * 4 in
  let byte o = Char.code img.rgba.[k + o] in
  (rgb (byte 0) (byte 1) (byte 2), byte 3)

module For_testing = struct
  let pixel_of_point n (x, y) =
    let to_px v = int_of_float (Float.floor ((v +. view_half) /. (2.0 *. view_half) *. float_of_int n)) in
    (to_px x, to_px (y -. view_centre_y))

  let wax_bounds b =
    let g = geometry b in
    (-.g.w, g.top, g.w, wax_bottom)

  let eye_centres b = eye_centre_list (geometry b)

  let flame_probe b =
    let g = geometry b in
    let ox = if b.twin_flame then fst twin_offsets else 0.0 in
    let base_y = g.top -. (0.14 *. g.fs) in
    (* inside the flame body, toward its lower right, clear of the core *)
    (ox +. (0.075 *. g.fs), base_y +. (0.05 *. g.fs))

  (* Outline and anti-aliasing reach past a part's own field by about this
     much at the sizes the tests draw. *)
  let ink_margin = 0.04

  let flame_box b =
    let g = geometry_posed b { still with flicker = 1.0 } in
    let spread = (0.12 *. g.fs) +. flicker_sway +. Float.abs b.flame_lean +. ink_margin in
    let left, right = if b.twin_flame then twin_offsets else (0.0, 0.0) in
    (left -. spread, g.top -. (0.50 *. g.fs) -. ink_margin, right +. spread, g.top +. ink_margin)

  let eye_boxes b =
    let g = geometry b in
    let half = (0.125 *. g.s) +. ink_margin in
    List.map (fun (ex, ey) -> (ex -. half, ey -. half, ex +. half, ey +. half)) (eye_centre_list g)

  let ink = ink_rgb
  let wax_rgb b = wax_colour b.wax
  let flame_rgb b = fst (flame_colours b.flame)
  let eye_rgb = eye_colour
  let backdrop_rgb = backdrop_colour
end
