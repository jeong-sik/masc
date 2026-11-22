module Theme = Masc_tui_core.Theme

type rgb = Theme.rgb

type depth =
  | Truecolor
  | Ansi256
  | Ansi16

type t =
  | Default
  | Ansi16 of int
  | Ansi256 of int
  | Rgb of rgb

let make_rgb = Theme.make_rgb
let rgb ~r ~g ~b = Rgb (make_rgb ~r ~g ~b)
let of_rgb c = Rgb c
let red = Theme.red
let green = Theme.green
let blue = Theme.blue

let ansi16_palette =
  [|
    0x000000; 0x800000; 0x008000; 0x808000;
    0x000080; 0x800080; 0x008080; 0xC0C0C0;
    0x808080; 0xFF0000; 0x00FF00; 0xFFFF00;
    0x0000FF; 0xFF00FF; 0x00FFFF; 0xFFFFFF;
  |]

let ansi16_to_rgb idx =
  let clamped = Int.max 0 (Int.min 15 idx) in
  ansi16_palette.(clamped)

let xterm_cube_levels = [| 0; 95; 135; 175; 215; 255 |]

let ansi256_palette =
  Array.init 256 (fun idx ->
      if idx < 16 then ansi16_palette.(idx)
      else if idx <= 231 then
        let offset = idx - 16 in
        let r = xterm_cube_levels.(offset / 36) in
        let g = xterm_cube_levels.((offset / 6) mod 6) in
        let b = xterm_cube_levels.(offset mod 6) in
        make_rgb ~r ~g ~b
      else
        let v = 8 + (10 * (idx - 232)) in
        make_rgb ~r:v ~g:v ~b:v)

let ansi256_to_rgb idx =
  let clamped = Int.max 0 (Int.min 255 idx) in
  ansi256_palette.(clamped)

let sq_dist c1 c2 =
  let dr = red c1 - red c2 in
  let dg = green c1 - green c2 in
  let db = blue c1 - blue c2 in
  (dr * dr) + (dg * dg) + (db * db)

let rgb_to_ansi256 target =
  let best_idx = ref 16 in
  let best_dist = ref max_int in
  for idx = 16 to 255 do
    let d = sq_dist target ansi256_palette.(idx) in
    if d < !best_dist then begin
      best_dist := d;
      best_idx := idx
    end
  done;
  !best_idx

let rgb_to_ansi16 target =
  let best_idx = ref 0 in
  let best_dist = ref max_int in
  for idx = 0 to 15 do
    let d = sq_dist target ansi16_palette.(idx) in
    if d < !best_dist then begin
      best_dist := d;
      best_idx := idx
    end
  done;
  !best_idx

let downscale ~depth color =
  match depth, color with
  | Truecolor, c -> c
  | Ansi256, Rgb c -> Ansi256 (rgb_to_ansi256 c)
  | Ansi256, ((Default | Ansi16 _ | Ansi256 _) as c) -> c
  | Ansi16, Rgb c -> Ansi16 (rgb_to_ansi16 c)
  | Ansi16, Ansi256 idx ->
      if idx >= 0 && idx < 16 then Ansi16 idx
      else Ansi16 (rgb_to_ansi16 (ansi256_to_rgb idx))
  | Ansi16, ((Default | Ansi16 _) as c) -> c

let contrast_ratio = Theme.contrast_ratio
let oklab_lightness = Theme.oklab_lightness
let lift_for_contrast = Theme.lift_for_contrast
let lerp_oklab = Theme.lerp_oklab

let equal a b =
  match a, b with
  | Default, Default -> true
  | Ansi16 x, Ansi16 y | Ansi256 x, Ansi256 y | Rgb x, Rgb y -> Int.equal x y
  | Default, (Ansi16 _ | Ansi256 _ | Rgb _)
  | Ansi16 _, (Default | Ansi256 _ | Rgb _)
  | Ansi256 _, (Default | Ansi16 _ | Rgb _)
  | Rgb _, (Default | Ansi16 _ | Ansi256 _) ->
      false
