(* A turning imp emblem in Braille.

   Technique after openai/codex codex-rs/tui/src/empty_state_animation
   (Apache-2.0); reimplemented. The steps are the same -- a flat mark's
   distance field stood up as a bevelled slab, surface points splatted through
   a depth buffer, a fixed set of lights, one Braille glyph per cell coloured
   with the mean of its dots -- and the shapes, lights, palette and motion are
   this emblem's own. *)

module Palette = Masc_tui_terminal_palette
module Shape = Masc_tui_imp_shape

let tau = 2.0 *. Float.pi
let clamp01 v = Float.min 1.0 (Float.max 0.0 v)

(* Perlin's smootherstep: starts and stops with no jolt. *)
let ease t =
  let t = clamp01 t in
  t *. t *. t *. ((t *. ((t *. 6.0) -. 15.0)) +. 10.0)

(* ---- size ---- *)

(* A Braille glyph is two dots across and four down. *)
let dots_across = 2
let dots_down = 4
let max_rows = 24
let max_cols = 2 * max_rows
let min_rows = 6

type size =
  { cols : int
  ; rows : int
  }

let fit ~cols ~rows =
  let rows = Int.min max_rows (Int.min rows (cols / 2)) in
  if rows < min_rows then None else Some { cols = 2 * rows; rows }

(* ---- pose ---- *)

type pose =
  | Turning of float
  | Settled

let settled = Settled

let turning phase =
  if Float.is_finite phase
  then (
    let within = phase -. Float.floor phase in
    (* A phase a hair under a whole number can round up to exactly 1.0. *)
    Some (Turning (if within >= 1.0 then 0.0 else within)))
  else None

(* Two turns and two changes; slow enough to read the face on the way round. *)
let loop_seconds = 8.0

(* The part of each half-loop spent turning; the rest holds the face still. *)
let turn_share = 0.8

(* How far into a turn the mark starts to change into the other one. *)
let change_from = 0.62

(* Radians the emblem tips forward and back as it turns. *)
let nod = 0.09

(* Radians it rolls, once over the whole loop. *)
let sway = 0.04

(* Radians the still imp is turned, so the bevel and one side show. *)
let settled_yaw = 0.42

type view =
  { yaw_sin : float
  ; yaw_cos : float
  ; nod_sin : float
  ; nod_cos : float
  ; roll_sin : float
  ; roll_cos : float
  ; blend : float  (** 0.0 is the imp, 1.0 the lantern. *)
  }

let view_of = function
  | Settled ->
    { yaw_sin = Float.sin settled_yaw
    ; yaw_cos = Float.cos settled_yaw
    ; nod_sin = 0.0
    ; nod_cos = 1.0
    ; roll_sin = 0.0
    ; roll_cos = 1.0
    ; blend = 0.0
    }
  | Turning phase ->
    let second_half = phase >= 0.5 in
    let half = if second_half then 1.0 else 0.0 in
    let spin = ease (((phase *. 2.0) -. half) /. turn_share) in
    let change = ease ((spin -. change_from) /. (1.0 -. change_from)) in
    let yaw = (half +. spin) *. tau in
    let tip = Float.sin yaw *. nod in
    let roll = Float.sin (phase *. tau) *. sway in
    { yaw_sin = Float.sin yaw
    ; yaw_cos = Float.cos yaw
    ; nod_sin = Float.sin tip
    ; nod_cos = Float.cos tip
    ; roll_sin = Float.sin roll
    ; roll_cos = Float.cos roll
    ; blend = (if second_half then 1.0 -. change else change)
    }

(* ---- slab and camera ---- *)

(* Half the slab's thickness, in emblem units. *)
let half_depth = 0.18

(* Width of the rounded band along every edge. *)
let bevel = 0.07

(* Extra rounding at the middle of a change, so the in-between shape reads
   as soft rather than torn. *)
let change_softening = 0.015

(* Camera distance from the slab's centre; nearer exaggerates perspective. *)
let eye_distance = 4.0

(* Emblem units that fill the shorter side of the box. The marks reach 1.08
   from the centre; the rest is room for perspective to grow them. *)
let span = 2.3

(* The marks sit high in their square; this moves them to the box's middle. *)
let lift = 0.12

(* Two sine ripples over the face, like hammered metal: (x rate, y rate,
   height). *)
let ripple_a = 2.6, 0.9, 0.06
let ripple_b = -0.5, 3.1, 0.035

(* Height of the ripples at a point, and its slope along x and y. *)
let texture ~x ~y =
  let ax, ay, ah = ripple_a and bx, by, bh = ripple_b in
  let u = (ax *. x) +. (ay *. y) and v = (bx *. x) +. (by *. y) in
  let cu = Float.cos u and cv = Float.cos v in
  ( (ah *. Float.sin u) +. (bh *. Float.sin v)
  , (ah *. ax *. cu) +. (bh *. bx *. cv)
  , (ah *. ay *. cu) +. (bh *. by *. cv) )

type raster =
  { dot_cols : int
  ; dot_rows : int
  ; scale : float
  }

let raster_of size =
  let dot_cols = size.cols * dots_across and dot_rows = size.rows * dots_down in
  { dot_cols; dot_rows; scale = Float.of_int (Int.min dot_cols dot_rows) /. span }

let rotate view ~x ~y ~z =
  let x1 = (x *. view.yaw_cos) +. (z *. view.yaw_sin) in
  let z1 = (z *. view.yaw_cos) -. (x *. view.yaw_sin) in
  let y2 = (y *. view.nod_cos) -. (z1 *. view.nod_sin) in
  let z2 = (y *. view.nod_sin) +. (z1 *. view.nod_cos) in
  ( (x1 *. view.roll_cos) -. (y2 *. view.roll_sin)
  , (x1 *. view.roll_sin) +. (y2 *. view.roll_cos)
  , z2 )

(* The dot a rotated point lands on, with its depth toward the viewer, or
   [None] off the raster. *)
let place raster ~x ~y ~z =
  let p = eye_distance /. (eye_distance -. z) in
  let col =
    Float.to_int
      (Float.floor ((Float.of_int raster.dot_cols /. 2.0) +. (x *. raster.scale *. p)))
  in
  let row =
    Float.to_int
      (Float.floor
         ((Float.of_int raster.dot_rows /. 2.0) +. ((y +. lift) *. raster.scale *. p)))
  in
  if col < 0 || col >= raster.dot_cols || row < 0 || row >= raster.dot_rows
  then None
  else Some ((row * raster.dot_cols) + col)

(* ---- lighting ---- *)

type backdrop =
  | Known of Palette.t
  | Page of Palette.theme_mode
  | Unknown

type tone =
  { r : float
  ; g : float
  ; b : float
  }

type tones =
  { shadow : tone  (** Where no light reaches. *)
  ; key : tone  (** Full light from the main lamp. *)
  ; fill : tone  (** Light bounced up from the lantern. *)
  ; rim : tone  (** Edges catching the lantern from the side. *)
  ; highlight : tone  (** The lamp's reflection. *)
  }

type lighting =
  | Lit of
      { tones : tones
      ; fade_to : tone option  (** The page colour deep surfaces fade toward. *)
      }
  | Unlit

let tone r g b = { r; g; b }
let tone_of_rgb c =
  tone (Float.of_int (Palette.red c)) (Float.of_int (Palette.green c))
    (Float.of_int (Palette.blue c))

(* [from] moved [share] of the way toward [towards]. *)
let mix from towards share =
  { r = from.r +. ((towards.r -. from.r) *. share)
  ; g = from.g +. ((towards.g -. from.g) *. share)
  ; b = from.b +. ((towards.b -. from.b) *. share)
  }

(* Warm coals on a dark page. *)
let ember =
  { shadow = tone 54.0 18.0 32.0
  ; key = tone 250.0 204.0 158.0
  ; fill = tone 156.0 60.0 66.0
  ; rim = tone 255.0 132.0 56.0
  ; highlight = tone 255.0 243.0 222.0
  }

(* Dark warm inks for a page known to be light but not in what colour. *)
let soot =
  { shadow = tone 34.0 20.0 30.0
  ; key = tone 132.0 84.0 72.0
  ; fill = tone 96.0 52.0 58.0
  ; rim = tone 178.0 84.0 40.0
  ; highlight = tone 206.0 160.0 128.0
  }

(* The terminal's own text colour on its own light page, like pencil: the
   shadow is the text colour and lit surfaces step toward the page. *)
let pencil ~ink ~page =
  { shadow = ink
  ; key = mix ink page 0.55
  ; fill = mix ink page 0.35
  ; rim = mix ink page 0.2
  ; highlight = mix ink page 0.78
  }

let lighting = function
  | Known palette ->
    let ink = Palette.foreground palette and page = Palette.background palette in
    let tones =
      if Masc_tui_color.is_light page
      then pencil ~ink:(tone_of_rgb ink) ~page:(tone_of_rgb page)
      else ember
    in
    Lit { tones; fade_to = Some (tone_of_rgb page) }
  | Page Palette.Dark -> Lit { tones = ember; fade_to = None }
  | Page Palette.Light -> Lit { tones = soot; fade_to = None }
  | Unknown -> Unlit

let normalize (x, y, z) =
  let length = Float.sqrt ((x *. x) +. (y *. y) +. (z *. z)) in
  x /. length, y /. length, z /. length

(* The main lamp: above, to the left, in front. *)
let key_light = normalize (-0.46, -0.58, 0.67)

(* Light thrown back up from the lantern, below and to the right. *)
let lantern_bounce = normalize (0.42, 0.48, -0.25)

(* Halfway between the lamp and the viewer: where the reflection sits. *)
let gloss_axis =
  let kx, ky, kz = key_light in
  normalize (kx, ky, kz +. 1.0)

(* Edges facing right and down catch the lantern. *)
let rim_x = 0.8
let rim_y = 0.35

(* How quickly the rim fades as a surface turns toward the viewer. *)
let rim_falloff = 2.2
let rim_strength = 0.85
let bounce_strength = 0.35

(* Sharpness and brightness of the lamp's reflection. *)
let gloss_power = 22
let gloss_strength = 0.9

(* A faint fixed grain so broad faces are not flat. *)
let grain_strength = 0.012

(* Surfaces toward the viewer keep their colour; ones further back fade
   toward the page, never below [fade_floor]. *)
let fade_near = 0.88
let fade_rate = 0.2
let fade_floor = 0.65

let dot3 (ax, ay, az) ~nx ~ny ~nz = (ax *. nx) +. (ay *. ny) +. (az *. nz)

let channel v = Int.min 255 (Int.max 0 (Float.to_int (Float.round v)))

let shade tones fade_to ~nx ~ny ~nz ~depth ~grain =
  let diffuse = clamp01 (dot3 key_light ~nx ~ny ~nz +. grain) in
  let bounce =
    clamp01 (dot3 lantern_bounce ~nx ~ny ~nz) *. (1.0 -. diffuse) *. bounce_strength
  in
  let edge =
    Float.pow (1.0 -. Float.abs (Float.min 1.0 (Float.max (-1.0) nz))) rim_falloff
    *. clamp01 ((nx *. rim_x) +. (ny *. rim_y))
    *. rim_strength
  in
  let gloss =
    Float.pow (clamp01 (dot3 gloss_axis ~nx ~ny ~nz)) (Float.of_int gloss_power)
    *. gloss_strength
  in
  let base = (1.0 -. bounce) *. (1.0 -. edge) *. (1.0 -. gloss) in
  let lit pick =
    (pick tones.shadow *. (1.0 -. diffuse) *. base)
    +. (pick tones.key *. diffuse *. base)
    +. (pick tones.fill *. bounce *. (1.0 -. edge) *. (1.0 -. gloss))
    +. (pick tones.rim *. edge *. (1.0 -. gloss))
    +. (pick tones.highlight *. gloss)
  in
  let faded pick =
    match fade_to with
    | None -> lit pick
    | Some page ->
      let gain = Float.min 1.0 (Float.max fade_floor (fade_near +. (depth *. fade_rate))) in
      pick page +. ((lit pick -. pick page) *. gain)
  in
  channel (faded (fun t -> t.r)), channel (faded (fun t -> t.g)), channel (faded (fun t -> t.b))

(* ---- renderer ---- *)

type cell =
  { dots : int
  ; ink : Palette.rgb option
  }

type frame =
  { size : size
  ; cells : cell array
  }

let max_dots = max_cols * dots_across * max_rows * dots_down

type t =
  { imp : Shape.field
  ; lantern : Shape.field
  ; shape : float array  (** The two fields blended for this frame. *)
  ; depth : float array  (** Nearest depth drawn at each dot; [neg_infinity] if none. *)
  ; red : int array
  ; green : int array
  ; blue : int array
  }

let create () =
  { imp = Shape.field Shape.Imp
  ; lantern = Shape.field Shape.Lantern
  ; shape = Array.make (Shape.grid * Shape.grid) 0.0
  ; depth = Array.make max_dots Float.neg_infinity
  ; red = Array.make max_dots 0
  ; green = Array.make max_dots 0
  ; blue = Array.make max_dots 0
  }

(* Unicode's Braille dot order: dots 1-3 down the left column, 4-6 down the
   right, then 7 and 8 under them. Indexed by row within the cell times two
   plus the column. *)
let dot_bits = [| 0x01; 0x08; 0x02; 0x10; 0x04; 0x20; 0x40; 0x80 |]

(* A point on the side wall sits this close to the outline, in lattice
   steps, to be drawn as wall. *)
let wall_band = 0.8

(* The fixed grain's pattern: (x rate, y rate, offset). *)
let grain_pattern = 29.0, 17.0, 1.7

let frame t size pose lighting =
  let view = view_of pose in
  let raster = raster_of size in
  let dots = raster.dot_cols * raster.dot_rows in
  Array.fill t.depth 0 dots Float.neg_infinity;
  let grid = Shape.grid and step = Shape.step and extent = Shape.extent in
  for row = 0 to grid - 1 do
    for col = 0 to grid - 1 do
      t.shape.((row * grid) + col)
      <- (Shape.sample t.imp ~col ~row *. (1.0 -. view.blend))
         +. (Shape.sample t.lantern ~col ~row *. view.blend)
    done
  done;
  let bevel = bevel +. (change_softening *. 4.0 *. view.blend *. (1.0 -. view.blend)) in
  let gx_rate, gy_rate, g_offset = grain_pattern in
  let plot ~x ~y ~z ~nx ~ny ~nz =
    let dz, slope_x, slope_y = texture ~x ~y in
    let z = z +. dz in
    let nx, ny, nz = normalize (nx -. (nz *. slope_x), ny -. (nz *. slope_y), nz) in
    let nx, ny, nz = rotate view ~x:nx ~y:ny ~z:nz in
    (* A surface facing away is hidden by the slab in front of it. Without
       this, once the emblem turns, its far face shows through the grin. *)
    if nz >= 0.0
    then (
      let px, py, pz = rotate view ~x ~y ~z in
      match place raster ~x:px ~y:py ~z:pz with
      | None -> ()
      | Some i ->
        if pz > t.depth.(i)
        then (
          t.depth.(i) <- pz;
          match lighting with
          | Unlit -> ()
          | Lit { tones; fade_to } ->
            let grain =
              Float.sin ((x *. gx_rate) +. (y *. gy_rate) +. g_offset) *. grain_strength
            in
            let r, g, b = shade tones fade_to ~nx ~ny ~nz ~depth:pz ~grain in
            t.red.(i) <- r;
            t.green.(i) <- g;
            t.blue.(i) <- b))
  in
  let wall_half = half_depth -. bevel in
  let layers = Int.max 1 (Float.to_int (Float.ceil (wall_half *. 2.0 /. step))) in
  for row = 1 to grid - 2 do
    for col = 1 to grid - 2 do
      let i = (row * grid) + col in
      let d = t.shape.(i) in
      if d >= -.step
      then (
        let x = -.extent +. (Float.of_int col *. step) in
        let y = -.extent +. (Float.of_int row *. step) in
        (* The field grows inward, so its gradient points into the mark and
           the outward normal is its negative. *)
        let dx = t.shape.(i + 1) -. t.shape.(i - 1) in
        let dy = t.shape.(i + grid) -. t.shape.(i - grid) in
        let length = Float.hypot dx dy in
        let length = if length = 0.0 then 1.0 else length in
        let gx = dx /. length and gy = dy /. length in
        if d > 0.0
        then (
          (* 1.0 at the outline, 0.0 once past the bevel: how far the
             surface has rounded over. *)
          let edge = clamp01 (1.0 -. (d /. bevel)) in
          let nz = Float.sqrt (1.0 -. (edge *. edge)) in
          let z = half_depth -. bevel +. (bevel *. nz) in
          plot ~x ~y ~z ~nx:(-.gx *. edge) ~ny:(-.gy *. edge) ~nz;
          plot ~x ~y ~z:(-.z) ~nx:(-.gx *. edge) ~ny:(-.gy *. edge) ~nz:(-.nz));
        if Float.abs d < step *. wall_band
        then
          for layer = 0 to layers do
            let z =
              -.wall_half +. (Float.of_int layer /. Float.of_int layers *. wall_half *. 2.0)
            in
            plot ~x:(x -. (gx *. d)) ~y:(y -. (gy *. d)) ~z ~nx:(-.gx) ~ny:(-.gy) ~nz:0.0
          done)
    done
  done;
  let cells =
    Array.init (size.cols * size.rows) (fun index ->
      let row = index / size.cols and col = index mod size.cols in
      let bits = ref 0 and count = ref 0 in
      let r = ref 0 and g = ref 0 and b = ref 0 in
      Array.iteri
        (fun point bit ->
          let i =
            ((((row * dots_down) + (point / dots_across)) * raster.dot_cols)
             + (col * dots_across))
            + (point mod dots_across)
          in
          if Float.is_finite t.depth.(i)
          then (
            bits := !bits lor bit;
            incr count;
            r := !r + t.red.(i);
            g := !g + t.green.(i);
            b := !b + t.blue.(i)))
        dot_bits;
      let ink =
        match lighting, !count with
        | Unlit, _ | Lit _, 0 -> None
        | Lit _, n ->
          let mean total = (total + (n / 2)) / n in
          Some (Palette.make_rgb ~red:(mean !r) ~green:(mean !g) ~blue:(mean !b))
      in
      { dots = !bits; ink })
  in
  { size; cells }

(* ---- text ---- *)

let braille_blank = 0x2800

let same_colour a b =
  Palette.red a = Palette.red b
  && Palette.green a = Palette.green b
  && Palette.blue a = Palette.blue b

let lines ~ink frame =
  let { cols; rows } = frame.size in
  List.init rows (fun row ->
    let buf = Buffer.create (cols * 8) in
    (* The colour last asked for, and whether its escape was non-empty and so
       is still in effect on the terminal. *)
    let current = ref None and active = ref false in
    for col = 0 to cols - 1 do
      let cell = frame.cells.((row * cols) + col) in
      if cell.dots = 0
      then Buffer.add_char buf ' '
      else (
        (match cell.ink, !current with
         | Some colour, Some previous when same_colour colour previous -> ()
         | Some colour, (Some _ | None) ->
           let escape = ink colour in
           Buffer.add_string buf escape;
           active := String.length escape > 0;
           current := Some colour
         | None, Some _ ->
           if !active then Buffer.add_string buf Masc_tui_theme.Sgr.reset;
           active := false;
           current := None
         | None, None -> ());
        Buffer.add_utf_8_uchar buf (Uchar.of_int (braille_blank + cell.dots)))
    done;
    if !active then Buffer.add_string buf Masc_tui_theme.Sgr.reset;
    Buffer.contents buf)

let stdout_ink colour = Masc_tui_theme.Sgr.foreground (Palette.best_color colour)

module For_testing = struct
  let dot_of_front_point size pose { Shape.x; y } =
    let view = view_of pose in
    let raster = raster_of size in
    let dz, _, _ = texture ~x ~y in
    let px, py, pz = rotate view ~x ~y ~z:(half_depth +. dz) in
    match place raster ~x:px ~y:py ~z:pz with
    | None -> None
    | Some i ->
      let dot_col = i mod raster.dot_cols and dot_row = i / raster.dot_cols in
      let point = ((dot_row mod dots_down) * dots_across) + (dot_col mod dots_across) in
      Some (dot_col / dots_across, dot_row / dots_down, dot_bits.(point))
end
