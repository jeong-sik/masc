(* Provenance: the bevel normal (the distance field's gradient tilted by a
   circular rim profile inside [bevel] of the silhouette) and the shading
   constants below ([bevel], [light], [lit_threshold], [shade_tint]) came from
   a session prototype that followed the idea of openai/codex's
   empty_state_animation (Apache-2.0). No code is shared with it. *)

open Keeper_portrait_look

type rgb = { red : int; green : int; blue : int }
type size = int
type image = { edge : int; rgba : string }
type pose = { flicker : float; blink : bool; bob : float }

let still = { flicker = 0.0; blink = false; bob = 0.0 }

(* Flicker and bob are fractions of their full swing. *)
let swing_range = (-1.0, 1.0)

let pose ~flicker ~blink ~bob =
  let lo, hi = swing_range in
  let within v = lo <= v && v <= hi in
  if within flicker && within bob then Some { flicker; blink; bob } else None

(* Motion, for the animated uses (the /about candle). Periods are prime-ish to
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

let milliseconds_per_second = 1000.0
let wave seconds period = Float.sin (2.0 *. Float.pi *. seconds /. period)

(* Milliseconds are an integer, so the moment is always finite and so is
   every pose made from it. *)
let pose_at ~milliseconds =
  let seconds = float_of_int milliseconds /. milliseconds_per_second in
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

(* At full bob the candle (not its backdrop) moves this far, shape units: a
   little over a pixel at 64 px, about three at 240. In shape units rather
   than pixels so the framing below holds at every size. *)
let bob_reach = 0.025

let min_size = 16
let max_size = 512
let size_of_int n = if n >= min_size && n <= max_size then Some n else None
let int_of_size n = n

(* ---- framing ----------------------------------------------------------------

   Shape units: the candle is designed in a square about 2 units wide, y
   growing downward, the wax's bottom edge at [wax_bottom]. *)

(* Half the default square; [frame_for] expands it when the scene needs more
   room, including a low-hanging item or a whole pixel of clearance. *)
let view_half = 0.95

(* The candle's middle sits a touch below the square's centre. *)
let view_centre_y = 0.02

(* The backdrop disc's radius as a share of [view_half]: a thin transparent
   margin keeps its edge off the image border. *)
let backdrop_share = 0.94

(* Samples per pixel along each axis. Small portraits need four for smooth
   edges; from [fine_edge_limit] up two are enough and cost a quarter. Both
   are even so the ink line below is the same width on either side. *)
let small_supersample = 4
let large_supersample = 2
let fine_edge_limit = 128
let supersample_for n = if n < fine_edge_limit then small_supersample else large_supersample

(* Two parts drawn next to each other get an ink line where a sample differs
   from the one this far away: half a pixel on each side, so the line is
   about a pixel wide at every size. *)
let line_reach_pixels = 0.5
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

(* ---- part proportions (shape units, or shares of the flame size [fs] and
   face scale [s]) ---------------------------------------------------------- *)

(* The wax's bottom edge; the dish sits just under it. *)
let wax_bottom = 0.74

(* The face was designed on a 0.30-wide candle; it scales with the width. *)
let reference_half_width = 0.30
let face_fill = 0.95

(* The face's centre sits this many face-scales under the wax top, plus a
   fixed gap. *)
let face_below_top = 0.30
let face_gap = 0.02

(* The flame's round body sits this far above the wax top, with this radius;
   its tip rises this far above the body; its bright core sits a little
   lower than the body's centre. All shares of the flame size. *)
let flame_base_rise = 0.14
let flame_body_radius = 0.12
let flame_tip_rise = 0.36
let flame_tip_body_radius = 0.11
let flame_tip_radius = 0.01
let flame_core_rise = 0.12
let flame_core_radius = 0.065
let flame_blend = 0.06

(* Horn heights and tip radii, shared by their fields and the frame bounds. *)
let horn_base_drop = 0.04
let nub_rise = 0.16
let nub_tip_radius = 0.035
let long_horn_rise = 0.30
let one_horn_rise = 0.34
let tall_horn_tip_radius = 0.02
let ram_rise = 0.10
let ram_knee_radius = 0.045

(* An open eye: an oval this wide and tall, in face-scales. *)
let eye_oval_rx = 0.062
let eye_oval_ry = 0.095

(* Every mouth, fang included, ends above this many face-scales under the
   face centre; a scarf starts below it. *)
let mouth_clearance = 0.30

(* The dish: an ellipse this far under the wax bottom, this much wider than
   the wax, this tall. *)
let dish_drop = 0.04
let dish_side = 0.14
let dish_half_height = 0.07

(* The scarf: a band of this half height hung under the mouth, as wide as the
   wax plus [scarf_overhang], with a short tail falling to the right. *)
let scarf_half_height = 0.045
let scarf_overhang = 0.02
let scarf_corner = 0.03
let scarf_tail_drop = 0.08
let scarf_tail_radius = 0.045
let scarf_tail_end_radius = 0.035

(* The medal's disc hangs below the neck band. Both its field and the bounds
   used by culling and framing derive from these dimensions. *)
let medal_drop = 0.185
let medal_radius = 0.145

(* ---- geometry, derived from the body, the items and the pose ------------- *)

type geometry = {
  w : float;
  h : float;
  top : float;
  centre_y : float;
  fs : float;  (** flame size, after flicker *)
  lean : float;  (** flame tip offset, after flicker *)
  s : float;  (** face scale *)
  fy : float;  (** face centre y *)
  scarf_top : float;  (** a scarf's band starts here, under the mouth *)
  blink : bool;
  cull : bool;  (** skip regions no part reaches; off only to check that skipping changes nothing *)
  (* Everything the candle can reach lies inside this box (shape units); a
     sample outside it is backdrop without evaluating a single part. *)
  reach_left : float;
  reach_right : float;
  reach_top : float;
  reach_bottom : float;
  (* Rows the drips can reach, from the widest start and the longest run. *)
  drip_top : float;
  drip_bottom : float;
}

(* Room left round a region a part can reach before skipping it: a region's
   edge must sit at least one sample outside the part, for the gradient and
   the ink line read their neighbours. The coarsest grid (16 px, four
   samples) has samples [2 * view_half / 64] apart; this is well over that. *)
let neighbour_margin = 0.05

(* The widest parts (dish, ram horns, glasses temples) stay within this of
   the wax's side; the flame tip and horn tips within [reach_above] of its
   top. The bottom comes from the parts actually worn: see [bottom_reach]. *)
let reach_side = 0.30
let reach_above = 0.95

let scarf_band_centre g = g.scarf_top +. scarf_half_height
let dish_bottom = wax_bottom +. dish_drop +. dish_half_height

let scarf_bottom g =
  scarf_band_centre g +. Float.max scarf_half_height (scarf_tail_drop +. scarf_tail_end_radius)

(* A bow tie's wings and a medal's disc hang from the same band; the medal's
   disc reaches lowest. *)
let bow_tie_bottom g = scarf_band_centre g +. 0.075
let medal_bottom g = scarf_band_centre g +. medal_drop +. medal_radius

let neck_bottom g (e : equipment) =
  match e.neck with
  | Scarf -> scarf_bottom g
  | Bow_tie -> bow_tie_bottom g
  | Medal -> medal_bottom g
  | Bare_neck -> wax_bottom

(* The lowest point any part reaches: the wax, then whatever hangs below it.
   The beard is cut at the wax's bottom, so it never does. *)
let bottom_reach g (e : equipment) =
  let dish = match e.base with Dish _ -> dish_bottom | No_dish -> wax_bottom in
  Float.max wax_bottom (Float.max dish (neck_bottom g e))

let geometry_posed ~cull (b : body) (e : equipment) (p : pose) =
  let top = wax_bottom -. (2.0 *. b.half_height) in
  let s = b.half_width /. reference_half_width *. face_fill in
  let fy = top +. (face_below_top *. s) +. face_gap in
  let widest_drip = List.fold_left (fun m d -> Float.max m d.drip_width) 0.0 b.drips in
  let longest_drip = List.fold_left (fun m d -> Float.max m (d.drip_length +. d.drip_width)) 0.0 b.drips in
  let g =
    {
      w = b.half_width;
      h = b.half_height;
      top;
      centre_y = wax_bottom -. b.half_height;
      fs = b.flame_size *. (1.0 +. (flicker_growth *. p.flicker));
      lean = b.flame_lean +. (flicker_sway *. p.flicker);
      s;
      fy;
      scarf_top = fy +. (mouth_clearance *. s);
      blink = p.blink;
      cull;
      reach_left = -.(b.half_width +. reach_side);
      reach_right = b.half_width +. reach_side;
      reach_top = top -. reach_above;
      reach_bottom = 0.0;
      drip_top = top -. widest_drip -. neighbour_margin;
      drip_bottom = top +. longest_drip +. neighbour_margin;
    }
  in
  { g with reach_bottom = bottom_reach g e +. neighbour_margin }

let geometry b = geometry_posed ~cull:true b bare still

type frame = { half : float; middle_y : float }

(* The highest point over every pose. A smooth union can extend the two
   flame fields by at most [flame_blend / 4]. Horn tips (the ram's knee) are
   their highest caps. These tops also cover the drips and head items. *)
let top_reach (b : body) g =
  let fs = b.flame_size *. (1.0 +. flicker_growth) in
  let flame =
    Float.min
      (g.top -. ((flame_base_rise +. flame_body_radius) *. fs))
      (g.top -. ((flame_base_rise +. flame_tip_rise) *. fs) -. flame_tip_radius)
    -. (flame_blend /. 4.0)
  in
  let horn =
    match b.horns with
    | Nub -> g.top +. horn_base_drop -. (nub_rise *. b.horn_length) -. nub_tip_radius
    | Long -> g.top +. horn_base_drop -. (long_horn_rise *. b.horn_length) -. tall_horn_tip_radius
    | One -> g.top +. horn_base_drop -. (one_horn_rise *. b.horn_length) -. tall_horn_tip_radius
    | Ram -> g.top -. (ram_rise *. b.horn_length) -. ram_knee_radius
  in
  Float.min flame horn -. bob_reach

(* Fit the whole scene, including the backdrop and full motion, inside the
   interior [n - 2] rows and columns. The same scale on both axes preserves
   proportions. Keep the default centre wherever its margins already fit;
   otherwise move it into the interval that leaves a pixel at both ends.
   Current flicker/bob do not affect these bounds, so the frame stays still. *)
let frame_for b g e n =
  let backdrop_r = backdrop_share *. view_half in
  let top = Float.min (view_centre_y -. backdrop_r) (top_reach b g) in
  let bottom = Float.max (view_centre_y +. backdrop_r) (bottom_reach g e +. bob_reach) in
  let half_width = Float.max backdrop_r (Float.max (-.g.reach_left) g.reach_right) in
  let extent = Float.max (2.0 *. half_width) (bottom -. top) in
  let span = Float.max (2.0 *. view_half) (extent *. float_of_int n /. float_of_int (n - 2)) in
  let half = span /. 2.0 in
  let margin = span /. float_of_int n in
  let middle_y =
    Float.max (bottom +. margin -. half)
      (Float.min (top -. margin +. half) view_centre_y)
  in
  { half; middle_y }

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

(* A capsule from a to b whose radius runs from ra to rb. A capsule whose
   ends meet is a circle round a. *)
let taper x y ax ay bx by ra rb =
  let px = x -. ax and py = y -. ay and dx = bx -. ax and dy = by -. ay in
  let length2 = (dx *. dx) +. (dy *. dy) in
  let h = if length2 > 0.0 then clamp01 (((px *. dx) +. (py *. dy)) /. length2) else 0.0 in
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
  let base_y = g.top -. (flame_base_rise *. g.fs) in
  let body = circle x y ox base_y (flame_body_radius *. g.fs) in
  let tip =
    taper x y ox base_y (ox +. g.lean) (base_y -. (flame_tip_rise *. g.fs)) (flame_tip_body_radius *. g.fs)
      flame_tip_radius
  in
  smooth_union body tip flame_blend

(* Where the two wicks of a twin flame stand. *)
let twin_offsets = (-0.07, 0.08)

(* The flames sit wholly above the wax top and within this of the middle. *)
let flame_reach_x = 0.45

let flames (b : body) g x y =
  if g.cull && (y > g.top || Float.abs x > flame_reach_x) then Float.infinity
  else if b.twin_flame then
    let left, right = twin_offsets in
    Float.min (flame_at g x y left) (flame_at g x y right)
  else flame_at g x y 0.0

(* The bright heart of a single flame. Twin flames are small enough that a
   core would swallow them, so they have none. *)
let flame_core (b : body) g x y =
  if b.twin_flame then Float.infinity
  else circle x y 0.0 (g.top -. (flame_core_rise *. g.fs)) (flame_core_radius *. g.fs)

let pair x y bx by tx ty ra rb = Float.min (taper x y (-.bx) by (-.tx) ty ra rb) (taper x y bx by tx ty ra rb)

(* Every horn's base lies within this below the wax top. *)
let horn_reach_below = 0.15

let horns (b : body) g x y =
  if g.cull && y > g.top +. horn_reach_below then Float.infinity
  else
  let l = b.horn_length in
  let bx = g.w *. 0.68 and by = g.top +. horn_base_drop in
  match b.horns with
  | Nub -> pair x y bx by (bx +. 0.04) (by -. (nub_rise *. l)) 0.065 nub_tip_radius
  | Long -> pair x y bx by (bx +. 0.10) (by -. (long_horn_rise *. l)) 0.065 tall_horn_tip_radius
  | One -> taper x y (-.bx) by (-.bx -. 0.08) (by -. (one_horn_rise *. l)) 0.075 tall_horn_tip_radius
  | Ram ->
      (* a hook that leaves the top corner, curls outward and comes back down *)
      let hook m =
        let ax = m *. (g.w -. 0.04) and ay = g.top +. 0.03 in
        let kx = m *. (g.w +. (0.09 *. l)) and ky = g.top -. (ram_rise *. l) in
        let ex = m *. (g.w +. (0.13 *. l)) and ey = g.top +. 0.06 in
        Float.min (taper x y ax ay kx ky 0.06 ram_knee_radius)
          (taper x y kx ky ex ey ram_knee_radius 0.02)
      in
      Float.min (hook (-1.0)) (hook 1.0)

let wax (b : body) g x y = rounded_box x y 0.0 g.centre_y g.w g.h b.corner

(* A drip narrows to this share of its starting width at its end. *)
let drip_end_share = 0.8

let drips (b : body) g x y =
  if g.cull && (y < g.drip_top || y > g.drip_bottom) then Float.infinity
  else
  List.fold_left
    (fun acc d ->
      Float.min acc
        (taper x y d.drip_x g.top (d.drip_x +. 0.005) (g.top +. d.drip_length) d.drip_width
           (d.drip_width *. drip_end_share)))
    Float.infinity b.drips

let dish_field g x y =
  if g.cull && y < wax_bottom +. dish_drop -. dish_half_height -. neighbour_margin then Float.infinity
  else ellipse x y 0.0 (wax_bottom +. dish_drop) (g.w +. dish_side) dish_half_height 0.0

(* Hung from the face, not the wax: on a short candle the face fills the wax
   and the scarf wraps its foot, over the dish, rather than the mouth. *)
let scarf_field g x y =
  if g.cull && y < g.scarf_top -. neighbour_margin then Float.infinity
  else
    let c = scarf_band_centre g in
    Float.min
      (rounded_box x y 0.0 c (g.w +. scarf_overhang) scarf_half_height scarf_corner)
      (taper x y (g.w *. 0.45) (c +. 0.01) (g.w *. 0.70) (c +. scarf_tail_drop) scarf_tail_radius
         scarf_tail_end_radius)

(* A bow tie and a medal hang from the same band the scarf does, so they clear
   the mouth the same way. The bow tie is two wings and a knot; the medal is a
   V ribbon with a disc below it. Heights are fixed units, not shares of the
   wax width, so the wings stay as thick as the scarf's band and the disc
   stays a visible dot even at 48 px, where one shape unit is about 25 px. *)
let neck_band_centre g = scarf_band_centre g

let bow_tie_wing_field g x y =
  let c = neck_band_centre g in
  let hw = g.w *. 0.40 in
  Float.min (ellipse x y (-.hw) c (hw *. 0.60) 0.075 0.25)
    (ellipse x y hw c (hw *. 0.60) 0.075 (-0.25))

let bow_tie_knot_field g x y =
  let c = neck_band_centre g in
  circle x y 0.0 c 0.06

let bow_tie_field g x y =
  Float.min (bow_tie_wing_field g x y) (bow_tie_knot_field g x y)

let medal_disc_field g x y =
  let c = neck_band_centre g in
  circle x y 0.0 (c +. medal_drop) medal_radius

let medal_ribbon_field g x y =
  let c = neck_band_centre g in
  Float.min
    (taper x y (-.(g.w *. 0.52)) (c -. 0.07) (-.0.045) (c +. 0.07) 0.034 0.022)
    (taper x y (g.w *. 0.52) (c -. 0.07) 0.045 (c +. 0.07) 0.034 0.022)

let medal_field g x y = Float.min (medal_ribbon_field g x y) (medal_disc_field g x y)

let bow_centre g = (-.g.w *. 0.55, g.top +. 0.02)

let bow_field g x y =
  let bx, by = bow_centre g in
  Float.min (ellipse x y (bx -. 0.06) by 0.06 0.035 0.3) (ellipse x y (bx +. 0.06) by 0.06 0.035 (-0.3))

let bow_knot g x y =
  let bx, by = bow_centre g in
  circle x y bx by 0.025

(* Head items sit on the wax rim, under the flame and between the horns.
   The flame owns their overlap in the middle; the crown's side teeth fit
   inside the horns' bases. *)
let crown_half_width = 0.15
let crown_band_half_height = 0.026
(* Rest the band's lower edge on the wax rim. A band embedded in the wax's
   outline becomes the same ink as that rim in the small Info mosaic, even
   though the full-size crown has a different paint. Its own silhouette must
   remain above the wax; the flame still owns any overlap at the centre. *)
let crown_centre g = (0.0, g.top -. crown_band_half_height)

let crown_field g x y =
  let cx, cy = crown_centre g in
  let band = rounded_box x y cx cy crown_half_width crown_band_half_height 0.012 in
  let point px = taper x y px (cy -. crown_band_half_height) px (cy -. crown_band_half_height -. 0.04) 0.026 0.004 in
  Float.min band (Float.min (point (cx -. 0.10)) (Float.min (point cx) (point (cx +. 0.10))))

(* A beanie fills the whole band: a round crown from just under the flame
   down to just above the eyes, with a folded brim wider than the crown at
   its foot. The crown's top is behind the flame at the centre and shows at
   the sides; the brim sits low enough that the horns, which leave the wax
   top and rise outward, are already above it. Sized from the face scale so
   it clears the eyes on the narrowest candle and the horns on the widest. *)
let beanie_field g x y =
  let s = g.s in
  let top_y = g.top -. (0.02 *. s) in
  let bottom_y = g.fy -. (0.13 *. s) in
  let h = Float.max 0.06 (bottom_y -. top_y) in
  let half_w = 0.14 *. s in
  let cy = (top_y +. bottom_y) /. 2.0 in
  let dome = ellipse x y 0.0 cy half_w (h /. 2.0) 0.0 in
  let brim = rounded_box x y 0.0 (bottom_y -. (0.16 *. h)) (0.62 *. g.w) (0.16 *. h) (0.012 *. s) in
  Float.min dome brim

(* Hand items are held at the candle's lower right, straddling the wax edge
   so they read as held rather than floating. Each is one bold silhouette
   with an inner detail the ink line separates: a book's spine and page edge,
   a mug's handle and rim, a quill's nib. Anchored to the wax width so the
   widest candle's item still stays inside the reach box the renderer skips
   outside of. *)
let hand_centre g = (g.w +. 0.05, g.centre_y +. (0.10 *. g.h))

(* A ring of half width [hw] round an ellipse: the mug's handle. *)
let ring x y cx cy rx ry hw = Float.abs (ellipse x y cx cy rx ry 0.0) -. hw

let book_spine_field g x y =
  let cx, cy = hand_centre g in
  rounded_box x y (cx -. 0.10) cy 0.03 0.09 0.006

let book_pages_field g x y =
  let cx, cy = hand_centre g in
  rounded_box x y (cx +. 0.10) cy 0.03 0.08 0.006

let book_field g x y =
  let cx, cy = hand_centre g in
  let cover = rounded_box x y cx cy 0.15 0.11 0.012 in
  Float.min cover (Float.min (book_spine_field g x y) (book_pages_field g x y))

let mug_rim_field g x y =
  let cx, cy = hand_centre g in
  ellipse x y cx (cy -. 0.105) 0.08 0.022 0.0

let mug_field g x y =
  let cx, cy = hand_centre g in
  let body = rounded_box x y cx cy 0.08 0.12 0.02 in
  let handle = ring x y (cx +. 0.095) cy 0.05 0.055 0.016 in
  Float.min body (Float.min handle (mug_rim_field g x y))

let quill_nib_field g x y =
  let cx, cy = hand_centre g in
  taper x y (cx -. 0.02) (cy +. 0.15) (cx -. 0.05) (cy +. 0.22) 0.014 0.002

let quill_field g x y =
  let cx, cy = hand_centre g in
  let feather = ellipse x y (cx +. 0.02) (cy -. 0.04) 0.08 0.17 0.32 in
  let shaft = taper x y (cx -. 0.02) (cy +. 0.15) (cx +. 0.07) (cy -. 0.21) 0.014 0.006 in
  Float.min feather (Float.min shaft (quill_nib_field g x y))

(* A beard: strands hanging from the jaw, with a mustache above the mouth.
   Separate strokes, not one filled oval: a solid oval whose top edge sits on
   the mouth line covers the mouth and reads as a mask at the sizes the TUI
   draws. The strands start below the mouth so it stays clear; they merge at
   the jaw and split into tips, so the shape reads as hair. Cut at the wax's
   bottom edge like the rest of the face. *)
let beard_field g x y =
  let s = g.s in
  (* Below the mouth and its fang (the fang ends 0.27 face-scales under the
     centre), so neither is covered. *)
  let jaw = g.fy +. (0.275 *. s) in
  let strand top_x tip_x tip_y =
    taper x y (top_x *. s) jaw (tip_x *. s) (g.fy +. (tip_y *. s)) (0.100 *. s) (0.055 *. s)
  in
  let chin =
    (* flat at the jaw: a strand's round cap would reach a radius above it,
       over the mouth *)
    Float.max
      (List.fold_left Float.min Float.infinity
         [
           strand (-0.20) (-0.25) 0.32;
           strand (-0.10) (-0.12) 0.36;
           strand 0.0 0.0 0.40;
           strand 0.10 0.12 0.36;
           strand 0.20 0.25 0.32;
         ])
      (jaw -. y)
  in
  let mustache =
    let my = g.fy +. (0.13 *. s) in
    Float.min
      (taper x y 0.0 my (-0.13 *. s) (my +. (0.03 *. s)) (0.030 *. s) (0.012 *. s))
      (taper x y 0.0 my (0.13 *. s) (my +. (0.03 *. s)) (0.030 *. s) (0.012 *. s))
  in
  Float.max (Float.min chin mustache) (y -. wax_bottom)

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
  | Dish_metal of dish
  | Eye
  | Glint
  | Blush
  | Mouth
  | Tooth
  | Frame
  | Lens
  | Beard_hair
  | Scarf_cloth
  | Bow_tie_wing
  | Bow_tie_knot
  | Medal_ribbon
  | Medal_metal
  | Bow_ribbon
  | Crown_metal
  | Beanie_felt
  | Book_cover
  | Book_spine
  | Book_pages
  | Mug_ceramic
  | Mug_rim
  | Quill_feather
  | Quill_nib
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
  | Dish_metal _ -> 6
  | Eye -> 7
  | Glint -> 8
  | Blush -> 9
  | Mouth -> 10
  | Tooth -> 11
  | Frame -> 12
  | Lens -> 13
  | Beard_hair -> 14
  | Scarf_cloth -> 15
  | Bow_tie_wing -> 16
  | Bow_tie_knot -> 17
  | Medal_ribbon -> 18
  | Medal_metal -> 19
  | Bow_ribbon -> 20
  | Crown_metal -> 21
  | Beanie_felt -> 22
  | Book_cover -> 23
  | Book_spine -> 24
  | Book_pages -> 25
  | Mug_ceramic -> 26
  | Mug_rim -> 27
  | Quill_feather -> 28
  | Quill_nib -> 29
  | Plaster_strip -> 30
  | Patch -> 31
  | Freckle -> 32

(* Soft marks and highlights sit on a part without an ink line round them. *)
let quiet = function
  | Glint | Blush | Freckle -> true
  | Outside | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal _ | Eye | Mouth | Tooth | Frame | Lens
  | Beard_hair | Scarf_cloth | Bow_tie_wing | Bow_tie_knot | Medal_ribbon | Medal_metal | Bow_ribbon | Crown_metal
  | Beanie_felt | Book_cover | Book_spine | Book_pages | Mug_ceramic | Mug_rim | Quill_feather | Quill_nib
  | Plaster_strip | Patch ->
      false

(* Parts that give light keep their colour in the shade band. *)
let emissive = function
  | Flame | Flame_core | Glint -> true
  | Outside | Wax | Wax_drip | Horn | Dish_metal _ | Eye | Blush | Mouth | Tooth | Frame | Lens | Beard_hair
  | Scarf_cloth | Bow_tie_wing | Bow_tie_knot | Medal_ribbon | Medal_metal | Bow_ribbon | Crown_metal | Beanie_felt
  | Book_cover | Book_spine | Book_pages | Mug_ceramic | Mug_rim | Quill_feather | Quill_nib | Plaster_strip | Patch
  | Freckle ->
      false

let outside = function
  | Outside -> true
  | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal _ | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens
  | Beard_hair | Scarf_cloth | Bow_tie_wing | Bow_tie_knot | Medal_ribbon | Medal_metal | Bow_ribbon | Crown_metal
  | Beanie_felt | Book_cover | Book_spine | Book_pages | Mug_ceramic | Mug_rim | Quill_feather | Quill_nib
  | Plaster_strip | Patch | Freckle ->
      false

(* The flame and its core are one light; no line between them. *)
let flame_part = function
  | Flame | Flame_core -> true
  | Outside | Wax | Wax_drip | Horn | Dish_metal _ | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens | Beard_hair
  | Scarf_cloth | Bow_tie_wing | Bow_tie_knot | Medal_ribbon | Medal_metal | Bow_ribbon | Crown_metal | Beanie_felt
  | Book_cover | Book_spine | Book_pages | Mug_ceramic | Mug_rim | Quill_feather | Quill_nib | Plaster_strip | Patch
  | Freckle ->
      false

let eye_offset = 0.19

let eye_centre_list g = [ (-.eye_offset *. g.s, g.fy); (eye_offset *. g.s, g.fy) ]

(* The upward arc of a closed eye. *)
let closed_eye g x y ex =
  arc x y ex (g.fy +. (0.07 *. g.s)) (0.07 *. g.s) (0.02 *. g.s) (-.pi +. 0.6) (-0.6)

(* Sparkle eyes are this much bigger than bean eyes. *)
let sparkle_eye_scale = 1.25

let open_oval g x y ex ey big =
  let s = g.s in
  ellipse x y ex ey (eye_oval_rx *. s *. big) (eye_oval_ry *. s *. big) 0.0 < 0.0

let one_eye (b : body) g x y ~right =
  let s = g.s in
  let ex = (if right then eye_offset else -.eye_offset) *. s and ey = g.fy in
  let closed () = if closed_eye g x y ex < 0.0 then Some Eye else None in
  let oval big =
    if open_oval g x y ex ey big then
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
      let second_glint = circle x y (ex +. (0.025 *. s)) (ey +. (0.04 *. s)) (0.012 *. s) < 0.0 in
      if open_oval g x y ex ey sparkle_eye_scale && second_glint then Some Glint else oval sparkle_eye_scale

(* The mouth's centre line, face-scales under the face centre. *)
let mouth_drop = 0.20

let mouth_paint (b : body) g x y =
  let s = g.s in
  let my = g.fy +. (mouth_drop *. s) in
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

(* Three freckles per cheek, (x, y) in face-scales from the face centre:
   below every eye style (the biggest ends 0.119 under the centre), beside
   the mouth, and inside the wax for every width (the outermost reaches 0.77
   of the half width). *)
let freckle_spots = [ (-0.13, 0.15); (-0.18, 0.175); (-0.23, 0.145); (0.13, 0.15); (0.18, 0.175); (0.23, 0.145) ]
let freckle_radius = 0.012

let freckle_centre_list g = List.map (fun (fx, fy_share) -> (fx *. g.s, g.fy +. (fy_share *. g.s))) freckle_spots

(* Marks on the wax itself, under the eyes and the mouth. *)
let skin_mark (e : equipment) g x y =
  let s = g.s in
  match e.face with
  | Plaster -> if rounded_box x y (0.30 *. s) (g.fy +. (0.13 *. s)) (0.07 *. s) (0.03 *. s) 0.01 < 0.0 then Some Plaster_strip else None
  | Freckles ->
      if List.exists (fun (cx, cy) -> circle x y cx cy (freckle_radius *. s) < 0.0) (freckle_centre_list g)
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

let neck_field (e : equipment) g x y =
  match e.neck with
  | Scarf -> scarf_field g x y
  | Bow_tie -> bow_tie_field g x y
  | Medal -> medal_field g x y
  | Bare_neck -> Float.infinity

(* The paint for whatever is worn at the neck. [Bare_neck] never reaches here:
   its field is infinite, so no sample is inside it. *)
let neck_paint (e : equipment) g x y =
  match e.neck with
  | Scarf -> Scarf_cloth
  | Bow_tie -> if bow_tie_knot_field g x y < 0.0 then Bow_tie_knot else Bow_tie_wing
  | Medal -> if medal_disc_field g x y < 0.0 then Medal_metal else Medal_ribbon
  | Bare_neck -> Outside

let head_field (e : equipment) g x y =
  match e.head with
  | Bow -> Float.min (bow_field g x y) (bow_knot g x y)
  | Crown -> crown_field g x y
  | Beanie -> beanie_field g x y
  | Bare_head -> Float.infinity

(* The paint for whatever is worn on the head. [Bare_head] never reaches here:
   its field is infinite, so no sample is inside it. *)
let head_paint (e : equipment) =
  match e.head with
  | Bow -> Bow_ribbon
  | Crown -> Crown_metal
  | Beanie -> Beanie_felt
  | Bare_head -> Outside

let face_field (e : equipment) g x y =
  match e.face with
  | Beard -> beard_field g x y
  | Glasses -> temples g x y
  | Bare_face | Shades | Eye_patch | Plaster | Freckles -> Float.infinity

let base_field (e : equipment) g x y = match e.base with Dish _ -> dish_field g x y | No_dish -> Float.infinity

(* The dish's paint, made once per render rather than once per sample. *)
let dish_paint (e : equipment) = match e.base with Dish d -> Some (Dish_metal d) | No_dish -> None
let hand_field (e : equipment) g x y =
  match e.hand with
  | Empty_hand -> Float.infinity
  | Book -> book_field g x y
  | Mug -> mug_field g x y
  | Quill -> quill_field g x y

(* The paint for whatever is held. [Empty_hand] never reaches here: its field
   is infinite, so no sample is inside it. *)
let hand_paint (e : equipment) g x y =
  match e.hand with
  | Empty_hand -> Outside
  | Book ->
      if book_spine_field g x y < 0.0 then Book_spine
      else if book_pages_field g x y < 0.0 then Book_pages
      else Book_cover
  | Mug -> if mug_rim_field g x y < 0.0 then Mug_rim else Mug_ceramic
  | Quill -> if quill_nib_field g x y < 0.0 then Quill_nib else Quill_feather

(* Samples outside the candle's reach are this far from it: any positive
   distance reads as backdrop, and no part is ever that close to the box. *)
let beyond_reach = 1.0

(* Eyes, cheeks and mouth all lie within this many face-scales of the face
   centre's row; the rest of the wax is plain. *)
let face_rows_above = 0.16
let face_rows_below = mouth_clearance

(* What is on the wax itself, in drawing order. *)
let on_wax (b : body) (e : equipment) g x y drip_d =
  let plain () = if drip_d < 0.0 then Wax_drip else Wax in
  if g.cull && (y < g.fy -. (face_rows_above *. g.s) || y > g.fy +. (face_rows_below *. g.s)) then plain ()
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
              | None -> ( match mouth_paint b g x y with Some p -> p | None -> plain ()))))

(* Below the items: horns, then the wax and what is on it, then drips. *)
let candle_part (b : body) (e : equipment) g x y ~wax_d ~drip_d ~horn_d =
  if horn_d < 0.0 && wax_d > -0.02 then Horn
  else if wax_d < 0.0 then on_wax b e g x y drip_d
  else if drip_d < 0.0 then Wax_drip
  else if horn_d < 0.0 then Horn
  else Wax

(* Distance to the whole silhouette and the part under the sample. *)
let sample (b : body) (e : equipment) ~dish g x y =
  if g.cull && (x < g.reach_left || x > g.reach_right || y < g.reach_top || y > g.reach_bottom) then
    (beyond_reach, Outside)
  else
    let wax_d = wax b g x y in
    let drip_d = drips b g x y in
    let flame_d = flames b g x y in
    let horn_d = horns b g x y in
    let neck_d = neck_field e g x y in
    let head_d = head_field e g x y in
    let face_d = face_field e g x y in
    let base_d = base_field e g x y in
    let hand_d = hand_field e g x y in
    let silhouette =
      Float.min
        (Float.min (Float.min wax_d drip_d) (Float.min flame_d horn_d))
        (Float.min (Float.min neck_d head_d) (Float.min face_d (Float.min base_d hand_d)))
    in
    let paint =
      if silhouette >= 0.0 then Outside
      else if flame_d < 0.0 then if flame_core b g x y < 0.0 then Flame_core else Flame
      else if head_d < 0.0 then head_paint e
      else if hand_d < 0.0 then hand_paint e g x y
      else
        match face_overlay e g x y with
        | Some p -> p
        | None -> (
            if neck_d < 0.0 then neck_paint e g x y
            else
              match dish with
              | Some metal when base_d < 0.0 && wax_d > -0.01 -> metal
              | Some _ | None -> candle_part b e g x y ~wax_d ~drip_d ~horn_d)
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

let paint_colour (b : body) = function
  | Outside -> backdrop_colour b
  | Wax -> wax_colour b.wax
  | Wax_drip -> scale_rgb (wax_colour b.wax) drip_share
  | Flame -> fst (flame_colours b.flame)
  | Flame_core -> snd (flame_colours b.flame)
  | Horn -> horn_rgb b.horn_colour
  | Dish_metal d -> dish_rgb d
  | Eye -> eye_colour b
  | Glint -> rgb 255 255 255
  | Blush -> rgb 255 140 160
  | Mouth -> rgb 160 60 80
  | Tooth -> rgb 255 255 255
  | Frame -> rgb 60 56 80
  | Lens -> rgb 30 30 40
  | Beard_hair -> rgb 150 112 84
  | Scarf_cloth -> rgb 214 64 84
  | Bow_tie_wing -> rgb 60 70 150
  | Bow_tie_knot -> rgb 36 42 100
  | Medal_ribbon -> rgb 200 60 70
  | Medal_metal -> rgb 226 186 74
  | Bow_ribbon -> rgb 236 110 150
  | Crown_metal -> rgb 240 200 70
  | Beanie_felt -> rgb 96 76 150
  | Book_cover -> rgb 158 72 62
  | Book_spine -> rgb 100 42 40
  | Book_pages -> rgb 244 236 214
  | Mug_ceramic -> rgb 88 142 168
  | Mug_rim -> rgb 200 226 238
  | Quill_feather -> rgb 232 226 206
  | Quill_nib -> rgb 60 50 60
  | Plaster_strip -> rgb 246 220 180
  | Patch -> rgb 40 36 44
  | Freckle -> rgb 150 96 80

type palette = {
  wax_rgb : rgb;
  drip_rgb : rgb;
  flame_rgb : rgb;
  flame_core_rgb : rgb;
  horn_rgb : rgb;
  eye_rgb : rgb;
  glint_rgb : rgb;
  blush_rgb : rgb;
  mouth_rgb : rgb;
  ink_rgb : rgb;
  backdrop_rgb : rgb;
}

let palette (b : body) =
  {
    wax_rgb = paint_colour b Wax;
    drip_rgb = paint_colour b Wax_drip;
    flame_rgb = paint_colour b Flame;
    flame_core_rgb = paint_colour b Flame_core;
    horn_rgb = paint_colour b Horn;
    eye_rgb = paint_colour b Eye;
    glint_rgb = paint_colour b Glint;
    blush_rgb = paint_colour b Blush;
    mouth_rgb = paint_colour b Mouth;
    ink_rgb = ink_rgb b;
    backdrop_rgb = paint_colour b Outside;
  }

let image_init size pixel_at =
  let rgba = Bytes.create (size * size * 4) in
  for y = 0 to size - 1 do
    for x = 0 to size - 1 do
      let { red; green; blue }, alpha = pixel_at ~x ~y in
      let at = ((y * size) + x) * 4 in
      let byte v = Char.chr (max 0 (min 255 v)) in
      Bytes.set rgba at (byte red);
      Bytes.set rgba (at + 1) (byte green);
      Bytes.set rgba (at + 2) (byte blue);
      Bytes.set rgba (at + 3) (byte alpha)
    done
  done;
  { edge = size; rgba = Bytes.unsafe_to_string rgba }

(* ---- raster -------------------------------------------------------------- *)

let shade c =
  let kr, kg, kb = shade_tint in
  let f v k = int_of_float (Float.round (float_of_int v *. k)) in
  rgb (f c.red kr) (f c.green kg) (f c.blue kb)

let render_with ?frame ~cull ~frame_of (b : body) (e : equipment) (p : pose) (n : size) =
  let g = geometry_posed ~cull b e p in
  let frame = match frame with Some frame -> frame | None -> frame_for b g frame_of n in
  let supersample = supersample_for n in
  let line_reach = line_reach_for supersample in
  let grid = n * supersample in
  let cell = 2.0 *. frame.half /. float_of_int grid in
  let x_of i = -.frame.half +. ((float_of_int i +. 0.5) *. cell) in
  let y_of j = frame.middle_y -. frame.half +. ((float_of_int j +. 0.5) *. cell) in
  (* the candle moves with the bob; the backdrop stays *)
  let lift = p.bob *. bob_reach in
  let dish = dish_paint e in
  let distance = Array.make (grid * grid) 0.0 in
  let paints = Array.make (grid * grid) Outside in
  for j = 0 to grid - 1 do
    let y = y_of j in
    for i = 0 to grid - 1 do
      let d, part = sample b e ~dish g (x_of i) (y +. lift) in
      distance.((j * grid) + i) <- d;
      paints.((j * grid) + i) <- part
    done
  done;
  let at i j = paints.((max 0 (min (grid - 1) j) * grid) + max 0 (min (grid - 1) i)) in
  let dist i j = distance.((max 0 (min (grid - 1) j) * grid) + max 0 (min (grid - 1) i)) in
  let outline = outline_pixels *. 2.0 *. frame.half /. float_of_int n in
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
    | Wax | Wax_drip | Flame | Flame_core | Horn | Dish_metal _ | Eye | Glint | Blush | Mouth | Tooth | Frame | Lens
    | Beard_hair | Scarf_cloth | Bow_tie_wing | Bow_tie_knot | Medal_ribbon | Medal_metal | Bow_ribbon | Crown_metal
    | Beanie_felt | Book_cover | Book_spine | Book_pages | Mug_ceramic | Mug_rim
    | Quill_feather | Quill_nib | Plaster_strip | Patch | Freckle ->
        let d = dist i j in
        if d > -.outline || boundary i j part then Some ink
        else
          let base = paint_colour b part in
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

let render_posed b e p n = render_with ~cull:true ~frame_of:e b e p n
let render b e n = render_posed b e still n

let render_icon b e n =
  let g = geometry b in
  (* Fit the wax width and facial features, with the renderer's existing
     clearance. Peripheral outfit pieces belong to the full preview. *)
  let frame = { half = g.w +. neighbour_margin; middle_y = g.fy } in
  render_with ~frame ~cull:true ~frame_of:e b e still n

(* The mosaic has only 24 samples across a Keeper's band. Sampling the full
   portrait at that size spends most of them on its round backdrop. Draw the
   candle on a 24-unit grid instead: the eyes and mouth each own whole cells,
   and the flame and horns keep their silhouette. *)
let render_compact_posed (b : body) (e : equipment) (p : pose) (n : size) =
  let colours = palette b in
  let painted colour = (colour, 255) in
  let clear = (rgb 0 0 0, 0) in
  let near x y cx cy rx ry =
    let dx = (x -. cx) /. rx and dy = (y -. cy) /. ry in
    (dx *. dx) +. (dy *. dy) <= 1.0
  in
  let horn_height =
    match b.horns with Nub -> 2.4 | Long | One -> 4.0 | Ram -> 3.2
  in
  let horn_centres = match b.horns with One -> [ 6.8 ] | Nub | Long | Ram -> [ 6.8; 17.2 ] in
  let dish =
    match e.base with
    | No_dish -> None
    | Dish material -> Some (paint_colour b (Dish_metal material))
  in
  image_init n (fun ~x ~y ->
      let edge = float_of_int n in
      let x = (float_of_int x +. 0.5) *. 24.0 /. edge in
      let y = (float_of_int y +. 0.5) *. 24.0 /. edge -. (p.bob *. 0.35) in
      let body =
        x >= 5.0 && x < 19.0 && y >= 9.0 && y < 20.5
        && (y >= 10.0 && y < 19.5 || x >= 6.0 && x < 18.0)
      in
      let eye cx = near x y cx 13.9 1.5 (if p.blink then 0.35 else 1.6) in
      let glint cx = near x y (cx -. 0.4) 13.4 0.45 0.45 in
      let mouth =
        match b.mouth with
        | O -> near x y 12.0 17.5 1.0 1.25
        | Flat -> Float.abs (x -. 12.0) < 1.8 && Float.abs (y -. 17.5) < 0.45
        | W | Smile | Fang ->
            Float.abs (x -. 12.0) < 2.2
            && Float.abs (y -. (18.0 -. (0.42 *. Float.abs (x -. 12.0)))) < 0.5
      in
      let horn =
        List.exists
          (fun cx ->
            y >= 9.5 -. horn_height && y < 10.0
            && Float.abs (x -. cx) < 0.25 +. ((y -. (9.5 -. horn_height)) *. 0.36))
          horn_centres
      in
      let flame_x = x -. (p.flicker *. 0.4) in
      let flame =
        near flame_x y 12.0 5.5 2.5 (3.0 +. (p.flicker *. 0.25))
        || (y >= 0.0 && y < 5.0
            && Float.abs (flame_x -. 12.0) < 0.8 +. (y *. 0.35))
      in
      if body then
        if eye 9.0 || eye 15.0 then
          painted
            (if not p.blink && (glint 9.0 || glint 15.0)
             then colours.glint_rgb else colours.eye_rgb)
        else if mouth then painted colours.mouth_rgb
        else if b.blush && (near x y 7.3 16.3 1.0 0.75 || near x y 16.7 16.3 1.0 0.75)
        then painted colours.blush_rgb
        else if x < 5.8 || x >= 18.2 || y < 9.7 || y >= 19.8
        then painted colours.ink_rgb
        else if (x < 7.2 && y < 12.0) || (x > 16.8 && y < 11.0)
        then painted colours.drip_rgb
        else painted (if x > 15.5 then shade colours.wax_rgb else colours.wax_rgb)
      else if horn then painted colours.horn_rgb
      else if flame then
        painted
          (if near flame_x y 12.0 5.9 1.05 1.7
           then colours.flame_core_rgb else colours.flame_rgb)
      else if x >= 11.5 && x < 12.5 && y >= 8.0 && y < 9.6
      then painted colours.ink_rgb
      else
        match dish with
        | Some metal when x >= 4.2 && x < 19.8 && y >= 20.3 && y < 22.0 ->
            painted metal
        | Some _ | None -> clear)

let pixel img ~x ~y =
  let x = max 0 (min (img.edge - 1) x) and y = max 0 (min (img.edge - 1) y) in
  let k = ((y * img.edge) + x) * 4 in
  let byte o = Char.code img.rgba.[k + o] in
  (rgb (byte 0) (byte 1) (byte 2), byte 3)

module For_testing = struct
  let render_unculled b e p n = render_with ~cull:false ~frame_of:e b e p n

  let render_in_frame_of b e ~frame_of p n = render_with ~cull:true ~frame_of b e p n

  let pixel_of_point n (x, y) =
    let to_px v = int_of_float (Float.floor ((v +. view_half) /. (2.0 *. view_half) *. float_of_int n)) in
    (to_px x, to_px (y -. view_centre_y))

  let wax_bounds b =
    let g = geometry b in
    (-.g.w, g.top, g.w, wax_bottom)

  let eye_centres b = eye_centre_list (geometry b)
  let freckle_centres b = freckle_centre_list (geometry b)

  let mouth_centre b =
    let g = geometry b in
    (0.0, g.fy +. (mouth_drop *. g.s))

  let flame_probe b =
    let g = geometry b in
    let ox = if b.twin_flame then fst twin_offsets else 0.0 in
    let base_y = g.top -. (flame_base_rise *. g.fs) in
    (* inside the flame body, toward its lower right, clear of the core *)
    (ox +. (0.075 *. g.fs), base_y +. (0.05 *. g.fs))

  (* Outline and anti-aliasing reach past a part's own field by about this
     much at the sizes the tests draw. *)
  let ink_margin = 0.04

  let flame_box b =
    let g = geometry_posed ~cull:true b bare { still with flicker = 1.0 } in
    let spread = (flame_body_radius *. g.fs) +. flicker_sway +. Float.abs b.flame_lean +. ink_margin in
    let left, right = if b.twin_flame then twin_offsets else (0.0, 0.0) in
    (left -. spread, g.top -. ((flame_base_rise +. flame_tip_rise) *. g.fs) -. ink_margin, right +. spread, g.top +. ink_margin)

  let eye_boxes b =
    let g = geometry b in
    let half = (0.125 *. g.s) +. ink_margin in
    List.map (fun (ex, ey) -> (ex -. half, ey -. half, ex +. half, ey +. half)) (eye_centre_list g)

  let line_reach_pixels n =
    let ss = supersample_for n in
    float_of_int (line_reach_for ss) /. float_of_int ss

  let ink = ink_rgb
  let wax_rgb b = wax_colour b.wax
  let flame_rgb b = fst (flame_colours b.flame)
  let eye_rgb = eye_colour
  let mouth_rgb b = paint_colour b Mouth
  let tooth_rgb b = paint_colour b Tooth
  let beard_rgb b = paint_colour b Beard_hair
  let backdrop_rgb = backdrop_colour
end
