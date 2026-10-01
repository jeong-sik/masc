module Draw = Keeper_portrait_draw
module Look = Keeper_portrait_look

let grid = 40

(* Thirty-six steps of the /about candle's 150 ms. *)
let sway_period_ms = 5400

(* ---- vectors ------------------------------------------------------------- *)

type vec = { x : float; y : float; z : float }

let vec x y z = { x; y; z }
let add a b = vec (a.x +. b.x) (a.y +. b.y) (a.z +. b.z)
let sub a b = vec (a.x -. b.x) (a.y -. b.y) (a.z -. b.z)
let scale a k = vec (a.x *. k) (a.y *. k) (a.z *. k)
let dot a b = (a.x *. b.x) +. (a.y *. b.y) +. (a.z *. b.z)
let length a = sqrt (dot a a)
let normalise a = scale a (1.0 /. length a)
let clamp lo hi value = Float.max lo (Float.min hi value)
let mix a b t = a +. ((b -. a) *. t)

(* Turn [p] by [angle] about the upright axis. *)
let turn angle p =
  let c = cos angle and s = sin angle in
  vec ((c *. p.x) +. (s *. p.z)) p.y ((-.s *. p.x) +. (c *. p.z))

(* ---- distances ----------------------------------------------------------- *)

(* An upright cylinder with rounded edges, centred on the origin. *)
let rounded_cylinder p ~radius ~half_height ~rounding =
  let across = sqrt ((p.x *. p.x) +. (p.z *. p.z)) -. radius +. rounding in
  let up = Float.abs p.y -. half_height +. rounding in
  Float.min (Float.max across up) 0.0
  +. sqrt ((Float.max across 0.0 ** 2.0) +. (Float.max up 0.0 ** 2.0))
  -. rounding

(* A segment from [a] to [b] whose radius goes from [ra] to [rb]. Not an
   exact distance where the radius changes fast, so the march steps short. *)
let tapered p a b ~ra ~rb =
  let ab = sub b a and ap = sub p a in
  let t = clamp 0.0 1.0 (dot ap ab /. dot ab ab) in
  length (sub ap (scale ab t)) -. mix ra rb t

let ellipsoid p centre ~rx ~ry ~rz =
  let q = sub p centre in
  let k0 = length (vec (q.x /. rx) (q.y /. ry) (q.z /. rz)) in
  let k1 = length (vec (q.x /. (rx *. rx)) (q.y /. (ry *. ry)) (q.z /. (rz *. rz))) in
  if k1 = 0.0 then -.rx else k0 *. (k0 -. 1.0) /. k1

let sphere p centre ~radius = length (sub p centre) -. radius

(* ---- the figure, in shape units: the backdrop's radius is about one ------- *)

(* A surface takes light; the flame and the glint in an eye give it. *)
type surface = Wax | Horn | Wick | Eye | Mouth
type part = Surface of surface | Flame | Glint

let wax_centre = vec 0.0 (-0.2) 0.0
let wax_radius = 0.46
let wax_half_height = 0.62
let wax_rounding = 0.12

(* Where a drip starts on the rim, where it ends down the front, and its
   radius at each end. *)
let drips =
  [ (vec (-0.22) 0.4 0.38, vec (-0.26) 0.05 0.43, 0.07, 0.05);
    (vec 0.3 0.4 0.3, vec 0.33 0.18 0.34, 0.06, 0.045) ]

(* Each horn from its root at the rim to its tip, for the side [s]. *)
let horn_root s = vec (0.27 *. s) 0.36 0.0
let horn_tip s = vec (0.5 *. s) 0.78 0.0
let horn_root_radius = 0.11
let horn_tip_radius = 0.015
let sides = [ -1.0; 1.0 ]
let wick_foot = vec 0.0 0.38 0.0
let wick_top = vec 0.0 0.55 0.0
let wick_radius = 0.022
let flame_foot = 0.6
let flame_height = 0.42
let flame_foot_radius = 0.11
let flame_tip_radius = 0.012
let eye_centre s = vec (0.17 *. s) 0.02 0.41
let eye_radii = (0.085, 0.11, 0.06)
let glint_centre s = vec ((0.17 *. s) +. 0.03) 0.07 0.455
let glint_radius = 0.028

(* The mouth's two strokes meet under the nose: a small w. *)
let mouth_strokes =
  [ (vec (-0.06) (-0.13) 0.455, vec 0.0 (-0.16) 0.465);
    (vec 0.0 (-0.16) 0.465, vec 0.06 (-0.13) 0.455) ]

let mouth_radius = 0.018

(* Where the cheeks blush on the front of the wax, and how wide. *)
let cheek_x = 0.3
let cheek_y = -0.08
let cheek_front = 0.3
let cheek_radius = 0.07

(* The nearest part at [p], in the figure's own frame; [flicker] stretches
   the flame. *)
let scene ~flicker p =
  let nearest = ref (infinity, Surface Wax) in
  let take distance part = if distance < fst !nearest then nearest := (distance, part) in
  let body =
    rounded_cylinder (sub p wax_centre) ~radius:wax_radius ~half_height:wax_half_height
      ~rounding:wax_rounding
  in
  let body =
    List.fold_left
      (fun d (a, b, ra, rb) -> Float.min d (tapered p a b ~ra ~rb))
      body drips
  in
  take body (Surface Wax);
  List.iter
    (fun s ->
      take
        (tapered p (horn_root s) (horn_tip s) ~ra:horn_root_radius ~rb:horn_tip_radius)
        (Surface Horn))
    sides;
  take (tapered p wick_foot wick_top ~ra:wick_radius ~rb:wick_radius) (Surface Wick);
  take
    (tapered p (vec 0.0 flame_foot 0.0)
       (vec 0.0 (flame_foot +. (flame_height *. flicker)) 0.0)
       ~ra:flame_foot_radius ~rb:flame_tip_radius)
    Flame;
  let rx, ry, rz = eye_radii in
  List.iter
    (fun s ->
      take (ellipsoid p (eye_centre s) ~rx ~ry ~rz) (Surface Eye);
      take (sphere p (glint_centre s) ~radius:glint_radius) Glint)
    sides;
  List.iter
    (fun (a, b) -> take (tapered p a b ~ra:mouth_radius ~rb:mouth_radius) (Surface Mouth))
    mouth_strokes;
  !nearest

let normal_step = 0.002

let normal ~flicker p =
  let d q = fst (scene ~flicker q) in
  let along axis = d (add p (scale axis normal_step)) -. d (sub p (scale axis normal_step)) in
  normalise (vec (along (vec 1.0 0.0 0.0)) (along (vec 0.0 1.0 0.0)) (along (vec 0.0 0.0 1.0)))

(* ---- colour -------------------------------------------------------------- *)

type colour = { r : float; g : float; b : float }

let of_rgb (c : Draw.rgb) =
  { r = float_of_int c.Draw.red; g = float_of_int c.Draw.green; b = float_of_int c.Draw.blue }

let blend a b t = { r = mix a.r b.r t; g = mix a.g b.g t; b = mix a.b b.b t }
let darken a k = { r = a.r *. k; g = a.g *. k; b = a.b *. k }
let white = { r = 255.0; g = 255.0; b = 255.0 }

(* Light from the upper left and in front, fixed while the figure sways. *)
let light = normalise (vec (-0.5) 0.7 0.8)

(* Three flat bands, the cel look the 2D renderer has. *)
let cel lambert = if lambert > 0.55 then 1.0 else if lambert > 0.15 then 0.84 else 0.7

(* A rim facing away from the eye catches a thin highlight. *)
let rim_threshold = 0.6
let rim_share = 0.18

(* Where up the flame it burns hottest: a third of the way, as a real flame
   does. *)
let flame_hottest = 0.35

(* The flame warms the top of the wax: this far below the rim, none. *)
let warm_depth = 0.33
let warm_share = 0.35
let blush_share = 0.55

let surface_colour (palette : Draw.palette) = function
  | Wax -> of_rgb palette.Draw.wax_rgb
  | Horn -> of_rgb palette.Draw.horn_rgb
  | Wick -> of_rgb palette.Draw.ink_rgb
  | Eye -> of_rgb palette.Draw.eye_rgb
  | Mouth -> of_rgb palette.Draw.mouth_rgb

let shade (palette : Draw.palette) ~angle ~flicker ~local part =
  match part with
  | Flame ->
      let height = clamp 0.0 1.0 ((local.y -. flame_foot) /. (flame_height *. flicker)) in
      blend (of_rgb palette.Draw.flame_rgb) (of_rgb palette.Draw.flame_core_rgb)
        (1.0 -. Float.abs (height -. flame_hottest))
  | Glint -> of_rgb palette.Draw.glint_rgb
  | Surface surface ->
      let n = turn angle (normal ~flicker local) in
      let lit = darken (surface_colour palette surface) (cel (dot n light)) in
      let lit =
        match surface with
        | Wax ->
            let warm = clamp 0.0 1.0 ((local.y -. (wick_foot.y -. warm_depth)) /. warm_depth) in
            let lit = blend lit (of_rgb palette.Draw.flame_core_rgb) (warm_share *. warm) in
            let off_cheek s = length (vec (local.x -. (cheek_x *. s)) (local.y -. cheek_y) 0.0) in
            if local.z > cheek_front && List.exists (fun s -> off_cheek s < cheek_radius) sides then
              blend lit (of_rgb palette.Draw.blush_rgb) blush_share
            else lit
        | Horn | Wick | Eye | Mouth -> lit
      in
      let facing_away = (1.0 -. Float.max 0.0 n.z) ** 3.0 in
      if facing_away > rim_threshold then blend lit white rim_share else lit

(* ---- camera -------------------------------------------------------------- *)

(* Orthographic, looking down -z; the view spans [-zoom, zoom] across and is
   lifted a little so the flame's tip and the wax's foot both fit. *)
let zoom = 1.14
let lift = 0.04
let eye_distance = 3.0
let far = 6.0
let march_steps = 160
let hit_distance = 0.0015

(* Distances from [tapered] overshoot where a radius changes fast. *)
let step_share = 0.8

(* The ink line round the silhouette, in dots. *)
let outline_dots = 1.15

(* The backdrop: its radius, the ring of ink at its edge, and the flame's
   glow on it. *)
let backdrop_radius = 0.97
let backdrop_ring = 1.0
let glow_centre = vec 0.0 0.8 0.0
let glow_radius = 0.35
let glow_share = 0.5

type sample = Painted of colour | Clear

let trace palette ~angle ~flicker ~outline sx sy =
  let rec march t steps closest =
    if steps = 0 || t > far then `Missed closest
    else
      let local = turn (-.angle) (vec sx sy (eye_distance -. t)) in
      let distance, part = scene ~flicker local in
      if distance < hit_distance then `Hit (local, part)
      else march (t +. (distance *. step_share)) (steps - 1) (Float.min closest distance)
  in
  match march 0.0 march_steps infinity with
  | `Hit (local, part) -> Painted (shade palette ~angle ~flicker ~local part)
  | `Missed closest when closest < outline -> Painted (of_rgb palette.Draw.ink_rgb)
  | `Missed _ ->
      let from_centre = sqrt ((sx *. sx) +. (sy *. sy)) in
      if from_centre < backdrop_radius then
        let glow = Float.max 0.0 (1.0 -. (length (sub (vec sx sy 0.0) glow_centre) /. glow_radius)) in
        Painted
          (blend (of_rgb palette.Draw.backdrop_rgb) (of_rgb palette.Draw.flame_rgb)
             (glow_share *. glow *. glow))
      else if from_centre < backdrop_ring then Painted (of_rgb palette.Draw.ink_rgb)
      else Clear

(* ---- motion -------------------------------------------------------------- *)

(* How far the figure turns each way, in radians, and how many times the
   flame flickers in one sway. *)
let sway_amplitude = 0.6
let flicker_waves = 5
let flicker_rest = 0.9
let flicker_depth = 0.12

let phase milliseconds =
  let within = ((milliseconds mod sway_period_ms) + sway_period_ms) mod sway_period_ms in
  float_of_int within /. float_of_int sway_period_ms

(* ---- raster -------------------------------------------------------------- *)

let opaque = 255
let transparent = ({ Draw.red = 0; green = 0; blue = 0 }, 0)
let channel value = int_of_float (Float.round value)

let mascot ~milliseconds size =
  let edge = Draw.int_of_size size in
  let dot_pixels = Int.max 1 ((edge + (grid / 2)) / grid) in
  let dots = edge / dot_pixels in
  let margin = (edge - (dots * dot_pixels)) / 2 in
  let palette = Draw.palette (fst Look.mascot) in
  let t = phase milliseconds in
  let angle = sway_amplitude *. sin (2.0 *. Float.pi *. t) in
  let flicker =
    flicker_rest +. (flicker_depth *. sin (2.0 *. Float.pi *. t *. float_of_int flicker_waves))
  in
  let dot_size = 2.0 *. zoom /. float_of_int dots in
  let outline = outline_dots *. dot_size in
  (* One sample per dot, then every pixel reads the dot it falls in. *)
  let samples =
    Array.init (dots * dots) (fun index ->
        let row = index / dots and column = index mod dots in
        let sx = ((float_of_int column +. 0.5) *. dot_size) -. zoom in
        let sy = zoom -. ((float_of_int row +. 0.5) *. dot_size) +. (lift *. zoom) in
        match trace palette ~angle ~flicker ~outline sx sy with
        | Clear -> transparent
        | Painted c ->
            ({ Draw.red = channel c.r; green = channel c.g; blue = channel c.b }, opaque))
  in
  let dot_of pixel = (pixel - margin) / dot_pixels in
  let inside pixel = pixel >= margin && dot_of pixel < dots in
  Draw.image_init size (fun ~x ~y ->
      if inside x && inside y then samples.((dot_of y * dots) + dot_of x) else transparent)
